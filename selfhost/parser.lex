// parser.lex — o parser do lex, escrito em lex (Fase 2).
//
// Espelha src/parser.rs + src/ast.rs. A AST é uma HIERARQUIA DE CLASSE (nó base
// + uma subclasse por construção), percorrida com `match` por padrão de tipo —
// o mesmo mecanismo que a sema/codegen vão usar. O operador binário/unário é
// guardado como o `Tok` do lexer (sem um enum BinOp separado).
//
// Cobertura atual:
//   - Expressões: literais (int/float/bool/string), variáveis, unários (! - ~),
//     toda a escada de precedência (precedence climbing), parênteses, chamadas,
//     array literal, pós-fixos `.campo`/`.metodo(args)`/`[i]`.
//   - Statements: let/const (com anotação de tipo), atribuição (`x`/`a.b`/`xs[i]`),
//     return, if/else (e else-if), while, break, continue, expr-statement.
//   - Declaração de função: `fn nome(p: T, …): R[!] { corpo }`.
// Como em src/parser.rs, quebras de linha são INVISÍVEIS p/ peek/advance.
// TODO: for/for-of, defer/fail, compound assign (+=,++), match/try/catch/spawn/
//   await/new/struct/map/template/arrow, e as demais declarações de topo
//   (class/type/enum/interface/import/declare).
import { lexSrc, Token, Tok } from "./lexer"

// ── AST: expressões ──────────────────────────────────────────────────────────
class Expr {}

class IntLit extends Expr {
    value: i64
    constructor(value: i64) { this.value = value }
}
class FloatLit extends Expr {
    value: f64
    constructor(value: f64) { this.value = value }
}
class BoolLit extends Expr {
    value: bool
    constructor(value: bool) { this.value = value }
}
class StrLit extends Expr {
    value: string
    constructor(value: string) { this.value = value }
}
class Var extends Expr {
    name: string
    constructor(name: string) { this.name = name }
}
class Unary extends Expr {
    op: Tok        // Tok.Bang / Tok.Minus / Tok.Tilde
    operand: Expr
    constructor(op: Tok, operand: Expr) { this.op = op; this.operand = operand }
}
class Binary extends Expr {
    op: Tok        // o Tok do operador (Tok.Plus, Tok.EqEq, …)
    lhs: Expr
    rhs: Expr
    constructor(op: Tok, lhs: Expr, rhs: Expr) { this.op = op; this.lhs = lhs; this.rhs = rhs }
}
class Call extends Expr {
    name: string
    args: Expr[]
    constructor(name: string, xs: Expr[]) { this.name = name; this.args = xs }
}
class ArrayLit extends Expr {
    items: Expr[]
    constructor(items: Expr[]) { this.items = items }
}
class Field extends Expr {
    base: Expr
    field: string
    constructor(base: Expr, field: string) { this.base = base; this.field = field }
}
class MethodCall extends Expr {
    base: Expr
    method: string
    args: Expr[]
    constructor(base: Expr, method: string, xs: Expr[]) {
        this.base = base; this.method = method; this.args = xs
    }
}
class Index extends Expr {
    base: Expr
    index: Expr
    constructor(base: Expr, index: Expr) { this.base = base; this.index = index }
}

// ── AST: statements e declarações ────────────────────────────────────────────
class Stmt {}

class LetStmt extends Stmt {
    name: string
    ty: string         // "" = sem anotação
    mutable: bool      // true = let, false = const
    value: Expr
    constructor(name: string, ty: string, mutable: bool, value: Expr) {
        this.name = name; this.ty = ty; this.mutable = mutable; this.value = value
    }
}
class AssignStmt extends Stmt {
    target: Expr       // lvalue: Var / Field / Index
    value: Expr
    constructor(target: Expr, value: Expr) { this.target = target; this.value = value }
}
class ReturnStmt extends Stmt {
    hasValue: bool
    value: Expr
    constructor(hasValue: bool, value: Expr) { this.hasValue = hasValue; this.value = value }
}
class IfStmt extends Stmt {
    cond: Expr
    thenB: Stmt[]
    elseB: Stmt[]
    constructor(cond: Expr, thenB: Stmt[], elseB: Stmt[]) {
        this.cond = cond; this.thenB = thenB; this.elseB = elseB
    }
}
class WhileStmt extends Stmt {
    cond: Expr
    body: Stmt[]
    constructor(cond: Expr, body: Stmt[]) { this.cond = cond; this.body = body }
}
class BreakStmt extends Stmt {}
class ContinueStmt extends Stmt {}
class ExprStmt extends Stmt {
    expr: Expr
    constructor(expr: Expr) { this.expr = expr }
}

