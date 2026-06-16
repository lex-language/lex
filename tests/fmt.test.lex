// Testes do formatador-em-lex (F6.7). Rode com:  lex test selfhost
// Confere a saída de formatSource (indentação, linhas em branco, templates).
import { formatSource } from "../selfhost/fmt"

describe("fmt: indentação", () => {
        test("bloco simples ganha 4 espaços", () => {
                expect(formatSource("fn f(): i64 {\nreturn 1\n}"))
                .toBe("fn f(): i64 {\n    return 1\n}\n");
        });

        test("aninhamento acumula níveis", () => {
                expect(formatSource("fn f() {\nif (a) {\nx = 1\n}\n}"))
                .toBe("fn f() {\n    if (a) {\n        x = 1\n    }\n}\n");
        });

        test("fechador inicial puxa a linha p/ a esquerda (} else {)", () => {
                expect(formatSource("if (a) {\nx\n} else {\ny\n}"))
                .toBe("if (a) {\n    x\n} else {\n    y\n}\n");
        });

        test("re-indenta o que estava torto", () => {
                expect(formatSource("fn f() {\n        x = 1\n  y = 2\n}"))
                .toBe("fn f() {\n    x = 1\n    y = 2\n}\n");
        });
});

describe("fmt: espaço em branco", () => {
        test("remove trailing e colapsa linhas em branco", () => {
                expect(formatSource("a   \n\n\n\nb\n\n")).toBe("a\n\nb\n");
        });

        test("garante exatamente um \\n no fim", () => {
                expect(formatSource("x")).toBe("x\n");
                expect(formatSource("x\n\n\n")).toBe("x\n");
        });
});

describe("fmt: seguro com strings e templates", () => {
        test("não conta { dentro de string", () => {
                expect(formatSource("fn f() {\nlet s: string = \"{{{\"\nreturn s\n}"))
                .toBe("fn f() {\n    let s: string = \"{{{\"\n    return s\n}\n");
        });

        test("interior de template multilinha sai intacto", () => {
                const input: string = "fn g() {\nlet s: string = `keep   me\n   and  me\n`\n}";
                expect(formatSource(input))
                .toBe("fn g() {\n    let s: string = `keep   me\n   and  me\n`\n}\n");
        });
});

describe("fmt: idempotência", () => {
        test("formatar duas vezes = formatar uma vez", () => {
                const once: string = formatSource("fn f(){\n  if (a) {\nx\n  }\n}");
                expect(formatSource(once)).toBe(once);
        });
});
