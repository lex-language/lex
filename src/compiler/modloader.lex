// modloader.lex — resolução de imports e merge de módulos (Fase F6.5).
//
// O compilador-em-lex compila UM programa que pode estar espalhado em vários
// arquivos via `import { … } from "./mod"`. Aqui carregamos o arquivo de entrada,
// seguimos os imports (recursivo, dedup por caminho), e juntamos tudo num único
// `Program` — momento em que tipos/classes cross-módulo passam a resolver (fecha
// a pendência da F6.2-B). O `main` é o do arquivo de entrada (script-mode).
import { lexSrc } from "./lexer"
import { Program, ClassDecl, EnumDecl, Func, Stmt, Import, Parser } from "./parser"
import { Expr, StrLit, IntLit, FloatLit, BoolLit, Var, Call, NewExpr, MethodCall, ExprStmt } from "./parser"
import { compileProgramToIR, compileProgramToIRT } from "./codegen"
import { parseLsx, componentName, propsClassName } from "./lsx"
import { write } from "libc"

// erro do loader → stderr (fd 2). NUNCA stdout: o LSP fala JSON-RPC por lá e
// qualquer print solto corromperia o protocolo.
fn loaderErr(msg: string) {
    const s: string = concat(msg, "\n");
    write(2, s, len(s));
}

fn isLsx(path: string): bool {
    const n: i64 = len(path);
    return n > 4 && strEq(substring(path, n - 4, n), ".lsx");
}

// true se o caminho/spec já termina em extensão de fonte conhecida.
fn hasSrcExt(s: string): bool {
    const n: i64 = len(s);
    if (n < 4) { return false; }
    const e: string = substring(s, n - 4, n);
    return strEq(e, ".lex") || strEq(e, ".lsx");
}

// `base` sem extensão → o arquivo que existe. Tenta .lex e depois .lsx; se
// nenhum existir devolve o .lex (preserva a mensagem de erro de antes).
fn pickExt(base: string): string {
    const a: string = concat(base, ".lex");
    if (exists(a)) { return a; }
    const b: string = concat(base, ".lsx");
    if (exists(b)) { return b; }
    return a;
}

// diretório de um caminho ("a/b/c.lex" → "a/b"; "c.lex" → "").
fn dirOf(path: string): string {
    let cut: i64 = -1;
    let i: i64 = 0;
    const n: i64 = len(path);
    while (i < n) {
        if (peek8(path, i) == 47) { cut = i; }   // '/'
        i = i + 1;
    }
    if (cut < 0) { return ""; }
    return substring(path, 0, cut);
}

// Raiz da instalação: $LEX_INSTALL_DIR, senão $HOME/.lex (o mesmo par que o
// install.sh usa). "" quando não dá para saber.
fn lexHome(): string {
    const custom: string = getenv("LEX_INSTALL_DIR");
    if (len(custom) > 0) { return custom; }
    const home: string = getenv("HOME");
    if (len(home) > 0) { return concat(home, "/.lex"); }
    return "";
}

// acha "src/std/<rel>" — é como um `import { x } from "libc"` (nome "bare")
// vira um caminho.
//
// Vale a MESMA regra do runtime.c (ver findRuntime): um `lex` instalado não tem
// o repositório por perto, e sem isto qualquer programa com `import` falhava no
// link ("undefined symbol: @argPort" e afins) — só quem não importava nada
// compilava. Dentro do repo o fonte continua ganhando do instalado.
fn findStd(rel: string): string {
    const explicito: string = getenv("LEX_STD");
    if (len(explicito) > 0) {
        const cand0: string = concat(concat(explicito, "/"), rel);
        if (exists(cand0)) { return cand0; }
    }

    let prefix: string = "";
    let i: i64 = 0;
    while (i < 8) {
        const cand: string = concat(prefix, concat("src/std/", rel));
        if (exists(cand)) { return cand; }
        prefix = concat(prefix, "../");
        i = i + 1;
    }

    const raiz: string = lexHome();
    if (len(raiz) > 0) {
        const inst: string = concat(raiz, concat("/lib/std/", rel));
        if (exists(inst)) { return inst; }
    }

    return concat("src/std/", rel);
}

