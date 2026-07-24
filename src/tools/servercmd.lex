// servercmd.lex — as partes PURAS do `lex server`: descobrir as páginas,
// derivar as rotas e GERAR o servidor. O comando em si (build + exec) vive no
// lexcli, que é quem tem o buildFile — mesma divisão de pkg.lex/pkgcmd.lex.
//
// A ideia: não há servidor a escrever. Numa pasta com `pages/`, cada .lsx é uma
// rota, e a porta sai do `lex.toml` (ou do `--port`):
//
//     pages/index.lsx        →  /
//     pages/sobre.lsx        →  /sobre
//     pages/docs/index.lsx   →  /docs
//     pages/docs/intro.lsx   →  /docs/intro
//     public/install.sh      →  /install.sh   (estático)
//
// O roteamento é GERADO e COMPILADO, não interpretado: uma página que não
// compila quebra o build, e não a requisição. E como as rotas viram `strEq`
// contra literais, nenhum caminho vindo da rede toca o filesystem — não há
// travessia de diretório a defender.
import { parseToml } from "./toml"
// o nome do componente vem do front-end dos .lsx — uma regra so, para o fonte
// gerado e o compilador nao discordarem sobre como o simbolo se chama.
import { componentName } from "../compiler/lsx"

// ── varredura de pages/ ─────────────────────────────────────────────────────

fn isLsxFile(nome: string): bool {
    const n: i64 = len(nome);
    return n > 4 && strEq(substring(nome, n - 4, n), ".lsx");
}

// Um nome de arquivo entra numa string do fonte gerado; aspas ou barra invertida
// no nome quebrariam esse fonte. É raro o bastante para recusar em vez de
// escapar — e o aviso diz qual arquivo foi ignorado.
fn nomeSeguro(nome: string): bool {
    let i: i64 = 0;
    while (i < len(nome)) {
        const c: i64 = peek8(nome, i);
        if (c == 34 || c == 92 || c == 96 || c == 36) { return false; }   // " \ ` $
        i = i + 1;
    }
    return true;
}

// caminhos relativos (a partir de `dir`) de todo .lsx, recursivamente.
fn scanPages(dir: string, prefixo: string, out: string[]) {
    for (const nome of readDir(dir)) {
        if (len(nome) == 0) { continue; }
        if (peek8(nome, 0) == 46) { continue; }                  // oculto (.git…)
        const cheio: string = concat(concat(dir, "/"), nome);
        let rel: string = nome;
        if (len(prefixo) > 0) { rel = concat(concat(prefixo, "/"), nome); }
        if (isDir(cheio) != 0) {
            scanPages(cheio, rel, out);
        } else if (isLsxFile(nome)) {
            if (!nomeSeguro(nome)) {
                Terminal.log(`lex server: ignorando '${rel}' (o nome tem aspas ou barra invertida)`);
            } else {
                out.push(rel);
            }
        }
    }
}

// arquivos de public/, recursivamente (qualquer extensão).
fn scanPublic(dir: string, prefixo: string, out: string[]) {
    for (const nome of readDir(dir)) {
        if (len(nome) == 0) { continue; }
        if (peek8(nome, 0) == 46) { continue; }
        const cheio: string = concat(concat(dir, "/"), nome);
        let rel: string = nome;
        if (len(prefixo) > 0) { rel = concat(concat(prefixo, "/"), nome); }
        if (isDir(cheio) != 0) {
            scanPublic(cheio, rel, out);
        } else if (nomeSeguro(nome)) {
            out.push(rel);
        } else {
            Terminal.log(`lex server: ignorando 'public/${rel}' (o nome tem aspas ou barra invertida)`);
        }
    }
}

// ── rota e nome de componente ───────────────────────────────────────────────

// "docs/intro.lsx" → "docs_intro". Dentro de pages/ o nome do componente é o
// caminho inteiro (ver componentName), o que é o que permite um `index.lsx`
// por pasta sem colidir.
fn compName(rel: string): string {
    return componentName(concat("pages/", rel));
}

// "index.lsx" → "/", "sobre.lsx" → "/sobre", "docs/index.lsx" → "/docs".
fn pageRoute(rel: string): string {
    const semExt: string = substring(rel, 0, len(rel) - 4);
    if (strEq(semExt, "index")) { return "/"; }
    const suf: string = "/index";
    if (len(semExt) > len(suf) && strEq(substring(semExt, len(semExt) - len(suf), len(semExt)), suf)) {
        return concat("/", substring(semExt, 0, len(semExt) - len(suf)));
    }
    return concat("/", semExt);
}

fn hasExt(nome: string, ext: string): bool {
    if (len(ext) >= len(nome)) { return false; }
    return strEq(substring(nome, len(nome) - len(ext), len(nome)), ext);
}

