// sema.lex — análise estrutural do lex, escrita em lex (Fase F6.2).
//
// Espelha o modelo de objeto de src/codegen.rs: cada objeto é um bloco de slots
// i64; o slot 0 é o ponteiro de vtable, os slots 1..n são os campos. Subclasse é
// layout-compatível com a superclasse (campos do pai PRIMEIRO, mesmos slots), e a
// vtable do filho começa como a do pai (override mantém o índice).
//
// Esta fase constrói, a partir do `Program` do parser:
//   - ClassTable: por classe, a lista ordenada de campos (com slot), a vtable
//     (método → índice, com herança+override), a classe-pai e uma TAG única
//     (id inteiro p/ o `match` por tipo discriminar em runtime).
//   - EnumTable: enum → (variante → valor inteiro, na ordem 0,1,2…).
// Ainda NÃO faz inferência de tipos por expressão (próximo passo da F6.2);
// aqui é só o esqueleto de nomes/layout que o codegen de classes (F6.4) exige.
import { lexSrc, Tok } from "./lexer"
import { Program, ClassDecl, ClassField, Func, Param, EnumDecl, Parser } from "./parser"
import {
    Expr, IntLit, FloatLit, BoolLit, StrLit, Var, Unary, Binary, Call, ArrayLit,
    Field, MethodCall, Index, NewExpr, MapLit, StructLit, Template, Match, MatchArm, Lambda,
    TryExpr, CatchExpr, SpawnExpr, AwaitExpr
} from "./parser"
import {
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt, ForOfStmt, ForStmt, ExprStmt,
    FailStmt, DeferStmt
} from "./parser"

// ── utilidades de conjunto de nomes (usadas pela sema E pelo codegen) ────────
fn addUniq(names: string[], n: string): i64 {
    for (const x of names) { if (strEq(x, n)) { return 0; } }
    names.push(n);
    return 0;
}
fn idxOf(names: string[], n: string): i64 {
    let i: i64 = 0;
    while (i < names.len()) { if (strEq(names[i], n)) { return i; } i = i + 1; }
    return -1;
}
fn without(list: string[], exclude: string[]): string[] {
    let out: string[] = [];
    for (const n of list) { if (idxOf(exclude, n) < 0) { out.push(n); } }
    return out;
}

// ── tabela de classes ────────────────────────────────────────────────────────
class FieldInfo {
    name: string
    ty: string
    slot: i64           // índice do slot no objeto (1.. ; slot 0 = vtable)
    constructor(name: string, ty: string, slot: i64) {
        this.name = name; this.ty = ty; this.slot = slot
    }
}
class MethodInfo {
    name: string
    vindex: i64         // índice na vtable
    owner: string       // classe que define/sobrescreve este slot
    constructor(name: string, vindex: i64, owner: string) {
        this.name = name; this.vindex = vindex; this.owner = owner
    }
}
class ClassInfo {
    name: string
    parent: string      // "" = sem herança
    tag: i64            // id único (posição na lista de decls) p/ match por tipo
    fields: FieldInfo[] // herdados (do pai, mesmos slots) + próprios, em ordem
    methods: MethodInfo[] // vtable completa (herdada + própria; override no lugar)
    nslots: i64         // 1 (vtable) + nº de campos
    constructor(name: string, parent: string, tag: i64,
        fields: FieldInfo[], methods: MethodInfo[], nslots: i64) {
        this.name = name; this.parent = parent; this.tag = tag
        this.fields = fields; this.methods = methods; this.nslots = nslots
    }
}

class ClassTable {
    decls: ClassDecl[]
    infos: ClassInfo[]
    constructor(decls: ClassDecl[]) {
        this.decls = decls
        this.infos = []
    }

