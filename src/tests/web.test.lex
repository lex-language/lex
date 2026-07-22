// Testes do contexto de requisição — o objeto `Lex` das páginas .lsx.
// Rode com:  lex test src/tests/web.test.lex
//
// A metade que mais interessa é a última: um .lsx que NÃO importa nada e ainda
// assim enxerga `Lex`. Isso só passa se o front-end dos .lsx tiver injetado a
// declaração e o import de std/web — um teste de unidade sobre LexCtx sozinho
// não pegaria a injeção, que é a feature.
import { LexCtx, LexRequest, lexCtx, lexCtxBegin, lexCtxEnd, lexResponse, parseQuery, urlDecode, flagIn, portIn } from "web"
import { Contexto, ContextoProps } from "./fixtures/Contexto.lsx"
import { Global, GlobalProps } from "./fixtures/Global.lsx"

describe("web: a requisicao", () => {
    test("linha de requisicao vira metodo, path e query", () => {
        const r: LexRequest = new LexRequest("POST /docs/intro?a=1&b=2 HTTP/1.1\r\nHost: lex.dev\r\n\r\ncorpo aqui");
        expect(r.method).toBe("POST");
        expect(r.path).toBe("/docs/intro");
        expect(r.query).toBe("a=1&b=2");
        expect(r.body).toBe("corpo aqui");
    });

    test("path sem query, e requisicao vazia cai no default", () => {
        expect(new LexRequest("GET /sobre HTTP/1.1\r\n\r\n").path).toBe("/sobre");
        expect(new LexRequest("").path).toBe("/");
        expect(new LexRequest("").method).toBe("GET");
    });

    test("cabecalho nao diferencia maiusculas", () => {
        const r: LexRequest = new LexRequest("GET / HTTP/1.1\r\nContent-Type: text/plain\r\nHost: lex.dev\r\n\r\n");
        expect(r.header("content-type")).toBe("text/plain");
        expect(r.header("HOST")).toBe("lex.dev");
        expect(r.header("Accept")).toBe("");
    });
});

describe("web: parametros", () => {
    test("percent-decoding, e '+' vale espaco", () => {
        expect(urlDecode("Fernando%20Souza")).toBe("Fernando Souza");
        expect(urlDecode("a+b")).toBe("a b");
        // um '%' solto passa literal em vez de comer os bytes seguintes
        expect(urlDecode("100%")).toBe("100%");
        expect(urlDecode("%zz")).toBe("%zz");
    });

    test("chave ausente vale \"\", e chave sem '=' vale \"\"", () => {
        const p: LexParams = parseQuery("nome=ana&debug");
        expect(p.get("nome")).toBe("ana");
        expect(p.get("debug")).toBe("");
        expect(p.has("debug")).toBe(true);
        expect(p.get("ausente")).toBe("");
        expect(p.has("ausente")).toBe(false);
    });
});

describe("web: a porta vem da linha de comando", () => {
    test("--port N e --port=N valem o mesmo", () => {
        let a: string[] = [];
        a.push("./server"); a.push("--port"); a.push("8080");
        expect(portIn(a, 3000)).toBe(8080);

        let b: string[] = [];
        b.push("./server"); b.push("--port=9090");
        expect(portIn(b, 3000)).toBe(9090);
    });

    test("sem a flag, o default", () => {
        let a: string[] = [];
        a.push("./server");
        expect(portIn(a, 3000)).toBe(3000);
        // `--port` como ÚLTIMO argumento não tem valor a ler
        a.push("--port");
        expect(portIn(a, 3000)).toBe(3000);
    });

    // Cair no default é melhor que virar porta 0, que o SO lê como "escolha
    // qualquer uma" — o servidor subiria numa porta que ninguém sabe qual é.
    test("valor nao-numerico cai no default", () => {
        let a: string[] = [];
        a.push("./server"); a.push("--port"); a.push("oitenta");
        expect(portIn(a, 3000)).toBe(3000);
    });

    test("flags convivem, em qualquer ordem", () => {
        let a: string[] = [];
        a.push("./server"); a.push("--host"); a.push("0.0.0.0");
        a.push("--port"); a.push("7070");
        expect(portIn(a, 3000)).toBe(7070);
        expect(flagIn(a, "host", "localhost")).toBe("0.0.0.0");
        expect(flagIn(a, "ausente", "padrao")).toBe("padrao");
    });
});

describe("web: a resposta sai do contexto", () => {
    test("status e content-type que a pagina deixou", () => {
        const c: LexCtx = new LexCtx("GET / HTTP/1.1\r\n\r\n");
        c.notFound();
        c.text();
        expect(lexResponse(c, "nada")).toBe("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnada");
    });

    // O `\r` é o motivo deste teste existir: enquanto o escape não funcionava
    // dentro de template literal, o bloco de cabeçalhos nunca terminava e o
    // cliente lia o início do corpo como se fosse cabeçalho.
    test("redirect acrescenta Location, com CRLF de verdade", () => {
        const c: LexCtx = new LexCtx("GET / HTTP/1.1\r\n\r\n");
        c.redirect("/novo");
        expect(lexResponse(c, "")).toBe("HTTP/1.1 302 Found\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 0\r\nLocation: /novo\r\nConnection: close\r\n\r\n");
    });
});

describe("web: `Lex` e nativo do .lsx", () => {
    test("a pagina enxerga a requisicao sem importar nada", () => {
        lexCtxBegin("POST /ola?nome=ana HTTP/1.1\r\n\r\n");
        expect(Contexto(new ContextoProps())).toBe("<p>ana|POST|/ola|200</p>");
        lexCtxEnd();
    });

    test("a pagina decide o proprio status", () => {
        lexCtxBegin("GET /ola HTTP/1.1\r\n\r\n");
        expect(Contexto(new ContextoProps())).toBe("<p>|GET|/ola|404</p>");
        lexCtxEnd();
    });

    // FORA de uma requisição (um `lex run pagina.lsx`, ou este próprio teste)
    // não há contexto na thread. Um vazio é instalado em vez de devolver lixo —
    // é o que permite olhar uma página sem subir servidor nenhum.
    test("sem requisicao, o contexto e vazio em vez de lixo", () => {
        lexCtxEnd();
        expect(lexCtx().request.path).toBe("/");
        expect(lexCtx().request.method).toBe("GET");
        expect(lexCtx().status).toBe(200);
    });
});

describe("lsx: <style is:global>", () => {
    // O local escopa (tag e seletor ganham data-lsx-…); o global sai intacto e
    // a diretiva não vaza para o HTML.
    test("global passa cru, local continua escopado", () => {
        expect(Global(new GlobalProps()))
        .toBe("<p data-lsx-qxdlrr>oi</p>\n<style>body { margin: 0 }</style>\n<style>p[data-lsx-qxdlrr] { color: red }</style>");
    });
});
