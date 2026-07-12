// typecheck.lex — checagem de TIPOS (espelha o grosso de src/sema.rs).
//
// O `checker.lex` já pegava sintaxe + variável indefinida. Aqui vem a camada de
// tipos, que é o que ainda prendia o compilador Rust: aridade e tipo de argumento,
// método/campo inexistente, `const` reatribuído, `new` de classe inexistente, e o
// retorno do `main`.
//
// PRINCÍPIO: leniência. O modelo de tipos da sema é grosseiro (strings) e o codegen
// é type-erased; um FALSO-POSITIVO quebraria o build do próprio compilador. Então
// quando um tipo é desconhecido ("?"/""), nunca acusamos — só reportamos o que dá
// pra afirmar com certeza.
import { Program, ClassDecl, Func, Param, Expr, Stmt } from "./parser"
import {
    IntLit, FloatLit, BoolLit, StrLit, Var, Unary, Binary, Call, ArrayLit,
    Field, MethodCall, Index, NewExpr, MapLit, StructLit, Template, Match, Lambda,
    TryExpr, CatchExpr, SpawnExpr, AwaitExpr
} from "./parser"
import {
    LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt, ForOfStmt, ForStmt,
    ExprStmt, FailStmt, DeferStmt
} from "./parser"
import { Sema, Scope, Diag, isClassTy, isArrayTy, isMapTy, isFloatTy, isFunctionType,
    baseName, elementTy, builtinFnRet } from "./sema"

// ── compatibilidade de tipos (leniente) ──────────────────────────────────────
// "desconhecido" nunca acusa. Só dizemos "incompatível" quando os DOIS lados são
// concretos e sabidamente diferentes.
fn tyUnknown(t: string): bool {
    return strEq(t, "") || strEq(t, "?") || strEq(t, "void");
}
// um type param genérico (T, U, …) é apagado — trate como desconhecido.
fn tyIsParam(t: string): bool {
    if (len(t) > 2) { return false; }
    if (len(t) == 0) { return false; }
    const c: i64 = peek8(t, 0);
    return c >= 65 && c <= 90;          // começa com maiúscula e é curtíssimo
}
// os inteiros compartilham a mesma célula i64 e convertem implicitamente entre si
// (o `main`/`testReport` devolvem i32 truncando um i64).
fn tyIsInt(t: string): bool {
    return strEq(t, "i64") || strEq(t, "i32") || strEq(t, "i16") || strEq(t, "i8");
}
fn tyIsRaw(t: string): bool { return strEq(t, "ptr") || strEq(t, "string"); }
fn tyAssignable(got: string, want: string, sema: Sema): bool {
    if (tyUnknown(got) || tyUnknown(want)) { return true; }
    if (strEq(want, "any")) { return true; }            // `any` aceita tudo (boxing)
    if (strEq(got, "any")) { return true; }             // any → concreto: unbox, ok
    if (strEq(got, want)) { return true; }
    if (tyIsParam(got) || tyIsParam(want)) { return true; }   // genérico apagado
    if (tyIsInt(want) && tyIsInt(got)) { return true; }
    if (isFloatTy(want) && (isFloatTy(got) || tyIsInt(got))) { return true; }
    // `ptr` e `string` são a MESMA célula (uma string é um char*): intercambiáveis.
    if (tyIsRaw(want) && tyIsRaw(got)) { return true; }
    if (isFunctionType(want) || isFunctionType(got)) { return true; }   // leniente
    // arrays: `[]` vazio vira "?[]"; elemento por elemento
    if (isArrayTy(want) && isArrayTy(got)) {
        return tyAssignable(elementTy(got), elementTy(want), sema);
    }
    if (isMapTy(want) && isMapTy(got)) { return true; }
    // classe: subclasse serve onde a base é pedida
    if (isClassTy(want) && isClassTy(got)) {
        if (sema.classes.findInfo(want) < 0 || sema.classes.findInfo(got) < 0) { return true; }
        return sema.classes.isSubclassOf(got, want);
    }
    return false;
}