class Param {
    name: string
    ty: string
    constructor(name: string, ty: string) { this.name = name; this.ty = ty }
}
class Func {
    name: string
    params: Param[]
    ret: string
    fallible: bool
    body: Stmt[]
    constructor(name: string, params: Param[], ret: string, fallible: bool, body: Stmt[]) {
        this.name = name; this.params = params; this.ret = ret
        this.fallible = fallible; this.body = body
    }
}

// Binding power do operador binário (0 = não é binário). Quanto maior, mais
// forte — mesma ordem da escada de src/parser.rs.
fn prec(k: Tok): i64 {
    if (k == Tok.PipePipe) { return 1; }
    if (k == Tok.AmpAmp) { return 2; }
    if (k == Tok.Pipe) { return 3; }
    if (k == Tok.Caret) { return 4; }
    if (k == Tok.Amp) { return 5; }
    if (k == Tok.EqEq || k == Tok.Neq) { return 6; }
    if (k == Tok.Lt || k == Tok.Gt || k == Tok.Le || k == Tok.Ge) { return 7; }
    if (k == Tok.Shl || k == Tok.Shr) { return 8; }
    if (k == Tok.Plus || k == Tok.Minus) { return 9; }
    if (k == Tok.Star || k == Tok.Slash || k == Tok.Percent) { return 10; }
    return 0;
}

// ── o parser ────────────────────────────────────────────────────────────────
class Parser {
    toks: Token[]
    pos: i64
    constructor(toks: Token[]) {
        this.toks = toks
        this.pos = 0
    }

    // índice do próximo token que NÃO é quebra de linha (newlines são invisíveis)
    nextPos(): i64 {
        let i: i64 = this.pos;
        while (i < this.toks.len() && this.toks[i].kind == Tok.Newline) { i = i + 1; }
        return i;
    }

    peekKind(): Tok { return this.toks[this.nextPos()].kind; }

    advance(): Token {
        const i: i64 = this.nextPos();
        const t: Token = this.toks[i];
        this.pos = i + 1;
        const last: i64 = this.toks.len() - 1;
        if (this.pos > last) { this.pos = last; }   // trava no Eof
        return t;
    }

    expect(k: Tok) {
        if (this.peekKind() == k) { this.advance(); }
        // erro: token inesperado — silencioso no PoC (spans/erros vêm depois)
    }

    eatSemi() {
        if (this.peekKind() == Tok.Semicolon) { this.advance(); }
    }

    // ── expressões ──────────────────────────────────────────────────────────
    parseExpr(): Expr { return this.parseBin(1); }

    // precedence climbing: associativo à esquerda (recursão com p+1)
    parseBin(minPrec: i64): Expr {
        let left: Expr = this.parseUnary();
        while (true) {
            const op: Tok = this.peekKind();
            const p: i64 = prec(op);
            if (p == 0 || p < minPrec) { break; }
            this.advance();
            const right: Expr = this.parseBin(p + 1);
            left = new Binary(op, left, right);
        }
        return left;
    }

    parseUnary(): Expr {
        const k: Tok = this.peekKind();
        if (k == Tok.Bang || k == Tok.Minus || k == Tok.Tilde) {
            this.advance();
            return new Unary(k, this.parseUnary());
        }
        return this.parsePostfix();
    }

