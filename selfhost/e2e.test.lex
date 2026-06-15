// e2e.test.lex — prova de ponta a ponta do compilador-em-lex (Fase 5/6).
// Para cada caso: compila o fonte (subset) para LLVM IR, linka com clang e RODA
// o binário nativo, conferindo o exit code. Tudo dirigido pelo próprio lex.
// Requer clang no PATH e /tmp gravável. Rode com:  lex test selfhost
import { compileToIR } from "./codegen"

// fonte (subset) -> exit code do binário nativo produzido (-1 se o clang falhar)
fn compileAndRun(src: string, name: string): i64 {
    const ll: string = concat(concat("/tmp/lex_e2e_", name), ".ll");
    const bin: string = concat("/tmp/lex_e2e_", name);
    writeFile(ll, compileToIR(src));
    const c: i64 = system(concat("clang -Wno-override-module -o ", concat(bin, concat(" ", ll))));
    if (c != 0) { return -1; }
    const status: i64 = system(bin);
    return status / 256;        // WEXITSTATUS: exit code mora nos bits 8..15
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
});