    // índice de uma classe na lista de decls (= sua tag), ou -1.
    indexOfDecl(name: string): i64 {
        const nm: string = baseName(name);
        let i: i64 = 0;
        while (i < this.decls.len()) {
            if (strEq(this.decls[i].name, nm)) { return i; }
            i = i + 1;
        }
        return -1;
    }
    // índice em `infos` de uma classe já construída, ou -1.
    findInfo(name: string): i64 {
        const nm: string = baseName(name);
        let i: i64 = 0;
        while (i < this.infos.len()) {
            if (strEq(this.infos[i].name, nm)) { return i; }
            i = i + 1;
        }
        return -1;
    }

    // constrói todas as classes (resolve pai-antes-do-filho via infoFor).
    build() {
        let i: i64 = 0;
        while (i < this.decls.len()) {
            this.infoFor(this.decls[i].name);
            i = i + 1;
        }
    }

    // ClassInfo da classe `name`, construindo (e memoizando) sob demanda. O pai é
    // construído primeiro, pra herdar slots de campo e índices de vtable.
    infoFor(name: string): ClassInfo {
        const cached: i64 = this.findInfo(name);
        if (cached >= 0) { return this.infos[cached]; }

        const di: i64 = this.indexOfDecl(name);
        const decl: ClassDecl = this.decls[di];
        let fields: FieldInfo[] = [];
        let methods: MethodInfo[] = [];
        let nextSlot: i64 = 1;

        // herança: copia campos (mesmos slots) e vtable do pai
        if (!strEq(decl.parent, "") && this.indexOfDecl(decl.parent) >= 0) {
            const pinfo: ClassInfo = this.infoFor(decl.parent);
            for (const pf of pinfo.fields) { fields.push(new FieldInfo(pf.name, pf.ty, pf.slot)); }
            for (const pm of pinfo.methods) { methods.push(new MethodInfo(pm.name, pm.vindex, pm.owner)); }
            nextSlot = pinfo.nslots;
        }

        // campos próprios: slots após os herdados
        for (const cf of decl.fields) {
            fields.push(new FieldInfo(cf.name, cf.ty, nextSlot));
            nextSlot = nextSlot + 1;
        }

        // métodos próprios: override mantém o índice; novo método ganha o próximo
        for (const cm of decl.methods) {
            let idx: i64 = -1;
            let j: i64 = 0;
            while (j < methods.len()) {
                if (strEq(methods[j].name, cm.name)) { idx = j; }
                j = j + 1;
            }
            if (idx >= 0) { methods[idx] = new MethodInfo(cm.name, methods[idx].vindex, decl.name); }
            else { methods.push(new MethodInfo(cm.name, methods.len(), decl.name)); }
        }

        const ci: ClassInfo = new ClassInfo(decl.name, decl.parent, di, fields, methods, nextSlot);
        this.infos.push(ci);
        return ci;
    }

    find(name: string): ClassInfo { return this.infos[this.findInfo(name)]; }

    // slot de um campo (resolve herança), ou -1.
    fieldSlot(cls: string, field: string): i64 {
        const ci: ClassInfo = this.find(cls);
        for (const f of ci.fields) { if (strEq(f.name, field)) { return f.slot; } }
        return -1;
    }
    // índice de vtable de um método, ou -1.
    methodIndex(cls: string, method: string): i64 {
        const ci: ClassInfo = this.find(cls);
        for (const m of ci.methods) { if (strEq(m.name, method)) { return m.vindex; } }
        return -1;
    }
    // tipo declarado de um campo (resolve herança), ou "?".
    fieldType(cls: string, field: string): string {
        const ci: ClassInfo = this.find(cls);
        for (const f of ci.fields) { if (strEq(f.name, field)) { return f.ty; } }
        return "?";
    }
    // classe que define/sobrescreve um método (dono do slot de vtable), ou "".
    methodOwner(cls: string, method: string): string {
        const ci: ClassInfo = this.find(cls);
        for (const m of ci.methods) { if (strEq(m.name, method)) { return m.owner; } }
        return "";
    }
}

