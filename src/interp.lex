// interp.lex — interpretador do lex, escrito em lex. SEM clang, SEM LLVM:
// anda na AST (vinda de parser.lex) e executa direto. Reusa todo o front-end.
//
// É a forma de "pular o clang": em vez de AST → LLVM IR → clang → binário, a
// gente avalia a árvore na hora. Zero ferramentas externas — roda no próprio lex.
//
// Cobre o mesmo subset do codegen: funções i64, let/const, atribuição a var,
// return, if/else/else-if, while, break/continue; expressões int/bool/var,
// aritmética, comparações, bitwise, lógicos, unários e chamadas; `print(x)`
// imprime via Terminal.log. `main()` é o ponto de entrada; seu retorno é o valor.
import { lexSrc, Tok } from "./lexer"
import {
    Expr, IntLit, BoolLit, Var, Unary, Binary, Call,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt,
    BreakStmt, ContinueStmt, ExprStmt, Func, Param, Parser
} from "./parser"

fn boolI(b: bool): i64 {
    if (b) { return 1; }
    return 0;
}

class Interp {
    funcs: Func[]
    ret: bool       // sinal de return propagado pelos blocos
    retVal: i64
    brk: bool       // sinal de break
    cont: bool      // sinal de continue
    constructor(funcs: Func[]) {
        this.funcs = funcs
        this.ret = false
        this.retVal = 0
        this.brk = false
        this.cont = false
    }

    findFunc(name: string): Func {
        for (const f of this.funcs) {
            if (strEq(f.name, name)) { return f; }
        }
        let ep: Param[] = [];
        let eb: Stmt[] = [];
        return new Func("", ep, "void", false, eb);   // não achou: função vazia
    }

    // chama `f` com os valores já avaliados; cada chamada tem seu ambiente novo
    callFunc(f: Func, argvals: i64[]): i64 {
        let env: Map<i64> = {};
        let i: i64 = 0;
        for (const p of f.params) {
            mapSet(env, p.name, argvals[i]);
            i = i + 1;
        }
        this.ret = false; this.retVal = 0;
        this.brk = false; this.cont = false;
        this.execBlock(f.body, env);
        const r: i64 = this.retVal;
        this.ret = false; this.retVal = 0;     // limpa p/ o chamador
        return r;
    }

    execBlock(body: Stmt[], env: Map<i64>): i64 {
        for (const s of body) {
            this.exec(s, env);
            if (this.ret) { break; }
            if (this.brk) { break; }
            if (this.cont) { break; }
        }
        return 0;
    }

    // ── statements ────────────────────────────────────────────────────────
    execLet(l: LetStmt, env: Map<i64>): i64 {
        mapSet(env, l.name, this.eval(l.value, env));
        return 0;
    }
    setVar(env: Map<i64>, name: string, v: i64): i64 {
        mapSet(env, name, v);
        return 0;
    }
    execAssign(a: AssignStmt, env: Map<i64>): i64 {
        const v: i64 = this.eval(a.value, env);
        return match (a.target) {
            Var vv => this.setVar(env, vv.name, v),
            _ => 0
        };
    }
    execReturn(r: ReturnStmt, env: Map<i64>): i64 {
        if (r.hasValue) { this.retVal = this.eval(r.value, env); }
        else { this.retVal = 0; }
        this.ret = true;
        return 0;
    }
    execIf(f: IfStmt, env: Map<i64>): i64 {
        if (this.eval(f.cond, env) != 0) { this.execBlock(f.thenB, env); }
        else { this.execBlock(f.elseB, env); }
        return 0;
    }
    execWhile(w: WhileStmt, env: Map<i64>): i64 {
        while (this.eval(w.cond, env) != 0) {
            this.execBlock(w.body, env);
            if (this.ret) { break; }
            if (this.brk) { this.brk = false; break; }
            if (this.cont) { this.cont = false; }
        }
        return 0;
    }
    doBreak(): i64 { this.brk = true; return 0; }
    doCont(): i64 { this.cont = true; return 0; }
    execExpr(e: ExprStmt, env: Map<i64>): i64 { this.eval(e.expr, env); return 0; }

    exec(s: Stmt, env: Map<i64>): i64 {
        return match (s) {
            LetStmt l => this.execLet(l, env),
            AssignStmt a => this.execAssign(a, env),
            ReturnStmt r => this.execReturn(r, env),
            IfStmt f => this.execIf(f, env),
            WhileStmt w => this.execWhile(w, env),
            BreakStmt b => this.doBreak(),
            ContinueStmt c => this.doCont(),
            ExprStmt e => this.execExpr(e, env),
            _ => 0
        };
    }

    // ── expressões ──────────────────────────────────────────────────────────
    evalUnary(u: Unary, env: Map<i64>): i64 {
        const v: i64 = this.eval(u.operand, env);
        if (u.op == Tok.Minus) { return -v; }
        if (u.op == Tok.Tilde) { return ~v; }
        if (u.op == Tok.Bang) {
            if (v == 0) { return 1; }
            return 0;
        }
        return v;
    }
    evalBin(b: Binary, env: Map<i64>): i64 {
        const a: i64 = this.eval(b.lhs, env);
        const r: i64 = this.eval(b.rhs, env);
        const op: Tok = b.op;
        if (op == Tok.Plus) { return a + r; }
        if (op == Tok.Minus) { return a - r; }
        if (op == Tok.Star) { return a * r; }
        if (op == Tok.Slash) { return a / r; }
        if (op == Tok.Percent) { return a % r; }
        if (op == Tok.Amp) { return a & r; }
        if (op == Tok.Pipe) { return a | r; }
        if (op == Tok.Caret) { return a ^ r; }
        if (op == Tok.Shl) { return a << r; }
        if (op == Tok.Shr) { return a >> r; }
        if (op == Tok.EqEq) { if (a == r) { return 1; } return 0; }
        if (op == Tok.Neq) { if (a != r) { return 1; } return 0; }
        if (op == Tok.Lt) { if (a < r) { return 1; } return 0; }
        if (op == Tok.Gt) { if (a > r) { return 1; } return 0; }
        if (op == Tok.Le) { if (a <= r) { return 1; } return 0; }
        if (op == Tok.Ge) { if (a >= r) { return 1; } return 0; }
        if (op == Tok.AmpAmp) { if (a != 0 && r != 0) { return 1; } return 0; }
        if (op == Tok.PipePipe) { if (a != 0 || r != 0) { return 1; } return 0; }
        return 0;
    }
    evalCall(c: Call, env: Map<i64>): i64 {
        if (strEq(c.name, "print")) {
            let v: i64 = 0;
            if (c.args.len() >= 1) { v = this.eval(c.args[0], env); }
            Terminal.log(v);
            return 0;
        }
        let argvals: i64[] = [];
        for (const a of c.args) { argvals.push(this.eval(a, env)); }
        return this.callFunc(this.findFunc(c.name), argvals);
    }

    eval(e: Expr, env: Map<i64>): i64 {
        return match (e) {
            IntLit n => n.value,
            BoolLit b => boolI(b.value),
            Var v => mapGet(env, v.name),
            Unary u => this.evalUnary(u, env),
            Binary b => this.evalBin(b, env),
            Call c => this.evalCall(c, env),
            _ => 0
        };
    }
}

// fonte (subset) → valor de retorno do main, executando direto (sem clang).
fn interpret(src: string): i64 {
    const p: Parser = new Parser(lexSrc(src));
    const prog: Func[] = p.parseProgram();
    const it: Interp = new Interp(prog);
    let noargs: i64[] = [];
    return it.callFunc(it.findFunc("main"), noargs);
}