    parsePostfix(): Expr {
        let e: Expr = this.parsePrimary();
        while (true) {
            const k: Tok = this.peekKind();
            if (k == Tok.Dot) {
                this.advance();
                const id: Token = this.advance();          // identificador após '.'
                if (this.peekKind() == Tok.LParen) {
                    e = new MethodCall(e, id.text, this.parseArgs());
                } else {
                    e = new Field(e, id.text);
                }
            } else if (k == Tok.LBracket) {
                this.advance();
                const idx: Expr = this.parseExpr();
                this.expect(Tok.RBracket);
                e = new Index(e, idx);
            } else {
                break;
            }
        }
        return e;
    }

    // ( expr ("," expr)* )?  — consome os parênteses
    parseArgs(): Expr[] {
        this.expect(Tok.LParen);
        let out: Expr[] = [];
        if (this.peekKind() != Tok.RParen) {
            out.push(this.parseExpr());
            while (this.peekKind() == Tok.Comma) {
                this.advance();
                out.push(this.parseExpr());
            }
        }
        this.expect(Tok.RParen);
        return out;
    }

    parsePrimary(): Expr {
        const t: Token = this.advance();
        const k: Tok = t.kind;
        if (k == Tok.Int) { return new IntLit(t.ival); }
        if (k == Tok.Float) { return new FloatLit(t.fval); }
        if (k == Tok.True) { return new BoolLit(true); }
        if (k == Tok.False) { return new BoolLit(false); }
        if (k == Tok.Str) { return new StrLit(t.text); }
        if (k == Tok.LParen) {
            const e: Expr = this.parseExpr();
            this.expect(Tok.RParen);
            return e;
        }
        if (k == Tok.LBracket) {
            let items: Expr[] = [];
            if (this.peekKind() != Tok.RBracket) {
                items.push(this.parseExpr());
                while (this.peekKind() == Tok.Comma) {
                    this.advance();
                    items.push(this.parseExpr());
                }
            }
            this.expect(Tok.RBracket);
            return new ArrayLit(items);
        }
        if (k == Tok.Ident) {
            if (this.peekKind() == Tok.LParen) {
                return new Call(t.text, this.parseArgs());
            }
            return new Var(t.text);
        }
        return new Var("<?>");   // token inesperado (PoC)
    }

    // ── tipos (forma textual, suficiente p/ a AST do PoC) ─────────────────────
    // base, genéricos de 1 nível `Map<i64>` e arrays `T[]`. Genéricos aninhados
    // (`Map<Map<i64>>`, fecham com `>>`) ficam de TODO.
    parseTypeStr(): string {
        let s: string = this.advance().text;        // nome base (Ident)
        if (this.peekKind() == Tok.Lt) {
            this.advance();
            s = concat(s, "<");
            s = concat(s, this.parseTypeStr());
            while (this.peekKind() == Tok.Comma) {
                this.advance();
                s = concat(s, ",");
                s = concat(s, this.parseTypeStr());
            }
            this.expect(Tok.Gt);
            s = concat(s, ">");
        }
        while (this.peekKind() == Tok.LBracket) {
            this.advance();
            this.expect(Tok.RBracket);
            s = concat(s, "[]");
        }
        return s;
    }

