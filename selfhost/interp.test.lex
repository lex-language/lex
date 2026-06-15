// interp.test.lex — o interpretador-em-lex rodando programas SEM clang/LLVM.
// interpret(src) devolve o valor de retorno do main, executando a AST direto.
import { interpret } from "./interp"

describe("interpretador (sem clang)", () => {
    test("recursão + if: fib(10) = 55", () => {
        const src: string = "fn fib(n: i64): i64 { if (n < 2) { return n } return fib(n-1) + fib(n-2) }\nfn main(): i64 { return fib(10) }";
        expect(interpret(src)).toBe(55);
    });

    test("while + let + assign: soma 1..100 = 5050", () => {
        const src: string = "fn main(): i64 {\n  let s: i64 = 0\n  let i: i64 = 1\n  while (i <= 100) {\n    s = s + i\n    i = i + 1\n  }\n  return s\n}";
        expect(interpret(src)).toBe(5050);
    });

    test("aritmética e precedência: 2 + 3 * 4 - 1 = 13", () => {
        expect(interpret("fn main(): i64 { return 2 + 3 * 4 - 1 }")).toBe(13);
    });

    test("bitwise/shift/~: (6 & 3) | (1 << 4) = 18, ~0 & 7 = 7", () => {
        expect(interpret("fn main(): i64 { return (6 & 3) | (1 << 4) }")).toBe(18);
        expect(interpret("fn main(): i64 { return ~0 & 7 }")).toBe(7);
    });

    test("lógicos e else-if", () => {
        expect(interpret("fn main(): i64 { if (2 > 1 && 3 > 2) { return 9 } return 0 }")).toBe(9);
        const cls: string = "fn cls(n: i64): i64 {\n  if (n < 0) { return 0 }\n  else if (n < 5) { return 1 }\n  else { return 2 }\n}\nfn main(): i64 { return cls(7) }";
        expect(interpret(cls)).toBe(2);
    });

    test("break e continue", () => {
        const brk: string = "fn main(): i64 {\n  let i: i64 = 0\n  while (i < 100) {\n    if (i == 5) { break }\n    i = i + 1\n  }\n  return i\n}";
        expect(interpret(brk)).toBe(5);
        const cnt: string = "fn main(): i64 {\n  let s: i64 = 0\n  let i: i64 = 0\n  while (i < 10) {\n    i = i + 1\n    if (i == 5) { continue }\n    s = s + i\n  }\n  return s\n}";
        expect(interpret(cnt)).toBe(50);   // 1+2+3+4+6+7+8+9+10 = 50
    });
});
