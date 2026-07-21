// Testes dos componentes .lsx (estilo Astro). Rode com:  lex test src/tests/
//
// São testes PONTA A PONTA de propósito: importam fixtures .lsx de verdade, o
// que exercita o caminho inteiro — ModuleLoader resolve a extensão, o front-end
// fatia frontmatter e corpo, o typecheck valida as props e o codegen desugara
// `<Selo/>` em `Selo(new SeloProps(…))`. Um teste de unidade sobre o parser não
// pegaria a metade que mais quebra: o desugar, que só é possível depois do
// merge dos módulos.
import { Selo, SeloProps } from "./fixtures/Selo.lsx"
import { Caixa, CaixaProps } from "./fixtures/Caixa.lsx"
import { Moldura, MolduraProps } from "./fixtures/Moldura.lsx"
import { Estilo, EstiloProps } from "./fixtures/Estilo.lsx"
import { Escapa, EscapaProps } from "./fixtures/Escapa.lsx"
import { Compoe, CompoeProps } from "./fixtures/Compoe.lsx"

describe("lsx: componente e props", () => {
    test("props tipadas chegam interpoladas no corpo", () => {
        expect(Selo(new SeloProps("itens", 42)))
        .toBe("<span class=\"selo\">itens:42</span>");
    });

    test("statement do frontmatter roda antes do return", () => {
        expect(Caixa(new CaixaProps("Titulo")))
        .toBe("<div><h2>Titulo!</h2><span class=\"selo\">n:7</span></div>");
    });
});

describe("lsx: slot", () => {
    test("<slot/> recebe o conteudo dos filhos", () => {
        expect(Moldura(new MolduraProps("x", "<b>dentro</b>")))
        .toBe("<section data-nome=\"x\"><b>dentro</b></section>");
    });

    test("sem filhos o slot fica vazio", () => {
        expect(Moldura(new MolduraProps("y", "")))
        .toBe("<section data-nome=\"y\"></section>");
    });
});

describe("lsx: <style> com escopo", () => {
    // o hash vem do NOME do componente, então é estável entre builds — se
    // deixasse de ser, este teste quebraria e é exatamente o que se quer.
    test("atributo de escopo entra na tag e no seletor", () => {
        expect(Estilo(new EstiloProps()))
        .toBe("<p data-lsx-v6r8dg class=\"a\">oi</p>\n<style>.a[data-lsx-v6r8dg] { color: red }</style>");
    });
});

describe("lsx: interpolacao em atributo", () => {
    // `data-nome={props.nome}` TEM de sair entre aspas: sem elas um valor com
    // espaco quebraria a tag, e o bug so apareceria com o dado certo.
    test("valor interpolado sai sempre entre aspas", () => {
        expect(Moldura(new MolduraProps("com espaco", "")))
        .toBe("<section data-nome=\"com espaco\"></section>");
    });
});

describe("lsx: escape por padrao", () => {
    // O motivo de `Html` existir. Um `string` interpolado no corpo de um
    // componente é DADO — potencialmente de usuário — e sai escapado, em texto
    // e em atributo. Só o que tem tipo `Html` passa cru.
    test("string interpolada escapa em texto e em atributo", () => {
        expect(Escapa(new EscapaProps("<script>alert('x')</script>", "")))
        .toBe("<li title=\"&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;\">&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;|</li>");
    });

    test("html(...) e a saida de emergencia: passa cru", () => {
        expect(Escapa(new EscapaProps("a&b", "<b>ok</b>")))
        .toBe("<li title=\"a&amp;b\">a&amp;b|<b>ok</b></li>");
    });

    // Se um componente devolvesse `string`, compor escaparia o markup do filho
    // e a página sairia com &lt;li&gt; na cara do usuário. Devolver `Html` é o
    // que impede o escape duplo.
    test("compor componente nao escapa o markup do filho", () => {
        expect(Compoe(new CompoeProps("<i>x</i>")))
        .toBe("<ul><li title=\"&lt;i&gt;x&lt;/i&gt;\">&lt;i&gt;x&lt;/i&gt;|<b>ok</b></li></ul>");
    });
});