// ── tabela de enums ──────────────────────────────────────────────────────────
class EnumInfo {
    name: string
    variants: string[]      // índice = valor (0,1,2…)
    constructor(name: string, variants: string[]) { this.name = name; this.variants = variants }
}
class EnumTable {
    enums: EnumInfo[]
    constructor(decls: EnumDecl[]) {
        this.enums = [];
        for (const e of decls) { this.enums.push(new EnumInfo(e.name, e.variants)); }
    }
    // valor inteiro de uma variante (`enum.value`), ou -1 se não existe.
    value(enumName: string, variant: string): i64 {
        for (const e of this.enums) {
            if (strEq(e.name, enumName)) {
                let i: i64 = 0;
                while (i < e.variants.len()) {
                    if (strEq(e.variants[i], variant)) { return i; }
                    i = i + 1;
                }
            }
        }
        return -1;
    }
}

// ── dump (S-expression) p/ os testes ─────────────────────────────────────────
fn dumpField(f: FieldInfo): string { return `(field ${f.name} ${f.ty} ${f.slot})`; }
fn dumpMethod(m: MethodInfo): string { return `(method ${m.name} ${m.vindex} ${m.owner})`; }
fn dumpClass(ci: ClassInfo): string {
    let par: string = "_";
    if (!strEq(ci.parent, "")) { par = ci.parent; }
    let s: string = `(class ${ci.name} tag${ci.tag} ${par} slots${ci.nslots}`;
    for (const f of ci.fields) { s = concat(s, concat(" ", dumpField(f))); }
    for (const m of ci.methods) { s = concat(s, concat(" ", dumpMethod(m))); }
    return concat(s, ")");
}

// ── conveniências pros testes ────────────────────────────────────────────────
fn buildClasses(src: string): ClassTable {
    const p: Parser = new Parser(lexSrc(src));
    const prog: Program = p.parseModule();
    const ct: ClassTable = new ClassTable(prog.classes);
    ct.build();
    return ct;
}
fn semaClassStr(src: string, cls: string): string {
    const ct: ClassTable = buildClasses(src);
    return dumpClass(ct.find(cls));
}
fn semaFieldSlot(src: string, cls: string, field: string): i64 {
    return buildClasses(src).fieldSlot(cls, field);
}
fn semaMethodIndex(src: string, cls: string, method: string): i64 {
    return buildClasses(src).methodIndex(cls, method);
}
fn semaEnumValue(src: string, enumName: string, variant: string): i64 {
    const p: Parser = new Parser(lexSrc(src));
    const prog: Program = p.parseModule();
    const et: EnumTable = new EnumTable(prog.enums);
    return et.value(enumName, variant);
}

// ── inferência de tipo grosseira (F6.2-B) ────────────────────────────────────
// Tipos são strings, na mesma forma de parseTypeStr: "i64"/"f64"/"bool"/"string"/
// "void", arrays "T[]", "Map<V>", nome de classe, ou "?" (desconhecido). O codegen
// usa isso pra escolher a chamada de runtime (concat vs add, arr_get vs map_get…).