class TypeChecker {
    sema: Sema
    diags: Diag[]
    consts: string[]        // nomes declarados com `const` (p/ pegar reatribuição)
    constructor(sema: Sema) {
        this.sema = sema
        this.diags = []
        this.consts = []
    }
    err(pos: i64, span: i64, msg: string) { this.diags.push(new Diag(pos, span, msg)); }

    // ── chamadas ────────────────────────────────────────────────────────────
    // f(args): confere aridade e tipo, se `f` for uma função do usuário. Builtins e
    // funções-valor (arrow em variável) passam batido (aridade variável/desconhecida).
    checkCall(c: Call, sc: Scope) {
        for (const a of c.args) { this.checkExpr(a, sc); }
        if (strEq(c.name, "super")) { return; }
        if (!strEq(builtinFnRet(c.name), "")) { return; }      // builtin conhecido
        if (isFunctionType(sc.get(c.name))) { return; }        // variável de função
        const fi: i64 = this.sema.funcIndex(c.name);
        if (fi < 0) { return; }                                // builtin/desconhecido: leniente
        const ps: Param[] = this.sema.funcs[fi].params;
        if (c.args.len() != ps.len()) {
            this.err(c.pos, len(c.name),
                `'${c.name}' expects ${ps.len()} argument(s), got ${c.args.len()}`);
            return;
        }
        this.checkArgs(c.args, ps, c.name, c.pos, sc);
    }
    // cada arg contra o tipo declarado do parâmetro
    checkArgs(xs: Expr[], ps: Param[], who: string, pos: i64, sc: Scope) {
        let i: i64 = 0;
        while (i < xs.len() && i < ps.len()) {
            const got: string = this.sema.typeOf(xs[i], sc);
            const want: string = ps[i].ty;
            if (!tyAssignable(got, want, this.sema)) {
                this.err(pos, len(who),
                    `argument ${i + 1} of '${who}' expects ${want}, got ${got}`);
            }
            i = i + 1;
        }
    }
    // obj.m(args): o método existe na classe? aridade/tipos batem?
    checkMethodCall(m: MethodCall, sc: Scope) {
        this.checkExpr(m.base, sc);
        for (const a of m.args) { this.checkExpr(a, sc); }
        const bt: string = this.sema.typeOf(m.base, sc);
        if (!isClassTy(bt)) { return; }                        // string/array/map: builtins
        const ci: i64 = this.sema.classes.findInfo(bt);
        if (ci < 0) { return; }                                // classe desconhecida: leniente
        const owner: string = this.sema.classes.methodOwner(bt, m.method);
        if (strEq(owner, "")) {
            this.err(m.pos, len(m.method),
                `class '${baseName(bt)}' has no method '${m.method}'`);
            return;
        }
        const ps: Param[] = this.sema.methodParams(bt, m.method);
        if (m.args.len() != ps.len()) {
            this.err(m.pos, len(m.method),
                `'${m.method}' expects ${ps.len()} argument(s), got ${m.args.len()}`);
            return;
        }
        this.checkArgs(m.args, ps, m.method, m.pos, sc);
    }
    // obj.campo: o campo existe?
    checkField(f: Field, sc: Scope) {
        this.checkExpr(f.base, sc);
        const bt: string = this.sema.typeOf(f.base, sc);
        if (!isClassTy(bt)) { return; }
        if (this.sema.classes.findInfo(bt) < 0) { return; }
        if (this.sema.classes.fieldSlot(bt, f.field) < 0) {
            // pode ser um método usado como valor — não acusa nesse caso
            if (strEq(this.sema.classes.methodOwner(bt, f.field), "")) {
                this.err(f.pos, len(f.field),
                    `class '${baseName(bt)}' has no field '${f.field}'`);
            }
        }
    }
    // new C(args): a classe existe? o constructor bate?
    checkNew(ne: NewExpr, sc: Scope) {
        for (const a of ne.args) { this.checkExpr(a, sc); }
        if (this.sema.classes.findInfo(ne.cls) < 0) { return; }   // já pego como indefinido
        const owner: string = this.sema.classes.methodOwner(ne.cls, "constructor");
        if (strEq(owner, "")) { return; }                         // sem constructor: 0 args
        const ps: Param[] = this.sema.methodParams(ne.cls, "constructor");
        if (ne.args.len() != ps.len()) {
            this.err(ne.pos, len(ne.cls), `'new ${ne.cls}' expects ${ps.len()} argument(s), got ${ne.args.len()}`);
            return;
        }
        this.checkArgs(ne.args, ps, concat("new ", ne.cls), ne.pos, sc);
    }

