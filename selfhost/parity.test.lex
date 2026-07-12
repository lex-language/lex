// parity.test.lex — PORTÃO DE PARIDADE com o compilador Rust (portado de tests/e2e.rs).
// NÃO faz parte da suíte verde: é o gate que diz o que AINDA falta portar.
// Rode com: lex test selfhost/parity.test.lex
// Portado de tests/e2e.rs (que morreu junto com o compilador Rust). Cada caso é um
// programa `main(): i32` que devolve 0 quando todas as verificações passam: o teste
// compila o fonte, linka com clang e RODA o binário, conferindo o exit code.
import { compileToIR } from "./codegen"

// fonte -> exit code do binário nativo (-1 se o clang falhar).
fn runSrc(src: string, name: string): i64 {
    const ll: string = concat(concat("/tmp/lex_lang_", name), ".ll");
    const bin: string = concat("/tmp/lex_lang_", name);
    writeFile(ll, compileToIR(src));
    if (system(`clang -Wno-override-module -o ${bin} ${ll} src/runtime.c -lpthread`) != 0) { return -1; }
    return system(bin) / 256;       // WEXITSTATUS
}

describe("linguagem completa (e2e)", () => {
    test("operadores e precedência", () => {
        expect(runSrc("fn main(): i32 {\nif (2 + 3 * 4 == 14 && 17 % 5 == 2 && (6 & 3) == 2 && (1 << 4) == 16) { return 0; }\nreturn 1;\n}", "c0")).toBe(0);
    });
    test("for + break + continue", () => {
        expect(runSrc("fn main(): i32 {\nlet s: i64 = 0;\nfor (let i: i64 = 0; i < 100; i++) {\nif (i % 2 == 1) { continue; }\nif (i > 8) { break; }\ns += i;\n}\nreturn s - 20;\n}", "c1")).toBe(0);
    });
    test("for...of sobre array", () => {
        expect(runSrc("fn main(): i32 {\nlet t: i64 = 0;\nfor (const v of [10, 20, 30]) { t += v; }\nreturn t - 60;\n}", "c2")).toBe(0);
    });
    test("match expressão + guarda + faixa", () => {
        expect(runSrc("fn main(): i32 {\nlet r: i64 = match (7) { 0..5 => 1, x if x > 5 => 2, _ => 3 };\nreturn r - 2;\n}", "c3")).toBe(0);
    });
    test("floats (f64) e math", () => {
        expect(runSrc("fn main(): i32 {\nlet a: f64 = 7.0;\nlet b: f64 = 2.0;\nlet raiz: i64 = round(sqrt(9.0));\nif (a / b == 3.5 && raiz == 3) { return 0; }\nreturn 1;\n}", "c4")).toBe(0);
    });
    test("f32 distinto", () => {
        expect(runSrc("fn main(): i32 {\nlet x: f32 = 0.5;\nif (x + x == 1.0) { return 0; }\nreturn 1;\n}", "c5")).toBe(0);
    });
    test("genéricos: função e classe (tipo concreto preservado)", () => {
        expect(runSrc("class Box<T> { v: T; constructor(x: T){this.v=x} get(): T { return this.v } }\nfn first<T>(xs: T[]): T { return xs[0]; }\nfn main(): i32 {\nlet b: Box<i64> = new Box<i64>(42);\nlet xs: i64[] = [10, 20];\nif (b.get() == 42 && first(xs) == 10) { return 0; }\nreturn 1;\n}", "c6")).toBe(0);
    });
    test("genérico com float através de T", () => {
        expect(runSrc("class Box<T> { v: T; constructor(x: T){this.v=x} get(): T { return this.v } }\nfn main(): i32 {\nlet b: Box<f64> = new Box<f64>(3.5);\nif (b.get() == 3.5) { return 0; }\nreturn 1;\n}", "c7")).toBe(0);
    });
    test("erros: try/catch", () => {
        expect(runSrc("fn d(a: i64, b: i64): i64! { if (b == 0) { fail 1; } return a / b; }\nfn main(): i32 {\nlet x: i64 = d(10, 0) catch 99;\nreturn x - 99;\n}", "c8")).toBe(0);
    });
    test("OOP: herança + polimorfismo (vtable)", () => {
        expect(runSrc("class A { f(): i64 { return 1; } }\nclass B extends A { f(): i64 { return 2; } }\nfn main(): i32 {\nlet a: A = new B();\nreturn a.f() - 2;\n}", "c9")).toBe(0);
    });
    test("async/await (threads reais, sem runtime)", () => {
        expect(runSrc("async fn sq(n: i64): i64 { return n * n; }\nfn main(): i32 {\nlet a: Future<i64> = sq(6);\nlet b: Future<i64> = sq(7);\nreturn (await a + await b) - 85;\n}", "c10")).toBe(0);
    });
    test("campos static: contador compartilhado + init não-const + herança", () => {
        expect(runSrc("class Counter {\nstatic count: i64 = 0;\nstatic base: i64 = 10 * 4 + 2;\nconstructor(){ Counter.count = Counter.count + 1; }\n}\nclass Sub extends Counter { constructor(){ super(); } }\nfn main(): i32 {\nlet a: Counter = new Counter();\nlet b: Sub = new Sub();\nCounter.count = Counter.count + 10;\nif (Counter.count == 12 && Counter.base == 42 && Sub.count == 12) { return 0; }\nreturn 1;\n}", "c11")).toBe(0);
    });
    test("arrow: tipo de retorno inferido do contexto (float sem anotação)", () => {
        expect(runSrc("fn callF(f: () => f64): f64 { return f(); }\nfn applyF(f: (f64) => f64, x: f64): f64 { return f(x); }\nfn main(): i32 {\nlet h: () => f64 = () => 2.5 * 2.0;\nlet dobro: (f64) => f64 = (x: f64) => x * 2.0;\nif (callF(h) == 5.0 && applyF(dobro, 3.0) == 6.0) { return 0; }\nreturn 1;\n}", "c12")).toBe(0);
    });
    test("closures com captura (por valor): simples, this e aninhada", () => {
        expect(runSrc("fn run(f: (i64) => i64, x: i64): i64 { return f(x); }\nfn run0(f: () => i64): i64 { return f(); }\nfn makeAdder(a: i64): (i64) => i64 { return (b: i64) => a + b; }\nclass Box { v: i64; constructor(x: i64){this.v=x} getter(): () => i64 { return () => this.v; } }\nfn main(): i32 {\nlet m: i64 = 10;\nlet add: (i64) => i64 = (x: i64) => x + m;\nlet add10: (i64) => i64 = makeAdder(10);\nlet g: () => i64 = new Box(42).getter();\nm = 99;                               // captura por valor: não afeta 'add'\nif (run(add, 5) == 15 && run(add10, 7) == 17 && run0(g) == 42) { return 0; }\nreturn 1;\n}", "c13")).toBe(0);
    });
    test("enum: valor, comparação e match de variante", () => {
        expect(runSrc("enum Color { Red, Green, Blue }\nfn rank(c: Color): i64 { return match (c) { Color.Red => 1, Color.Green => 2, _ => 3 }; }\nfn main(): i32 {\nlet c: Color = Color.Blue;\nif (Color.Green == 1 && rank(Color.Red) == 1 && rank(c) == 3 && c == 2) { return 0; }\nreturn 1;\n}", "c14")).toBe(0);
    });
    test("match sobre tipos (vtable) + destructuring de struct", () => {
        expect(runSrc("class Shape { area(): i64 { return 0; } }\nclass Circle extends Shape { r: i64; constructor(x: i64){this.r=x} }\nclass Square extends Shape { s: i64; constructor(x: i64){this.s=x} }\ntype Pt = { x: i64, y: i64 };\nfn kind(sh: Shape): i64 {\nreturn match (sh) { Circle c => c.r, Square sq => sq.s * 10, _ => -1 };\n}\nfn main(): i32 {\nlet a: Shape = new Circle(5);\nlet b: Shape = new Square(4);\nlet p: Pt = { x: 3, y: 9 };\nlet d: i64 = match (p) { {x, y} => x + y };\nif (kind(a) == 5 && kind(b) == 40 && d == 12) { return 0; }\nreturn 1;\n}", "c15")).toBe(0);
    });
    test("spawn de método de instância (this na thread)", () => {
        expect(runSrc("class Acc { b: i64; constructor(x: i64){this.b=x} add(n: i64): i64 { return this.b + n; } }\nfn main(): i32 {\nlet w: Acc = new Acc(100);\nreturn join(spawn w.add(23)) - 123;\n}", "c16")).toBe(0);
    });
    test("indexação por [] em Map e JSON (leitura + escrita + encadeado)", () => {
        expect(runSrc("fn main(): i32 {\nlet m: Map<i64> = { \"a\": 1 };\nm[\"b\"] = 41;\nlet j: json = jsonParse(\"{\\\"ns\\\":[7,8,9]}\");\nif (m[\"a\"] + m[\"b\"] == 42 && jsonAsInt(j[\"ns\"][2]) == 9) { return 0; }\nreturn 1;\n}", "c17")).toBe(0);
    });
    test("atribuição composta e ++/--", () => {
        expect(runSrc("fn main(): i32 {\nlet i: i64 = 10;\ni += 5; i *= 2; i--;\nreturn i - 29;\n}", "c18")).toBe(0);
    });
});
