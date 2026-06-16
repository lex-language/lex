// parser.lex — o parser do lex, escrito em lex (Fase 2).
//
// Espelha src/parser.rs + src/ast.rs. A AST é uma HIERARQUIA DE CLASSE (nó base
// + uma subclasse por construção), percorrida com `match` por padrão de tipo —
// o mesmo mecanismo que a sema/codegen vão usar. O operador binário/unário é
// guardado como o `Tok` do lexer (sem um enum BinOp separado).
//
// Cobertura (F6.1 — cobre todo o subset que o próprio selfhost/*.lex usa):
//   - Expressões: literais (int/float/bool/string), variáveis, unários (! - ~),
//     toda a escada de precedência (precedence climbing), parênteses, chamadas,
//     array literal, pós-fixos `.campo`/`.metodo(args)`/`[i]`, `new C(args)`,
//     `match` por tipo, template literals `...${}...`, map `{}`/struct literal.
//   - Statements: let/const (com anotação de tipo), atribuição (`x`/`a.b`/`xs[i]`),
//     return, if/else (e else-if), while, for-of, for C-style, break, continue,
//     expr-statement.
//   - Declarações de topo: `fn`, `class` (extends/constructor/campos/métodos),
//     `enum`, `import`; statements de topo viram um `main` (script-mode).
// Como em src/parser.rs, quebras de linha são INVISÍVEIS p/ peek/advance.
// TODO: defer/fail, compound assign (+=,++), try/catch/spawn/await/arrow, e as
//   declarações de topo type/interface/declare (não usadas pelo compilador).
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
    pos: i64           // offset de byte do identificador no fonte (p/ diagnósticos)
    constructor(name: string, pos: i64) { this.name = name; this.pos = pos }
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
class NewExpr extends Expr {
    cls: string
    args: Expr[]
    constructor(cls: string, args: Expr[]) { this.cls = cls; this.args = args }
}
class MapLit extends Expr {
    mapKeys: string[]   // chaves string (paralelo a vals); vazio = `{}`
    vals: Expr[]
    constructor(mapKeys: string[], vals: Expr[]) { this.mapKeys = mapKeys; this.vals = vals }
}
class StructLit extends Expr {
    fields: string[]    // chaves identificadoras (paralelo a vals)
    vals: Expr[]
    constructor(fields: string[], vals: Expr[]) { this.fields = fields; this.vals = vals }
}
class Template extends Expr {
    parts: Expr[]       // pedaços: StrLit (literal) ou Expr (interpolação ${})
    constructor(parts: Expr[]) { this.parts = parts }
}
// um braço de `match`: padrão `Tipo bind` (bind="" e pat="_" → curinga) e corpo
class MatchArm {
    pat: string
    bind: string
    body: Expr
    constructor(pat: string, bind: string, body: Expr) {
        this.pat = pat; this.bind = bind; this.body = body
    }
}
class Match extends Expr {
    subject: Expr
    arms: MatchArm[]
    constructor(subject: Expr, arms: MatchArm[]) { this.subject = subject; this.arms = arms }
}
// arrow function (não-capturante): içada p/ uma função de topo `__lambda_N`; a
// expressão avalia para o ponteiro dessa função.
class Lambda extends Expr {
    fnName: string
    constructor(fnName: string) { this.fnName = fnName }
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
class ForOfStmt extends Stmt {
    name: string
    mutable: bool
    iter: Expr
    body: Stmt[]
    constructor(name: string, mutable: bool, iter: Expr, body: Stmt[]) {
        this.name = name; this.mutable = mutable; this.iter = iter; this.body = body
    }
}
class ForStmt extends Stmt {
    init: Stmt          // ausente → placeholder; ver hasInit
    hasInit: bool
    cond: Expr
    hasCond: bool
    update: Stmt
    hasUpdate: bool
    body: Stmt[]
    constructor(init: Stmt, hasInit: bool, cond: Expr, hasCond: bool,
        update: Stmt, hasUpdate: bool, body: Stmt[]) {
        this.init = init; this.hasInit = hasInit
        this.cond = cond; this.hasCond = hasCond
        this.update = update; this.hasUpdate = hasUpdate
        this.body = body
    }
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

// ── declarações de topo ──────────────────────────────────────────────────────
class Import {
    names: string[]
    module: string
    constructor(names: string[], module: string) { this.names = names; this.module = module }
}
class EnumDecl {
    name: string
    variants: string[]
    constructor(name: string, variants: string[]) { this.name = name; this.variants = variants }
}
class ClassField {
    name: string
    ty: string
    constructor(name: string, ty: string) { this.name = name; this.ty = ty }
}
class ClassDecl {
    name: string
    parent: string          // "" = sem extends
    fields: ClassField[]
    methods: Func[]         // métodos e constructor (Func com name="constructor")
    constructor(name: string, parent: string, fields: ClassField[], methods: Func[]) {
        this.name = name; this.parent = parent; this.fields = fields; this.methods = methods
    }
}
// Programa = imports + enums + classes + funções + statements de topo
// (script-mode → corpo de um `main` sintetizado). Espelha src/parser.rs.
class Program {
    imports: Import[]
    enums: EnumDecl[]
    classes: ClassDecl[]
    funcs: Func[]
    main: Stmt[]
    constructor(imports: Import[], enums: EnumDecl[], classes: ClassDecl[], funcs: Func[], main: Stmt[]) {
        this.imports = imports; this.enums = enums
        this.classes = classes; this.funcs = funcs; this.main = main
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

// nome legível de um token esperado (p/ mensagens de erro de sintaxe).
fn tokName(k: Tok): string {
    if (k == Tok.RParen) { return "')'"; }
    if (k == Tok.RBrace) { return "'}'"; }
    if (k == Tok.RBracket) { return "']'"; }
    if (k == Tok.LParen) { return "'('"; }
    if (k == Tok.LBrace) { return "'{'"; }
    if (k == Tok.Colon) { return "':'"; }
    if (k == Tok.Eq) { return "'='"; }
    if (k == Tok.FatArrow) { return "'=>'"; }
    if (k == Tok.Gt) { return "'>'"; }
    if (k == Tok.From) { return "'from'"; }
    if (k == Tok.Function) { return "'fn'"; }
    return "token";
}

// ── o parser ────────────────────────────────────────────────────────────────
class Parser {
    toks: Token[]
    pos: i64
    lambdas: Func[]    // arrow functions içadas (anexadas a `funcs` em parseModule)
    lambdaN: i64
    errs: string[]     // erros de sintaxe acumulados (mensagem)
    errPos: i64[]      // posição (offset de byte) de cada erro
    constructor(toks: Token[]) {
        this.toks = toks
        this.pos = 0
        this.lambdas = []
        this.lambdaN = 0
        this.errs = []
        this.errPos = []
    }
    recordErrAt(pos: i64, msg: string) { this.errs.push(msg); this.errPos.push(pos); }
    recordErr(msg: string) { this.recordErrAt(this.peekToken(0).pos, msg); }

    // índice do próximo token que NÃO é quebra de linha (newlines são invisíveis)
    nextPos(): i64 {
        let i: i64 = this.pos;
        while (i < this.toks.len() && this.toks[i].kind == Tok.Newline) { i = i + 1; }
        return i;
    }

    peekKind(): Tok { return this.toks[this.nextPos()].kind; }

    // o `skip`-ésimo token a partir do atual, ignorando newlines (lookahead).
    peekToken(skip: i64): Token {
        let i: i64 = this.pos;
        let seen: i64 = 0;
        const last: i64 = this.toks.len() - 1;
        while (i < this.toks.len()) {
            if (this.toks[i].kind != Tok.Newline) {
                if (seen == skip) { return this.toks[i]; }
                seen = seen + 1;
            }
            i = i + 1;
        }
        return this.toks[last];
    }

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
        else { this.recordErr(concat("expected ", tokName(k))); }
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
            // arrow function?  `() =>`  ou  `(ident: T, …) =>`
            if (this.peekKind() == Tok.RParen
                || (this.peekKind() == Tok.Ident && this.peekToken(1).kind == Tok.Colon)) {
                return this.parseLambda();
            }
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
        if (k == Tok.New) {
            const cname: string = this.advance().text;
            this.skipTypeArgs();
            return new NewExpr(cname, this.parseArgs());
        }
        if (k == Tok.Match) { return this.parseMatch(); }
        if (k == Tok.Template) { return this.parseTemplate(t.text); }
        if (k == Tok.LBrace) { return this.parseBrace(); }
        if (k == Tok.Ident) {
            if (this.peekKind() == Tok.LParen) {
                return new Call(t.text, this.parseArgs());
            }
            return new Var(t.text, t.pos);
        }
        this.recordErrAt(t.pos, "unexpected token in expression");
        return new Var("<?>", t.pos);
    }

    // pula `<...>` de argumentos de tipo (ex.: `new Box<i64>(...)`), se houver.
    skipTypeArgs() {
        if (this.peekKind() != Tok.Lt) { return; }
        let depth: i64 = 0;
        while (true) {
            const kk: Tok = this.peekKind();
            if (kk == Tok.Lt) { depth = depth + 1; this.advance(); }
            else if (kk == Tok.Gt) {
                depth = depth - 1; this.advance();
                if (depth == 0) { break; }
            }
            else if (kk == Tok.Eof) { break; }
            else { this.advance(); }
        }
    }

    // `match (subj) { Tipo bind => expr, _ => expr, ... }` — expressão. O token
    // `match` já foi consumido pelo advance() de parsePrimary.
    parseMatch(): Expr {
        this.expect(Tok.LParen);
        const subj: Expr = this.parseExpr();
        this.expect(Tok.RParen);
        this.expect(Tok.LBrace);
        let arms: MatchArm[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.Comma || this.peekKind() == Tok.Semicolon) {
                this.advance(); continue;
            }
            const pat: string = this.advance().text;     // Tipo, ou "_"
            let bind: string = "";
            if (!strEq(pat, "_")) { bind = this.advance().text; }
            this.expect(Tok.FatArrow);
            const body: Expr = this.parseExpr();
            arms.push(new MatchArm(pat, bind, body));
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RBrace);
        return new Match(subj, arms);
    }

