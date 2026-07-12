// Testes da sema estrutural (F6.2). Rode com:  lex test tests/
// Confere o layout de classes (slots de campo, vtable, herança+override, tag) e
// os valores de enum — a informação que o codegen de classes (F6.4) consome.
import { semaClassStr, semaFieldSlot, semaMethodIndex, semaEnumValue, inferType } from "../src/sema"

describe("sema: tabela de classes", () => {
        test("classe com campos e constructor", () => {
                const src: string = "class Token { kind: Tok  text: string  constructor(kind: Tok, text: string) { this.kind = kind } }";
                expect(semaClassStr(src, "Token"))
                .toBe("(class Token tag0 _ slots3 (field kind Tok 1) (field text string 2) (method constructor 0 Token))");
        });

        test("herança: campos do pai primeiro, slots em sequência", () => {
                const src: string = "class A { x: i64 }\nclass B extends A { y: i64 }";
                expect(semaClassStr(src, "A")).toBe("(class A tag0 _ slots2 (field x i64 1))");
                expect(semaClassStr(src, "B"))
                .toBe("(class B tag1 A slots3 (field x i64 1) (field y i64 2))");
        });

        test("vtable: override mantém índice, método novo ganha o próximo", () => {
                const src: string = "class Animal { sound(): string { return \"?\" } }\nclass Dog extends Animal { name: string  sound(): string { return \"woof\" }  fetch() { } }";
                expect(semaClassStr(src, "Animal"))
                .toBe("(class Animal tag0 _ slots1 (method sound 0 Animal))");
                expect(semaClassStr(src, "Dog"))
                .toBe("(class Dog tag1 Animal slots2 (field name string 1) (method sound 0 Dog) (method fetch 1 Dog))");
        });

        test("lookups: slot de campo e índice de método (com herança)", () => {
                const src: string = "class Animal { sound(): string { return \"?\" } }\nclass Dog extends Animal { name: string  sound(): string { return \"woof\" }  fetch() { } }";
                expect(semaFieldSlot(src, "Dog", "name")).toBe(1);
                expect(semaMethodIndex(src, "Dog", "sound")).toBe(0);   // herdado/sobrescrito
                expect(semaMethodIndex(src, "Dog", "fetch")).toBe(1);
                expect(semaFieldSlot(src, "Dog", "naoexiste")).toBe(-1);
        });
});

describe("sema: tabela de enums", () => {
        test("variante → valor na ordem", () => {
                const src: string = "enum Color { Red, Green, Blue }";
                expect(semaEnumValue(src, "Color", "Red")).toBe(0);
                expect(semaEnumValue(src, "Color", "Green")).toBe(1);
                expect(semaEnumValue(src, "Color", "Blue")).toBe(2);
                expect(semaEnumValue(src, "Color", "Roxo")).toBe(-1);
        });
});

describe("sema: inferência de tipo por expressão", () => {
        const NONE: string[] = [];

        test("literais e operadores", () => {
                expect(inferType("", "1 + 2 * 3", NONE, NONE)).toBe("i64");
                expect(inferType("", "1 < 2", NONE, NONE)).toBe("bool");
                expect(inferType("", "a && b", ["a", "b"], ["bool", "bool"])).toBe("bool");
                expect(inferType("", "!x", ["x"], ["bool"])).toBe("bool");
                expect(inferType("", "-n", ["n"], ["f64"])).toBe("f64");   // unário preserva
                expect(inferType("", "\"hi\"", NONE, NONE)).toBe("string");
                expect(inferType("", "`v=${a}`", ["a"], ["i64"])).toBe("string");
        });

        test("variável, array/map literal", () => {
                expect(inferType("", "x", ["x"], ["Token[]"])).toBe("Token[]");
                expect(inferType("", "[1, 2, 3]", NONE, NONE)).toBe("i64[]");
                expect(inferType("", "{\"k\": 1}", NONE, NONE)).toBe("Map<i64>");
        });

        test("new, campo e índice", () => {
                expect(inferType("class Pt { x: i64 }", "new Pt()", NONE, NONE)).toBe("Pt");
                expect(inferType("class Pt { x: i64 }", "p.x", ["p"], ["Pt"])).toBe("i64");
                expect(inferType("", "xs[0]", ["xs"], ["Token[]"])).toBe("Token");
                expect(inferType("", "m[\"k\"]", ["m"], ["Map<i64>"])).toBe("i64");
                expect(inferType("", "s[0]", ["s"], ["string"])).toBe("string");
        });

        test("campos encadeados", () => {
                const decls: string = "class Inner { name: string }\nclass Outer { inner: Inner }";
                expect(inferType(decls, "o.inner.name", ["o"], ["Outer"])).toBe("string");
        });

        test("chamadas: função, método de classe e builtins", () => {
                expect(inferType("fn f(): bool { return true }", "f()", NONE, NONE)).toBe("bool");
                expect(inferType("class C { val(): string { return \"a\" } }", "c.val()", ["c"], ["C"]))
                .toBe("string");
                expect(inferType("", "xs.len()", ["xs"], ["i64[]"])).toBe("i64");
                expect(inferType("", "xs.pop()", ["xs"], ["Token[]"])).toBe("Token");
                expect(inferType("", "concat(a, b)", ["a", "b"], ["string", "string"])).toBe("string");
                expect(inferType("", "str(n)", ["n"], ["i64"])).toBe("string");
                expect(inferType("", "parseFloat(t)", ["t"], ["string"])).toBe("f64");
        });

        test("match: tipo do 1º braço com binding no escopo", () => {
                const decls: string = "class IntLit { value: i64 }";
                expect(inferType(decls, "match (e) { IntLit n => n.value }", ["e"], ["IntLit"]))
                .toBe("i64");
        });
});
