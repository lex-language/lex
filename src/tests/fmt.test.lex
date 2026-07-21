// Testes do formatador-em-lex (F6.7). Rode com:  lex test tests/
// Confere a saída de formatSource (indentação, linhas em branco, templates).
import { formatSource } from "../tools/fmt"

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

describe("fmt: fn inline não é permitida", () => {
        test("quebra corpo de um statement", () => {
                expect(formatSource("fn dl(): string { return \"$\"; }"))
                .toBe("fn dl(): string {\n    return \"$\";\n}\n");
        });

        test("quebra corpo de vários statements", () => {
                expect(formatSource("fn f(): i64 { let a: i64 = 1; return a; }"))
                .toBe("fn f(): i64 {\n    let a: i64 = 1;\n    return a;\n}\n");
        });

        test("não quebra no ';' dentro de string", () => {
                expect(formatSource("fn s(): string { return \"a;b\"; }"))
                .toBe("fn s(): string {\n    return \"a;b\";\n}\n");
        });

        test("bloco aninhado fica junto do statement", () => {
                expect(formatSource("fn f() { if (a) { x(); } return 1; }"))
                .toBe("fn f() {\n    if (a) { x(); }\n    return 1;\n}\n");
        });

        test("comentário no fim sobra com o '}'", () => {
                expect(formatSource("fn f(): i64 { return 7070; }  // porta"))
                .toBe("fn f(): i64 {\n    return 7070;\n}  // porta\n");
        });

        test("corpo vazio e não-fn ficam como estão", () => {
                expect(formatSource("fn f() {}")).toBe("fn f() {}\n");
                expect(formatSource("if (a) { x(); }")).toBe("if (a) { x(); }\n");
        });

        test("statement sem ';' final também quebra", () => {
                expect(formatSource("fn f(): i64 { return 1 }"))
                .toBe("fn f(): i64 {\n    return 1\n}\n");
        });

        test("idempotente", () => {
                const once: string = formatSource("fn f(): i64 { let a: i64 = 1; return a; }");
                expect(formatSource(once)).toBe(once);
        });

        test("} else { não é cortado", () => {
                expect(formatSource("fn f(): i64 { if (a) { return 1; } else { return 2; } }"))
                .toBe("fn f(): i64 {\n    if (a) { return 1; } else { return 2; }\n}\n");
        });

        test("';' do for(;;) não conta", () => {
                expect(formatSource("fn f() { for (let i: i64 = 0; i < 3; i = i + 1) { x(); } y(); }"))
                .toBe("fn f() {\n    for (let i: i64 = 0; i < 3; i = i + 1) { x(); }\n    y();\n}\n");
        });

        test("fn já quebrada não muda", () => {
                const src: string = "fn f(): i64 {\n    return 1;\n}\n";
                expect(formatSource(src)).toBe(src);
        });

});