// acha o `src/runtime.c` subindo diretórios (p/ o link via clang funcionar de
// qualquer subpasta). Devolve o 1º que existe, ou "src/runtime.c".
// Todo build linka o `runtime.c`, então o compilador precisa achá-lo — e um
// `lex` INSTALADO não tem o repositório por perto. Era o furo da distribuição:
// `curl … | sh` entregava um binário que rodava `lex version` mas falhava em
// `lex run` com "no such file or directory: 'src/runtime.c'".
//
// Ordem, da mais específica para a mais genérica:
//   1. $LEX_RUNTIME       — o caminho exato, para quem quer mandar
//   2. ./src/runtime.c    — subindo diretórios: é o repo, e dentro dele o
//                           runtime do FONTE tem de ganhar do instalado
//   3. a raiz da instalação (lexHome): $LEX_INSTALL_DIR, senão $HOME/.lex
fn runtimeUnder(dir: string): string {
    if (len(dir) == 0) { return ""; }
    const cand: string = concat(dir, "/lib/runtime.c");
    if (exists(cand)) { return cand; }
    return "";
}

fn findRuntime(): string {
    const explicito: string = getenv("LEX_RUNTIME");
    if (len(explicito) > 0 && exists(explicito)) { return explicito; }

    let prefix: string = "";
    let i: i64 = 0;
    while (i < 8) {
        const cand: string = concat(prefix, "src/runtime.c");
        if (exists(cand)) { return cand; }
        prefix = concat(prefix, "../");
        i = i + 1;
    }

    const instalado: string = runtimeUnder(lexHome());
    if (len(instalado) > 0) { return instalado; }

    return "src/runtime.c";
}

// resolve um import:
//   "./mod"     → "dir/mod.lex" (relativo ao importador)
//   "../x/mod"  → "dir/../x/mod.lex" (relativo, mantém o ../)
//   "mod"       → módulo std: "std/mod.lex" (subindo diretórios)
// colapsa os `x/../` de um caminho ("src/tools/../compiler/lexer.lex" →
// "src/compiler/lexer.lex"). CRÍTICO: o dedup do loader é por STRING de caminho, e
// sem isto o mesmo arquivo, alcançado por duas grafias, seria carregado DUAS vezes —
// e as classes dele apareceriam duplicadas na IR.
fn normPath(path: string): string {
    const abs: bool = len(path) > 0 && peek8(path, 0) == 47;   // preserva o "/" inicial
    let parts: string[] = [];
    let cur: string = "";
    let i: i64 = 0;
    const n: i64 = len(path);
    while (i <= n) {
        if (i == n || peek8(path, i) == 47) {              // '/' ou fim
            if (strEq(cur, "..") && parts.len() > 0 && !strEq(parts[parts.len() - 1], "..")) {
                parts.pop();                              // sobe um nível
            } else if (!strEq(cur, "") && !strEq(cur, ".")) {
                parts.push(cur);
            }
            cur = "";
        } else {
            cur = concat(cur, charAt(path, i));
        }
        i = i + 1;
    }
    const joined: string = parts.join("/");
    if (abs) { return concat("/", joined); }
    return joined;
}

