// O registry do lex como SITE — escrito em lex (dogfooding do servidor HTTP +
// fs + JSON da própria linguagem). Serve:
//
//   GET  /                      lista + busca (HTML)            ?q=<termo>
//   GET  /pkg/<nome>            página de detalhe do pacote (HTML)
//   GET  /api/packages          índice em JSON (array)
//   GET  /api/pkg/<nome>        1 pacote em JSON — é o que o `lex add` consome
//   POST /api/publish           publica/atualiza um pacote (usado por `lex publish`)
//
// Cada pacote é um arquivo `data/<nome>.json` = { name, repo, version,
// description }. Publicar grava esse arquivo. Se existir um arquivo `data/.token`,
// o publish exige `token` igual no corpo (auth simples); sem ele, é aberto.
//
//   lex registry-site/server.lex -o registry && ./registry      # porta 8080

import { Server, Conn } from "http";

// lex não tem estado de módulo — constantes viram funções.
function dataDir(): string { return "data"; }
function port(): i64 { return 8080; }

// --- helpers ---------------------------------------------------------------

// nome de pacote seguro: sem barra nem ".." (evita escapar do diretório data/).
function safeName(name: string): bool {
    if (len(name) == 0) { return false; }
    if (contains(name, "/")) { return false; }
    if (contains(name, "..")) { return false; }
    return true;
}

function pkgPath(name: string): string {
    return `${dataDir()}/${name}.json`;
}

// valor de um parâmetro da query string (`q=foo&x=1` → param "q" = "foo").
function qparam(query: string, key: string): string {
    const needle: string = `${key}=`;
    const idx: i64 = indexOf(query, needle);
    if (idx < 0) { return ""; }
    const after: string = substring(query, idx + len(needle), len(query));
    const amp: i64 = indexOf(after, "&");
    if (amp < 0) { return after; }
    return substring(after, 0, amp);
}

// --- páginas HTML ----------------------------------------------------------

function page(title: string, inner: string): string {
    return `<!doctype html>
<html lang="pt-br"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · lex registry</title>
<style>
  body{font:16px/1.5 system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
  a{color:#2563eb;text-decoration:none} a:hover{text-decoration:underline}
  h1{font-size:1.5rem} code{background:#f3f4f6;padding:.15rem .35rem;border-radius:4px}
  .pkg{padding:.6rem 0;border-bottom:1px solid #eee}
  input{padding:.5rem;width:100%;box-sizing:border-box;border:1px solid #ccc;border-radius:6px}
  .muted{color:#666}
</style></head><body>
<h1><a href="/">lex registry</a></h1>
${inner}
</body></html>`;
}

// lista (com busca) — varre data/ e monta os itens num passe só.
function htmlList(q: string): string {
    const files: string[] = readDir(dataDir());
    let items: string = "";
    let count: i64 = 0;
    for (const f of files) {
        if (endsWith(f, ".json")) {
            const name: string = substring(f, 0, len(f) - 5);
            if (len(q) == 0 || contains(name, q)) {
                const p: json = jsonParse(readFile(`${dataDir()}/${f}`));
                const desc: string = jsonAsStr(jsonGet(p, "description"));
                items = `${items}<div class="pkg"><a href="/pkg/${name}">${name}</a> <span class="muted">${desc}</span></div>`;
                count = count + 1;
            }
        }
    }
    if (count == 0) { items = `<p class="muted">nenhum pacote ainda — publique com <code>lex publish</code>.</p>`; }
    const search: string = `<form method="get"><input name="q" value="${q}" placeholder="buscar pacotes..."></form>`;
    return page("pacotes", `${search}${items}`);
}