fn isPrimTy(ty: string): bool {
    return strEq(ty, "i64") || strEq(ty, "f64") || strEq(ty, "bool")
    || strEq(ty, "string") || strEq(ty, "void") || strEq(ty, "?") || strEq(ty, "any");
}
fn isArrayTy(ty: string): bool {
    const n: i64 = len(ty);
    if (n < 2) { return false; }
    return peek8(ty, n - 2) == 91 && peek8(ty, n - 1) == 93;   // termina em "[]"
}
fn elementTy(ty: string): string {
    if (isArrayTy(ty)) { return substring(ty, 0, len(ty) - 2); }
    return "?";
}
fn isMapTy(ty: string): bool {
    if (len(ty) < 5) { return false; }                         // "Map<>"
    return peek8(ty, 0) == 77 && peek8(ty, 1) == 97
    && peek8(ty, 2) == 112 && peek8(ty, 3) == 60;          // "Map<"
}
fn mapValueTy(ty: string): string {
    if (isMapTy(ty)) { return substring(ty, 4, len(ty) - 1); }
    return "?";
}
// tipo de função contém "=>" (ex.: "()=>i64", "(i64)=>i64").
fn isFunctionType(ty: string): bool {
    const n: i64 = len(ty);
    let i: i64 = 0;
    while (i + 1 < n) {
        if (peek8(ty, i) == 61 && peek8(ty, i + 1) == 62) { return true; }   // "=>"
        i = i + 1;
    }
    return false;
}
// nome de uma expressão Var, ou "" (p/ detectar `Classe.metodo()` estático).
fn exprVarName(e: Expr): string {
    return match (e) { Var v => v.name, _ => "" };
}
// f32 é promovido a f64 nos cálculos/saída (o modelo do runtime só tem double).
fn isFloatTy(ty: string): bool {
    return strEq(ty, "f64") || strEq(ty, "f32");
}
// nome-base de um tipo: tira os args genéricos ("Pilha<i64>" → "Pilha"). O type
// erasure faz `Pilha<i64>` e `Pilha<string>` compartilharem a MESMA classe.
fn baseName(ty: string): string {
    let i: i64 = 0;
    const n: i64 = len(ty);
    while (i < n) {
        if (peek8(ty, i) == 60) { return substring(ty, 0, i); }   // '<'
        i = i + 1;
    }
    return ty;
}
fn isClassTy(ty: string): bool {
    if (isPrimTy(ty)) { return false; }
    if (isArrayTy(ty)) { return false; }
    if (isMapTy(ty)) { return false; }
    if (isFunctionType(ty)) { return false; }
    return !strEq(ty, "");
}

// retorno de um builtin chamado por função `f(...)`; "" = não é builtin.
fn builtinFnRet(name: string): string {
    if (strEq(name, "len")) { return "i64"; }
    if (strEq(name, "concat")) { return "string"; }
    if (strEq(name, "charAt")) { return "string"; }
    if (strEq(name, "substring")) { return "string"; }
    if (strEq(name, "strEq")) { return "bool"; }
    if (strEq(name, "str")) { return "string"; }
    if (strEq(name, "parseInt")) { return "i64"; }
    if (strEq(name, "parseFloat")) { return "f64"; }
    if (strEq(name, "jsonAsFloat")) { return "f64"; }   // extrator de any → f64
    if (strEq(name, "fabs")) { return "f64"; }
    if (strEq(name, "sqrt") || strEq(name, "pow") || strEq(name, "floor")
        || strEq(name, "ceil") || strEq(name, "round") || strEq(name, "sin")
        || strEq(name, "cos") || strEq(name, "tan") || strEq(name, "exp")
        || strEq(name, "ln") || strEq(name, "log10")) { return "f64"; }
    if (strEq(name, "peek8")) { return "i64"; }
    if (strEq(name, "readFile")) { return "string"; }
    if (strEq(name, "writeFile")) { return "i64"; }
    if (strEq(name, "system")) { return "i64"; }
    if (strEq(name, "args")) { return "string[]"; }
    if (strEq(name, "mapGet")) { return "i64"; }
    if (strEq(name, "print")) { return "void"; }
    return "";
}

// Escopo léxico: nome → tipo (forma textual). Sobrescreve se já existe.
class Scope {
    names: string[]
    types: string[]
    constructor() { this.names = []; this.types = [] }
    set(name: string, ty: string) {
        let i: i64 = 0;
        while (i < this.names.len()) {
            if (strEq(this.names[i], name)) { this.types[i] = ty; return; }
            i = i + 1;
        }
        this.names.push(name); this.types.push(ty);
    }
    get(name: string): string {
        let i: i64 = 0;
        while (i < this.names.len()) {
            if (strEq(this.names[i], name)) { return this.types[i]; }
            i = i + 1;
        }
        return "?";
    }
}