// A extensão pode vir EXPLÍCITA no spec (`"./Card.lsx"`) ou ser deduzida por
// sondagem (`"./Card"` → Card.lex, senão Card.lsx). Explícito ganha, e é o que
// eu recomendo escrever quando existirem Card.lex e Card.lsx lado a lado — sem
// isso a precedência do pickExt vira shadowing silencioso.
fn resolveImport(importer: string, spec: string): string {
    const dir: string = dirOf(importer);
    const rel: bool = len(spec) >= 2 && peek8(spec, 0) == 46 && peek8(spec, 1) == 47;      // "./"
    const up: bool = len(spec) >= 3 && peek8(spec, 0) == 46 && peek8(spec, 1) == 46 && peek8(spec, 2) == 47;  // "../"
    if (rel || up) {
        let s: string = spec;
        if (rel) { s = substring(spec, 2, len(spec)); }      // "../" mantém o ../
        let base: string = s;
        if (!strEq(dir, "")) { base = normPath(concat(concat(dir, "/"), s)); }
        else if (up) { base = normPath(s); }
        if (hasSrcExt(base)) { return base; }
        return pickExt(base);
    }
    if (hasSrcExt(spec)) { return findStd(spec); }
    const std: string = findStd(concat(spec, ".lex"));      // nome "bare" → std
    if (exists(std)) { return std; }
    const stdx: string = findStd(concat(spec, ".lsx"));
    if (exists(stdx)) { return stdx; }
    return std;
}

class ModuleLoader {
    visited: string[]
    externs: Func[]
    classes: ClassDecl[]
    enums: EnumDecl[]
    funcs: Func[]
    main: Stmt[]
    lambdaN: i64        // contador GLOBAL de arrows içadas (ver nota em load)
    comps: string[]     // componentes .lsx já vistos (nome)
    compPaths: string[] // …e de qual arquivo vieram, p/ a mensagem de colisão
    clientFuncs: Func[] // `client function` — funções client-side (WASM)
    constructor() {
        this.visited = []
        this.externs = []
        this.classes = []
        this.enums = []
        this.funcs = []
        this.main = []
        this.lambdaN = 0
        this.comps = []
        this.compPaths = []
        this.clientFuncs = []
    }

    // um componente .lsx exporta uma `fn <Nome>` e uma `class <Nome>Props` de
    // topo. O espaço de nomes do lex é plano, então dois Card.lsx em pastas
    // diferentes dariam duas `@Card` na IR. O clang até acusa, mas com uma
    // mensagem sobre símbolo duplicado que não diz nada sobre componentes.
    noteComponent(name: string, path: string) {
        let i: i64 = 0;
        while (i < this.comps.len()) {
            if (strEq(this.comps[i], name)) {
                loaderErr(concat(concat(concat("erro: dois componentes chamados '", name), concat("' (", this.compPaths[i])), concat(concat(" e ", path), ") — o nome de um componente e o nome do arquivo, e precisa ser unico no programa")));
                return;
            }
            i = i + 1;
        }
        this.comps.push(name);
        this.compPaths.push(path);
    }

    seen(path: string): bool {
        for (const v of this.visited) { if (strEq(v, path)) { return true; } }
        return false;
    }

    // carrega `path` (e seus imports, antes), juntando as declarações.
    //
    // O `lambdaN` é semeado a partir do contador do LOADER e devolvido depois:
    // cada Parser nasce com o contador em 0, então dois módulos com uma arrow
    // cada produziam DOIS `__lambda_0` e o clang recusava a IR por redefinição.
    load(path: string) {
        if (this.seen(path)) { return; }
        this.visited.push(path);
        const src: string = readFile(path);
        let prog: Program = new Program([], [], [], [], []);
        if (isLsx(path)) {
            // o corpo de um .lsx NÃO passa pelo lexer do lex — o parser aqui é
            // só o "hospedeiro" dos lambdas e erros das interpolações.
            const h: Parser = new Parser(lexSrc(""));
            h.lambdaN = this.lambdaN;
            this.noteComponent(componentName(path), path);
            prog = parseLsx(path, src, h);
            for (const lm of h.lambdas) { prog.funcs.push(lm); }
            this.lambdaN = h.lambdaN;
        } else {
            const p: Parser = new Parser(lexSrc(src));
            p.lambdaN = this.lambdaN;
            prog = p.parseModule();
            this.lambdaN = p.lambdaN;
        }
        // dependências primeiro
        for (const im of prog.imports) {
            this.load(resolveImport(path, im.module));
        }
        // junta as declarações próprias deste módulo
        for (const c of prog.classes) { this.classes.push(c); }
        for (const e of prog.enums) { this.enums.push(e); }
        for (const f of prog.funcs) { this.funcs.push(f); }
        for (const s of prog.main) { this.main.push(s); }   // só o entry tem main
        for (const e of prog.externs) { this.externs.push(e); }
        for (const cf of prog.clientFuncs) { this.clientFuncs.push(cf); }
    }

