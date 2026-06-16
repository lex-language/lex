// e2e.test.lex — prova de ponta a ponta do compilador-em-lex (Fase 5/6).
// Para cada caso: compila o fonte (subset) para LLVM IR, linka com clang e RODA
// o binário nativo, conferindo o exit code. Tudo dirigido pelo próprio lex.
// Requer clang no PATH e /tmp gravável. Rode com:  lex test selfhost
import { compileToIR } from "./codegen"
import { compileFileToIR } from "./modloader"

// fonte (subset) -> exit code do binário nativo produzido (-1 se o clang falhar).
// Linka o runtime C (src/runtime.c) p/ resolver os __lex_* (strings/arrays/etc.);
// roda da raiz do repo (onde `lex test selfhost` é chamado).
fn compileAndRun(src: string, name: string): i64 {
    const ll: string = concat(concat("/tmp/lex_e2e_", name), ".ll");
    const bin: string = concat("/tmp/lex_e2e_", name);
    writeFile(ll, compileToIR(src));
    const cmd: string = `clang -Wno-override-module -o ${bin} ${ll} src/runtime.c -lpthread`;
    const c: i64 = system(cmd);
    if (c != 0) { return -1; }
    const status: i64 = system(bin);
    return status / 256;        // WEXITSTATUS: exit code mora nos bits 8..15
}

// arquivo de entrada (com imports) -> exit code do binário nativo.
fn compileFileAndRun(entry: string, name: string): i64 {
    const ll: string = concat(concat("/tmp/lex_e2e_", name), ".ll");
    const bin: string = concat("/tmp/lex_e2e_", name);
    writeFile(ll, compileFileToIR(entry));
    const cmd: string = `clang -Wno-override-module -o ${bin} ${ll} src/runtime.c -lpthread`;
    if (system(cmd) != 0) { return -1; }
    return system(bin) / 256;
}

// roda o binário capturando o stdout numa string (via arquivo temporário).
fn compileRunOut(src: string, name: string): string {
    const ll: string = concat(concat("/tmp/lex_e2e_", name), ".ll");
    const bin: string = concat("/tmp/lex_e2e_", name);
    const outf: string = concat("/tmp/lex_e2e_", concat(name, ".out"));
    writeFile(ll, compileToIR(src));
    const cmd: string = `clang -Wno-override-module -o ${bin} ${ll} src/runtime.c -lpthread`;
    if (system(cmd) != 0) { return "<clang falhou>"; }
    system(`${bin} > ${outf}`);
    return readFile(outf);
}