    // `{}`/`{ "k": v, ... }` (map) ou `{ ident: v, ... }` (struct). O `{` já saiu.
    parseBrace(): Expr {
        const k: Tok = this.peekKind();
        if (k == Tok.RBrace || k == Tok.Str) {
            let mkeys: string[] = [];
            let mvals: Expr[] = [];
            while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
                mkeys.push(this.advance().text);          // chave string
                this.expect(Tok.Colon);
                mvals.push(this.parseExpr());
                if (this.peekKind() == Tok.Comma) { this.advance(); }
            }
            this.expect(Tok.RBrace);
            return new MapLit(mkeys, mvals);
        }
        let fields: string[] = [];
        let svals: Expr[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            fields.push(this.advance().text);            // chave identificadora
            this.expect(Tok.Colon);
            svals.push(this.parseExpr());
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RBrace);
        return new StructLit(fields, svals);
    }

    // template `...${expr}...`: o lexer entrega o corpo CRU; aqui dividimos em
    // literais (StrLit) e interpolações (expr lexada+parseada). Rastreia a
    // profundidade de chaves dentro de `${ }`; literais vazios são omitidos.
    parseTemplate(raw: string): Expr {
        let parts: Expr[] = [];
        const n: i64 = len(raw);
        let i: i64 = 0;
        let lit: string = "";
        while (i < n) {
            const c: i64 = peek8(raw, i);
            if (c == 36 && i + 1 < n && peek8(raw, i + 1) == 123) {   // ${
                if (len(lit) > 0) { parts.push(new StrLit(lit)); lit = ""; }
                i = i + 2;
                const start: i64 = i;
                let depth: i64 = 1;
                while (i < n && depth > 0) {
                    const d: i64 = peek8(raw, i);
                    if (d == 123) { depth = depth + 1; }
                    else if (d == 125) { depth = depth - 1; if (depth == 0) { break; } }
                    i = i + 1;
                }
                const inner: string = substring(raw, start, i);
                if (i < n) { i = i + 1; }                              // pula }
                const sub: Parser = new Parser(lexSrc(inner));
                parts.push(sub.parseExpr());
                continue;
            }
            if (c == 92 && i + 1 < n) {                                // escape \X
                const e: i64 = peek8(raw, i + 1);
                if (e == 110) { lit = concat(lit, "\n"); }
                else if (e == 116) { lit = concat(lit, "\t"); }
                else { lit = concat(lit, charAt(raw, i + 1)); }
                i = i + 2;
                continue;
            }
            lit = concat(lit, charAt(raw, i));
            i = i + 1;
        }
        if (len(lit) > 0) { parts.push(new StrLit(lit)); }
        return new Template(parts);
    }

