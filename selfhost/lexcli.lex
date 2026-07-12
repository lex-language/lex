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
import { compileFileToIR, compileFileToIRT, findRuntime } from "./modloader"
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

// ── cross-compile ────────────────────────────────────────────────────────────
// Um alvo: triple do LLVM (p/ emitir o objeto), arquitetura (p/ o llvm-lib do
// Windows), SO (escolhe como linkar) e extensão do binário. `os` vazio = alias
// desconhecido.
class CrossT {
    llvm: string
    arch: string
    os: string
    ext: string
    constructor(llvm: string, arch: string, os: string, ext: string) {
        this.llvm = llvm; this.arch = arch; this.os = os; this.ext = ext
    }
}
fn resolveCross(alias: string): CrossT {
    if (strEq(alias, "linux-x64")) { return new CrossT("x86_64-unknown-linux-gnu", "x86_64", "linux", ""); }
    if (strEq(alias, "linux-arm64")) { return new CrossT("aarch64-unknown-linux-gnu", "aarch64", "linux", ""); }
    if (strEq(alias, "windows-x64")) { return new CrossT("x86_64-pc-windows-msvc", "x64", "windows", ".exe"); }
    if (strEq(alias, "windows-arm64")) { return new CrossT("aarch64-pc-windows-msvc", "arm64", "windows", ".exe"); }
    if (strEq(alias, "macos-x64")) { return new CrossT("x86_64-apple-macosx11.0.0", "x86_64", "macos", ""); }
    if (strEq(alias, "macos-arm64")) { return new CrossT("arm64-apple-macosx11.0.0", "arm64", "macos", ""); }
    return new CrossT("", "", "", "");
}

// .def das funções do kernel32/ws2_32 que a runtime freestanding do Windows usa.
// O llvm-lib gera a import lib MS a partir daqui — sem Windows SDK, sem mingw.
fn kernel32Def(): string {
    return "LIBRARY kernel32.dll\nEXPORTS\nGetStdHandle\nWriteFile\nReadFile\nCloseHandle\nGetProcessHeap\nHeapAlloc\nHeapFree\nHeapReAlloc\nCreateFileW\nSetFilePointerEx\nGetFileAttributesW\nGetFileAttributesExW\nDeleteFileW\nMoveFileExW\nCreateDirectoryW\nRemoveDirectoryW\nFindFirstFileW\nFindNextFileW\nFindClose\nMultiByteToWideChar\nWideCharToMultiByte\nGetCurrentThreadId\nCreateThread\nWaitForSingleObject\nSleep\nInitializeCriticalSection\nEnterCriticalSection\nLeaveCriticalSection\nDeleteCriticalSection\nInitializeConditionVariable\nSleepConditionVariableCS\nWakeConditionVariable\nWakeAllConditionVariable\nExitProcess\n";
}
fn ws2Def(): string {
    return "LIBRARY ws2_32.dll\nEXPORTS\nWSAStartup\nsocket\nbind\nlisten\naccept\nsetsockopt\nrecv\nsend\nclosesocket\n";
}

