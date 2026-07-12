// Testes do JSON-em-lex (F6.11). Rode com:  lex test tests/
import { jParse, jGet, jStr, jNum, jArr, jPath, jEscape } from "../src/json"

describe("json: parse e acessores", () => {
        test("objeto simples", () => {
                const doc = jParse("{\"a\": 1, \"b\": \"hi\"}");
                expect(jNum(jGet(doc, "a"))).toBe(1);
                expect(jStr(jGet(doc, "b"))).toBe("hi");
        });

        test("aninhado via jPath", () => {
                const doc = jParse("{\"x\": {\"y\": 7}}");
                expect(jNum(jPath(doc, ["x", "y"]))).toBe(7);
        });

        test("array", () => {
                const doc = jParse("[10, 20, 30]");
                const items = jArr(doc);
                expect(items.len()).toBe(3);
                expect(jNum(items[0])).toBe(10);
                expect(jNum(items[2])).toBe(30);
        });

        test("escapes na string (\\n vira quebra real)", () => {
                const doc = jParse("{\"s\": \"a\\nb\"}");
                expect(jStr(jGet(doc, "s"))).toBe("a\nb");
        });

        test("campo ausente → vazio/zero (best-effort)", () => {
                const doc = jParse("{\"a\": 1}");
                expect(jStr(jGet(doc, "naoexiste"))).toBe("");
                expect(jNum(jGet(doc, "naoexiste"))).toBe(0);
        });

        test("mensagem estilo LSP", () => {
                const msg = jParse("{\"method\": \"textDocument/didOpen\", \"params\": {\"textDocument\": {\"uri\": \"file:///a.lex\"}}}");
                expect(jStr(jGet(msg, "method"))).toBe("textDocument/didOpen");
                expect(jStr(jPath(msg, ["params", "textDocument", "uri"]))).toBe("file:///a.lex");
        });
});

describe("json: escape p/ saída", () => {
        test("aspas, barra e controles", () => {
                expect(jEscape("a\"b")).toBe("a\\\"b");
                expect(jEscape("c\\d")).toBe("c\\\\d");
                expect(jEscape("e\nf")).toBe("e\\nf");
        });
});
