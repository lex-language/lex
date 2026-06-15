// codegen.lex — backend do compilador-em-lex (Fase 5): AST → LLVM IR TEXTUAL.
//
// Estratégia: tudo é i64 (célula uniforme do lex); cada parâmetro/variável vira
// um `alloca` com load/store (sem SSA/phi à mão — o clang -O0 lida). Comparações
// dão i1, estendidas a i64 com zext. `main` sai como `i32` (exit code).
//
// Cobertura (F6.3 — dados + host, dirigido pela Sema):
//   - escalares: int, bool, e f64 (literal via bitcast; bits trafegam em i64);
//   - strings: literais (globais de bytes), concat/strEq/substring/charAt/str/
//     parseInt/parseFloat/peek8/len — via runtime __lex_*;
//   - arrays `T[]`: literal, .push/.pop/.len, índice `xs[i]` e `xs[i]=v`;
//   - Map: literal `{}`/`{"k":v}`, índice `m[k]`/`m[k]=v`, mapGet/mapSet/len;
//   - template `...${}...` → cadeia de concat com conversão por tipo;
//   - host: Terminal.log (por tipo), readFile/writeFile/system/args;
//   - controle (de F5): if/else, while, break/continue, return; +-*/%, comparações,
//     bitwise, &&/|| (sem curto-circuito), unários.
// Tudo é célula i64 (ponteiros como inteiros); o codegen consulta `Sema.typeOf`
// pra escolher a chamada de runtime certa. Linka `src/runtime.c` via clang.
// TODO: classes/métodos/new/match (F6.4), for, curto-circuito, aritmética f64.
//
// Espelha src/codegen.rs (que usa inkwell); aqui montamos o texto do IR e o
// clang faz o resto — mantendo a identidade "compila direto pra LLVM IR".
import { lexSrc, Tok } from "./lexer"
import {
    Expr, IntLit, FloatLit, BoolLit, StrLit, Var, Unary, Binary, Call,
    ArrayLit, Field, MethodCall, Index, MapLit, Template, Match, Lambda,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt, BreakStmt,
    ContinueStmt, ExprStmt, ForOfStmt, ForStmt, Func, Param, Program, Parser
} from "./parser"
import { Sema, Scope, ClassInfo, isArrayTy, isMapTy, isClassTy, isFunctionType, elementTy } from "./sema"

fn boolLit(b: bool): string {
    if (b) { return "1"; }
    return "0";
}

// nome de uma Var, ou "" se a expressão não for uma Var (p/ achar `Terminal.log`).
fn varName(e: Expr): string {
    return match (e) { Var v => v.name, _ => "" };
}

// ── escape de string p/ um literal de IR `c"..."` ────────────────────────────
fn irHex(b: i64): string {
    const HX: string = "0123456789ABCDEF";
    return concat(charAt(HX, b / 16), charAt(HX, b % 16));
}
fn irEscape(s: string): string {
    let out: string = "";
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(s, i);
        if (c < 32 || c > 126 || c == 34 || c == 92) {   // não-imprimível, " ou \
            out = concat(out, concat("\\", irHex(c)));
        } else {
            out = concat(out, charAt(s, i));
        }
        i = i + 1;
    }
    return out;
}

// builtin chamado por função `f(...)` → função de runtime `__lex_*` (1:1).
// "" = não é um builtin direto (len é especial; ver genLen).
fn runtimeFn(name: string): string {
    if (strEq(name, "concat")) { return "__lex_concat"; }
    if (strEq(name, "strEq")) { return "__lex_str_eq"; }
    if (strEq(name, "substring")) { return "__lex_substring"; }
    if (strEq(name, "charAt")) { return "__lex_char_at"; }
    if (strEq(name, "str")) { return "__lex_i64_to_str"; }
    if (strEq(name, "parseInt")) { return "__lex_parse_int"; }
    if (strEq(name, "parseFloat")) { return "__lex_parse_float"; }
    if (strEq(name, "peek8")) { return "__lex_peek8"; }
    if (strEq(name, "readFile")) { return "__lex_fs_read"; }
    if (strEq(name, "writeFile")) { return "__lex_fs_write"; }
    if (strEq(name, "system")) { return "__lex_system"; }
    if (strEq(name, "args")) { return "__lex_args"; }
    if (strEq(name, "mapGet")) { return "__lex_map_get"; }
    if (strEq(name, "mapSet")) { return "__lex_map_set"; }
    // json / any (boxing comparado por valor)
    if (strEq(name, "jsonEq")) { return "__lex_json_eq"; }
    if (strEq(name, "jsonAsInt")) { return "__lex_json_as_int"; }
    if (strEq(name, "jsonAsFloat")) { return "__lex_json_as_float"; }
    if (strEq(name, "jsonAsStr")) { return "__lex_json_as_str"; }
    if (strEq(name, "jsonStringify")) { return "__lex_json_stringify"; }
    if (strEq(name, "jsonNum")) { return "__lex_json_num"; }
    if (strEq(name, "jsonStr")) { return "__lex_json_str"; }
    if (strEq(name, "jsonFloat")) { return "__lex_json_float"; }
    if (strEq(name, "jsonBool")) { return "__lex_json_bool"; }
    return "";
}