    // ── statements ────────────────────────────────────────────────────────────
    parseBlock(): Stmt[] {
        this.expect(Tok.LBrace);
        let body: Stmt[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.Semicolon) { this.advance(); }
            else { body.push(this.parseStmt()); }
        }
        this.expect(Tok.RBrace);
        return body;
    }

    parseStmt(): Stmt {
        const k: Tok = this.peekKind();
        if (k == Tok.Const || k == Tok.Let) { return this.parseLet(); }
        if (k == Tok.Return) { return this.parseReturn(); }
        if (k == Tok.If) { return this.parseIf(); }
        if (k == Tok.While) { return this.parseWhile(); }
        if (k == Tok.Break) { this.advance(); this.eatSemi(); return new BreakStmt(); }
        if (k == Tok.Continue) { this.advance(); this.eatSemi(); return new ContinueStmt(); }
        // default: expr-statement ou atribuição (`lvalue = expr`)
        const e: Expr = this.parseExpr();
        if (this.peekKind() == Tok.Eq) {
            this.advance();
            const v: Expr = this.parseExpr();
            this.eatSemi();
            return new AssignStmt(e, v);
        }
        this.eatSemi();
        return new ExprStmt(e);
    }

    parseLet(): Stmt {
        const mutable: bool = (this.peekKind() == Tok.Let);
        this.advance();                              // const/let
        const name: string = this.advance().text;    // ident
        let ty: string = "";
        if (this.peekKind() == Tok.Colon) {
            this.advance();
            ty = this.parseTypeStr();
        }
        this.expect(Tok.Eq);
        const value: Expr = this.parseExpr();
        this.eatSemi();
        return new LetStmt(name, ty, mutable, value);
    }

    parseReturn(): Stmt {
        this.advance();                              // return
        const k: Tok = this.peekKind();
        if (k == Tok.Semicolon || k == Tok.RBrace || k == Tok.Eof) {
            this.eatSemi();
            return new ReturnStmt(false, new IntLit(0));   // sem valor (placeholder)
        }
        const v: Expr = this.parseExpr();
        this.eatSemi();
        return new ReturnStmt(true, v);
    }

    // `if cond { ... }` — em lex o `(cond)` é parseado como expr entre parênteses
    parseIf(): Stmt {
        this.advance();                              // if
        const cond: Expr = this.parseExpr();
        const thenB: Stmt[] = this.parseBlock();
        let elseB: Stmt[] = [];
        if (this.peekKind() == Tok.Else) {
            this.advance();
            if (this.peekKind() == Tok.If) {
                elseB = [this.parseStmt()];          // else if (encadeia)
            } else {
                elseB = this.parseBlock();
            }
        }
        return new IfStmt(cond, thenB, elseB);
    }

    parseWhile(): Stmt {
        this.advance();                              // while
        const cond: Expr = this.parseExpr();
        const body: Stmt[] = this.parseBlock();
        return new WhileStmt(cond, body);
    }

    // ── declaração de função ──────────────────────────────────────────────────
    parseFunc(): Func {
        this.expect(Tok.Function);                   // fn / function
        const name: string = this.advance().text;
        this.expect(Tok.LParen);
        let params: Param[] = [];
        while (this.peekKind() != Tok.RParen && this.peekKind() != Tok.Eof) {
            const pname: string = this.advance().text;
            let pty: string = "";
            if (this.peekKind() == Tok.Colon) {
                this.advance();
                pty = this.parseTypeStr();
            }
            params.push(new Param(pname, pty));
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RParen);
        let ret: string = "void";
        if (this.peekKind() == Tok.Colon) {
            this.advance();
            ret = this.parseTypeStr();
        }
        let fallible: bool = false;
        if (this.peekKind() == Tok.Bang) { this.advance(); fallible = true; }
        const body: Stmt[] = this.parseBlock();
        return new Func(name, params, ret, fallible, body);
    }

    // Programa = lista de funções de topo. (Subset: ignora outras declarações;
    // class/type/enum/import/script-mode são TODO.)
    parseProgram(): Func[] {
        let fns: Func[] = [];
        while (this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.Function) {
                fns.push(this.parseFunc());
            } else {
                this.advance();   // pula o que o subset ainda não parseia
            }
        }
        return fns;
    }
}

// ── impressão da AST como S-expression (pra testar) ─────────────────────────
fn boolStr(b: bool): string {
    if (b) { return "true"; }
    return "false";
}

fn opSym(op: Tok): string {
    if (op == Tok.Plus) { return "+"; }
    if (op == Tok.Minus) { return "-"; }
    if (op == Tok.Star) { return "*"; }
    if (op == Tok.Slash) { return "/"; }
    if (op == Tok.Percent) { return "%"; }
    if (op == Tok.EqEq) { return "=="; }
    if (op == Tok.Neq) { return "!="; }
    if (op == Tok.Lt) { return "<"; }
    if (op == Tok.Gt) { return ">"; }
    if (op == Tok.Le) { return "<="; }
    if (op == Tok.Ge) { return ">="; }
    if (op == Tok.AmpAmp) { return "&&"; }
    if (op == Tok.PipePipe) { return "||"; }
    if (op == Tok.Amp) { return "&"; }
    if (op == Tok.Pipe) { return "|"; }
    if (op == Tok.Caret) { return "^"; }
    if (op == Tok.Shl) { return "<<"; }
    if (op == Tok.Shr) { return ">>"; }
    if (op == Tok.Tilde) { return "~"; }
    if (op == Tok.Bang) { return "!"; }
    return "?";
}

