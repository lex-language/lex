// Testes do parser-em-lex (Fase 2). Rode com:  lex test selfhost
// Cada caso parseia uma expressão e confere a AST renderizada como S-expression
// (string → comparação robusta, sem depender de boxing de array em `any`).
import { parseExprStr, parseStmtStr, parseFuncStr, parseModuleStr } from "./parser"

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

describe("parser de expressões (F6.1)", () => {
    test("new", () => {
        expect(parseExprStr("new Token(k, t)")).toBe("(new Token k t)");
        expect(parseExprStr("new Codegen()")).toBe("(new Codegen)");
    });

    test("map e struct literal", () => {
        expect(parseExprStr("{}")).toBe("(map)");
        expect(parseExprStr("{\"a\": 1, \"b\": 2}")).toBe("(map \"a\" 1 \"b\" 2)");
        expect(parseExprStr("{x: 1, y: 2}")).toBe("(struct x 1 y 2)");
    });

    test("match por tipo + curinga", () => {
        expect(parseExprStr("match (e) { IntLit n => n.value, _ => 0 }"))
            .toBe("(match e (IntLit n (. n value)) (_ 0))");
        expect(parseExprStr("match (s) { LetStmt l => f(l), BreakStmt b => 1 }"))
            .toBe("(match s (LetStmt l (call f l)) (BreakStmt b 1))");
    });

    test("template literal com ${}", () => {
        expect(parseExprStr("`x=${a}`")).toBe("(tpl \"x=\" a)");
        expect(parseExprStr("`${a}-${b}`")).toBe("(tpl a \"-\" b)");
        expect(parseExprStr("`v=${f(1)}`")).toBe("(tpl \"v=\" (call f 1))");
        expect(parseExprStr("`só texto`")).toBe("(tpl \"só texto\")");
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

    test("for-of", () => {
        expect(parseStmtStr("for (const x of xs) { f(x) }"))
            .toBe("(forof x xs (do (call f x)))");
        expect(parseStmtStr("for (const t of toks) { g(t) h(t) }"))
            .toBe("(forof t toks (do (call g t) (call h t)))");
    });

    test("for C-style", () => {
        expect(parseStmtStr("for (let i: i64 = 0; i < n; i = i + 1) { g(i) }"))
            .toBe("(for (let i:i64 0) (< i n) (= i (+ i 1)) (do (call g i)))");
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

describe("parser de módulo (F6.1)", () => {
    test("import", () => {
        expect(parseModuleStr("import { a, b } from \"./m\""))
            .toBe("(program (import (a b) \"./m\"))");
    });

    test("enum", () => {
        expect(parseModuleStr("enum Color { Red, Green, Blue }"))
            .toBe("(program (enum Color Red Green Blue))");
    });

    test("class: campo, constructor e método", () => {
        const src: string = "class Pt { x: i64  constructor(x: i64) { this.x = x }  get(): i64 { return this.x } }";
        expect(parseModuleStr(src))
            .toBe("(program (class Pt _ (field x i64) (fn constructor (x:i64) void (do (= (. this x) x))) (fn get () i64 (do (return (. this x))))))");
    });

    test("class com extends (herança)", () => {
        expect(parseModuleStr("class Dog extends Animal { }"))
            .toBe("(program (class Dog Animal))");
    });

    test("módulo completo: import + enum + class + fn", () => {
        const src: string = "import { x } from \"./a\"\nenum E { A, B }\nclass C { n: i64 }\nfn main(): i64 { return 0 }";
        expect(parseModuleStr(src))
            .toBe("(program (import (x) \"./a\") (enum E A B) (class C _ (field n i64)) (fn main () i64 (do (return 0))))");
    });

    test("script-mode: statements de topo viram (main ...)", () => {
        const src: string = "const x: i64 = 1\nTerminal.log(x)";
        expect(parseModuleStr(src))
            .toBe("(program (do (const x:i64 1) (. Terminal log x)))");
    });
});

describe("parser: arrow functions (Fase A)", () => {
    test("arrow içada p/ __lambda_N e referenciada como (lambda …)", () => {
        expect(parseModuleStr("fn main(): i64 { return apply(() => 42) }"))
            .toBe("(program (fn main () i64 (do (return (call apply (lambda __lambda_0))))) (fn __lambda_0 () i64 (do (return 42))))");
    });

    test("tipo de função na anotação + arrow com parâmetro", () => {
        expect(parseStmtStr("let f: (i64) => i64 = (x: i64) => x + 1"))
            .toBe("(let f:(i64)=>i64 (lambda __lambda_0))");
    });
});
