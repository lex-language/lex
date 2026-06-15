// lexlsp.lex — Language Server mínimo em lex (Fase F6.9), espelha src/lsp.rs.
// Fala o subset do LSP p/ diagnósticos ao vivo por stdio: initialize,
// textDocument/didOpen + didChange, shutdown/exit. A cada edição grava o texto
// num arquivo temporário e roda `lex check --json` num SUBPROCESSO (o parser
// aborta no 1º erro; rodar fora evita derrubar o servidor) e republica os diags.
// Usa o parser JSON de json.lex e o builtin de host readStdin(n).
import { jParse, jGet, jStr, jNum, jArr, jPath, jEscape, Json, JNum, JStr } from "./json"

// ── leitura de mensagens (Content-Length + corpo) ────────────────────────────
fn endsCRLF2(s: string): bool {
    const n: i64 = len(s);
    if (n < 4) { return false; }
    return peek8(s, n - 4) == 13 && peek8(s, n - 3) == 10
        && peek8(s, n - 2) == 13 && peek8(s, n - 1) == 10;
}
fn lspTrim(s: string): string {
    const n: i64 = len(s);
    let a: i64 = 0;
    while (a < n && (peek8(s, a) == 32 || peek8(s, a) == 9 || peek8(s, a) == 13 || peek8(s, a) == 10)) { a = a + 1; }
    let b: i64 = n;
    while (b > a && (peek8(s, b - 1) == 32 || peek8(s, b - 1) == 9 || peek8(s, b - 1) == 13 || peek8(s, b - 1) == 10)) { b = b - 1; }
    return substring(s, a, b);
}
fn pStartsLsp(s: string, pre: string): bool {
    if (len(pre) > len(s)) { return false; }
    return strEq(substring(s, 0, len(pre)), pre);
}
// extrai o Content-Length dos cabeçalhos (linhas separadas por \n).
fn contentLength(headers: string): i64 {
    const n: i64 = len(headers);
    let start: i64 = 0;
    let i: i64 = 0;
    while (i <= n) {
        if (i == n || peek8(headers, i) == 10) {
            const line: string = substring(headers, start, i);
            if (pStartsLsp(line, "Content-Length:")) {
                return parseInt(lspTrim(substring(line, 15, len(line))));
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return -1;
}
// lê exatamente n bytes do corpo (loop p/ leituras parciais).
fn readBody(n: i64): string {
    let buf: string = "";
    while (len(buf) < n) {
        const chunk: string = readStdin(n - len(buf));
        if (len(chunk) == 0) { return buf; }     // EOF no meio
        buf = concat(buf, chunk);
    }
    return buf;
}
// uma mensagem LSP completa, ou "" no EOF.
fn readMessage(): string {
    let headers: string = "";
    while (true) {
        const b: string = readStdin(1);
        if (len(b) == 0) { return ""; }           // EOF
        headers = concat(headers, b);
        if (endsCRLF2(headers)) { break; }
    }
    const n: i64 = contentLength(headers);
    if (n <= 0) { return "{}"; }                   // sem corpo → objeto vazio
    return readBody(n);
}

// ── saída ────────────────────────────────────────────────────────────────────
// escreve uma mensagem com cabeçalho Content-Length. Terminal.log acrescenta um
// \n final (tolerado: o cliente lê só Content-Length bytes; o \n vira whitespace
// antes do próximo cabeçalho). O runtime dá fflush(stdout) ao ler a próxima msg.
fn lspSend(payload: string) {
    Terminal.log(`Content-Length: ${len(payload)}\r\n\r\n${payload}`);
}
fn idStr(id: Json): string {
    return match (id) {
        JNum x => str(x.n),
        JStr s => `"${jEscape(s.s)}"`,
        _ => "null"
    };
}
fn respond(id: Json, result: string) {
    lspSend(`{"jsonrpc":"2.0","id":${idStr(id)},"result":${result}}`);
}

// ── diagnósticos ─────────────────────────────────────────────────────────────
fn lspDiag(line: i64, col: i64, endLine: i64, endCol: i64, msg: string): string {
    return `{"range":{"start":{"line":${line},"character":${col}},"end":{"line":${endLine},"character":${endCol}}},"severity":1,"message":"${jEscape(msg)}"}`;
}
fn diagToLsp(d: Json): string {
    const line: i64 = jNum(jGet(d, "line"));
    const col: i64 = jNum(jGet(d, "col"));
    const endLine: i64 = jNum(jGet(d, "endLine"));
    const endCol: i64 = jNum(jGet(d, "endCol"));
    return lspDiag(line, col, endLine, endCol, jStr(jGet(d, "message")));
}
fn diagsToLsp(arr: Json): string {
    let s: string = "";
    let first: bool = true;
    for (const d of jArr(arr)) {
        if (!first) { s = concat(s, ","); }
        s = concat(s, diagToLsp(d));
        first = false;
    }
    return s;
}
// roda o `lexcheck` (self-hostado) no texto e publica os diagnósticos sob uri.
// (Antes chamava o `lex check --json` do Rust; agora a análise é toda em lex.)
fn analyzeAndPublish(uri: string, text: string) {
    const tmp: string = "/tmp/lex_lsp_doc.lex";
    const outf: string = "/tmp/lex_lsp_out.json";
    writeFile(tmp, text);
    system(`lexcheck ${tmp} > ${outf} 2>/dev/null`);
    const arr: Json = jParse(lspTrim(readFile(outf)));
    const diags: string = diagsToLsp(arr);
    lspSend(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"${jEscape(uri)}","diagnostics":[${diags}]}}`);
}

// ── despacho ─────────────────────────────────────────────────────────────────
// devolve 1 p/ sair (método "exit"), 0 p/ continuar.
fn handleMessage(body: string): i64 {
    const msg: Json = jParse(body);
    const method: string = jStr(jGet(msg, "method"));
    if (strEq(method, "initialize")) {
        respond(jGet(msg, "id"), "{\"capabilities\":{\"textDocumentSync\":1},\"serverInfo\":{\"name\":\"lex-lsp\"}}");
        return 0;
    }
    if (strEq(method, "shutdown")) { respond(jGet(msg, "id"), "null"); return 0; }
    if (strEq(method, "exit")) { return 1; }
    if (strEq(method, "textDocument/didOpen")) {
        const td: Json = jPath(msg, ["params", "textDocument"]);
        const uri: string = jStr(jGet(td, "uri"));
        if (!strEq(uri, "")) { analyzeAndPublish(uri, jStr(jGet(td, "text"))); }
        return 0;
    }
    if (strEq(method, "textDocument/didChange")) {
        const uri: string = jStr(jPath(msg, ["params", "textDocument", "uri"]));
        const changes = jArr(jPath(msg, ["params", "contentChanges"]));
        if (!strEq(uri, "") && changes.len() > 0) {
            analyzeAndPublish(uri, jStr(jGet(changes[changes.len() - 1], "text")));
        }
        return 0;
    }
    return 0;
}

// ── loop principal (script-mode → main) ──────────────────────────────────────
let running: bool = true;
while (running) {
    const body: string = readMessage();
    if (len(body) == 0) { running = false; }
    else { if (handleMessage(body) == 1) { running = false; } }
}
