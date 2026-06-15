// pages — renderização das páginas HTML do registry (lista, busca, detalhe).

import { dataDir, pkgPath } from "./store";

// molde da página: cabeçalho + estilo + conteúdo.
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

// página de detalhe de um pacote.
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
