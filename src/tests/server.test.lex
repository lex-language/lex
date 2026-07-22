// Testes do `lex server` — o mapeamento de pages/ para rotas.
// Rode com:  lex test src/tests/server.test.lex
//
// São as funções PURAS do comando (rota, nome do símbolo, content-type,
// ordenação). O que elas decidem vira o fonte gerado, então errar aqui é
// errar a rota de todo mundo.
import { pageRoute, compName, ctypeOf, sortStrs, strLess } from "../tools/servercmd"
import { componentName } from "../compiler/lsx"

describe("lex server: rotas a partir de pages/", () => {
    test("index e a raiz; o resto e o caminho", () => {
        expect(pageRoute("index.lsx")).toBe("/");
        expect(pageRoute("sobre.lsx")).toBe("/sobre");
        expect(pageRoute("ola.lsx")).toBe("/ola");
    });

    test("index de subpasta e a propria subpasta", () => {
        expect(pageRoute("docs/index.lsx")).toBe("/docs");
        expect(pageRoute("docs/api/index.lsx")).toBe("/docs/api");
    });

    test("pagina em subpasta mantem o caminho inteiro", () => {
        expect(pageRoute("docs/intro.lsx")).toBe("/docs/intro");
        expect(pageRoute("blog/2026/post.lsx")).toBe("/blog/2026/post");
    });
});

describe("lex server: nome do componente", () => {
    // A regressão que motivou qualificar o nome pelo caminho: sob roteamento
    // por arquivo, `index.lsx` se repete em CADA pasta — é assim que se faz
    // `/docs`. Com o nome-do-arquivo os dois viravam o mesmo símbolo `index`,
    // e o clang recusava a IR por redefinição.
    test("dois index.lsx em pastas diferentes nao colidem", () => {
        expect(compName("index.lsx")).toBe("index");
        expect(compName("docs/index.lsx")).toBe("docs_index");
        expect(compName("blog/index.lsx")).toBe("blog_index");
    });

    test("o gerador e o compilador concordam sobre o simbolo", () => {
        expect(compName("docs/intro.lsx")).toBe(componentName("pages/docs/intro.lsx"));
        expect(compName("index.lsx")).toBe(componentName("pages/index.lsx"));
    });

    // fora de pages/ nada muda: um componente escrito à mão continua sendo o
    // nome do arquivo, que é o que as tags `<Selo/>` usam.
    test("fora de pages/ o nome segue sendo o do arquivo", () => {
        expect(componentName("src/tests/fixtures/Selo.lsx")).toBe("Selo");
        expect(componentName("componentes/Card.lsx")).toBe("Card");
        // `subpages/` NÃO é um segmento `pages/`
        expect(componentName("subpages/Card.lsx")).toBe("Card");
    });

    // o símbolo vai para a IR; um traço na pasta não é identificador válido.
    test("caracteres invalidos viram _ no simbolo", () => {
        expect(compName("docs-api/index.lsx")).toBe("docs_api_index");
    });
});

describe("lex server: estaticos de public/", () => {
    test("content-type por extensao", () => {
        expect(ctypeOf("install.sh")).toBe("text/plain; charset=utf-8");
        expect(ctypeOf("estilo.css")).toBe("text/css; charset=utf-8");
        expect(ctypeOf("app.js")).toBe("text/javascript; charset=utf-8");
        expect(ctypeOf("dados.json")).toBe("application/json; charset=utf-8");
    });

    // Servir um desconhecido como text/html deixaria o navegador interpretá-lo.
    test("extensao desconhecida nao vira html", () => {
        expect(ctypeOf("arquivo.xyz")).toBe("application/octet-stream");
        expect(ctypeOf("semextensao")).toBe("application/octet-stream");
    });
});

describe("lex server: ordem estavel", () => {
    // readDir devolve na ordem do SO. Sem ordenar, o fonte gerado — e portanto
    // a IR — mudaria de máquina para máquina.
    test("as paginas saem ordenadas", () => {
        let xs: string[] = [];
        xs.push("ola.lsx"); xs.push("docs/intro.lsx"); xs.push("index.lsx");
        const s: string[] = sortStrs(xs);
        expect(s[0]).toBe("docs/intro.lsx");
        expect(s[1]).toBe("index.lsx");
        expect(s[2]).toBe("ola.lsx");
    });

    test("prefixo vem antes do mais longo", () => {
        expect(strLess("docs", "docs/intro")).toBe(true);
        expect(strLess("b", "a")).toBe(false);
    });
});
