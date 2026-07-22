// std/web.lex — o objeto `Lex` das páginas .lsx (o que o `Astro` é no Astro).
//
// Um .lsx que menciona `Lex.` recebe de graça, no topo de cada função, um
// `const Lex: LexCtx = lexCtx();` — quem injeta é o front-end dos .lsx
// (src/compiler/lsx.lex). Este arquivo é o que esse `Lex` É: a requisição já
// parseada e os controles da resposta.
//
//     ---
//     const nome: string = Lex.params.get("nome");
//     if (strEq(Lex.request.method, "POST")) { Lex.status = 201; }
//     ---
//     <h1>Ola, {nome}</h1>
//
// O contexto é POR THREAD. O servidor faz `spawn` por conexão, então um global
// simples seria corrida entre duas requisições concorrentes: cada thread lê e
// escreve o seu (ver __lex_ctx_* em runtime.c). O objeto mora na arena da
// thread, que o thunk do spawn libera quando a conexão termina — por isso não
// há nada a liberar aqui.

// ── parâmetros (query string, e as rotas dinâmicas quando existirem) ─────────
// Dois arrays em vez de um Map: `get` precisa de um default ("") e a ordem de
// inserção é o que faz `Lex.params` imprimir igual ao que chegou.
class LexParams {
    names: string[]
    vals: string[]

    constructor() {
        this.names = [];
        this.vals = [];
    }

    set(k: string, v: string) {
        this.names.push(k);
        this.vals.push(v);
    }

    // índice de `k`, ou -1. A 1ª ocorrência vence (`?a=1&a=2` → "1").
    find(k: string): i64 {
        let i: i64 = 0;
        while (i < this.names.len()) {
            if (strEq(this.names[i], k)) { return i; }
            i = i + 1;
        }
        return 0 - 1;
    }

    has(k: string): bool { return this.find(k) >= 0; }

    // "" quando não existe: uma página que lê `?nome=` não deveria ter de
    // checar antes de interpolar.
    get(k: string): string {
        const i: i64 = this.find(k);
        if (i < 0) { return ""; }
        return this.vals[i];
    }
}

// hex de um byte de '%XX'; -1 se não for hex.
fn hexVal(c: i64): i64 {
    if (c >= 48 && c <= 57) { return c - 48; }        // 0-9
    if (c >= 97 && c <= 102) { return c - 97 + 10; }  // a-f
    if (c >= 65 && c <= 70) { return c - 65 + 10; }   // A-F
    return 0 - 1;
}

// percent-decoding de um valor de query/form: `%20` vira espaço e `+` também
// (é o que `application/x-www-form-urlencoded` manda). Um `%` solto ou com hex
// inválido passa literal, em vez de comer os bytes seguintes.
fn urlDecode(s: string): string {
    let out: string = "";
    let i: i64 = 0;
    const n: i64 = len(s);
    while (i < n) {
        const c: i64 = peek8(s, i);
        if (c == 37 && i + 2 < n) {                   // '%'
            const hi: i64 = hexVal(peek8(s, i + 1));
            const lo: i64 = hexVal(peek8(s, i + 2));
            if (hi >= 0 && lo >= 0) {
                const b: ptr = alloc(2);
                poke8(b, 0, hi * 16 + lo);
                poke8(b, 1, 0);
                out = concat(out, b);
                free(b);
                i = i + 3;
                continue;
            }
        }
        if (c == 43) { out = concat(out, " "); i = i + 1; continue; }   // '+'
        out = concat(out, charAt(s, i));
        i = i + 1;
    }
    return out;
}

// `a=1&b=hello%20world` → params. Uma chave sem `=` vale "" (`?debug`).
fn parseQuery(q: string): LexParams {
    const p: LexParams = new LexParams();
    if (len(q) == 0) { return p; }
    for (const pair of split(q, "&")) {
        if (len(pair) == 0) { continue; }
        const eq: i64 = indexOf(pair, "=");
        if (eq < 0) {
            p.set(urlDecode(pair), "");
        } else {
            p.set(urlDecode(substring(pair, 0, eq)), urlDecode(substring(pair, eq + 1, len(pair))));
        }
    }
    return p;
}

