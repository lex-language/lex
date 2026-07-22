// lexcli.lex — driver unificado do lex, escrito em lex. Junta num único binário
// os subcomandos do `lex` de produção. Cada subcomando delega a um módulo
// self-hosted.
//
//   lex build <arquivo.lex> [-o saida]   compila → binário nativo (linka runtime.c)
//   lex run <arquivo.lex>                 compila p/ temp e executa (devolve exit)
//   lex fmt [--check] <arquivos.lex>      formata (in-place) ou confere
//   lex test <arquivos.test.lex>...       roda as suítes via o harness
//   lex check [--json] <arquivos.lex>...  diagnósticos (variável indefinida) em JSON
//   lex server [--port N] [dir]           sobe o site de uma pasta com pages/
//   lex lsp                               Language Server por stdio
//   lex pkg <init|add|remove|list> ...    gerenciador de pacotes (manifesto)
//   lex init [dir]                        cria estrutura de projeto (lex.toml, src/, pages/)
//   lex version | -v                      versão
//   lex help | -h                         ajuda
//   lex update                            atualiza para a última versão
//
// (o fetch de rede do pkg ainda é parcial.)
import { compileFileToIR, compileFileToIRT, findRuntime } from "./compiler/modloader"

// ── versão ────────────────────────────────────────────────────────────────────
const LEX_VERSION: string = "0.1.0";
const LEX_REPO: string = "doxacode/lex-lang";
const LEX_RELEASES_URL: string = "https://github.com/doxacode/lex-lang/releases";
import { formatSource, formatLsx } from "./tools/fmt"
import { runTestFile } from "./tools/testrunner"
import { runCheck } from "./tools/checker"
import { runLsp } from "./tools/lspserver"
import { runPkg } from "./tools/pkgcmd"
import { scanPages, scanPublic, sortStrs, portFromToml, genServerSrc, pageRoute, compName } from "./tools/servercmd"

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
// implícita `lex <arquivo.lex> …`, compatível com o invocar do bootstrap).
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

// aspas simples p/ o shell: dentro delas nada é interpretado, e um apóstrofo
// no meio fecha-escapa-reabre ('\''). Sem isto um argumento com espaço viraria
// dois, e um com `;` ou `$` seria executado pelo shell do `system`.
fn shellQuote(s: string): string {
    let out: string = "'";
    let i: i64 = 0;
    while (i < len(s)) {
        if (peek8(s, i) == 39) { out = concat(out, "'\\''"); }
        else { out = concat(out, charAt(s, i)); }
        i = i + 1;
    }
    return concat(out, "'");
}

// `lex run <arquivo> [args…]` — o que vem DEPOIS do arquivo é do programa, não
// do lex. É assim que `lex run site/server.lex --port 8080` chega no `args()`
// do servidor; antes o binário rodava sem argumento nenhum e a flag sumia.
fn cmdRun(av: string[]): i64 {
    if (av.len() < 3) { Terminal.log("uso: lex run <arquivo.lex> [args...]"); return 1; }
    const bin: string = "/tmp/lexcli_run";
    if (buildFile(av[2], bin) != 0) { return 1; }
    let cmd: string = bin;
    let i: i64 = 3;
    while (i < av.len()) {
        cmd = concat(cmd, concat(" ", shellQuote(av[i])));
        i = i + 1;
    }
    return system(cmd) / 256;       // WEXITSTATUS
}