// ── coleta de variáveis locais (p/ hoistar as alloca pro bloco entry) ────────
// LLVM exige nomes SSA únicos por função; um `let x` em blocos irmãos geraria
// duas `%x.addr = alloca`. Hoistamos uma alloca por nome no entry (domina tudo).
fn addUniq(names: string[], n: string): i64 {
    for (const x of names) { if (strEq(x, n)) { return 0; } }
    names.push(n);
    return 0;
}
fn collectStmtLocal(s: Stmt, names: string[]): i64 {
    return match (s) { LetStmt l => addUniq(names, l.name), _ => 0 };
}
fn collectLocals(stmts: Stmt[], names: string[]): i64 {
    for (const s of stmts) {
        match (s) {
            LetStmt l => addUniq(names, l.name),
            ForOfStmt fo => collectForOf(fo, names),
            ForStmt fr => collectForC(fr, names),
            IfStmt f => collectIf(f, names),
            WhileStmt w => collectLocals(w.body, names),
            _ => 0
        };
    }
    return 0;
}
fn collectForOf(fo: ForOfStmt, names: string[]): i64 {
    addUniq(names, fo.name);
    return collectLocals(fo.body, names);
}
fn collectForC(fr: ForStmt, names: string[]): i64 {
    if (fr.hasInit) { collectStmtLocal(fr.init, names); }
    return collectLocals(fr.body, names);
}
fn collectIf(f: IfStmt, names: string[]): i64 {
    collectLocals(f.thenB, names);
    return collectLocals(f.elseB, names);
}

class Codegen {
    out: string
    tmp: i64           // contador de temporários SSA (%tN)
    lbl: i64           // contador de labels (LN)
    term: bool         // o bloco básico atual já terminou (ret/br)?
    curMain: bool      // estamos gerando o `main` (retorno i32)?
    loopCond: string[] // pilha de labels de condição (continue)
    loopEnd: string[]  // pilha de labels de saída (break)
    sema: Sema         // tabela de classes/tipos (dirige a escolha de runtime)
    scope: Scope       // tipos das variáveis no escopo atual
    strs: string[]     // globais de string literais (emitidos no fim do módulo)
    strN: i64          // contador de string literais
    matchN: i64        // contador de blocos de match (nomes únicos)
    bindNames: string[] // pilha de bindings de match (nome → endereço)
    bindAddrs: string[]

    constructor(sema: Sema) {
        this.out = ""
        this.tmp = 0
        this.lbl = 0
        this.term = false
        this.curMain = false
        this.loopCond = []
        this.loopEnd = []
        this.sema = sema
        this.scope = new Scope()
        this.strs = []
        this.strN = 0
        this.matchN = 0
        this.bindNames = []
        this.bindAddrs = []
    }

    // instrução normal: pulada se o bloco já terminou (código morto)
    emit(line: string) {
        if (this.term) { return; }
        this.out = concat(this.out, concat(line, "\n"));
    }
    // linha estrutural (define/label/}): sempre escrita
    raw(line: string) {
        this.out = concat(this.out, concat(line, "\n"));
    }
    newTmp(): string {
        const r: string = concat("%t", str(this.tmp));
        this.tmp = this.tmp + 1;
        return r;
    }
    newLabel(): string {
        const r: string = concat("L", str(this.lbl));
        this.lbl = this.lbl + 1;
        return r;
    }
    label(name: string) {            // inicia um novo bloco básico
        this.out = concat(this.out, concat(name, ":\n"));
        this.term = false;
    }