// ── a requisição ────────────────────────────────────────────────────────────
// Parseada UMA vez, no começo da conexão; as páginas só leem os campos.
class LexRequest {
    method: string      // "GET", "POST", …
    path: string        // "/docs/intro" (sem a query)
    query: string       // "a=1&b=2" (cru, sem o '?')
    body: string        // o que vem depois da linha em branco
    raw: string         // a requisição inteira, para quem precisar do resto

    constructor(raw: string) {
        this.raw = raw;
        this.method = "GET";
        this.path = "/";
        this.query = "";
        this.body = "";

        // linha de requisição: "GET /caminho?x=1 HTTP/1.1"
        const sp1: i64 = indexOf(raw, " ");
        if (sp1 < 0) { return; }
        this.method = substring(raw, 0, sp1);
        const rest: string = substring(raw, sp1 + 1, len(raw));
        const sp2: i64 = indexOf(rest, " ");
        let target: string = rest;
        if (sp2 >= 0) { target = substring(rest, 0, sp2); }
        const qm: i64 = indexOf(target, "?");
        if (qm < 0) {
            this.path = target;
        } else {
            this.path = substring(target, 0, qm);
            this.query = substring(target, qm + 1, len(target));
        }
        if (len(this.path) == 0) { this.path = "/"; }

        // corpo: depois do CRLF CRLF que fecha os cabeçalhos.
        const sep: i64 = indexOf(raw, "\r\n\r\n");
        if (sep >= 0) { this.body = substring(raw, sep + 4, len(raw)); }
    }

    // valor de um cabeçalho, sem diferenciar maiúsculas ("" se não houver).
    header(name: string): string {
        const want: string = concat(toLower(name), ":");
        for (const line of split(this.raw, "\n")) {
            const clean: string = trim(line);
            if (len(clean) == 0) { return ""; }        // linha em branco = fim
            const c: i64 = indexOf(clean, ":");
            if (c < 0) { continue; }
            if (strEq(concat(toLower(substring(clean, 0, c)), ":"), want)) {
                return trim(substring(clean, c + 1, len(clean)));
            }
        }
        return "";
    }
}

// ── o contexto ──────────────────────────────────────────────────────────────
// `status`, `contentType` e `location` são de ESCRITA: a página os ajusta e o
// servidor monta a resposta a partir deles depois do render. É o que permite um
// 404 ou um redirect saírem de dentro do .lsx, sem o arquivo saber de sockets.
class LexCtx {
    request: LexRequest
    params: LexParams
    status: i64
    contentType: string
    location: string      // "" = sem redirect
    title: string         // <title> do documento
    lang: string          // <html lang="…">
    head: string          // markup extra no <head> (og:, link, …)

    constructor(raw: string) {
        this.request = new LexRequest(raw);
        this.params = parseQuery(this.request.query);
        this.status = 200;
        this.contentType = "text/html; charset=utf-8";
        this.location = "";
        this.title = "";
        this.lang = "en";
        this.head = "";
    }

    // atalhos que leem melhor no frontmatter que mexer nos campos na mão.
    notFound() { this.status = 404; }
    redirect(url: string) { this.status = 302; this.location = url; }
    json() { this.contentType = "application/json; charset=utf-8"; }
    text() { this.contentType = "text/plain; charset=utf-8"; }
}

// O slot por thread do runtime. Um extern trafega tudo em célula i64, então o
// ponteiro do objeto volta já com o tipo certo — não há cast a fazer.
declare function __lex_ctx_set(c: LexCtx): void;
declare function __lex_ctx_get(): LexCtx;
declare function __lex_ctx_has(): i64;
declare function __lex_ctx_clear(): void;

// O `Lex` que o .lsx enxerga.
//
// FORA de uma requisição (um `lex run pagina.lsx`, ou um teste que chama o
// componente direto) não há contexto na thread — e aí um vazio é instalado em
// vez de devolver lixo. Sem isso a mesma página não poderia ser renderizada
// pela linha de comando, que é justamente como se olha uma página sem subir
// servidor nenhum.
fn lexCtx(): LexCtx {
    if (__lex_ctx_has() == 0) { __lex_ctx_set(new LexCtx("")); }
    return __lex_ctx_get();
}

// instala o contexto da requisição na thread corrente e o devolve. Chamado uma
// vez por conexão, ANTES de a página rodar.
fn lexCtxBegin(raw: string): LexCtx {
    const c: LexCtx = new LexCtx(raw);
    __lex_ctx_set(c);
    return c;
}

