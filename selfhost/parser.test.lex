// Testes do parser-em-lex (Fase 2). Rode com:  lex test selfhost
// Cada caso parseia uma expressão e confere a AST renderizada como S-expression
// (string → comparação robusta, sem depender de boxing de array em `any`).
import { parseExprStr, parseStmtStr, parseFuncStr } from "./parser"

describe("parser de expressões", () => {
    test("precedência aritmética", () => {
        expect(parseExprStr("1 + 2 * 3")).toBe("(+ 1 (* 2 3))");
        expect(parseExprStr("1 * 2 + 3")).toBe("(+ (* 1 2) 3)");
        expect(parseExprStr("1 - 2 - 3")).toBe("(- (- 1 2) 3)");   // assoc. à esquerda
        expect(parseExprStr("2 * 3 % 4")).toBe("(% (* 2 3) 4)");
    });

    test("parênteses sobrepõem precedência", () => {
        expect(parseExprStr("(1 + 2) * 3")).toBe("(* (+ 1 2) 3)");
    });

    test("lógicos, comparações e bitwise", () => {
        expect(parseExprStr("a && b || c")).toBe("(|| (&& a b) c)");
        expect(parseExprStr("a == b && c != d")).toBe("(&& (== a b) (!= c d))");
        expect(parseExprStr("x < 1 | y >> 2")).toBe("(| (< x 1) (>> y 2))");
    });

    test("unários", () => {
        expect(parseExprStr("-x + 1")).toBe("(+ (- x) 1)");
        expect(parseExprStr("!a && b")).toBe("(&& (! a) b)");
        expect(parseExprStr("~x")).toBe("(~ x)");
    });

    test("chamadas e array literal", () => {
        expect(parseExprStr("f(1, 2)")).toBe("(call f 1 2)");
        expect(parseExprStr("g()")).toBe("(call g)");
        expect(parseExprStr("[1, 2, 3]")).toBe("[1 2 3]");
        expect(parseExprStr("[]")).toBe("[]");
    });

    test("pós-fixos: campo, método, índice", () => {
        expect(parseExprStr("a.b.c")).toBe("(. (. a b) c)");
        expect(parseExprStr("obj.m(1)")).toBe("(. obj m 1)");
        expect(parseExprStr("xs[0]")).toBe("(index xs 0)");
        expect(parseExprStr("a.b[c].d")).toBe("(. (index (. a b) c) d)");
    });

    test("literais", () => {
        expect(parseExprStr("true")).toBe("true");
        expect(parseExprStr("false")).toBe("false");
        expect(parseExprStr("\"hi\"")).toBe("\"hi\"");
    });
});

describe("parser de statements", () => {
    test("let/const com e sem tipo", () => {
        expect(parseStmtStr("let x: i64 = 1 + 2")).toBe("(let x:i64 (+ 1 2))");
        expect(parseStmtStr("const y = 5")).toBe("(const y 5)");
        expect(parseStmtStr("let xs: i64[] = [1, 2]")).toBe("(let xs:i64[] [1 2])");
        expect(parseStmtStr("let m: Map<i64> = z")).toBe("(let m:Map<i64> z)");
    });

    test("atribuição a variável, campo e índice", () => {
        expect(parseStmtStr("x = 10")).toBe("(= x 10)");
        expect(parseStmtStr("a.b = 3")).toBe("(= (. a b) 3)");
        expect(parseStmtStr("xs[i] = 0")).toBe("(= (index xs i) 0)");
    });

    test("return, break, continue, expr-statement", () => {
        expect(parseStmtStr("return")).toBe("(return)");
        expect(parseStmtStr("return x + 1")).toBe("(return (+ x 1))");
        expect(parseStmtStr("break")).toBe("(break)");
        expect(parseStmtStr("continue")).toBe("(continue)");
        expect(parseStmtStr("foo(1)")).toBe("(call foo 1)");
    });

    test("if / else / else-if", () => {
        expect(parseStmtStr("if (x > 0) { return x }")).toBe("(if (> x 0) (do (return x)))");
        expect(parseStmtStr("if (a) { x = 1 } else { x = 2 }"))
            .toBe("(if a (do (= x 1)) (do (= x 2)))");
        expect(parseStmtStr("if (a) { x = 1 } else if (b) { x = 2 }"))
            .toBe("(if a (do (= x 1)) (do (if b (do (= x 2)))))");
    });

    test("while", () => {
        expect(parseStmtStr("while (i < 10) { i = i + 1 }"))
            .toBe("(while (< i 10) (do (= i (+ i 1))))");
    });
});

describe("parser de funções", () => {
    test("assinatura: params, retorno, falível", () => {
        expect(parseFuncStr("fn add(a: i64, b: i64): i64 { return a + b }"))
            .toBe("(fn add (a:i64 b:i64) i64 (do (return (+ a b))))");
        expect(parseFuncStr("fn f(): i64! { return 1 }"))
            .toBe("(fn f () i64! (do (return 1)))");
        expect(parseFuncStr("fn greet(name: string) { foo(name) }"))
            .toBe("(fn greet (name:string) void (do (call foo name)))");
    });

    test("corpo multilinha (newlines invisíveis)", () => {
        const src: string = "fn g(n: i64): i64 {\n  let x: i64 = n * 2\n  if (x > 10) { return x }\n  return 0\n}";
        expect(parseFuncStr(src))
            .toBe("(fn g (n:i64) i64 (do (let x:i64 (* n 2)) (if (> x 10) (do (return x))) (return 0)))");
    });
});