// Visão semântica do programa: tabela de classes + enums + retornos de função.
// Expõe `typeOf(expr, scope)`, que o codegen consulta.
class Sema {
    classes: ClassTable
    enums: EnumTable
    funcs: Func[]
    funcNames: string[]
    funcRets: string[]
    constructor(prog: Program) {
        this.classes = new ClassTable(prog.classes);
        this.classes.build();
        this.enums = new EnumTable(prog.enums);
        this.funcs = prog.funcs;
        this.funcNames = [];
        this.funcRets = [];
        for (const f of prog.funcs) {
            this.funcNames.push(f.name);
            this.funcRets.push(f.ret);
        }
    }

    funcRet(name: string): string {
        let i: i64 = 0;
        while (i < this.funcNames.len()) {
            if (strEq(this.funcNames[i], name)) { return this.funcRets[i]; }
            i = i + 1;
        }
        return "?";
    }

    // tipos dos parâmetros de uma função de topo (vazio se não achar).
    funcParamTypes(name: string): string[] {
        for (const f of this.funcs) {
            if (strEq(f.name, name)) {
                let out: string[] = [];
                for (const p of f.params) { out.push(p.ty); }
                return out;
            }
        }
        let empty: string[] = [];
        return empty;
    }
    // tipos dos parâmetros de um método (ou constructor) de classe.
    methodParamTypes(cls: string, method: string): string[] {
        let empty: string[] = [];
        if (this.classes.findInfo(cls) < 0) { return empty; }
        const owner: string = this.classes.methodOwner(cls, method);
        const di: i64 = this.classes.indexOfDecl(owner);
        if (di < 0) { return empty; }
        const decl: ClassDecl = this.classes.decls[di];
        for (const f of decl.methods) {
            if (strEq(f.name, method)) {
                let out: string[] = [];
                for (const p of f.params) { out.push(p.ty); }
                return out;
            }
        }
        return empty;
    }

    // retorno de um método de classe (resolve dono via tabela de classes), ou "?".
    methodRet(cls: string, method: string): string {
        if (this.classes.findInfo(cls) < 0) { return "?"; }
        const owner: string = this.classes.methodOwner(cls, method);
        const di: i64 = this.classes.indexOfDecl(owner);
        if (di < 0) { return "?"; }
        const decl: ClassDecl = this.classes.decls[di];
        for (const f of decl.methods) { if (strEq(f.name, method)) { return f.ret; } }
        return "?";
    }

    typeOf(e: Expr, scope: Scope): string {
        return match (e) {
            IntLit n => "i64",
            FloatLit f => "f64",
            BoolLit b => "bool",
            StrLit s => "string",
            Template t => "string",
            Var v => scope.get(v.name),
            Unary u => this.typeUnary(u, scope),
            Binary b => this.typeBinary(b, scope),
            NewExpr ne => ne.cls,
            ArrayLit a => this.typeArrayLit(a, scope),
            MapLit ml => this.typeMapLit(ml, scope),
            Call c => this.typeCall(c, scope),
            MethodCall m => this.typeMethodCall(m, scope),
            Field fld => this.typeField(fld, scope),
            Index ix => this.typeIndex(ix, scope),
            Match mt => this.typeMatch(mt, scope),
            Lambda lm => "()=>?",
            TryExpr t => this.typeOf(t.call, scope),    // try f() tem o tipo de f()
            CatchExpr c => this.typeOf(c.lhs, scope),   // x catch y tem o tipo de x
            SpawnExpr s => "i64",                       // handle de thread (Future)
            AwaitExpr a => "i64",                       // resultado da thread
            _ => "?"
        };
    }

    typeUnary(u: Unary, scope: Scope): string {
        if (u.op == Tok.Bang) { return "bool"; }
        return this.typeOf(u.operand, scope);     // - e ~ preservam o tipo
    }

