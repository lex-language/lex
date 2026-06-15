// lexcli.lex — driver unificado do lex, escrito em lex. Junta num único binário
// os subcomandos já portados (compilar/rodar/formatar), rumo a substituir o
// `lex` de produção (src/main.rs). Cada subcomando delega a um módulo self-hosted.
//
//   lex build <arquivo.lex> [-o saida]   compila → binário nativo (linka runtime.c)
//   lex run <arquivo.lex>                 compila p/ temp e executa (devolve exit)
//   lex fmt [--check] <arquivos.lex>      formata (in-place) ou confere
//   lex version                           versão
//
// (check/test/lsp/pkg/wasm ainda são binários/ferramentas à parte — ver README.)
import { compileFileToIR } from "./modloader"
import { formatSource } from "./fmt"

fn hasSuffix(s: string, suf: string): bool {
    const sl: i64 = len(s);
    const fl: i64 = len(suf);
    if (fl > sl) { return false; }
    return strEq(substring(s, sl - fl, sl), suf);
}

// compila um arquivo .lex (resolvendo imports) p/ binário nativo `out`.
fn buildFile(file: string, out: string): i64 {
    const ir: string = compileFileToIR(file);
    const ll: string = concat(out, ".ll");
    writeFile(ll, ir);
    const rc: i64 = system(`clang -Wno-override-module -o ${out} ${ll} src/runtime.c -lpthread`);
    if (rc != 0) { Terminal.log(`erro: clang falhou (rc=${rc})`); return 1; }
    return 0;
}

fn cmdBuild(av: string[]): i64 {
    let file: string = "";
    let out: string = "a.out";
    let i: i64 = 2;
    while (i < av.len()) {
        if (strEq(av[i], "-o") && i + 1 < av.len()) { out = av[i + 1]; i = i + 2; }
        else { file = av[i]; i = i + 1; }
    }
    if (strEq(file, "")) { Terminal.log("uso: lex build <arquivo.lex> [-o saida]"); return 1; }
    if (buildFile(file, out) != 0) { return 1; }
    Terminal.log(`ok: ${file} -> ${out}`);
    return 0;
}

fn cmdRun(av: string[]): i64 {
    if (av.len() < 3) { Terminal.log("uso: lex run <arquivo.lex>"); return 1; }
    const bin: string = "/tmp/lexcli_run";
    if (buildFile(av[2], bin) != 0) { return 1; }
    return system(bin) / 256;       // WEXITSTATUS
}

fn cmdFmt(av: string[]): i64 {
    let check: bool = false;
    let files: string[] = [];
    let i: i64 = 2;
    while (i < av.len()) {
        if (strEq(av[i], "--check")) { check = true; }
        else { files.push(av[i]); }
        i = i + 1;
    }
    if (files.len() == 0) { Terminal.log("uso: lex fmt [--check] <arquivos.lex>"); return 1; }
    let changed: i64 = 0;
    for (const f of files) {
        if (!hasSuffix(f, ".lex")) { Terminal.log(`lex fmt: pulando '${f}' (não é .lex)`); }
        else {
            const src: string = readFile(f);
            const formatted: string = formatSource(src);
            if (!strEq(formatted, src)) {
                changed = changed + 1;
                if (check) { Terminal.log(`would reformat ${f}`); }
                else { writeFile(f, formatted); Terminal.log(`formatted ${f}`); }
            }
        }
    }
    if (check && changed > 0) { return 1; }
    return 0;
}

// ── despacho (script-mode → main) ────────────────────────────────────────────
const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lex <build|run|fmt|version> ...");
    return 1;
}
const cmd: string = av[1];
let rc: i64 = 0;
if (strEq(cmd, "version") || strEq(cmd, "--version")) { Terminal.log("lex (self-hosted) 0.1.0"); }
else if (strEq(cmd, "build") || strEq(cmd, "compile")) { rc = cmdBuild(av); }
else if (strEq(cmd, "run")) { rc = cmdRun(av); }
else if (strEq(cmd, "fmt")) { rc = cmdFmt(av); }
else { Terminal.log(`lex: comando desconhecido '${cmd}'`); rc = 1; }
return rc;