    checkExprs(xs: Expr[], sc: Scope) { for (const e of xs) { this.checkExpr(e, sc); } }

    checkExpr(e: Expr, sc: Scope) {
        match (e) {
            Call c => this.checkCall(c, sc),
            MethodCall m => this.checkMethodCall(m, sc),
            Field f => this.checkField(f, sc),
            NewExpr ne => this.checkNew(ne, sc),
            Binary b => this.checkBin(b, sc),
            Unary u => this.checkExpr(u.operand, sc),
            Index ix => this.checkIndex(ix, sc),
            ArrayLit a => this.checkExprs(a.items, sc),
            MapLit ml => this.checkExprs(ml.vals, sc),
            StructLit sl => this.checkExprs(sl.vals, sc),
            Template t => this.checkExprs(t.parts, sc),
            TryExpr t => this.checkExpr(t.call, sc),
            CatchExpr c => this.checkCatch(c, sc),
            SpawnExpr s => this.checkExpr(s.call, sc),
            AwaitExpr a => this.checkExpr(a.inner, sc),
            Match mt => this.checkMatch(mt, sc),
            _ => 0
        };
    }
    checkBin(b: Binary, sc: Scope) { this.checkExpr(b.lhs, sc); this.checkExpr(b.rhs, sc); }
    checkIndex(ix: Index, sc: Scope) { this.checkExpr(ix.base, sc); this.checkExpr(ix.index, sc); }
    checkCatch(c: CatchExpr, sc: Scope) { this.checkExpr(c.lhs, sc); this.checkExpr(c.handler, sc); }
    checkMatch(mt: Match, sc: Scope) {
        this.checkExpr(mt.subject, sc);
        const st: string = this.sema.typeOf(mt.subject, sc);
        for (const arm of mt.arms) {
            // o binding entra no escopo do braço (tipo do padrão, ou do subject)
            if (!strEq(arm.bind, "")) {
                if (arm.kind == 0) { sc.set(arm.bind, arm.pat); } else { sc.set(arm.bind, st); }
            }
            if (arm.hasGuard) { this.checkExpr(arm.guard, sc); }
            this.checkExpr(arm.body, sc);
        }
    }