    // ── expressões → devolve o operando (um %tN ou um imediato como "42") ────
    bin(opc: string, l: string, r: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = ${opc} i64 ${l}, ${r}`);
        return t;
    }
    cmp(pred: string, l: string, r: string): string {
        const c: string = this.newTmp();
        this.emit(`  ${c} = icmp ${pred} i64 ${l}, ${r}`);
        const t: string = this.newTmp();
        this.emit(`  ${t} = zext i1 ${c} to i64`);
        return t;
    }
    // normaliza um i64 qualquer para 0/1 (verdade lógica)
    truth(v: string): string {
        const c: string = this.newTmp();
        this.emit(`  ${c} = icmp ne i64 ${v}, 0`);
        const t: string = this.newTmp();
        this.emit(`  ${t} = zext i1 ${c} to i64`);
        return t;
    }

    // endereço de uma variável: binding de match (se houver) ou `%nome.addr`.
    varAddrOf(name: string): string {
        let i: i64 = this.bindNames.len() - 1;
        while (i >= 0) {
            if (strEq(this.bindNames[i], name)) { return this.bindAddrs[i]; }
            i = i - 1;
        }
        return concat("%", concat(name, ".addr"));
    }
    bindPush(name: string, addr: string, ty: string) {
        this.bindNames.push(name);
        this.bindAddrs.push(addr);
        if (!strEq(name, "")) { this.scope.set(name, ty); }
    }
    bindPop() {
        const n: i64 = this.bindNames.len();
        if (n > 0) { this.bindNames.pop(); this.bindAddrs.pop(); }
    }

    genLoad(name: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = load i64, ptr ${this.varAddrOf(name)}`);
        return t;
    }

    genUnary(u: Unary): string {
        const v: string = this.genExpr(u.operand);
        if (u.op == Tok.Minus) { return this.bin("sub", "0", v); }
        if (u.op == Tok.Tilde) { return this.bin("xor", v, "-1"); }   // ~v = v ^ -1
        if (u.op == Tok.Bang) {
            const c: string = this.newTmp();
            this.emit(`  ${c} = icmp eq i64 ${v}, 0`);
            const t: string = this.newTmp();
            this.emit(`  ${t} = zext i1 ${c} to i64`);
            return t;
        }
        return v;
    }

    genBinary(b: Binary): string {
        const l: string = this.genExpr(b.lhs);
        const r: string = this.genExpr(b.rhs);
        const op: Tok = b.op;
        if (op == Tok.Plus) { return this.bin("add", l, r); }
        if (op == Tok.Minus) { return this.bin("sub", l, r); }
        if (op == Tok.Star) { return this.bin("mul", l, r); }
        if (op == Tok.Slash) { return this.bin("sdiv", l, r); }
        if (op == Tok.Percent) { return this.bin("srem", l, r); }
        if (op == Tok.EqEq) { return this.cmp("eq", l, r); }
        if (op == Tok.Neq) { return this.cmp("ne", l, r); }
        if (op == Tok.Lt) { return this.cmp("slt", l, r); }
        if (op == Tok.Gt) { return this.cmp("sgt", l, r); }
        if (op == Tok.Le) { return this.cmp("sle", l, r); }
        if (op == Tok.Ge) { return this.cmp("sge", l, r); }
        // bitwise
        if (op == Tok.Amp) { return this.bin("and", l, r); }
        if (op == Tok.Pipe) { return this.bin("or", l, r); }
        if (op == Tok.Caret) { return this.bin("xor", l, r); }
        if (op == Tok.Shl) { return this.bin("shl", l, r); }
        if (op == Tok.Shr) { return this.bin("ashr", l, r); }   // shift aritmético (sinal)
        // lógicos (sem curto-circuito por ora: normaliza p/ 0/1 e and/or — TODO)
        if (op == Tok.AmpAmp) { return this.bin("and", this.truth(l), this.truth(r)); }
        if (op == Tok.PipePipe) { return this.bin("or", this.truth(l), this.truth(r)); }
        return "0";
    }

    // float literal → bits do double como i64 (modelo do runtime: f64 trafega em
    // i64). `${value}` formata o f64 em decimal (o compilador host lê via double).
    // OBS: exige literal exatamente representável (0.0, 2.5, …); aritmética f64
    // não é suportada no subset (o compilador-fonte só carrega/imprime floats).
    genFloatLit(value: f64): string {
        return `bitcast (double ${value} to i64)`;
    }

    // template `...${e}...` → cadeia de concat; cada interpolação é convertida a
    // string conforme o tipo (string como está; f64 via f64_to_str; resto i64_to_str).
    tplPart(e: Expr): string {
        const ty: string = this.sema.typeOf(e, this.scope);
        const v: string = this.genExpr(e);
        if (strEq(ty, "string")) { return v; }
        if (strEq(ty, "f64")) { return this.emitCall("__lex_f64_to_str", concat("i64 ", v)); }
        return this.emitCall("__lex_i64_to_str", concat("i64 ", v));
    }
    genTemplate(t: Template): string {
        if (t.parts.len() == 0) { return this.genStrLit(""); }
        let acc: string = this.tplPart(t.parts[0]);
        let i: i64 = 1;
        while (i < t.parts.len()) {
            const p: string = this.tplPart(t.parts[i]);
            acc = this.emitCall("__lex_concat", `i64 ${acc}, i64 ${p}`);
            i = i + 1;
        }
        return acc;
    }

    // string literal → global de bytes; devolve o operando i64 (ponteiro).
    genStrLit(value: string): string {
        const name: string = concat("@.str", str(this.strN));
        this.strN = this.strN + 1;
        const nbytes: i64 = len(value) + 1;
        this.strs.push(`${name} = private unnamed_addr constant [${nbytes} x i8] c"${irEscape(value)}\\00"`);
        return `ptrtoint (ptr ${name} to i64)`;
    }

    // emite `%t = call i64 @rfn(argStr)` e devolve o temporário.
    emitCall(rfn: string, argStr: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = call i64 @${rfn}(${argStr})`);
        return t;
    }
    // gera cada arg como i64 e junta em "i64 a, i64 b, …".
    argList(args: Expr[]): string {
        let s: string = "";
        let first: bool = true;
        for (const a of args) {
            const v: string = this.genExpr(a);
            if (!first) { s = concat(s, ", "); }
            s = concat(s, concat("i64 ", v));
            first = false;
        }
        return s;
    }
    callRuntime(rfn: string, args: Expr[]): string {
        return this.emitCall(rfn, this.argList(args));
    }

    // gera um arg; se o parâmetro é `any` e o valor é concreto, BOX num LexJson
    // do runtime (tag+payload) — assim `jsonEq` compara por valor (int/str/float).
    boxArg(a: Expr, paramTy: string): string {
        const v: string = this.genExpr(a);
        if (!strEq(paramTy, "any")) { return v; }
        const at: string = this.sema.typeOf(a, this.scope);
        if (strEq(at, "any")) { return v; }                                  // já é any
        if (strEq(at, "string")) { return this.emitCall("__lex_json_str", concat("i64 ", v)); }
        if (strEq(at, "f64")) { return this.emitCall("__lex_json_float", concat("i64 ", v)); }
        if (strEq(at, "bool")) { return this.emitCall("__lex_json_bool", concat("i64 ", v)); }
        if (strEq(at, "i64")) { return this.emitCall("__lex_json_num", concat("i64 ", v)); }
        return v;                                                            // classe/array/map: best-effort sem box
    }
    // lista de args com boxing por tipo de parâmetro (ptypes[i]); "" = sem box.
    argListBoxed(args: Expr[], ptypes: string[]): string {
        let s: string = "";
        let first: bool = true;
        let i: i64 = 0;
        for (const a of args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            if (!first) { s = concat(s, ", "); }
            s = concat(s, concat("i64 ", this.boxArg(a, pt)));
            first = false;
            i = i + 1;
        }
        return s;
    }

    // len(x): strlen / arr_len / map_len conforme o tipo de x.
    genLen(c: Call): string {
        const ty: string = this.sema.typeOf(c.args[0], this.scope);
        let rfn: string = "__lex_strlen";
        if (isArrayTy(ty)) { rfn = "__lex_arr_len"; }
        else if (isMapTy(ty)) { rfn = "__lex_map_len"; }
        return this.callRuntime(rfn, c.args);
    }

    // Terminal.log(x): imprime conforme o tipo de x (string/f64/inteiro) + \n.
    genTerminalLog(args: Expr[]): string {
        if (args.len() == 0) { return "0"; }
        const ty: string = this.sema.typeOf(args[0], this.scope);
        const v: string = this.genExpr(args[0]);
        if (strEq(ty, "string")) {
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_str, i64 ${v})`);
        } else if (strEq(ty, "f64")) {
            const s: string = this.emitCall("__lex_f64_to_str", concat("i64 ", v));
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_str, i64 ${s})`);
        } else {
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_int, i64 ${v})`);
        }
        return "0";
    }

    genCall(c: Call): string {
        // chamada INDIRETA: c.name é uma variável de tipo função (arrow recebido)
        if (isFunctionType(this.scope.get(c.name))) {
            const fp: string = this.genLoad(c.name);
            const fpp: string = this.newTmp();
            this.emit(`  ${fpp} = inttoptr i64 ${fp} to ptr`);
            const t: string = this.newTmp();
            this.emit(`  ${t} = call i64 ${fpp}(${this.argList(c.args)})`);
            return t;
        }
        // print(x): imprime um i64 via printf da libc (saída de verdade).
        if (strEq(c.name, "print")) {
            let v: string = "0";
            if (c.args.len() >= 1) { v = this.genExpr(c.args[0]); }
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_int, i64 ${v})`);
            return "0";
        }
        if (strEq(c.name, "len")) { return this.genLen(c); }
        const rt: string = runtimeFn(c.name);
        if (!strEq(rt, "")) { return this.callRuntime(rt, c.args); }
        // chamada a função do usuário (boxando args `any`)
        return this.emitCall(c.name, this.argListBoxed(c.args, this.sema.funcParamTypes(c.name)));
    }

    // chamadas de método: Terminal.log e (Stage B/C) coleções; resto → F6.4.
    genMethodCall(m: MethodCall): string {
        if (strEq(varName(m.base), "Terminal") && strEq(m.method, "log")) {
            return this.genTerminalLog(m.args);
        }
        const baseTy: string = this.sema.typeOf(m.base, this.scope);
        const bv: string = this.genExpr(m.base);
        if (strEq(m.method, "len")) {
            let rfn: string = "__lex_strlen";
            if (isArrayTy(baseTy)) { rfn = "__lex_arr_len"; }
            else if (isMapTy(baseTy)) { rfn = "__lex_map_len"; }
            return this.emitCall(rfn, concat("i64 ", bv));
        }
        if (strEq(m.method, "push")) {
            let v: string = "0";
            if (m.args.len() >= 1) { v = this.genExpr(m.args[0]); }
            this.emit(`  call i64 @__lex_arr_push(i64 ${bv}, i64 ${v})`);
            return "0";
        }
        if (strEq(m.method, "pop")) {
            return this.emitCall("__lex_arr_pop", concat("i64 ", bv));
        }
        // método de classe: dispatch estático @Dono.metodo(this, args…)
        if (isClassTy(baseTy) && this.sema.classes.findInfo(baseTy) >= 0) {
            const owner: string = this.sema.classes.methodOwner(baseTy, m.method);
            if (!strEq(owner, "")) {
                const ptypes: string[] = this.sema.methodParamTypes(baseTy, m.method);
                let argStr: string = concat("i64 ", bv);
                let i: i64 = 0;
                for (const a of m.args) {
                    let pt: string = "";
                    if (i < ptypes.len()) { pt = ptypes[i]; }
                    argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
                    i = i + 1;
                }
                return this.emitCall(concat(owner, concat(".", m.method)), argStr);
            }
        }
        return "0";
    }

    // [a, b, c] → arr_new(n) + arr_push por item; devolve o ponteiro do array.
    genArrayLit(a: ArrayLit): string {
        const arr: string = this.emitCall("__lex_arr_new", concat("i64 ", str(a.items.len())));
        for (const it of a.items) {
            const v: string = this.genExpr(it);
            this.emit(`  call i64 @__lex_arr_push(i64 ${arr}, i64 ${v})`);
        }
        return arr;
    }

    // {} / {"k": v, …} → map_new + map_set por entrada; devolve o ponteiro do map.
    genMapLit(ml: MapLit): string {
        const m: string = this.emitCall("__lex_map_new", "");
        let i: i64 = 0;
        while (i < ml.mapKeys.len()) {
            const k: string = this.genStrLit(ml.mapKeys[i]);
            const v: string = this.genExpr(ml.vals[i]);
            this.emit(`  call i64 @__lex_map_set(i64 ${m}, i64 ${k}, i64 ${v})`);
            i = i + 1;
        }
        return m;
    }

    // base[idx]: arr_get / map_get / char_at conforme o tipo da base.
    genIndex(ix: Index): string {
        const baseTy: string = this.sema.typeOf(ix.base, this.scope);
        const b: string = this.genExpr(ix.base);
        const i: string = this.genExpr(ix.index);
        let rfn: string = "__lex_arr_get";
        if (isMapTy(baseTy)) { rfn = "__lex_map_get"; }
        else if (strEq(baseTy, "string")) { rfn = "__lex_char_at"; }
        return this.emitCall(rfn, `i64 ${b}, i64 ${i}`);
    }

    // base[idx] = valor: arr_set / map_set (base, idx, valor) — nessa ordem.
    genIndexAssign(ix: Index, valExpr: Expr): i64 {
        const baseTy: string = this.sema.typeOf(ix.base, this.scope);
        const b: string = this.genExpr(ix.base);
        const i: string = this.genExpr(ix.index);
        const v: string = this.genExpr(valExpr);
        let rfn: string = "__lex_arr_set";
        if (isMapTy(baseTy)) { rfn = "__lex_map_set"; }
        this.emit(`  call i64 @${rfn}(i64 ${b}, i64 ${i}, i64 ${v})`);
        return 0;
    }

    // endereço do slot `slot` do objeto `objVal` (i64 ptr). slot 0 = a própria base.
    slotAddr(objVal: string, slot: i64): string {
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${objVal} to ptr`);
        if (slot == 0) { return p; }
        const ep: string = this.newTmp();
        this.emit(`  ${ep} = getelementptr i64, ptr ${p}, i64 ${slot}`);
        return ep;
    }

    // obj.campo: membro de enum (Tok.Newline → inteiro) ou load do slot do campo.
    genField(f: Field): string {
        const ev: i64 = this.sema.enums.value(varName(f.base), f.field);
        if (ev >= 0) { return str(ev); }
        const baseTy: string = this.sema.typeOf(f.base, this.scope);
        const b: string = this.genExpr(f.base);
        const slot: i64 = this.sema.classes.fieldSlot(baseTy, f.field);
        const addr: string = this.slotAddr(b, slot);
        const v: string = this.newTmp();
        this.emit(`  ${v} = load i64, ptr ${addr}`);
        return v;
    }

    // obj.campo = valor: store no slot do campo.
    genFieldAssign(f: Field, valExpr: Expr): i64 {
        const baseTy: string = this.sema.typeOf(f.base, this.scope);
        const b: string = this.genExpr(f.base);
        const slot: i64 = this.sema.classes.fieldSlot(baseTy, f.field);
        const v: string = this.boxArg(valExpr, this.sema.classes.fieldType(baseTy, f.field));  // boxa se o campo é `any`
        const addr: string = this.slotAddr(b, slot);
        this.emit(`  store i64 ${v}, ptr ${addr}`);
        return 0;
    }

    // new C(args): aloca nslots*8 bytes, grava a tag no slot 0, chama o constructor.
    genNew(ne: NewExpr): string {
        const ci: ClassInfo = this.sema.classes.find(ne.cls);
        const obj: string = this.emitCall("__lex_alloc", concat("i64 ", str(ci.nslots * 8)));
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${obj} to ptr`);
        this.emit(`  store i64 ${ci.tag}, ptr ${p}`);
        const owner: string = this.sema.classes.methodOwner(ne.cls, "constructor");
        if (!strEq(owner, "")) {
            const ptypes: string[] = this.sema.methodParamTypes(ne.cls, "constructor");
            let argStr: string = concat("i64 ", obj);
            let i: i64 = 0;
            for (const a of ne.args) {
                let pt: string = "";
                if (i < ptypes.len()) { pt = ptypes[i]; }
                argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
                i = i + 1;
            }
            this.emitCall(concat(owner, ".constructor"), argStr);
        }
        return obj;
    }

    genExpr(e: Expr): string {
        return match (e) {
            IntLit n => str(n.value),
            FloatLit f => this.genFloatLit(f.value),
            BoolLit b => boolLit(b.value),
            StrLit s => this.genStrLit(s.value),
            Template t => this.genTemplate(t),
            Var v => this.genLoad(v.name),
            Unary u => this.genUnary(u),
            Binary b => this.genBinary(b),
            Call c => this.genCall(c),
            MethodCall m => this.genMethodCall(m),
            ArrayLit a => this.genArrayLit(a),
            MapLit ml => this.genMapLit(ml),
            Index ix => this.genIndex(ix),
            NewExpr ne => this.genNew(ne),
            Field f => this.genField(f),
            Match mt => this.genMatch(mt),
            Lambda lm => `ptrtoint (ptr @${lm.fnName} to i64)`,
            _ => "0"
        };
    }

    // ── statements (devolvem i64 dummy p/ caberem no match-expressão) ────────
    storeVar(name: string, v: string): i64 {
        this.emit(`  store i64 ${v}, ptr ${this.varAddrOf(name)}`);
        return 0;
    }

    genLet(l: LetStmt): i64 {
        // tipo: anotação, ou inferido do valor (com o escopo ANTES de l)
        let ty: string = l.ty;
        if (strEq(ty, "")) { ty = this.sema.typeOf(l.value, this.scope); }
        const v: string = this.genExpr(l.value);
        this.emit(`  store i64 ${v}, ptr ${this.varAddrOf(l.name)}`);   // alloca hoistada no entry
        this.scope.set(l.name, ty);
        return 0;
    }

    genAssign(a: AssignStmt): i64 {
        return match (a.target) {
            Var vv => this.storeVar(vv.name, this.genExpr(a.value)),
            Index ix => this.genIndexAssign(ix, a.value),
            Field f => this.genFieldAssign(f, a.value),
            _ => 0
        };
    }

    genReturn(r: ReturnStmt): i64 {
        let val: string = "0";
        if (r.hasValue) { val = this.genExpr(r.value); }
        if (this.curMain) {
            const t: string = this.newTmp();
            this.emit(`  ${t} = trunc i64 ${val} to i32`);
            this.emit(`  ret i32 ${t}`);
        } else {
            this.emit(`  ret i64 ${val}`);
        }
        this.term = true;
        return 0;
    }

    genStmts(list: Stmt[]): i64 {
        for (const s of list) { this.genStmt(s); }
        return 0;
    }

    genIf(f: IfStmt): i64 {
        const c: string = this.genExpr(f.cond);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
        const lt: string = this.newLabel();
        const lend: string = this.newLabel();
        const hasElse: bool = f.elseB.len() > 0;
        let le: string = lend;
        if (hasElse) { le = this.newLabel(); }
        this.emit(`  br i1 ${cb}, label %${lt}, label %${le}`);
        this.term = true;

        this.label(lt);
        this.genStmts(f.thenB);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }

        if (hasElse) {
            this.label(le);
            this.genStmts(f.elseB);
            if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
        }
        this.label(lend);
        return 0;
    }

    genWhile(w: WhileStmt): i64 {
        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`);
        this.term = true;

        this.label(lcond);
        const c: string = this.genExpr(w.cond);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
        this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`);
        this.term = true;

        this.label(lbody);
        this.loopCond.push(lcond);
        this.loopEnd.push(lend);
        this.genStmts(w.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) { this.emit(`  br label %${lcond}`); this.term = true; }

        this.label(lend);
        return 0;
    }

    // for (const x of xs) { ... } → i=0; while i<len(xs) { x=xs[i]; corpo; i++ }
    genForOf(fo: ForOfStmt): i64 {
        const iterTy: string = this.sema.typeOf(fo.iter, this.scope);
        const iter: string = this.genExpr(fo.iter);       // ponteiro do array (SSA, domina o laço)
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const ia: string = `%fo${id}.i.addr`;
        const xa: string = this.varAddrOf(fo.name);     // alloca hoistada no entry
        this.emit(`  ${ia} = alloca i64`);
        this.emit(`  store i64 0, ptr ${ia}`);
        this.scope.set(fo.name, elementTy(iterTy));

        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lcond);
        const iv: string = this.newTmp();
        this.emit(`  ${iv} = load i64, ptr ${ia}`);
        const nv: string = this.emitCall("__lex_arr_len", concat("i64 ", iter));
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp slt i64 ${iv}, ${nv}`);
        this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`); this.term = true;

        this.label(lbody);
        const ev: string = this.emitCall("__lex_arr_get", `i64 ${iter}, i64 ${iv}`);
        this.emit(`  store i64 ${ev}, ptr ${xa}`);
        this.loopCond.push(lcond);
        this.loopEnd.push(lend);
        this.genStmts(fo.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) {
            const i2: string = this.newTmp();
            this.emit(`  ${i2} = load i64, ptr ${ia}`);
            const i3: string = this.bin("add", i2, "1");
            this.emit(`  store i64 ${i3}, ptr ${ia}`);
            this.emit(`  br label %${lcond}`); this.term = true;
        }
        this.label(lend);
        return 0;
    }

    // for (init; cond; update) { ... } — continue salta p/ o update.
    genFor(fr: ForStmt): i64 {
        if (fr.hasInit) { this.genStmt(fr.init); }
        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lupd: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lcond);
        if (fr.hasCond) {
            const c: string = this.genExpr(fr.cond);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
            this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`);
        } else {
            this.emit(`  br label %${lbody}`);
        }
        this.term = true;

        this.label(lbody);
        this.loopCond.push(lupd);
        this.loopEnd.push(lend);
        this.genStmts(fr.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) { this.emit(`  br label %${lupd}`); this.term = true; }

        this.label(lupd);
        if (fr.hasUpdate) { this.genStmt(fr.update); }
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lend);
        return 0;
    }

    genBreak(): i64 {
        const n: i64 = this.loopEnd.len();
        if (n > 0) { this.emit(`  br label %${this.loopEnd[n - 1]}`); this.term = true; }
        return 0;
    }
    genContinue(): i64 {
        const n: i64 = this.loopCond.len();
        if (n > 0) { this.emit(`  br label %${this.loopCond[n - 1]}`); this.term = true; }
        return 0;
    }
    genExprStmt(e: ExprStmt): i64 {
        this.genExpr(e.expr);
        return 0;
    }

    genStmt(s: Stmt): i64 {
        return match (s) {
            LetStmt l => this.genLet(l),
            AssignStmt a => this.genAssign(a),
            ReturnStmt r => this.genReturn(r),
            IfStmt f => this.genIf(f),
            WhileStmt w => this.genWhile(w),
            ForOfStmt fo => this.genForOf(fo),
            ForStmt fr => this.genFor(fr),
            BreakStmt b => this.genBreak(),
            ContinueStmt c => this.genContinue(),
            ExprStmt e => this.genExprStmt(e),
            _ => 0
        };
    }

    // match (subj) { Classe bind => corpo, _ => corpo } como EXPRESSÃO.
    // Carrega a tag (slot 0 do objeto) e compara com a tag de cada classe; o
    // resultado do braço que casar vai p/ um alloca, lido no fim (sem phi).
    genMatch(mt: Match): string {
        const subj: string = this.genExpr(mt.subject);
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const sa: string = `%msubj${id}.addr`;
        const ra: string = `%mres${id}.addr`;
        this.emit(`  ${sa} = alloca i64`);
        this.emit(`  store i64 ${subj}, ptr ${sa}`);
        this.emit(`  ${ra} = alloca i64`);
        // tag = load slot 0
        const sp: string = this.newTmp();
        this.emit(`  ${sp} = inttoptr i64 ${subj} to ptr`);
        const tag: string = this.newTmp();
        this.emit(`  ${tag} = load i64, ptr ${sp}`);

        const lend: string = this.newLabel();
        for (const arm of mt.arms) {
            if (strEq(arm.pat, "_")) {
                this.bindPush(arm.bind, sa, "?");
                const v: string = this.genExpr(arm.body);
                this.bindPop();
                this.emit(`  store i64 ${v}, ptr ${ra}`);
                if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
            } else {
                const at: i64 = this.sema.classes.indexOfDecl(arm.pat);
                const cb: string = this.newTmp();
                this.emit(`  ${cb} = icmp eq i64 ${tag}, ${at}`);
                const lyes: string = this.newLabel();
                const lno: string = this.newLabel();
                this.emit(`  br i1 ${cb}, label %${lyes}, label %${lno}`);
                this.term = true;
                this.label(lyes);
                this.bindPush(arm.bind, sa, arm.pat);
                const v: string = this.genExpr(arm.body);
                this.bindPop();
                this.emit(`  store i64 ${v}, ptr ${ra}`);
                if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
                this.label(lno);
            }
        }
        // nenhum braço casou (sem curinga): resultado 0
        this.emit(`  store i64 0, ptr ${ra}`);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
        this.label(lend);
        const res: string = this.newTmp();
        this.emit(`  ${res} = load i64, ptr ${ra}`);
        return res;
    }

    // método de classe: como genFunc, mas com `this` como 1º parâmetro.
    genMethod(cls: string, f: Func): i64 {
        this.tmp = 0;
        this.lbl = 0;
        this.term = false;
        this.curMain = false;
        this.scope = new Scope();
        this.scope.set("this", cls);
        for (const p of f.params) { this.scope.set(p.name, p.ty); }

        let ps: string = "i64 %this";
        for (const p of f.params) { ps = concat(ps, concat(", i64 %", p.name)); }
        this.raw(`define i64 @${cls}.${f.name}(${ps}) {`);
        this.term = false;   // 1º bloco implícito
        let locals: string[] = [];
        addUniq(locals, "this");
        for (const p of f.params) { addUniq(locals, p.name); }
        collectLocals(f.body, locals);
        for (const lnm of locals) { this.emit(`  %${lnm}.addr = alloca i64`); }
        this.emit(`  store i64 %this, ptr %this.addr`);
        for (const p of f.params) {
            this.emit(`  store i64 %${p.name}, ptr %${p.name}.addr`);
        }
        this.genStmts(f.body);
        if (!this.term) { this.emit("  ret i64 0"); this.term = true; }
        this.raw("}");
        this.raw("");
        return 0;
    }

    genFunc(f: Func): i64 {
        this.tmp = 0;
        this.lbl = 0;
        this.term = false;
        this.curMain = strEq(f.name, "main");
        this.scope = new Scope();
        for (const p of f.params) { this.scope.set(p.name, p.ty); }

        let ps: string = "";
        let first: bool = true;
        for (const p of f.params) {
            if (!first) { ps = concat(ps, ", "); }
            ps = concat(ps, concat("i64 %", p.name));
            first = false;
        }
        let retTy: string = "i64";
        if (this.curMain) { retTy = "i32"; }

        this.raw(`define ${retTy} @${f.name}(${ps}) {`);
        this.term = false;   // 1º bloco é implícito (não rotular: 'entry' colidiria c/ params)

        // hoista uma alloca por nome de local (params + lets + for-of) no entry
        let locals: string[] = [];
        for (const p of f.params) { addUniq(locals, p.name); }
        collectLocals(f.body, locals);
        for (const lnm of locals) { this.emit(`  %${lnm}.addr = alloca i64`); }
        for (const p of f.params) {
            this.emit(`  store i64 %${p.name}, ptr %${p.name}.addr`);
        }

        this.genStmts(f.body);

        if (!this.term) {
            if (this.curMain) { this.emit("  ret i32 0"); }
            else { this.emit("  ret i64 0"); }
            this.term = true;
        }
        this.raw("}");
        this.raw("");
        return 0;
    }

    genProgram(prog: Program): i64 {
        // preâmbulo: formatos de print + printf + declarações do runtime (__lex_*).
        // Tudo trafega i64 (ponteiros como inteiros); as funções void do runtime
        // (arr_push/set, map_set) são declaradas i64 e o retorno é ignorado.
        this.raw("@.lex_fmt_int = private unnamed_addr constant [6 x i8] c\"%lld\\0A\\00\"");
        this.raw("@.lex_fmt_str = private unnamed_addr constant [4 x i8] c\"%s\\0A\\00\"");
        this.raw("declare i32 @printf(ptr, ...)");
        this.raw("declare i64 @__lex_concat(i64, i64)");
        this.raw("declare i64 @__lex_strlen(i64)");
        this.raw("declare i64 @__lex_str_eq(i64, i64)");
        this.raw("declare i64 @__lex_substring(i64, i64, i64)");
        this.raw("declare i64 @__lex_char_at(i64, i64)");
        this.raw("declare i64 @__lex_i64_to_str(i64)");
        this.raw("declare i64 @__lex_f64_to_str(i64)");
        this.raw("declare i64 @__lex_parse_int(i64)");
        this.raw("declare i64 @__lex_parse_float(i64)");
        this.raw("declare i64 @__lex_peek8(i64, i64)");
        this.raw("declare i64 @__lex_arr_new(i64)");
        this.raw("declare i64 @__lex_arr_len(i64)");
        this.raw("declare i64 @__lex_arr_push(i64, i64)");
        this.raw("declare i64 @__lex_arr_pop(i64)");
        this.raw("declare i64 @__lex_arr_get(i64, i64)");
        this.raw("declare i64 @__lex_arr_set(i64, i64, i64)");
        this.raw("declare i64 @__lex_map_new()");
        this.raw("declare i64 @__lex_map_get(i64, i64)");
        this.raw("declare i64 @__lex_map_set(i64, i64, i64)");
        this.raw("declare i64 @__lex_map_len(i64)");
        this.raw("declare i64 @__lex_alloc(i64)");
        this.raw("declare i64 @__lex_fs_read(i64)");
        this.raw("declare i64 @__lex_fs_write(i64, i64)");
        this.raw("declare i64 @__lex_system(i64)");
        this.raw("declare i64 @__lex_args()");
        this.raw("declare i64 @__lex_json_num(i64)");
        this.raw("declare i64 @__lex_json_float(i64)");
        this.raw("declare i64 @__lex_json_str(i64)");
        this.raw("declare i64 @__lex_json_bool(i64)");
        this.raw("declare i64 @__lex_json_eq(i64, i64)");
        this.raw("declare i64 @__lex_json_as_int(i64)");
        this.raw("declare i64 @__lex_json_as_float(i64)");
        this.raw("declare i64 @__lex_json_as_str(i64)");
        this.raw("declare i64 @__lex_json_stringify(i64)");
        this.raw("");
        // métodos de classe (dispatch estático): @Classe.metodo(i64 %this, …)
        for (const c of prog.classes) {
            for (const mm of c.methods) { this.genMethod(c.name, mm); }
        }
        for (const f of prog.funcs) { this.genFunc(f); }
        // script-mode: statements de topo viram o `main` (i32). Convenção do lex:
        // ou há `fn main` explícito (já em funcs), ou statements de topo — não os dois.
        if (prog.main.len() > 0) {
            let pp: Param[] = [];
            const mainFn: Func = new Func("main", pp, "i32", false, prog.main);
            this.genFunc(mainFn);
        }
        // globais de string literais (ordem livre no módulo → no fim)
        for (const g of this.strs) { this.raw(g); }
        return 0;
    }
}

// Program já parseado → texto do LLVM IR (usado pelo driver multi-arquivo).
fn compileProgramToIR(prog: Program): string {
    const sema: Sema = new Sema(prog);
    const cg: Codegen = new Codegen(sema);
    cg.genProgram(prog);
    return cg.out;
}

// Conveniência: fonte lex (um módulo) → texto do LLVM IR.
fn compileToIR(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return compileProgramToIR(p.parseModule());
}