    typeBinary(b: Binary, scope: Scope): string {
        const op: Tok = b.op;
        if (op == Tok.EqEq || op == Tok.Neq || op == Tok.Lt || op == Tok.Gt
            || op == Tok.Le || op == Tok.Ge || op == Tok.AmpAmp || op == Tok.PipePipe) {
            return "bool";
        }
        if (isFloatTy(this.typeOf(b.lhs, scope))) { return "f64"; }
        if (isFloatTy(this.typeOf(b.rhs, scope))) { return "f64"; }
        return "i64";
    }

    typeArrayLit(a: ArrayLit, scope: Scope): string {
        if (a.items.len() == 0) { return "?[]"; }
        return concat(this.typeOf(a.items[0], scope), "[]");
    }
    typeMapLit(ml: MapLit, scope: Scope): string {
        if (ml.vals.len() == 0) { return "Map<?>"; }
        return concat(concat("Map<", this.typeOf(ml.vals[0], scope)), ">");
    }

    typeCall(c: Call, scope: Scope): string {
        // min/max são polimórficos: o tipo é o dos operandos (i64 ou f64)
        if (strEq(c.name, "min") || strEq(c.name, "max")) {
            if (c.args.len() == 0) { return "i64"; }
            const t0: string = this.typeOf(c.args[0], scope);
            if (strEq(t0, "f64")) { return "f64"; }
            if (c.args.len() > 1 && strEq(this.typeOf(c.args[1], scope), "f64")) { return "f64"; }
            return t0;
        }
        const bi: string = builtinFnRet(c.name);
        if (!strEq(bi, "")) { return bi; }
        return this.funcRet(c.name);
    }

    typeMethodCall(m: MethodCall, scope: Scope): string {
        // método ESTÁTICO: a base é o NOME de uma classe, não uma variável.
        const sbn: string = exprVarName(m.base);
        if (!strEq(sbn, "") && strEq(scope.get(sbn), "?") && this.classes.findInfo(sbn) >= 0) {
            return this.methodRet(sbn, m.method);
        }
        const bt: string = this.typeOf(m.base, scope);
        if (strEq(m.method, "len")) { return "i64"; }
        if (strEq(m.method, "push")) { return "void"; }
        if (strEq(m.method, "pop")) { return elementTy(bt); }
        if (strEq(m.method, "charAt") || strEq(m.method, "substring")) { return "string"; }
        if (strEq(m.method, "join")) { return "string"; }   // string[].join(sep) → string
        if (strEq(m.method, "trim") || strEq(m.method, "toLower") || strEq(m.method, "toUpper")
            || strEq(m.method, "replace")) { return "string"; }
        if (isClassTy(bt)) { return this.methodRet(bt, m.method); }
        return "?";
    }

    typeField(fld: Field, scope: Scope): string {
        const bt: string = this.typeOf(fld.base, scope);
        if (isClassTy(bt) && this.classes.findInfo(bt) >= 0) {
            return this.classes.fieldType(bt, fld.field);
        }
        return "?";
    }

    typeIndex(ix: Index, scope: Scope): string {
        const bt: string = this.typeOf(ix.base, scope);
        if (isArrayTy(bt)) { return elementTy(bt); }
        if (isMapTy(bt)) { return mapValueTy(bt); }
        if (strEq(bt, "string")) { return "string"; }    // char como string de 1 byte
        return "?";
    }

    // tipo do match = tipo do 1º braço (todos devem concordar). O binding do braço
    // entra no escopo com o tipo do padrão (mutação coarse; o codegen gerencia o seu).
    typeMatch(mt: Match, scope: Scope): string {
        if (mt.arms.len() == 0) { return "?"; }
        const a0: MatchArm = mt.arms[0];
        if (!strEq(a0.bind, "")) { scope.set(a0.bind, a0.pat); }
        return this.typeOf(a0.body, scope);
    }
}

fn buildSema(src: string): Sema {
    const p: Parser = new Parser(lexSrc(src));
    const prog: Program = p.parseModule();
    return new Sema(prog);
}