    // ── statements ──────────────────────────────────────────────────────────
    checkStmts(xs: Stmt[], sc: Scope, ret: string) {
        for (const s of xs) { this.checkStmt(s, sc, ret); }
    }
    checkStmt(s: Stmt, sc: Scope, ret: string) {
        match (s) {
            LetStmt l => this.checkLet(l, sc),
            AssignStmt a => this.checkAssign(a, sc),
            ReturnStmt r => this.checkReturn(r, sc, ret),
            IfStmt f => this.checkIf(f, sc, ret),
            WhileStmt w => this.checkWhile(w, sc, ret),
            ForOfStmt fo => this.checkForOf(fo, sc, ret),
            ForStmt fr => this.checkFor(fr, sc, ret),
            ExprStmt e => this.checkExpr(e.expr, sc),
            FailStmt fs => this.checkExpr(fs.value, sc),
            DeferStmt d => this.checkStmt(d.body, sc, ret),
            _ => 0
        };
    }
    checkLet(l: LetStmt, sc: Scope) {
        this.checkExpr(l.value, sc);
        const got: string = this.sema.typeOf(l.value, sc);
        if (!strEq(l.ty, "") && !tyAssignable(got, l.ty, this.sema)) {
            this.err(l.pos, len(l.name), `'${l.name}' is declared ${l.ty} but the value is ${got}`);
        }
        // tipo efetivo no escopo: o anotado (se houver), senão o inferido
        if (strEq(l.ty, "")) { sc.set(l.name, got); } else { sc.set(l.name, l.ty); }
        if (!l.mutable) { addUniqStr(this.consts, l.name); }
    }
    checkAssign(a: AssignStmt, sc: Scope) {
        this.checkExpr(a.target, sc);
        this.checkExpr(a.value, sc);
        const nm: string = tcVarName(a.target);
        if (!strEq(nm, "")) {
            const ap: i64 = tcVarPos(a.target);
            if (idxOfStr(this.consts, nm) >= 0) {
                this.err(ap, len(nm), `cannot reassign '${nm}': it was declared with 'const' — use 'let'`);
            }
            const want: string = sc.get(nm);
            const got: string = this.sema.typeOf(a.value, sc);
            if (!tyAssignable(got, want, this.sema)) {
                this.err(ap, len(nm), `'${nm}' is ${want} but the value is ${got}`);
            }
        }
    }
    checkReturn(r: ReturnStmt, sc: Scope, ret: string) {
        if (!r.hasValue) { return; }
        this.checkExpr(r.value, sc);
        const got: string = this.sema.typeOf(r.value, sc);
        if (!tyAssignable(got, ret, this.sema)) {
            this.err(0, 0, `this function returns ${ret}, but the value is ${got}`);
        }
    }
    checkIf(f: IfStmt, sc: Scope, ret: string) {
        this.checkExpr(f.cond, sc);
        this.checkStmts(f.thenB, sc, ret);
        this.checkStmts(f.elseB, sc, ret);
    }
    checkWhile(w: WhileStmt, sc: Scope, ret: string) {
        this.checkExpr(w.cond, sc);
        this.checkStmts(w.body, sc, ret);
    }
    checkForOf(fo: ForOfStmt, sc: Scope, ret: string) {
        this.checkExpr(fo.iter, sc);
        sc.set(fo.name, elementTy(this.sema.typeOf(fo.iter, sc)));
        this.checkStmts(fo.body, sc, ret);
    }
    checkFor(fr: ForStmt, sc: Scope, ret: string) {
        if (fr.hasInit) { this.checkStmt(fr.init, sc, ret); }
        if (fr.hasCond) { this.checkExpr(fr.cond, sc); }
        if (fr.hasUpdate) { this.checkStmt(fr.update, sc, ret); }
        this.checkStmts(fr.body, sc, ret);
    }

    // uma função/método: monta o escopo (params) e percorre o corpo.
    checkFunc(f: Func, thisTy: string) {
        const sc: Scope = new Scope();
        if (!strEq(thisTy, "")) { sc.set("this", thisTy); }
        for (const p of f.params) { sc.set(p.name, p.ty); }
        this.consts = [];
        this.checkStmts(f.body, sc, f.ret);
    }
}

// nome de um lvalue Var (ou "" se for campo/índice)
fn tcVarName(e: Expr): string {
    return match (e) { Var v => v.name, _ => "" };
}
fn tcVarPos(e: Expr): i64 {
    return match (e) { Var v => v.pos, _ => 0 };
}
fn addUniqStr(xs: string[], s: string): i64 {
    for (const x of xs) { if (strEq(x, s)) { return 0; } }
    xs.push(s);
    return 0;
}
fn idxOfStr(xs: string[], s: string): i64 {
    let i: i64 = 0;
    while (i < xs.len()) {
        if (strEq(xs[i], s)) { return i; }
        i = i + 1;
    }
    return -1;
}

// checa o programa inteiro e devolve os diagnósticos de TIPO.
fn typeCheck(prog: Program): Diag[] {
    const sema: Sema = new Sema(prog);
    const tc: TypeChecker = new TypeChecker(sema);
    for (const f of prog.funcs) {
        tc.checkFunc(f, "");
        // `main` vira o exit code do processo
        if (strEq(f.name, "main") && !strEq(f.ret, "i32") && !strEq(f.ret, "void")) {
            tc.err(0, 0, "main must return i32 (it becomes the process exit code)");
        }
    }
    for (const c of prog.classes) {
        for (const m of c.methods) { tc.checkFunc(m, c.name); }
    }
    // statements de topo (script-mode) — sem retorno declarado
    const mainFn: Func = new Func("", [], "", false, prog.main);
    tc.checkFunc(mainFn, "");
    return tc.diags;
}
