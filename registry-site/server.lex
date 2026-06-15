// O registry do lex como SITE — escrito em lex (dogfooding do servidor HTTP +
// fs + JSON da própria linguagem). Este arquivo é só o roteamento + o `main`;
// a lógica está nos módulos: store (dados), pages (HTML) e api (JSON).
//
//   GET  /                      lista + busca (HTML)            ?q=<termo>
//   GET  /pkg/<nome>            página de detalhe do pacote (HTML)
//   GET  /api/packages          índice em JSON (array)
//   GET  /api/pkg/<nome>        1 pacote em JSON — é o que o `lex add` consome
//   POST /api/publish           publica/atualiza um pacote (usado por `lex publish`)
//
//   lex registry-site/server.lex -o registry && ./registry      # porta 8080

import { Server, Conn } from "http";
import { dataDir, port, pkgPath, safeName } from "./store";
import { page, htmlList, htmlDetail } from "./pages";
import { qparam, apiList, publish } from "./api";

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