// Content-Type de um estático. O default é octet-stream de propósito: servir um
// arquivo desconhecido como text/html deixaria o navegador interpretá-lo.
fn ctypeOf(nome: string): string {
    if (hasExt(nome, ".html")) { return "text/html; charset=utf-8"; }
    if (hasExt(nome, ".css")) { return "text/css; charset=utf-8"; }
    if (hasExt(nome, ".js")) { return "text/javascript; charset=utf-8"; }
    if (hasExt(nome, ".json")) { return "application/json; charset=utf-8"; }
    if (hasExt(nome, ".svg")) { return "image/svg+xml"; }
    if (hasExt(nome, ".txt")) { return "text/plain; charset=utf-8"; }
    if (hasExt(nome, ".sh")) { return "text/plain; charset=utf-8"; }
    return "application/octet-stream";
}

// ── ordenação (saída determinística) ────────────────────────────────────────
// readDir devolve na ordem do SO. Sem ordenar, o fonte gerado — e portanto a
// IR — mudaria de máquina para máquina.
fn strLess(a: string, b: string): bool {
    let n: i64 = len(a);
    if (len(b) < n) { n = len(b); }
    let i: i64 = 0;
    while (i < n) {
        const ca: i64 = peek8(a, i);
        const cb: i64 = peek8(b, i);
        if (ca != cb) { return ca < cb; }
        i = i + 1;
    }
    return len(a) < len(b);
}

fn sortStrs(xs: string[]): string[] {
    let out: string[] = [];
    for (const x of xs) { out.push(x); }
    let i: i64 = 1;
    while (i < out.len()) {                       // inserção: as listas são pequenas
        const v: string = out[i];
        let j: i64 = i - 1;
        while (j >= 0 && strLess(v, out[j])) {
            out[j + 1] = out[j];
            j = j - 1;
        }
        out[j + 1] = v;
        i = i + 1;
    }
    return out;
}

// ── porta ───────────────────────────────────────────────────────────────────
// Precedência: --port > lex.toml > 3000. O manifesto é o mesmo do gerenciador
// de pacotes; a porta mora em `[server] port = 8080`.
fn portFromToml(root: string, fallback: i64): i64 {
    const path: string = concat(root, "/lex.toml");
    if (exists(path) == 0) { return fallback; }
    const v: string = parseToml(readFile(path)).table("server").getStr("port");
    if (len(v) == 0) { return fallback; }
    let i: i64 = 0;
    while (i < len(v)) {
        const c: i64 = peek8(v, i);
        if (c < 48 || c > 57) {
            Terminal.log(`lex.toml: [server] port = '${v}' nao e um numero; usando ${fallback}`);
            return fallback;
        }
        i = i + 1;
    }
    return parseInt(v);
}

// ── o fonte do servidor ─────────────────────────────────────────────────────
// Gera um .lex normal. Ele é escrito NA RAIZ do projeto porque os imports das
// páginas são relativos ao arquivo que importa (`./pages/x.lsx`) — de /tmp os
// caminhos não resolveriam.
fn genServerSrc(pages: string[], estaticos: string[], porta: i64, pagesPath: string): string {
    let s: string = "// GERADO por `lex server` — não edite; este arquivo é temporário.\n";
    s = concat(s, "import { Server } from \"http\"\n");
    s = concat(s, "import { LexCtx, argPort } from \"web\"\n");

    for (const rel of pages) {
        const c: string = compName(rel);
        s = concat(s, `import { ${c}, ${c}Props } from "./${pagesPath}/${rel}"\n`);
    }

    // a porta descoberta aqui é o DEFAULT; `--port` ainda vence em runtime.
    // Num container é o que permite trocar a porta sem rebuildar a imagem.
    s = concat(s, `\nconst PORT: i64 = argPort(${porta});\n\n`);
    s = concat(s, "fn rotas(Lex: LexCtx): string {\n");
    s = concat(s, "    const p: string = Lex.request.path;\n");

    for (const rel of pages) {
        const c: string = compName(rel);
        const rota: string = pageRoute(rel);
        s = concat(s, `    if (strEq(p, "${rota}")) { return ${c}(new ${c}Props()); }\n`);
    }

    for (const rel of estaticos) {
        s = concat(s, `    if (strEq(p, "/${rel}")) {\n`);
        s = concat(s, `        Lex.contentType = "${ctypeOf(rel)}";\n`);
        s = concat(s, `        return readFile("public/${rel}");\n`);
        s = concat(s, "    }\n");
    }

    s = concat(s, "    Lex.notFound();\n");
    s = concat(s, "    Lex.text();\n");
    s = concat(s, "    return \"404 Not Found\";\n");
    s = concat(s, "}\n\n");

    s = concat(s, "fn main(): i32 {\n");
    s = concat(s, "    const app: Server = new Server(PORT);\n");
    s = concat(s, "    app.startPages(rotas) catch {\n");
    s = concat(s, "        Terminal.log(`lex server: a porta ${PORT} ja esta em uso`);\n");
    s = concat(s, "        return 1;\n");
    s = concat(s, "    };\n");
    s = concat(s, "    return 0;\n");
    s = concat(s, "}\n");
    return s;
}
