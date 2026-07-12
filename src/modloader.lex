// modloader.lex — resolução de imports e merge de módulos (Fase F6.5).
//
// O compilador-em-lex compila UM programa que pode estar espalhado em vários
// arquivos via `import { … } from "./mod"`. Aqui carregamos o arquivo de entrada,
// seguimos os imports (recursivo, dedup por caminho), e juntamos tudo num único
// `Program` — momento em que tipos/classes cross-módulo passam a resolver (fecha
// a pendência da F6.2-B). O `main` é o do arquivo de entrada (script-mode).
import { lexSrc } from "./lexer"
import { Program, ClassDecl, EnumDecl, Func, Stmt, Import, Parser } from "./parser"
import { compileProgramToIR, compileProgramToIRT } from "./codegen"

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

// acha "std/<rel>" subindo diretórios (igual find_std_file do compilador Rust):
// tenta std/, ../std/, ../../std/… Devolve o 1º que existe, ou "std/<rel>".
fn findStd(rel: string): string {
    let prefix: string = "";
    let i: i64 = 0;
    while (i < 8) {
        const cand: string = concat(prefix, concat("std/", rel));
        if (exists(cand)) { return cand; }
        prefix = concat(prefix, "../");
        i = i + 1;
    }
    return concat("std/", rel);
}

// acha o `src/runtime.c` subindo diretórios (p/ o link via clang funcionar de
// qualquer subpasta). Devolve o 1º que existe, ou "src/runtime.c".
fn findRuntime(): string {
    let prefix: string = "";
    let i: i64 = 0;
    while (i < 8) {
        const cand: string = concat(prefix, "src/runtime.c");
        if (exists(cand)) { return cand; }
        prefix = concat(prefix, "../");
        i = i + 1;
    }
    return "src/runtime.c";
}

// resolve um import:
//   "./mod"     → "dir/mod.lex" (relativo ao importador)
//   "../x/mod"  → "dir/../x/mod.lex" (relativo, mantém o ../)
//   "mod"       → módulo std: "std/mod.lex" (subindo diretórios)
fn resolveImport(importer: string, spec: string): string {
    const dir: string = dirOf(importer);
    if (len(spec) >= 2 && peek8(spec, 0) == 46 && peek8(spec, 1) == 47) {   // "./"
        const s: string = substring(spec, 2, len(spec));
        if (strEq(dir, "")) { return concat(s, ".lex"); }
        return concat(concat(dir, "/"), concat(s, ".lex"));
    }
    if (len(spec) >= 3 && peek8(spec, 0) == 46 && peek8(spec, 1) == 46 && peek8(spec, 2) == 47) {  // "../"
        if (strEq(dir, "")) { return concat(spec, ".lex"); }
        return concat(concat(dir, "/"), concat(spec, ".lex"));
    }
    return findStd(concat(spec, ".lex"));   // nome "bare" → módulo std
}

class ModuleLoader {
    visited: string[]
    classes: ClassDecl[]
    enums: EnumDecl[]
    funcs: Func[]
    main: Stmt[]
    constructor() {
        this.visited = []
        this.classes = []
        this.enums = []
        this.funcs = []
        this.main = []
    }

    seen(path: string): bool {
        for (const v of this.visited) { if (strEq(v, path)) { return true; } }
        return false;
    }

    // carrega `path` (e seus imports, antes), juntando as declarações.
    load(path: string) {
        if (this.seen(path)) { return; }
        this.visited.push(path);
        const src: string = readFile(path);
        const p: Parser = new Parser(lexSrc(src));
        const prog: Program = p.parseModule();
        // dependências primeiro
        for (const im of prog.imports) {
            this.load(resolveImport(path, im.module));
        }
        // junta as declarações próprias deste módulo
        for (const c of prog.classes) { this.classes.push(c); }
        for (const e of prog.enums) { this.enums.push(e); }
        for (const f of prog.funcs) { this.funcs.push(f); }
        for (const s of prog.main) { this.main.push(s); }   // só o entry tem main
    }

    toProgram(): Program {
        let noImports: Import[] = [];
        return new Program(noImports, this.enums, this.classes, this.funcs, this.main);
    }
}

// caminho do arquivo de entrada → Program único (com tudo mesclado).
fn loadProgram(entry: string): Program {
    const ml: ModuleLoader = new ModuleLoader();
    ml.load(entry);
    return ml.toProgram();
}

// caminho de entrada → texto do LLVM IR (resolve imports + codegen).
// `target`: 0 = nativo, 1 = wasm32.
fn compileFileToIRT(entry: string, target: i64): string {
    return compileProgramToIRT(loadProgram(entry), target);
}
fn compileFileToIR(entry: string): string { return compileFileToIRT(entry, 0); }