    // arrow function `(p: T, …)[: R] => corpo` — o `(` já saiu. Içada p/ uma
    // função de topo `__lambda_N`; devolve um Lambda com o nome içado.
    parseLambda(): Expr {
        let params: Param[] = [];
        while (this.peekKind() != Tok.RParen && this.peekKind() != Tok.Eof) {
            const pname: string = this.advance().text;
            let pty: string = "";
            if (this.peekKind() == Tok.Colon) { this.advance(); pty = this.parseTypeStr(); }
            if (this.peekKind() == Tok.Eq) { this.advance(); this.parseExpr(); }   // default descartado
            params.push(new Param(pname, pty));
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RParen);
        let ret: string = "i64";                       // arrow sem anotação assume i64
        if (this.peekKind() == Tok.Colon) { this.advance(); ret = this.parseTypeStr(); }
        this.expect(Tok.FatArrow);
        let body: Stmt[] = [];
        if (this.peekKind() == Tok.LBrace) { body = this.parseBlock(); }
        else { body = [new ReturnStmt(true, this.parseExpr())]; }    // corpo-expr → return
        const name: string = concat("__lambda_", str(this.lambdaN));
        this.lambdaN = this.lambdaN + 1;
        this.lambdas.push(new Func(name, params, ret, false, body));
        return new Lambda(name);
    }

