// lexcli.lex — driver unificado do lex, escrito em lex. Junta num único binário
// os subcomandos já portados (compilar/rodar/formatar), rumo a substituir o
// `lex` de produção (src/main.rs). Cada subcomando delega a um módulo self-hosted.
//
//   lex build <arquivo.lex> [-o saida]   compila → binário nativo (linka runtime.c)
//   lex run <arquivo.lex>                 compila p/ temp e executa (devolve exit)
//   lex fmt [--check] <arquivos.lex>      formata (in-place) ou confere
//   lex test <arquivos.test.lex>...       roda as suítes via o harness
//   lex check [--json] <arquivos.lex>...  diagnósticos (variável indefinida) em JSON
//   lex lsp                               Language Server por stdio
//   lex pkg <init|add|remove|list> ...    gerenciador de pacotes (manifesto)
//   lex version                           versão
//
// (wasm/cross-compile e o fetch de rede do pkg ainda faltam — ver REMOVER-RUST.md.)
import { compileFileToIR, findRuntime } from "./modloader"
import { formatSource } from "./fmt"
import { runTestFile } from "./testrunner"
import { runCheck } from "./checker"
import { runLsp } from "./lspserver"
import { runPkg } from "./pkgcmd"

fn hasSuffix(s: string, suf: string): bool {
    const sl: i64 = len(s);
    const fl: i64 = len(suf);
    if (fl > sl) { return false; }
    return strEq(substring(s, sl - fl, sl), suf);
}

// flags do clang p/ um alias de alvo (cross-compile). "" = nativo.
// macOS x64/arm64 funciona no mesmo SO (clang -arch). linux/windows precisam de
// sysroot; wasm32 precisa de codegen ptr-aware (i32) — ainda não suportados.
fn targetFlags(alias: string): string {
    if (strEq(alias, "macos-x64")) { return "-arch x86_64 -mmacosx-version-min=11.0"; }
    if (strEq(alias, "macos-arm64")) { return "-arch arm64 -mmacosx-version-min=11.0"; }
    Terminal.log(`aviso: alvo '${alias}' nao suportado (so macos-x64/arm64); usando nativo`);
    return "";
}

// compila um arquivo .lex (resolvendo imports) p/ binário em `out`, com flags de
// alvo opcionais.
fn buildFileT(file: string, out: string, flags: string): i64 {
    const ir: string = compileFileToIR(file);
    const ll: string = concat(out, ".ll");
    writeFile(ll, ir);
    const rc: i64 = system(`clang -Wno-override-module ${flags} -o ${out} ${ll} ${findRuntime()} -lpthread`);
    if (rc != 0) { Terminal.log(`erro: clang falhou (rc=${rc})`); return 1; }
    return 0;
}
fn buildFile(file: string, out: string): i64 { return buildFileT(file, out, ""); }

// recompila ao mudar o arquivo (poll de conteúdo a cada 1s — não há builtin de
// mtime/sleep, então usa system("sleep 1")). Roda até Ctrl-C.
fn watchLoop(file: string, out: string): i64 {
    Terminal.log("watching... (Ctrl-C p/ sair)");
    let last: string = readFile(file);
    while (true) {
        system("sleep 1");
        const cur: string = readFile(file);
        if (!strEq(cur, last)) {
            Terminal.log(`mudou: recompilando ${file}`);
            buildFile(file, out);
            last = cur;
        }
    }
    return 0;
}

fn cmdBuild(av: string[]): i64 {
    let file: string = "";
    let out: string = "a.out";
    let watch: bool = false;
    let flags: string = "";
    let i: i64 = 2;
    while (i < av.len()) {
        if (strEq(av[i], "-o") && i + 1 < av.len()) { out = av[i + 1]; i = i + 2; }
        else if (strEq(av[i], "--watch")) { watch = true; i = i + 1; }
        else if (strEq(av[i], "--target") && i + 1 < av.len()) { flags = targetFlags(av[i + 1]); i = i + 2; }
        else { file = av[i]; i = i + 1; }
    }
    if (strEq(file, "")) { Terminal.log("uso: lex build <arquivo.lex> [-o saida] [--target t] [--watch]"); return 1; }
    if (buildFileT(file, out, flags) != 0) { return 1; }
    Terminal.log(`ok: ${file} -> ${out}`);
    if (watch) { return watchLoop(file, out); }
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

// lex test <arquivos.test.lex>... — roda cada suíte via o harness (lextest).
fn cmdTest(av: string[]): i64 {
    let failed: i64 = 0;
    let i: i64 = 2;
    while (i < av.len()) {
        const f: string = av[i];
        Terminal.log(concat("── ", f));
        if (runTestFile(f) != 0) { failed = failed + 1; }
        i = i + 1;
    }
    if (failed == 0) { Terminal.log("✓ tudo passou"); }
    return failed;
}

// lex check [--json] <arquivos.lex>... — diagnósticos (variável indefinida) em JSON.
fn cmdCheck(av: string[]): i64 {
    let bad: i64 = 0;
    let i: i64 = 2;
    while (i < av.len()) {
        const path: string = av[i];
        if (strEq(path, "--json")) { i = i + 1; }       // sempre JSON; ignora a flag
        else {
            if (runCheck(path) != 0) { bad = 1; }
            i = i + 1;
        }
    }
    return bad;
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
else if (strEq(cmd, "test")) { rc = cmdTest(av); }
else if (strEq(cmd, "check")) { rc = cmdCheck(av); }
else if (strEq(cmd, "lsp")) { rc = runLsp(); }
else if (strEq(cmd, "pkg")) { rc = runPkg(av, 2); }
else { Terminal.log(`lex: comando desconhecido '${cmd}'`); rc = 1; }
return rc;
