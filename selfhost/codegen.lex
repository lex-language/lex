// codegen.lex — backend do compilador-em-lex (Fase 5): AST → LLVM IR TEXTUAL.
//
// Estratégia: tudo é i64 (célula uniforme do lex); cada parâmetro/variável vira
// um `alloca` com load/store (sem SSA/phi à mão — o clang -O0 lida). Comparações
// dão i1, estendidas a i64 com zext. `main` sai como `i32` (exit code).
//
// Subset suportado: funções com params i64; let/const, atribuição a variável,
// return, if/else, while, break/continue, expr-statement; expressões: int/bool,
// variáveis, + - * / %, == != < > <= >=, unários (- !), e chamadas a funções.
// TODO: float/string/arrays/structs/classes, &&/||, bitwise, for, e o resto.
//
// Espelha src/codegen.rs (que usa inkwell); aqui montamos o texto do IR e o
// clang faz o resto — mantendo a identidade "compila direto pra LLVM IR".
import { lexSrc, Tok } from "./lexer"
import {
    Expr, IntLit, FloatLit, BoolLit, StrLit, Var, Unary, Binary, Call,
    ArrayLit, Field, MethodCall, Index,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt, BreakStmt,
    ContinueStmt, ExprStmt, Func, Param, Parser
} from "./parser"

fn boolLit(b: bool): string {
    if (b) { return "1"; }
    return "0";
}

class Codegen {
    out: string
    tmp: i64           // contador de temporários SSA (%tN)
    lbl: i64           // contador de labels (LN)
    term: bool         // o bloco básico atual já terminou (ret/br)?
    curMain: bool      // estamos gerando o `main` (retorno i32)?
    loopCond: string[] // pilha de labels de condição (continue)
    loopEnd: string[]  // pilha de labels de saída (break)

    constructor() {
        this.out = ""
        this.tmp = 0
        this.lbl = 0
        this.term = false
        this.curMain = false
        this.loopCond = []
        this.loopEnd = []
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

    genLoad(name: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = load i64, ptr %${name}.addr`);
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

    genCall(c: Call): string {
        // print(x): imprime um i64 via printf da libc (saída de verdade).
        if (strEq(c.name, "print")) {
            let v: string = "0";
            if (c.args.len() >= 1) { v = this.genExpr(c.args[0]); }
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_int, i64 ${v})`);
            return "0";
        }
        let argStr: string = "";
        let first: bool = true;
        for (const a of c.args) {
            const v: string = this.genExpr(a);
            if (!first) { argStr = concat(argStr, ", "); }
            argStr = concat(argStr, concat("i64 ", v));
            first = false;
        }
        const t: string = this.newTmp();
        this.emit(`  ${t} = call i64 @${c.name}(${argStr})`);
        return t;
    }

    genExpr(e: Expr): string {
        return match (e) {
            IntLit n => str(n.value),
            BoolLit b => boolLit(b.value),
            Var v => this.genLoad(v.name),
            Unary u => this.genUnary(u),
            Binary b => this.genBinary(b),
            Call c => this.genCall(c),
            _ => "0"   // float/string/array/etc → TODO
        };
    }

    // ── statements (devolvem i64 dummy p/ caberem no match-expressão) ────────
    storeVar(name: string, v: string): i64 {
        this.emit(`  store i64 ${v}, ptr %${name}.addr`);
        return 0;
    }

    genLet(l: LetStmt): i64 {
        this.emit(`  %${l.name}.addr = alloca i64`);
        const v: string = this.genExpr(l.value);
        this.emit(`  store i64 ${v}, ptr %${l.name}.addr`);
        return 0;
    }

    genAssign(a: AssignStmt): i64 {
        const v: string = this.genExpr(a.value);
        return match (a.target) {
            Var vv => this.storeVar(vv.name, v),
            _ => 0   // a.b = / xs[i] = → TODO
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
            BreakStmt b => this.genBreak(),
            ContinueStmt c => this.genContinue(),
            ExprStmt e => this.genExprStmt(e),
            _ => 0
        };
    }

    genFunc(f: Func): i64 {
        this.tmp = 0;
        this.lbl = 0;
        this.term = false;
        this.curMain = strEq(f.name, "main");

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
        this.raw("entry:");
        this.term = false;

        for (const p of f.params) {
            this.emit(`  %${p.name}.addr = alloca i64`);
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

    genProgram(prog: Func[]): i64 {
        // preâmbulo: formato p/ print + declaração do printf da libc
        this.raw("@.lex_fmt_int = private unnamed_addr constant [6 x i8] c\"%lld\\0A\\00\"");
        this.raw("declare i32 @printf(ptr, ...)");
        this.raw("");
        for (const f of prog) { this.genFunc(f); }
        return 0;
    }
}

// Conveniência: fonte lex (subset) → texto do LLVM IR.
fn compileToIR(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    const prog: Func[] = p.parseProgram();
    const cg: Codegen = new Codegen();
    cg.genProgram(prog);
    return cg.out;
}