// conveniência de teste: tipa `exprSrc` num escopo com (names[i] → types[i]),
// usando as declarações de `declSrc` (classes/enums/funcs).
fn inferType(declSrc: string, exprSrc: string, names: string[], types: string[]): string {
    const sm: Sema = buildSema(declSrc);
    const scope: Scope = new Scope();
    let i: i64 = 0;
    while (i < names.len()) { scope.set(names[i], types[i]); i = i + 1; }
    const p: Parser = new Parser(lexSrc(exprSrc));
    return sm.typeOf(p.parseExpr(), scope);
}

// ── checagem: variável indefinida (Fase E, slice) ────────────────────────────
// Um diagnóstico carrega o offset de byte (linha/coluna são derivados no driver).
class Diag {
    pos: i64           // offset de byte de início
    span: i64          // comprimento (p/ endCol)
    msg: string
    constructor(pos: i64, span: i64, msg: string) { this.pos = pos; this.span = span; this.msg = msg }
}

// coleta nomes DECLARADOS (let/const/for-of) recursivamente — para o conjunto
// de nomes "definidos" (abordagem grosseira: definido em QUALQUER lugar = ok).
fn declStmts(stmts: Stmt[], names: string[]): i64 {
    for (const s of stmts) { declStmt(s, names); }
    return 0;
}
fn declStmt(s: Stmt, names: string[]): i64 {
    return match (s) {
        LetStmt l => addUniq(names, l.name),
        ForOfStmt fo => declForOf(fo, names),
        ForStmt fr => declForC(fr, names),
        IfStmt f => declIf(f, names),
        WhileStmt w => declStmts(w.body, names),
        _ => 0
    };
}
fn declForOf(fo: ForOfStmt, names: string[]): i64 { addUniq(names, fo.name); return declStmts(fo.body, names); }
fn declForC(fr: ForStmt, names: string[]): i64 {
    if (fr.hasInit) { declStmt(fr.init, names); }
    return declStmts(fr.body, names);
}
fn declIf(f: IfStmt, names: string[]): i64 { declStmts(f.thenB, names); return declStmts(f.elseB, names); }