// `lex server [--port N] [--dir D]` — sobe o site de uma pasta com `pages/`.
//
// Não há servidor a escrever: as rotas SÃO os .lsx de pages/. O comando gera um
// .lex com o roteamento, compila e executa. O fonte gerado é temporário e sai
// no fim, mas mora na raiz do projeto enquanto existe — os imports das páginas
// são relativos a ele.
fn cmdServer(av: string[]): i64 {
    let root: string = ".";
    let porta: i64 = 0 - 1;
    let saidaBin: string = "";        // --build <arq>: compila e NÃO executa
    let i: i64 = 2;
    while (i < av.len()) {
        if (strEq(av[i], "--port") && i + 1 < av.len()) { porta = parseInt(av[i + 1]); i = i + 2; }
        else if (strEq(av[i], "--dir") && i + 1 < av.len()) { root = av[i + 1]; i = i + 2; }
        else if (strEq(av[i], "--build") && i + 1 < av.len()) { saidaBin = av[i + 1]; i = i + 2; }
        else { root = av[i]; i = i + 1; }
    }

    const pagesDir: string = concat(root, "/pages");
    if (isDir(pagesDir) == 0) {
        Terminal.log(`lex server: nao achei '${pagesDir}'.`);
        Terminal.log("            as rotas sao os .lsx dentro de pages/ (pages/index.lsx = /).");
        return 1;
    }

    let pages: string[] = [];
    scanPages(pagesDir, "", pages);
    if (pages.len() == 0) {
        Terminal.log(`lex server: '${pagesDir}' nao tem nenhum .lsx`);
        return 1;
    }
    pages = sortStrs(pages);

    let estaticos: string[] = [];
    const publicDir: string = concat(root, "/public");
    if (isDir(publicDir) != 0) { scanPublic(publicDir, "", estaticos); }
    estaticos = sortStrs(estaticos);

    if (porta < 0) { porta = portFromToml(root, 3000); }

    for (const rel of pages) { Terminal.log(`  ${pageRoute(rel)}  ←  pages/${rel}`); }
    for (const rel of estaticos) { Terminal.log(`  /${rel}  ←  public/${rel}`); }

    // o fonte gerado é efêmero, mas visível: se o build falhar, o erro aponta
    // para ele, e ver o roteamento gerado é a forma de entender o que houve.
    const gen: string = concat(root, "/.lex-server.lex");
    let bin: string = concat(root, "/.lex-server");
    if (!strEq(saidaBin, "")) { bin = saidaBin; }
    writeFile(gen, genServerSrc(pages, estaticos, porta));
    const rc: i64 = buildFile(gen, bin);
    if (rc != 0) {
        Terminal.log(`lex server: o build falhou; o fonte gerado ficou em ${gen}`);
        return 1;
    }
    remove(gen);
    remove(concat(bin, ".ll"));

    // `--build`: entrega o binário e sai. É o que permite a imagem Docker
    // compilar no estágio de build e RODAR num estágio sem clang — sem isto o
    // servidor recompilaria a cada start e a imagem carregaria um LLVM inteiro.
    if (!strEq(saidaBin, "")) {
        Terminal.log(`lex server: binario em ${bin}`);
        Terminal.log("            rode-o com a pasta do site como diretorio atual (ele lê public/ por caminho relativo)");
        return 0;
    }

    // com a raiz como cwd: o gerado lê os estáticos por caminho relativo
    // (`public/…`), o que mantém a pasta do site movível.
    const saida: i64 = system(`cd ${root} && ./.lex-server`) / 256;
    remove(bin);
    return saida;
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
        if (!hasSuffix(f, ".lex") && !hasSuffix(f, ".lsx")) { Terminal.log(`lex fmt: pulando '${f}' (não é .lex nem .lsx)`); }
        else {
            const src: string = readFile(f);
            // num .lsx só o frontmatter é código; o corpo é HTML, onde o espaço
            // é conteúdo e reindentar mudaria a saída.
            let formatted: string = formatSource(src);
            if (hasSuffix(f, ".lsx")) { formatted = formatLsx(src); }
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

// ── update ────────────────────────────────────────────────────────────────────
// Detecta o SO e arquitetura para baixar o binário correto.
fn detectPlatform(): string {
    const uname: string = captureCmdOutput("uname -s");
    const arch: string = captureCmdOutput("uname -m");
    let os: string = "linux";
    if (findSubstring(uname, "Darwin") >= 0) { os = "macos"; }
    else if (findSubstring(uname, "MINGW") >= 0 || findSubstring(uname, "MSYS") >= 0) { os = "windows"; }
    let cpu: string = "x64";
    if (findSubstring(arch, "arm64") >= 0 || findSubstring(arch, "aarch64") >= 0) { cpu = "arm64"; }
    return concat(os, concat("-", cpu));
}

// Captura a saída de um comando num arquivo temporário.
fn captureCmdOutput(cmd: string): string {
    system(`${cmd} > /tmp/lex_cap 2>/dev/null`);
    return readFile("/tmp/lex_cap");
}

// Busca um substring dentro de uma string.
fn findSubstring(hay: string, needle: string): i64 {
    const hn: i64 = len(hay);
    const nn: i64 = len(needle);
    let i: i64 = 0;
    while (i + nn <= hn) {
        if (strEq(substring(hay, i, i + nn), needle)) { return i; }
        i = i + 1;
    }
    return -1;
}

// Compara duas versões semver (simples: major.minor.patch).
// Retorna: -1 se a < b, 0 se a == b, 1 se a > b.
fn compareVersions(a: string, b: string): i64 {
    // Remove prefixo 'v' se houver
    let va: string = a;
    let vb: string = b;
    if (len(va) > 0 && peek8(va, 0) == 118) { va = substring(va, 1, len(va)); }
    if (len(vb) > 0 && peek8(vb, 0) == 118) { vb = substring(vb, 1, len(vb)); }

    // Extrai major.minor.patch de cada
    let aParts: i64[] = [0, 0, 0];
    let bParts: i64[] = [0, 0, 0];
    let idx: i64 = 0;
    let num: i64 = 0;
    let i: i64 = 0;
    while (i <= len(va)) {
        if (i == len(va) || peek8(va, i) == 46) {
            if (idx < 3) { aParts[idx] = num; idx = idx + 1; }
            num = 0;
        } else {
            const c: i64 = peek8(va, i);
            if (c >= 48 && c <= 57) { num = num * 10 + (c - 48); }
        }
        i = i + 1;
    }
    idx = 0; num = 0; i = 0;
    while (i <= len(vb)) {
        if (i == len(vb) || peek8(vb, i) == 46) {
            if (idx < 3) { bParts[idx] = num; idx = idx + 1; }
            num = 0;
        } else {
            const c: i64 = peek8(vb, i);
            if (c >= 48 && c <= 57) { num = num * 10 + (c - 48); }
        }
        i = i + 1;
    }

    // Compara componente a componente
    i = 0;
    while (i < 3) {
        if (aParts[i] < bParts[i]) { return 0 - 1; }
        if (aParts[i] > bParts[i]) { return 1; }
        i = i + 1;
    }
    return 0;
}

// Trim de espaços e quebras de linha.
fn trimWhitespace(s: string): string {
    const n: i64 = len(s);
    let a: i64 = 0;
    while (a < n && (peek8(s, a) == 32 || peek8(s, a) == 9 || peek8(s, a) == 13 || peek8(s, a) == 10)) { a = a + 1; }
    let b: i64 = n;
    while (b > a && (peek8(s, b - 1) == 32 || peek8(s, b - 1) == 9 || peek8(s, b - 1) == 13 || peek8(s, b - 1) == 10)) { b = b - 1; }
    return substring(s, a, b);
}

// Busca a última versão disponível no GitHub Releases.
fn fetchLatestVersion(): string {
    const url: string = `https://api.github.com/repos/${LEX_REPO}/releases/latest`;
    const rc: i64 = system(`curl -fsSL ${url} -o /tmp/lex_latest 2>/dev/null`);
    if (rc != 0) { return ""; }
    // Extrai "tag_name" do JSON (simples, sem parser completo)
    const json: string = readFile("/tmp/lex_latest");
    const marker: string = "\"tag_name\":";
    const idx: i64 = findSubstring(json, marker);
    if (idx < 0) { return ""; }
    // Encontra o valor entre aspas após tag_name
    let start: i64 = idx + len(marker);
    while (start < len(json) && peek8(json, start) != 34) { start = start + 1; }
    start = start + 1;  // pula a aspa inicial
    let end: i64 = start;
    while (end < len(json) && peek8(json, end) != 34) { end = end + 1; }
    return substring(json, start, end);
}

// Verifica se há atualização disponível e retorna a versão (ou "" se não há).
fn checkForUpdate(): string {
    const latest: string = fetchLatestVersion();
    if (strEq(latest, "")) { return ""; }
    if (compareVersions(LEX_VERSION, latest) < 0) { return latest; }
    return "";
}

// Mostra aviso de atualização disponível.
fn showUpdateNotice(): void {
    const latest: string = checkForUpdate();
    if (!strEq(latest, "")) {
        Terminal.log("");
        Terminal.log(`*** Nova versao disponivel: ${latest} (atual: ${LEX_VERSION})`);
        Terminal.log("    Execute 'lex update' para atualizar.");
    }
}

// Encontra o caminho do binário atual.
fn findSelfPath(): string {
    // macOS/Linux: /proc/self/exe ou argv[0] resolvido
    if (exists("/proc/self/exe")) {
        return trimWhitespace(captureCmdOutput("readlink -f /proc/self/exe"));
    }
    // macOS não tem /proc, usa which
    return trimWhitespace(captureCmdOutput("which lex"));
}

// Comando update: baixa a nova versão e substitui o binário.
fn cmdUpdate(): i64 {
    Terminal.log(`lex ${LEX_VERSION}`);
    Terminal.log("Verificando atualizacoes...");

    const latest: string = fetchLatestVersion();
    if (strEq(latest, "")) {
        Terminal.log("erro: nao foi possivel verificar atualizacoes");
        Terminal.log(`      verifique sua conexao ou acesse ${LEX_RELEASES_URL}`);
        return 1;
    }

    if (compareVersions(LEX_VERSION, latest) >= 0) {
        Terminal.log(`Voce ja esta na versao mais recente (${LEX_VERSION})`);
        return 0;
    }

    Terminal.log(`Nova versao disponivel: ${latest}`);

    const platform: string = detectPlatform();
    const binName: string = concat("lex-", platform);
    // GitHub Releases: https://github.com/REPO/releases/download/TAG/ASSET.tar.gz
    const url: string = `https://github.com/${LEX_REPO}/releases/download/${latest}/${binName}.tar.gz`;

    Terminal.log(`Baixando ${url}...`);

    const tmpDir: string = "/tmp/lex_update";
    const tmpTar: string = "/tmp/lex_update.tar.gz";
    const tmpBin: string = "/tmp/lex_update/lex";

    let rc: i64 = system(`curl -fsSL -L ${url} -o ${tmpTar}`);
    if (rc != 0) {
        Terminal.log("erro: falha ao baixar a nova versao");
        return 1;
    }

    // Verifica se o download foi bem sucedido (não é HTML de erro)
    const content: string = readFile(tmpTar);
    if (len(content) < 1000 || findSubstring(content, "<!DOCTYPE") >= 0 || findSubstring(content, "Not Found") >= 0) {
        Terminal.log("erro: binario nao encontrado para esta plataforma");
        Terminal.log(`      verifique em ${LEX_RELEASES_URL}`);
        return 1;
    }

    // Extrai o tar.gz
    Terminal.log("Extraindo...");
    system(`rm -rf ${tmpDir} && mkdir -p ${tmpDir}`);
    rc = system(`tar -xzf ${tmpTar} -C ${tmpDir}`);
    if (rc != 0) {
        Terminal.log("erro: falha ao extrair o arquivo");
        return 1;
    }

    // Torna executável
    system(`chmod +x ${tmpBin}`);

    // Encontra onde está o binário atual
    const selfPath: string = findSelfPath();
    if (strEq(selfPath, "")) {
        Terminal.log("erro: nao consegui localizar o binario atual");
        Terminal.log(`      mova manualmente ${tmpBin} para o seu PATH`);
        return 1;
    }

    Terminal.log(`Atualizando ${selfPath}...`);

    // Tenta substituir (pode precisar de sudo)
    let mvRc: i64 = system(`mv ${tmpBin} ${selfPath} 2>/dev/null`);
    if (mvRc != 0) {
        Terminal.log("Permissao negada. Tentando com sudo...");
        mvRc = system(`sudo mv ${tmpBin} ${selfPath}`);
        if (mvRc != 0) {
            Terminal.log("erro: falha ao substituir o binario");
            Terminal.log(`      mova manualmente ${tmpBin} para ${selfPath}`);
            return 1;
        }
    }

    Terminal.log(`Atualizado para ${latest}!`);
    return 0;
}

// ── help ──────────────────────────────────────────────────────────────────────
fn showHelp(): void {
    Terminal.log("lex — compilador e ferramentas para a linguagem Lex");
    Terminal.log("");
    Terminal.log("uso: lex <comando> [opcoes]");
    Terminal.log("");
    Terminal.log("comandos:");
    Terminal.log("  build <arquivo.lex> [-o saida]   compila para binario nativo");
    Terminal.log("  run <arquivo.lex> [args...]      compila e executa");
    Terminal.log("  fmt [--check] <arquivos...>      formata codigo (in-place ou confere)");
    Terminal.log("  test <arquivos.test.lex>...      roda suites de teste");
    Terminal.log("  check [--json] <arquivos...>     diagnosticos em JSON");
    Terminal.log("  server [--port N] [dir]          sobe servidor web de pages/");
    Terminal.log("  lsp                              Language Server (stdio)");
    Terminal.log("  pkg <init|add|remove|list>       gerenciador de pacotes");
    Terminal.log("  init [dir]                       cria estrutura de projeto");
    Terminal.log("  update                           atualiza para a ultima versao");
    Terminal.log("  version                          mostra versao");
    Terminal.log("  help                             mostra esta ajuda");
    Terminal.log("");
    Terminal.log("flags:");
    Terminal.log("  -v, --version                    mostra versao");
    Terminal.log("  -h, --help                       mostra esta ajuda");
    Terminal.log("");
    Terminal.log("exemplos:");
    Terminal.log("  lex build main.lex -o app");
    Terminal.log("  lex run server.lex --port 8080");
    Terminal.log("  lex init meu-projeto");
    Terminal.log("  lex server --port 3000");
    showUpdateNotice();
}

// ── init ──────────────────────────────────────────────────────────────────────
fn cmdInit(av: string[]): i64 {
    let dir: string = ".";
    if (av.len() > 2) { dir = av[2]; }

    // cria diretorio se nao existir
    if (!strEq(dir, ".") && isDir(dir) == 0) {
        const rc: i64 = system(`mkdir -p ${shellQuote(dir)}`);
        if (rc != 0) { Terminal.log(`erro: nao consegui criar '${dir}'`); return 1; }
    }

    // lex.toml
    const tomlPath: string = concat(dir, "/lex.toml");
    if (exists(tomlPath)) {
        Terminal.log(`aviso: '${tomlPath}' ja existe, pulando`);
    } else {
        const tomlContent: string = "[project]\nname = \"meu-projeto\"\nversion = \"0.1.0\"\n\n[server]\nport = 3000\n";
        writeFile(tomlPath, tomlContent);
        Terminal.log(`criado: ${tomlPath}`);
    }

    // src/
    const srcDir: string = concat(dir, "/src");
    if (isDir(srcDir) == 0) {
        system(`mkdir -p ${shellQuote(srcDir)}`);
        Terminal.log(`criado: ${srcDir}/`);
    }

    // src/main.lex
    const mainPath: string = concat(srcDir, "/main.lex");
    if (exists(mainPath)) {
        Terminal.log(`aviso: '${mainPath}' ja existe, pulando`);
    } else {
        const mainContent: string = "// ponto de entrada do projeto\n\nTerminal.log(\"Ola, Lex!\");\n";
        writeFile(mainPath, mainContent);
        Terminal.log(`criado: ${mainPath}`);
    }

    // pages/
    const pagesDir: string = concat(dir, "/pages");
    if (isDir(pagesDir) == 0) {
        system(`mkdir -p ${shellQuote(pagesDir)}`);
        Terminal.log(`criado: ${pagesDir}/`);
    }

    // pages/index.lsx
    const indexPath: string = concat(pagesDir, "/index.lsx");
    if (exists(indexPath)) {
        Terminal.log(`aviso: '${indexPath}' ja existe, pulando`);
    } else {
        const indexContent: string = "---\nexport fn GET(req: Request): Response {\n    return this.render({ title: \"Lex\" });\n}\n---\n<!DOCTYPE html>\n<html>\n<head>\n    <title>{{ title }}</title>\n</head>\n<body>\n    <h1>Bem-vindo ao Lex!</h1>\n</body>\n</html>\n";
        writeFile(indexPath, indexContent);
        Terminal.log(`criado: ${indexPath}`);
    }

    // public/
    const publicDir: string = concat(dir, "/public");
    if (isDir(publicDir) == 0) {
        system(`mkdir -p ${shellQuote(publicDir)}`);
        Terminal.log(`criado: ${publicDir}/`);
    }

    Terminal.log("");
    Terminal.log("projeto inicializado!");
    Terminal.log("");
    Terminal.log("proximos passos:");
    if (!strEq(dir, ".")) { Terminal.log(`  cd ${dir}`); }
    Terminal.log("  lex run src/main.lex       # roda o ponto de entrada");
    Terminal.log("  lex server                 # sobe o servidor web");
    return 0;
}

// ── despacho (script-mode → main) ────────────────────────────────────────────
const av: string[] = args();
if (av.len() < 2) {
    showHelp();
    return 1;
}
const cmd: string = av[1];
let rc: i64 = 0;
if (strEq(cmd, "version") || strEq(cmd, "--version") || strEq(cmd, "-v")) {
    Terminal.log(`lex ${LEX_VERSION}`);
    showUpdateNotice();
}
else if (strEq(cmd, "help") || strEq(cmd, "--help") || strEq(cmd, "-h")) { showHelp(); }
else if (strEq(cmd, "update")) { rc = cmdUpdate(); }
else if (strEq(cmd, "init")) { rc = cmdInit(av); }
else if (strEq(cmd, "build") || strEq(cmd, "compile")) { rc = cmdBuild(av, 2); }
else if (strEq(cmd, "run")) { rc = cmdRun(av); }
else if (strEq(cmd, "fmt")) { rc = cmdFmt(av); }
else if (strEq(cmd, "test")) { rc = cmdTest(av); }
else if (strEq(cmd, "check")) { rc = cmdCheck(av); }
else if (strEq(cmd, "server")) { rc = cmdServer(av); }
else if (strEq(cmd, "lsp")) { rc = runLsp(); }
else if (strEq(cmd, "pkg")) { rc = runPkg(av, 2); }
else if (hasSuffix(cmd, ".lex") || hasSuffix(cmd, ".lsx")) { rc = cmdBuild(av, 1); }   // forma implícita: lex <arquivo>
else { Terminal.log(`lex: comando desconhecido '${cmd}'`); rc = 1; }
return rc;