// " a b c" — cada item precedido de um espaço (pra `(call f 1 2)`)
fn printArgs(xs: Expr[]): string {
    let s: string = "";
    for (const a of xs) { s = concat(s, concat(" ", printExpr(a))); }
    return s;
}

// "a b c" — itens separados por espaço (pra `[1 2 3]`)
fn printList(items: Expr[]): string {
    let s: string = "";
    let first: bool = true;
    for (const a of items) {
        if (!first) { s = concat(s, " "); }
        s = concat(s, printExpr(a));
        first = false;
    }
    return s;
}

fn printExpr(e: Expr): string {
    return match (e) {
        IntLit n => str(n.value),
        FloatLit f => `${f.value}`,
        BoolLit b => boolStr(b.value),
        StrLit s => `"${s.value}"`,
        Var v => v.name,
        Unary u => `(${opSym(u.op)} ${printExpr(u.operand)})`,
        Binary b => `(${opSym(b.op)} ${printExpr(b.lhs)} ${printExpr(b.rhs)})`,
        Call c => `(call ${c.name}${printArgs(c.args)})`,
        MethodCall m => `(. ${printExpr(m.base)} ${m.method}${printArgs(m.args)})`,
        Field fld => `(. ${printExpr(fld.base)} ${fld.field})`,
        Index ix => `(index ${printExpr(ix.base)} ${printExpr(ix.index)})`,
        ArrayLit a => `[${printList(a.items)}]`,
        _ => "?"
    };
}

// bloco → "(do s1 s2 …)" (sem chaves, p/ não confundir com ${} no template)
fn printBlock(body: Stmt[]): string {
    let s: string = "(do";
    for (const st of body) { s = concat(s, concat(" ", printStmt(st))); }
    return concat(s, ")");
}

fn letKw(mutable: bool): string {
    if (mutable) { return "let"; }
    return "const";
}
fn tyPart(ty: string): string {
    if (strEq(ty, "")) { return ""; }
    return concat(":", ty);
}
fn retStr(r: ReturnStmt): string {
    if (r.hasValue) { return `(return ${printExpr(r.value)})`; }
    return "(return)";
}
fn ifStr(f: IfStmt): string {
    let s: string = `(if ${printExpr(f.cond)} ${printBlock(f.thenB)}`;
    if (f.elseB.len() > 0) { s = concat(concat(s, " "), printBlock(f.elseB)); }
    return concat(s, ")");
}

fn printStmt(s: Stmt): string {
    return match (s) {
        LetStmt l => `(${letKw(l.mutable)} ${l.name}${tyPart(l.ty)} ${printExpr(l.value)})`,
        AssignStmt a => `(= ${printExpr(a.target)} ${printExpr(a.value)})`,
        ReturnStmt r => retStr(r),
        IfStmt f => ifStr(f),
        WhileStmt w => `(while ${printExpr(w.cond)} ${printBlock(w.body)})`,
        BreakStmt b => "(break)",
        ContinueStmt c => "(continue)",
        ExprStmt e => printExpr(e.expr),
        _ => "?"
    };
}

fn printFunc(f: Func): string {
    let ps: string = "";
    let first: bool = true;
    for (const p of f.params) {
        if (!first) { ps = concat(ps, " "); }
        ps = concat(ps, concat(concat(p.name, ":"), p.ty));
        first = false;
    }
    let bang: string = "";
    if (f.fallible) { bang = "!"; }
    return `(fn ${f.name} (${ps}) ${f.ret}${bang} ${printBlock(f.body)})`;
}

// ── conveniências pros testes ────────────────────────────────────────────────
fn parseExprStr(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return printExpr(p.parseExpr());
}
fn parseStmtStr(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return printStmt(p.parseStmt());
}
fn parseFuncStr(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return printFunc(p.parseFunc());
}