function htmlDetail(name: string): string {
    const path: string = pkgPath(name);
    if (exists(path) == 0) {
        return page("não encontrado", `<p>pacote <code>${name}</code> não existe.</p>`);
    }
    const p: json = jsonParse(readFile(path));
    const repo: string = jsonAsStr(jsonGet(p, "repo"));
    const version: string = jsonAsStr(jsonGet(p, "version"));
    const desc: string = jsonAsStr(jsonGet(p, "description"));
    const inner: string = `<h2>${name} <span class="muted">${version}</span></h2>
<p>${desc}</p>
<p>repo: <a href="${repo}">${repo}</a></p>
<p>instalar: <code>lex add ${name}</code></p>`;
    return page(name, inner);
}

// --- API (JSON) ------------------------------------------------------------

// índice inteiro em JSON (array de objetos).
function apiList(): string {
    const files: string[] = readDir(dataDir());
    const arr: json = jsonArray();
    for (const f of files) {
        if (endsWith(f, ".json")) {
            jsonPush(arr, jsonParse(readFile(`${dataDir()}/${f}`)));
        }
    }
    return jsonStringify(arr);
}

// publica: valida o corpo JSON, checa o token (se houver) e grava o pacote.
// devolve o status HTTP (201 ok, 400 inválido, 401 token errado).
function publish(c: Conn): i64 {
    const b: json = jsonParse(c.body());
    const name: string = jsonAsStr(jsonGet(b, "name"));
    const repo: string = jsonAsStr(jsonGet(b, "repo"));
    if (safeName(name) == false || len(repo) == 0) {
        c.respondWith(400, "application/json", `{"error":"name and repo are required"}`);
        return 0;
    }
    // auth opcional: se existir data/.token, o corpo precisa do mesmo token.
    const tokenFile: string = `${dataDir()}/.token`;
    if (exists(tokenFile) == 1) {
        const want: string = trim(readFile(tokenFile));
        const got: string = jsonAsStr(jsonGet(b, "token"));
        if (strEq(want, got) == false) {
            c.respondWith(401, "application/json", `{"error":"invalid token"}`);
            return 0;
        }
    }
    let version: string = jsonAsStr(jsonGet(b, "version"));
    if (len(version) == 0) { version = "0.0.0"; }
    const desc: string = jsonAsStr(jsonGet(b, "description"));
    const obj: json = jsonObject();
    jsonSet(obj, "name", jsonStr(name));
    jsonSet(obj, "repo", jsonStr(repo));
    jsonSet(obj, "version", jsonStr(version));
    jsonSet(obj, "description", jsonStr(desc));
    writeFile(pkgPath(name), jsonStringify(obj));
    c.respondWith(201, "application/json", `{"ok":true,"name":"${name}","version":"${version}"}`);
    return 0;
}

// --- roteamento ------------------------------------------------------------

function handle(c: Conn): i64 {
    const m: string = c.method();
    const p: string = c.path();

    if (strEq(m, "POST") && strEq(p, "/api/publish")) {
        return publish(c);
    }
    if (strEq(m, "GET")) {
        if (strEq(p, "/")) {
            c.respondWith(200, "text/html; charset=utf-8", htmlList(qparam(c.query(), "q")));
            return 0;
        }
        if (strEq(p, "/api/packages")) {
            c.respondWith(200, "application/json", apiList());
            return 0;
        }
        if (startsWith(p, "/api/pkg/")) {
            const name: string = substring(p, 9, len(p));
            if (safeName(name) && exists(pkgPath(name)) == 1) {
                c.respondWith(200, "application/json", readFile(pkgPath(name)));
            } else {
                c.respondWith(404, "application/json", `{"error":"not found"}`);
            }
            return 0;
        }
        if (startsWith(p, "/pkg/")) {
            const name: string = substring(p, 5, len(p));
            c.respondWith(200, "text/html; charset=utf-8", htmlDetail(name));
            return 0;
        }
    }
    c.respondWith(404, "text/html; charset=utf-8", page("404", "<p>não encontrado</p>"));
    return 0;
}

function main(): i32! {
    if (exists(dataDir()) == 0) {
        mkdir(dataDir());
    }
    const srv: Server = new Server(port());
    try srv.startRaw(handle);
    return 0;
}