// cross-compile p/ outro SO/arquitetura. A IR é agnóstica: o objeto sai no triple
// do alvo (clang --target), e o link traz o que cada SO precisa:
//   macOS   — clang do sistema com -arch (usa o SDK; sem toolchain extra)
//   Linux   — runtime FREESTANDING (syscalls cruas, sem libc/CRT) + ld.lld → estático
//   Windows — runtime FREESTANDING pela Win32 (kernel32/ws2_32) + lld-link, com as
//             import libs geradas na hora pelo llvm-lib a partir dos .def
fn buildCross(file: string, out: string, xt: CrossT): i64 {
    const ir: string = compileFileToIR(file);       // mesma IR de sempre (agnóstica)
    const ll: string = concat(out, ".ll");
    writeFile(ll, ir);
    const clang: string = findLlvmTool("clang");
    const obj: string = concat(out, ".o");
    const rt: string = findRuntime();

    let rc: i64 = system(`${clang} --target=${xt.llvm} -O2 -c ${ll} -o ${obj} -Wno-override-module`);
    if (rc != 0) { Terminal.log(`erro: clang falhou ao emitir o objeto (rc=${rc})`); return 1; }

    if (strEq(xt.os, "macos")) {
        rc = system(`clang -arch ${xt.arch} -mmacosx-version-min=11.0 ${obj} ${rt} -o ${out} -lpthread`);
    } else if (strEq(xt.os, "linux")) {
        rc = system(`${clang} --target=${xt.llvm} -DLEX_NATIVE_FREESTANDING -ffreestanding -fno-builtin -nostdlib -fno-stack-protector -fno-pie -static -fuse-ld=lld -Wl,--entry,_start ${obj} ${rt} -o ${out}`);
    } else {
        const k32d: string = "/tmp/lex_kernel32.def";
        const ws2d: string = "/tmp/lex_ws2_32.def";
        const k32l: string = "/tmp/lex_kernel32.lib";
        const ws2l: string = "/tmp/lex_ws2_32.lib";
        writeFile(k32d, kernel32Def());
        writeFile(ws2d, ws2Def());
        const llvmlib: string = findLlvmTool("llvm-lib");
        rc = system(`${llvmlib} /def:${k32d} /out:${k32l} /machine:${xt.arch}`);
        if (rc == 0) { rc = system(`${llvmlib} /def:${ws2d} /out:${ws2l} /machine:${xt.arch}`); }
        if (rc != 0) { Terminal.log("erro: llvm-lib falhou ao gerar as import libs"); return 1; }
        rc = system(`${clang} --target=${xt.llvm} -DLEX_WIN_FREESTANDING -ffreestanding -fno-builtin -fno-stack-protector -nostdlib -fuse-ld=lld -Wl,/entry:lexWinStart -Wl,/subsystem:console ${obj} ${rt} ${k32l} ${ws2l} -o ${out}`);
    }
    if (rc != 0) { Terminal.log(`erro: link falhou p/ ${xt.os} (rc=${rc})`); return 1; }
    system(`rm -f ${obj}`);
    return 0;
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

// clang/wasm-ld do LLVM 18 — o clang do sistema costuma não ter o backend wasm.
// Tenta os prefixos usuais do brew e cai no PATH.
fn findLlvmTool(name: string): string {
    const a: string = concat("/opt/homebrew/opt/llvm@18/bin/", name);
    if (exists(a)) { return a; }
    const b: string = concat("/usr/local/opt/llvm@18/bin/", name);
    if (exists(b)) { return b; }
    return name;
}

// --target wasm: emite um módulo WebAssembly.
//   .lex → .ll (triple wasm32, ABI ptr-aware) → clang -c → objeto
//   runtime.c → objeto wasm32 FREESTANDING (sem libc/sysroot: a runtime traz
//               printf/mem*/str* próprios; o único import é `lex.write` do host)
//   wasm-ld linka os dois.
fn buildWasm(file: string, out: string): i64 {
    const ir: string = compileFileToIRT(file, 1);
    const ll: string = concat(out, ".ll");
    writeFile(ll, ir);
    const clang: string = findLlvmTool("clang");
    const wld: string = findLlvmTool("wasm-ld");
    const obj: string = concat(out, ".o");
    const rtobj: string = concat(out, ".rt.o");

    // -fno-builtin é ESSENCIAL: sem ele o clang reescreve printf("%s\n", x) em
    // puts(x), e a runtime freestanding não tem puts → vira um import `env.puts`
    // que nenhum host fornece.
    let rc: i64 = system(`${clang} --target=wasm32 -O2 -fno-builtin -Wno-override-module -c ${ll} -o ${obj}`);
    if (rc != 0) { Terminal.log(`erro: clang falhou no .ll wasm (rc=${rc})`); return 1; }
    rc = system(`${clang} --target=wasm32 -O2 -ffreestanding -fno-builtin -nostdlib -c ${findRuntime()} -o ${rtobj}`);
    if (rc != 0) { Terminal.log(`erro: clang falhou na runtime wasm (rc=${rc})`); return 1; }
    rc = system(`${wld} ${obj} ${rtobj} --no-entry --export-all --allow-undefined --export-memory -o ${out}`);
    if (rc != 0) { Terminal.log(`erro: wasm-ld falhou (rc=${rc})`); return 1; }
    system(`rm -f ${obj} ${rtobj}`);
    return 0;
}

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

// start = índice onde começa a varrer (2 p/ `lex build …`; 1 p/ a forma
// implícita `lex <arquivo.lex> …`, compatível com o invocar do Rust/bootstrap).
fn cmdBuild(av: string[], start: i64): i64 {
    let file: string = "";
    let out: string = "";
    let watch: bool = false;
    let tgt: string = "native";
    let i: i64 = start;
    while (i < av.len()) {
        if (strEq(av[i], "-o") && i + 1 < av.len()) { out = av[i + 1]; i = i + 2; }
        else if (strEq(av[i], "--watch")) { watch = true; i = i + 1; }
        else if (strEq(av[i], "--target") && i + 1 < av.len()) { tgt = av[i + 1]; i = i + 2; }
        else { file = av[i]; i = i + 1; }
    }
    if (strEq(file, "")) {
        Terminal.log("uso: lex build <arquivo.lex> [-o saida] [--watch]");
        Terminal.log("     [--target native|wasm|linux-x64|linux-arm64|windows-x64|windows-arm64|macos-x64|macos-arm64]");
        return 1;
    }
    const wasm: bool = strEq(tgt, "wasm") || strEq(tgt, "wasm32");
    const xt: CrossT = resolveCross(tgt);
    if (strEq(out, "")) {
        if (wasm) { out = "a.wasm"; }
        else { out = concat("a.out", xt.ext); }
    }
    if (wasm) {
        if (buildWasm(file, out) != 0) { return 1; }
        Terminal.log(`ok (wasm): ${file} -> ${out}`);
        return 0;
    }
    if (!strEq(xt.os, "")) {                       // alias de cross conhecido
        if (buildCross(file, out, xt) != 0) { return 1; }
        Terminal.log(`ok (${tgt}): ${file} -> ${out}`);
        return 0;
    }
    if (!strEq(tgt, "native")) {
        Terminal.log(`erro: alvo desconhecido '${tgt}' (use: native, wasm, linux-x64, linux-arm64, windows-x64, windows-arm64, macos-x64, macos-arm64)`);
        return 1;
    }
    if (buildFileT(file, out, "") != 0) { return 1; }
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
else if (strEq(cmd, "build") || strEq(cmd, "compile")) { rc = cmdBuild(av, 2); }
else if (strEq(cmd, "run")) { rc = cmdRun(av); }
else if (strEq(cmd, "fmt")) { rc = cmdFmt(av); }
else if (strEq(cmd, "test")) { rc = cmdTest(av); }
else if (strEq(cmd, "check")) { rc = cmdCheck(av); }
else if (strEq(cmd, "lsp")) { rc = runLsp(); }
else if (strEq(cmd, "pkg")) { rc = runPkg(av, 2); }
else if (hasSuffix(cmd, ".lex")) { rc = cmdBuild(av, 1); }   // forma implícita: lex <arquivo.lex>
else { Terminal.log(`lex: comando desconhecido '${cmd}'`); rc = 1; }
return rc;