// desinstala. A thread da conexão morre logo depois, mas a thread PRINCIPAL
// (um teste, um `lex run`) é reusada — deixar o contexto velho para trás faria
// a requisição seguinte enxergar a anterior.
fn lexCtxEnd() { __lex_ctx_clear(); }

// ── a linha de comando ──────────────────────────────────────────────────────
// A porta é decisão de QUEM RODA, não de quem escreve o servidor: trocar de
// porta não deveria custar uma recompilação. `args()` é o argv do processo,
// então isto vale tanto para o binário (`./site/server --port 8080`) quanto
// para o `lex run site/server.lex --port 8080`.

// O SCAN é separado do `args()` de propósito: assim os testes passam um argv
// sintético em vez de depender do argv do processo de teste, que eles não
// controlam.

// valor de `--nome V` ou `--nome=V` em `av`; `fallback` se a flag não vier.
fn flagIn(av: string[], name: string, fallback: string): string {
    const flag: string = concat("--", name);
    const eq: string = concat(flag, "=");
    let i: i64 = 0;
    while (i < av.len()) {
        if (strEq(av[i], flag) && i + 1 < av.len()) { return av[i + 1]; }
        if (startsWith(av[i], eq) != 0) { return substring(av[i], len(eq), len(av[i])); }
        i = i + 1;
    }
    return fallback;
}

// `--port` em `av`, com default. Um valor não-numérico cai no default em vez
// de virar porta 0 — que o SO leria como "escolha qualquer uma", e um servidor
// que sobe numa porta secreta é pior que um que reclama.
fn portIn(av: string[], fallback: i64): i64 {
    const v: string = flagIn(av, "port", "");
    if (len(v) == 0) { return fallback; }
    let i: i64 = 0;
    while (i < len(v)) {
        const c: i64 = peek8(v, i);
        if (c < 48 || c > 57) {
            Terminal.log(`--port: '${v}' nao e um numero; usando ${fallback}`);
            return fallback;
        }
        i = i + 1;
    }
    return parseInt(v);
}

fn argFlag(name: string, fallback: string): string { return flagIn(args(), name, fallback); }
fn argPort(fallback: i64): i64 { return portIn(args(), fallback); }

// ── a resposta ──────────────────────────────────────────────────────────────
fn statusText(code: i64): string {
    if (code == 201) { return "Created"; }
    if (code == 204) { return "No Content"; }
    if (code == 302) { return "Found"; }
    if (code == 400) { return "Bad Request"; }
    if (code == 401) { return "Unauthorized"; }
    if (code == 403) { return "Forbidden"; }
    if (code == 404) { return "Not Found"; }
    if (code == 405) { return "Method Not Allowed"; }
    if (code == 500) { return "Internal Server Error"; }
    return "OK";
}

// ── o documento ─────────────────────────────────────────────────────────────
// Um .lsx é um COMPONENTE, não um documento: ele não escreve `<html>`, `<head>`
// nem `<body>` em lugar nenhum — do mesmo jeito que uma página .astro não
// escreve. O envelope é montado aqui, uma vez, e o que a página controla dele
// sai do contexto (`Lex.title`, `Lex.lang`, `Lex.head`).
//
// Só embrulha HTML: um endpoint que chamou `Lex.text()` ou `Lex.json()` devolve
// o corpo cru (ver servePage em std/http.lex).
fn lexDocument(c: LexCtx, body: string): string {
    return `<!DOCTYPE html>
<html lang="${c.lang}">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${c.title}</title>
${c.head}</head>
<body>
${body}
</body>
</html>`;
}

// o corpo desta resposta é um documento HTML (e não JSON/texto de endpoint)?
fn isHtmlResponse(c: LexCtx): bool { return startsWith(c.contentType, "text/html") != 0; }

// monta a resposta HTTP a partir do que a página deixou no contexto + o corpo
// que ela renderizou.
fn lexResponse(c: LexCtx, body: string): string {
    let extra: string = "";
    if (len(c.location) > 0) { extra = `Location: ${c.location}\r\n`; }
    return `HTTP/1.1 ${c.status} ${statusText(c.status)}\r\nContent-Type: ${c.contentType}\r\nContent-Length: ${len(body)}\r\n${extra}Connection: close\r\n\r\n${body}`;
}