    toProgram(): Program {
        let noImports: Import[] = [];
        const prog: Program = new Program(noImports, this.enums, this.classes, this.funcs, this.main);
        prog.externs = this.externs;
        prog.clientFuncs = this.clientFuncs;
        return prog;
    }
}

// Parseia UM arquivo pelo pipeline certo da sua extensão e devolve o Parser,
// que carrega os erros de sintaxe (errs/errPos). É o que o `lex check` e o LSP
// usam — sem isto um .lsx seria lexado como .lex e cuspiria uma cascata de
// "unexpected token" em cima do markup.
fn parseSource(path: string, src: string): Parser {
    if (isLsx(path)) {
        const h: Parser = new Parser(lexSrc(""));
        parseLsx(path, src, h);
        return h;
    }
    const p: Parser = new Parser(lexSrc(src));
    p.parseModule();
    return p;
}

// caminho do arquivo de entrada → Program único (com tudo mesclado).
// valor default de uma prop, p/ o `main` sintetizado do entry .lsx. Espelha o
// propValue do codegen: a célula é a mesma, só o tipo escolhe o literal.
fn defaultForTy(ty: string): Expr {
    if (strEq(ty, "string") || strEq(ty, "Html") || strEq(ty, "ptr")) { return new StrLit(""); }
    if (strEq(ty, "f64") || strEq(ty, "f32")) { return new FloatLit(0.0); }
    if (strEq(ty, "bool")) { return new BoolLit(false); }
    return new IntLit(0);
}

// `lex run site.lsx` — um .lsx usado como ENTRADA sintetiza o próprio `main`:
// renderiza o componente e imprime o HTML.
//
// Sem isto um .lsx só declara `fn <Nome>` e `class <Nome>Props`, nunca um
// `main` — e o clang falhava com "symbol _main not found". Obrigar um .lex de
// embrulho só para chamar Terminal.log era cerimônia pura: o arquivo já diz o
// que quer renderizar.
//
// As props do componente de entrada saem no default (""/0/false): quem roda uma
// página pela linha de comando não tem de onde tirá-las. Um componente que
// EXIGE props segue sendo importável normalmente de outro módulo.
fn synthLsxMain(ml: ModuleLoader, entry: string) {
    const comp: string = componentName(entry);
    const propsTy: string = propsClassName(comp);
    let args: Expr[] = [];
    for (const cd of ml.classes) {
        if (!strEq(cd.name, propsTy)) { continue; }
        for (const m of cd.methods) {
            if (!strEq(m.name, "constructor")) { continue; }
            for (const p of m.params) { args.push(defaultForTy(p.ty)); }
        }
    }
    let callArgs: Expr[] = [];
    callArgs.push(new NewExpr(propsTy, args));
    let logArgs: Expr[] = [];
    logArgs.push(new Call(comp, callArgs));
    ml.main.push(new ExprStmt(new MethodCall(new Var("Terminal", 0), "log", logArgs)));
}

fn loadProgram(entry: string): Program {
    const ml: ModuleLoader = new ModuleLoader();
    if (isLsx(entry)) { ml.load(findStd("terminal.lex")); }   // p/ o Terminal.log do main
    ml.load(entry);
    if (isLsx(entry)) { synthLsxMain(ml, entry); }
    return ml.toProgram();
}

// caminho de entrada → texto do LLVM IR (resolve imports + codegen).
// `target`: 0 = nativo, 1 = wasm32.
fn compileFileToIRT(entry: string, target: i64): string {
    return compileProgramToIRT(loadProgram(entry), target);
}
fn compileFileToIR(entry: string): string { return compileFileToIRT(entry, 0); }