    // ── tipos (forma textual, suficiente p/ a AST do PoC) ─────────────────────
    // base, genéricos de 1 nível `Map<i64>` e arrays `T[]`. Genéricos aninhados
    // (`Map<Map<i64>>`, fecham com `>>`) ficam de TODO.
    parseTypeStr(): string {
        // tipo de função: `(T, …) => R`  →  "(T,…)=>R"
        if (this.peekKind() == Tok.LParen) {
            this.advance();
            let f: string = "(";
            let first: bool = true;
            while (this.peekKind() != Tok.RParen && this.peekKind() != Tok.Eof) {
                if (!first) { f = concat(f, ","); }
                f = concat(f, this.parseTypeStr());
                first = false;
                if (this.peekKind() == Tok.Comma) { this.advance(); }
            }
            this.expect(Tok.RParen);
            f = concat(f, ")");
            if (this.peekKind() == Tok.FatArrow) {
                this.advance();
                f = concat(concat(f, "=>"), this.parseTypeStr());
            }
            return f;
        }
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

    // operador binário equivalente de um composto (`+=`→`+`); Tok.Eof = não é composto.
    compoundOp(k: Tok): Tok {
        if (k == Tok.PlusEq) { return Tok.Plus; }
        if (k == Tok.MinusEq) { return Tok.Minus; }
        if (k == Tok.StarEq) { return Tok.Star; }
        if (k == Tok.SlashEq) { return Tok.Slash; }
        if (k == Tok.PercentEq) { return Tok.Percent; }
        return Tok.Eof;
    }
    // após um lvalue `e`, trata `=`, compostos (`+=`…) e `++`/`--`, desaçucarando
    // `e += v` → `e = e + v` e `e++` → `e = e + 1`. Não consome ';'.
    opAssignStmt(e: Expr): Stmt {
        const k: Tok = this.peekKind();
        if (k == Tok.Eq) { this.advance(); return new AssignStmt(e, this.parseExpr()); }
        if (k == Tok.PlusPlus) { this.advance(); return new AssignStmt(e, new Binary(Tok.Plus, e, new IntLit(1))); }
        if (k == Tok.MinusMinus) { this.advance(); return new AssignStmt(e, new Binary(Tok.Minus, e, new IntLit(1))); }
        const co: Tok = this.compoundOp(k);
        if (co != Tok.Eof) { this.advance(); return new AssignStmt(e, new Binary(co, e, this.parseExpr())); }
        return new ExprStmt(e);
    }

    parseStmt(): Stmt {
        const k: Tok = this.peekKind();
        if (k == Tok.Const || k == Tok.Let) { return this.parseLet(); }
        if (k == Tok.Return) { return this.parseReturn(); }
        if (k == Tok.If) { return this.parseIf(); }
        if (k == Tok.While) { return this.parseWhile(); }
        if (k == Tok.For) { return this.parseFor(); }
        if (k == Tok.Break) { this.advance(); this.eatSemi(); return new BreakStmt(); }
        if (k == Tok.Continue) { this.advance(); this.eatSemi(); return new ContinueStmt(); }
        // default: expr-statement ou atribuição (`lvalue [op]= expr`, `lvalue++`)
        const e: Expr = this.parseExpr();
        const s: Stmt = this.opAssignStmt(e);
        this.eatSemi();
        return s;
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

    // init/update de `for` C-style: let-decl ou expr/atribuição, SEM consumir ';'.
    parseSimpleStmtNoSemi(): Stmt {
        const k: Tok = this.peekKind();
        if (k == Tok.Const || k == Tok.Let) {
            const mutable: bool = (k == Tok.Let);
            this.advance();
            const name: string = this.advance().text;
            let ty: string = "";
            if (this.peekKind() == Tok.Colon) { this.advance(); ty = this.parseTypeStr(); }
            this.expect(Tok.Eq);
            const value: Expr = this.parseExpr();
            return new LetStmt(name, ty, mutable, value);
        }
        const e: Expr = this.parseExpr();
        return this.opAssignStmt(e);
    }

    // `for (const x of iter) { ... }` (for-of) ou `for (init; cond; update) {...}`
    parseFor(): Stmt {
        this.advance();                              // for
        this.expect(Tok.LParen);
        // for-of: (const|let) ident 'of' ...  ('of' é Ident contextual)
        const k0: Tok = this.peekToken(0).kind;
        if ((k0 == Tok.Const || k0 == Tok.Let)
            && this.peekToken(1).kind == Tok.Ident
            && this.peekToken(2).kind == Tok.Ident
            && strEq(this.peekToken(2).text, "of")) {
            const mutable: bool = (k0 == Tok.Let);
            this.advance();                          // const/let
            const name: string = this.advance().text;
            this.advance();                          // 'of'
            const iter: Expr = this.parseExpr();
            this.expect(Tok.RParen);
            const body: Stmt[] = this.parseBlock();
            return new ForOfStmt(name, mutable, iter, body);
        }
        // estilo C: init ; cond ; update
        let init: Stmt = new ExprStmt(new IntLit(0));
        let hasInit: bool = false;
        if (this.peekKind() != Tok.Semicolon) { init = this.parseSimpleStmtNoSemi(); hasInit = true; }
        this.expect(Tok.Semicolon);
        let cond: Expr = new BoolLit(true);
        let hasCond: bool = false;
        if (this.peekKind() != Tok.Semicolon) { cond = this.parseExpr(); hasCond = true; }
        this.expect(Tok.Semicolon);
        let update: Stmt = new ExprStmt(new IntLit(0));
        let hasUpdate: bool = false;
        if (this.peekKind() != Tok.RParen) { update = this.parseSimpleStmtNoSemi(); hasUpdate = true; }
        this.expect(Tok.RParen);
        const body: Stmt[] = this.parseBlock();
        return new ForStmt(init, hasInit, cond, hasCond, update, hasUpdate, body);
    }

    // ── declaração de função e métodos ────────────────────────────────────────
    parseFunc(): Func {
        this.expect(Tok.Function);                   // fn / function
        const name: string = this.advance().text;
        return this.parseSig(name);
    }

    // `(params): R[!] { corpo }` — assinatura+corpo, compartilhada por funções e
    // métodos. Tolera variádico `...p` e defaults `p = expr` (ambos descartados
    // na forma textual). `name` é o nome já lido pelo chamador.
    parseSig(name: string): Func {
        this.expect(Tok.LParen);
        let params: Param[] = [];
        while (this.peekKind() != Tok.RParen && this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.DotDotDot) { this.advance(); }     // variádico
            const pname: string = this.advance().text;
            let pty: string = "";
            if (this.peekKind() == Tok.Colon) {
                this.advance();
                pty = this.parseTypeStr();
            }
            if (this.peekKind() == Tok.Eq) { this.advance(); this.parseExpr(); }  // default
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

    // ── declarações de topo ───────────────────────────────────────────────────
    // `import { a, b } from "módulo"`
    parseImport(): Import {
        this.advance();                              // import
        this.expect(Tok.LBrace);
        let names: string[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            names.push(this.advance().text);
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RBrace);
        this.expect(Tok.From);
        const mod: string = this.advance().text;     // Str
        this.eatSemi();
        return new Import(names, mod);
    }

    // `enum Nome { A, B, C }` — variantes separadas por vírgula/';'/quebra.
    parseEnum(): EnumDecl {
        this.advance();                              // enum
        const name: string = this.advance().text;
        this.expect(Tok.LBrace);
        let variants: string[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.Comma || this.peekKind() == Tok.Semicolon) {
                this.advance(); continue;
            }
            variants.push(this.advance().text);
            if (this.peekKind() == Tok.Comma) { this.advance(); }
        }
        this.expect(Tok.RBrace);
        this.eatSemi();
        return new EnumDecl(name, variants);
    }

    // `class Nome [extends Pai] [implements ...] { campos  métodos }`
    parseClass(): ClassDecl {
        this.advance();                              // class
        const name: string = this.advance().text;
        this.skipTypeArgs();                         // <T> opcional
        let parent: string = "";
        if (this.peekKind() == Tok.Extends) { this.advance(); parent = this.advance().text; }
        if (this.peekKind() == Tok.Implements) {     // implements A, B — descartado
            this.advance(); this.advance();
            while (this.peekKind() == Tok.Comma) { this.advance(); this.advance(); }
        }
        this.expect(Tok.LBrace);
        let fields: ClassField[] = [];
        let methods: Func[] = [];
        while (this.peekKind() != Tok.RBrace && this.peekKind() != Tok.Eof) {
            if (this.peekKind() == Tok.Semicolon) { this.advance(); continue; }
            // modificadores private/static — descartados na forma textual
            while (this.peekKind() == Tok.Private || this.peekKind() == Tok.Static) {
                this.advance();
            }
            const mname: string = this.advance().text;
            if (this.peekKind() == Tok.LParen) {     // método ou constructor
                methods.push(this.parseSig(mname));
            } else {                                  // campo: `nome: tipo [= init]`
                this.expect(Tok.Colon);
                const ty: string = this.parseTypeStr();
                if (this.peekKind() == Tok.Eq) { this.advance(); this.parseExpr(); }  // static init
                this.eatSemi();
                fields.push(new ClassField(mname, ty));
            }
        }
        this.expect(Tok.RBrace);
        this.eatSemi();
        return new ClassDecl(name, parent, fields, methods);
    }

    // Programa completo: imports + enums + classes + funções. (type/interface/
    // declare e statements de topo ainda são pulados — TODO.)
    parseModule(): Program {
        let imports: Import[] = [];
        let enums: EnumDecl[] = [];
        let classes: ClassDecl[] = [];
        let funcs: Func[] = [];
        let main: Stmt[] = [];
        while (this.peekKind() != Tok.Eof) {
            const k: Tok = this.peekKind();
            if (k == Tok.Semicolon) { this.advance(); }
            else if (k == Tok.Import) { imports.push(this.parseImport()); }
            else if (k == Tok.Enum) { enums.push(this.parseEnum()); }
            else if (k == Tok.Class) { classes.push(this.parseClass()); }
            else if (k == Tok.Function) { funcs.push(this.parseFunc()); }
            else if (k == Tok.Type || k == Tok.Interface || k == Tok.Declare) {
                this.advance();   // type/interface/declare: ainda não modelados (TODO)
            }
            else { main.push(this.parseStmt()); }   // statement de topo (script-mode)
        }
        for (const lm of this.lambdas) { funcs.push(lm); }   // arrow functions içadas
        return new Program(imports, enums, classes, funcs, main);
    }

    // Compat: o codegen/interp do subset só querem as funções de topo.
    parseProgram(): Func[] {
        return this.parseModule().funcs;
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

fn printArm(a: MatchArm): string {
    if (strEq(a.pat, "_")) { return `(_ ${printExpr(a.body)})`; }
    return `(${a.pat} ${a.bind} ${printExpr(a.body)})`;
}
fn printMatch(m: Match): string {
    let s: string = `(match ${printExpr(m.subject)}`;
    for (const a of m.arms) { s = concat(s, concat(" ", printArm(a))); }
    return concat(s, ")");
}
fn printTpl(t: Template): string {
    let s: string = "(tpl";
    for (const p of t.parts) { s = concat(s, concat(" ", printExpr(p))); }
    return concat(s, ")");
}
fn printMap(m: MapLit): string {
    let s: string = "(map";
    let i: i64 = 0;
    while (i < m.mapKeys.len()) {
        s = concat(s, ` "${m.mapKeys[i]}" ${printExpr(m.vals[i])}`);
        i = i + 1;
    }
    return concat(s, ")");
}
fn printStruct(st: StructLit): string {
    let s: string = "(struct";
    let i: i64 = 0;
    while (i < st.fields.len()) {
        s = concat(s, ` ${st.fields[i]} ${printExpr(st.vals[i])}`);
        i = i + 1;
    }
    return concat(s, ")");
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
        NewExpr ne => `(new ${ne.cls}${printArgs(ne.args)})`,
        Match mt => printMatch(mt),
        Template tp => printTpl(tp),
        MapLit ml => printMap(ml),
        StructLit sl => printStruct(sl),
        Lambda lm => `(lambda ${lm.fnName})`,
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
fn forStr(f: ForStmt): string {
    let ini: string = "_";
    if (f.hasInit) { ini = printStmt(f.init); }
    let cnd: string = "_";
    if (f.hasCond) { cnd = printExpr(f.cond); }
    let upd: string = "_";
    if (f.hasUpdate) { upd = printStmt(f.update); }
    return `(for ${ini} ${cnd} ${upd} ${printBlock(f.body)})`;
}

fn printStmt(s: Stmt): string {
    return match (s) {
        LetStmt l => `(${letKw(l.mutable)} ${l.name}${tyPart(l.ty)} ${printExpr(l.value)})`,
        AssignStmt a => `(= ${printExpr(a.target)} ${printExpr(a.value)})`,
        ReturnStmt r => retStr(r),
        IfStmt f => ifStr(f),
        WhileStmt w => `(while ${printExpr(w.cond)} ${printBlock(w.body)})`,
        ForOfStmt fo => `(forof ${fo.name} ${printExpr(fo.iter)} ${printBlock(fo.body)})`,
        ForStmt fr => forStr(fr),
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

// ── impressão das declarações de topo ────────────────────────────────────────
fn printImport(im: Import): string {
    let s: string = "(import (";
    let first: bool = true;
    for (const nm of im.names) {
        if (!first) { s = concat(s, " "); }
        s = concat(s, nm); first = false;
    }
    return concat(s, `) "${im.module}")`);
}
fn printEnum(en: EnumDecl): string {
    let s: string = concat("(enum ", en.name);
    for (const v of en.variants) { s = concat(s, concat(" ", v)); }
    return concat(s, ")");
}
fn printField(f: ClassField): string { return `(field ${f.name} ${f.ty})`; }
fn printClass(c: ClassDecl): string {
    let par: string = "_";
    if (!strEq(c.parent, "")) { par = c.parent; }
    let s: string = `(class ${c.name} ${par}`;
    for (const f of c.fields) { s = concat(s, concat(" ", printField(f))); }
    for (const m of c.methods) { s = concat(s, concat(" ", printFunc(m))); }
    return concat(s, ")");
}
fn printProgram(p: Program): string {
    let s: string = "(program";
    for (const im of p.imports) { s = concat(s, concat(" ", printImport(im))); }
    for (const en of p.enums) { s = concat(s, concat(" ", printEnum(en))); }
    for (const c of p.classes) { s = concat(s, concat(" ", printClass(c))); }
    for (const fnc of p.funcs) { s = concat(s, concat(" ", printFunc(fnc))); }
    if (p.main.len() > 0) { s = concat(s, concat(" ", printBlock(p.main))); }
    return concat(s, ")");
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
fn parseModuleStr(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return printProgram(p.parseModule());
}