// ── walk de checagem: cada Var fora de `defined` vira um diagnóstico ──────────
fn checkVar(v: Var, defined: string[], diags: Diag[]): i64 {
    if (idxOf(defined, v.name) < 0) {
        diags.push(new Diag(v.pos, len(v.name), concat(concat("undefined variable: '", v.name), "'")));
    }
    return 0;
}
fn checkExprs(es: Expr[], defined: string[], diags: Diag[]): i64 {
    for (const e of es) { checkExpr(e, defined, diags); }
    return 0;
}
fn checkBin(b: Binary, defined: string[], diags: Diag[]): i64 {
    checkExpr(b.lhs, defined, diags); return checkExpr(b.rhs, defined, diags);
}
fn checkMC(m: MethodCall, defined: string[], diags: Diag[]): i64 {
    checkExpr(m.base, defined, diags); return checkExprs(m.args, defined, diags);
}
fn checkIdx(ix: Index, defined: string[], diags: Diag[]): i64 {
    checkExpr(ix.base, defined, diags); return checkExpr(ix.index, defined, diags);
}
fn checkMatch(mt: Match, defined: string[], diags: Diag[]): i64 {
    checkExpr(mt.subject, defined, diags);
    for (const a of mt.arms) { addUniq(defined, a.bind); checkExpr(a.body, defined, diags); }
    return 0;
}
fn checkExpr(e: Expr, defined: string[], diags: Diag[]): i64 {
    return match (e) {
        Var v => checkVar(v, defined, diags),
        Unary u => checkExpr(u.operand, defined, diags),
        Binary b => checkBin(b, defined, diags),
        Call c => checkExprs(c.args, defined, diags),
        MethodCall m => checkMC(m, defined, diags),
        ArrayLit a => checkExprs(a.items, defined, diags),
        MapLit ml => checkExprs(ml.vals, defined, diags),
        StructLit sl => checkExprs(sl.vals, defined, diags),
        Index ix => checkIdx(ix, defined, diags),
        Field f => checkExpr(f.base, defined, diags),
        NewExpr ne => checkExprs(ne.args, defined, diags),
        Template t => checkExprs(t.parts, defined, diags),
        Match mt => checkMatch(mt, defined, diags),
        _ => 0
    };
}
fn checkStmts(stmts: Stmt[], defined: string[], diags: Diag[]): i64 {
    for (const s of stmts) { checkStmt(s, defined, diags); }
    return 0;
}
fn checkIf(f: IfStmt, defined: string[], diags: Diag[]): i64 {
    checkExpr(f.cond, defined, diags);
    checkStmts(f.thenB, defined, diags);
    return checkStmts(f.elseB, defined, diags);
}
fn checkWhile(w: WhileStmt, defined: string[], diags: Diag[]): i64 {
    checkExpr(w.cond, defined, diags); return checkStmts(w.body, defined, diags);
}
fn checkForOf(fo: ForOfStmt, defined: string[], diags: Diag[]): i64 {
    checkExpr(fo.iter, defined, diags); return checkStmts(fo.body, defined, diags);
}
fn checkForC(fr: ForStmt, defined: string[], diags: Diag[]): i64 {
    if (fr.hasInit) { checkStmt(fr.init, defined, diags); }
    if (fr.hasCond) { checkExpr(fr.cond, defined, diags); }
    if (fr.hasUpdate) { checkStmt(fr.update, defined, diags); }
    return checkStmts(fr.body, defined, diags);
}
fn checkAssign(a: AssignStmt, defined: string[], diags: Diag[]): i64 {
    checkExpr(a.target, defined, diags); return checkExpr(a.value, defined, diags);
}
fn checkReturn(r: ReturnStmt, defined: string[], diags: Diag[]): i64 {
    if (r.hasValue) { return checkExpr(r.value, defined, diags); }
    return 0;
}
fn checkStmt(s: Stmt, defined: string[], diags: Diag[]): i64 {
    return match (s) {
        LetStmt l => checkExpr(l.value, defined, diags),
        AssignStmt a => checkAssign(a, defined, diags),
        ReturnStmt r => checkReturn(r, defined, diags),
        IfStmt f => checkIf(f, defined, diags),
        WhileStmt w => checkWhile(w, defined, diags),
        ForOfStmt fo => checkForOf(fo, defined, diags),
        ForStmt fr => checkForC(fr, defined, diags),
        ExprStmt e => checkExpr(e.expr, defined, diags),
        _ => 0
    };
}

// checa um programa inteiro → lista de diagnósticos de variável indefinida.
fn checkProgram(prog: Program): Diag[] {
    let defined: string[] = [];
    addUniq(defined, "this");
    addUniq(defined, "Terminal");          // prelúdio
    for (const f of prog.funcs) { addUniq(defined, f.name); }
    for (const c of prog.classes) { addUniq(defined, c.name); }
    for (const e of prog.enums) { addUniq(defined, e.name); }
    // params + locais de todas as funções/métodos/main (definido em qq lugar = ok)
    for (const f of prog.funcs) {
        for (const p of f.params) { addUniq(defined, p.name); }
        declStmts(f.body, defined);
    }
    for (const c of prog.classes) {
        for (const m of c.methods) {
            for (const p of m.params) { addUniq(defined, p.name); }
            declStmts(m.body, defined);
        }
    }
    declStmts(prog.main, defined);

    let diags: Diag[] = [];
    for (const f of prog.funcs) { checkStmts(f.body, defined, diags); }
    for (const c of prog.classes) {
        for (const m of c.methods) { checkStmts(m.body, defined, diags); }
    }
    checkStmts(prog.main, defined, diags);
    return diags;
}