describe("end-to-end: lex -> LLVM IR -> binário nativo -> roda", () => {
        test("recursão + if: fib(10) = 55", () => {
                const src: string = "fn fib(n: i64): i64 {\n  if (n < 2) { return n }\n  return fib(n - 1) + fib(n - 2)\n}\nfn main(): i32 { return fib(10) }";
                expect(compileAndRun(src, "fib")).toBe(55);
        });

        test("while + let + assign: soma 1..10 = 55", () => {
                const src: string = "fn main(): i32 {\n  let s: i64 = 0\n  let i: i64 = 1\n  while (i <= 10) {\n    s = s + i\n    i = i + 1\n  }\n  return s\n}";
                expect(compileAndRun(src, "loop")).toBe(55);
        });

        test("aritmética com precedência: 6*7 - 2 = 40", () => {
                const src: string = "fn main(): i32 { return 6 * 7 - 2 }";
                expect(compileAndRun(src, "arith")).toBe(40);
        });

        test("else-if encadeado: classifica 7 -> 2", () => {
                const src: string = "fn cls(n: i64): i64 {\n  if (n < 0) { return 0 }\n  else if (n < 5) { return 1 }\n  else { return 2 }\n}\nfn main(): i32 { return cls(7) }";
                expect(compileAndRun(src, "cls")).toBe(2);
        });

        test("bitwise e shift: (6 & 3) | (1 << 4) = 18", () => {
                const src: string = "fn main(): i32 { return (6 & 3) | (1 << 4) }";
                expect(compileAndRun(src, "bits")).toBe(18);
        });

        test("lógicos em condição: 2>1 && 3>2 -> 9", () => {
                const src: string = "fn main(): i32 { if (2 > 1 && 3 > 2) { return 9 } return 0 }";
                expect(compileAndRun(src, "logic")).toBe(9);
        });

        test("~ e máscara: ~0 & 7 = 7", () => {
                const src: string = "fn main(): i32 { return ~0 & 7 }";
                expect(compileAndRun(src, "bnot")).toBe(7);
        });

        test("strings: concat + Terminal.log imprime de verdade", () => {
                const src: string = "fn main(): i32 {\n  let a: string = \"hello\"\n  let b: string = concat(a, \" world\")\n  Terminal.log(b)\n  return 0\n}";
                expect(compileRunOut(src, "str")).toBe("hello world\n");
        });

        test("strings: strEq decide o exit code", () => {
                const src: string = "fn main(): i32 {\n  if (strEq(\"ab\", \"ab\")) { return 7 }\n  return 0\n}";
                expect(compileAndRun(src, "streq")).toBe(7);
        });

        test("str(i64) + len: tamanho de \"123\" = 3", () => {
                const src: string = "fn main(): i32 {\n  let s: string = str(123)\n  return len(s)\n}";
                expect(compileAndRun(src, "strlen")).toBe(3);
        });

        test("Terminal.log de inteiro", () => {
                const src: string = "fn main(): i32 { Terminal.log(42) return 0 }";
                expect(compileRunOut(src, "logint")).toBe("42\n");
        });

        test("array: push + index + len somam 1..4 = 10", () => {
                const src: string = "fn main(): i32 {\n  let xs: i64[] = []\n  let i: i64 = 1\n  while (i <= 4) { xs.push(i) i = i + 1 }\n  let s: i64 = 0\n  let j: i64 = 0\n  while (j < xs.len()) { s = s + xs[j] j = j + 1 }\n  return s\n}";
                expect(compileAndRun(src, "arr")).toBe(10);
        });

        test("array: índice de literal e atribuição", () => {
                const src: string = "fn main(): i32 {\n  let xs: i64[] = [10, 20, 30]\n  xs[1] = 5\n  return xs[0] + xs[1] + xs[2]\n}";
                expect(compileAndRun(src, "arrset")).toBe(45);
        });

        test("Map: set + get por chave string", () => {
                const src: string = "fn main(): i32 {\n  let m: Map<i64> = {}\n  m[\"a\"] = 7\n  m[\"b\"] = 13\n  return m[\"a\"] + m[\"b\"]\n}";
                expect(compileAndRun(src, "map")).toBe(20);
        });

        test("template: interpolação de string e inteiro", () => {
                const src: string = "fn main(): i32 {\n  let n: i64 = 3\n  let who: string = \"lex\"\n  Terminal.log(`${who} tem ${n} letras`)\n  return 0\n}";
                expect(compileRunOut(src, "tpl")).toBe("lex tem 3 letras\n");
        });

        test("f64: literal compila e roda (bits via bitcast)", () => {
                const src: string = "fn main(): i32 {\n  let x: f64 = 0.0\n  let y: f64 = 2.5\n  return 0\n}";
                expect(compileAndRun(src, "flt")).toBe(0);
        });

        test("classe: constructor + campo + método (dispatch estático)", () => {
                const src: string = "class Pt {\n  x: i64\n  y: i64\n  constructor(x: i64, y: i64) { this.x = x  this.y = y }\n  sum(): i64 { return this.x + this.y }\n}\nfn main(): i32 {\n  let p: Pt = new Pt(3, 4)\n  return p.sum()\n}";
                expect(compileAndRun(src, "cls")).toBe(7);
        });

        test("classe com string: campo + método imprime", () => {
                const src: string = "class Person {\n  name: string\n  constructor(name: string) { this.name = name }\n  greet(): string { return concat(\"hi \", this.name) }\n}\nfn main(): i32 {\n  let p: Person = new Person(\"lex\")\n  Terminal.log(p.greet())\n  return 0\n}";
                expect(compileRunOut(src, "person")).toBe("hi lex\n");
        });

        test("match por tipo: herança + tag no slot 0 (Pair -> 42)", () => {
                const src: string = "class Node {}\nclass Leaf extends Node {\n  v: i64\n  constructor(v: i64) { this.v = v }\n}\nclass Pair extends Node {\n  a: i64\n  b: i64\n  constructor(a: i64, b: i64) { this.a = a  this.b = b }\n}\nfn ev(n: Node): i64 {\n  return match (n) {\n    Leaf l => l.v,\n    Pair p => p.a + p.b,\n    _ => 0\n  }\n}\nfn main(): i32 {\n  let x: Node = new Pair(20, 22)\n  return ev(x)\n}";
                expect(compileAndRun(src, "match")).toBe(42);
        });

        test("for-of soma os elementos do array (10+20+30=60)", () => {
                const src: string = "fn main(): i32 {\n  let xs: i64[] = [10, 20, 30]\n  let s: i64 = 0\n  for (const x of xs) { s = s + x }\n  return s\n}";
                expect(compileAndRun(src, "forof")).toBe(60);
        });

        test("for C-style com continue (soma ímpares 1..9 = 25)", () => {
                const src: string = "fn main(): i32 {\n  let s: i64 = 0\n  for (let i: i64 = 1; i <= 9; i = i + 1) {\n    if (i % 2 == 0) { continue }\n    s = s + i\n  }\n  return s\n}";
                expect(compileAndRun(src, "forc")).toBe(25);
        });

        test("módulos: import de classe entre arquivos compila e roda", () => {
                writeFile("/tmp/lex_mod_lib.lex", "class Box {\n  v: i64\n  constructor(v: i64) { this.v = v }\n  get(): i64 { return this.v }\n}");
                writeFile("/tmp/lex_mod_main.lex", "import { Box } from \"./lex_mod_lib\"\nfn main(): i32 {\n  let b: Box = new Box(9)\n  return b.get()\n}");
                expect(compileFileAndRun("/tmp/lex_mod_main.lex", "mod")).toBe(9);
        });

        test("arrow: passa arrow e chama indireto (apply(() => 42))", () => {
                const src: string = "fn apply(f: () => i64): i64 { return f() }\nfn main(): i32 { return apply(() => 42) }";
                expect(compileAndRun(src, "arrow0")).toBe(42);
        });

        test("arrow com parâmetro: applyTo((n) => n*2, 21) = 42", () => {
                const src: string = "fn applyTo(f: (i64) => i64, x: i64): i64 { return f(x) }\nfn main(): i32 { return applyTo((n: i64) => n * 2, 21) }";
                expect(compileAndRun(src, "arrow1")).toBe(42);
        });

        test("any/boxing: jsonEq compara por valor (int + string)", () => {
                const src: string = "fn check(a: any, b: any): i64 { if (jsonEq(a, b)) { return 1 } return 0 }\nfn main(): i32 { return check(42, 42) * 100 + check(1, 2) * 10 + check(\"x\", \"x\") }";
                expect(compileAndRun(src, "anybox")).toBe(101);
        });

        test("any em campo+método de classe (padrão do expect/toBe)", () => {
                const src: string = "class Box2 {\n  v: any\n  constructor(a: any) { this.v = a }\n  same(w: any): i64 { if (jsonEq(this.v, w)) { return 1 } return 0 }\n}\nfn main(): i32 {\n  let b: Box2 = new Box2(7)\n  return b.same(7) * 10 + b.same(8)\n}";
                expect(compileAndRun(src, "anyfield")).toBe(10);
        });
});
