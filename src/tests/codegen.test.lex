// Testes do codegen-em-lex (Fase 5). Rode com:  lex test tests/
// Confere fragmentos do LLVM IR gerado (contains devolve i64 0/1).
import { compileToIR } from "../compiler/codegen"

describe("codegen LLVM IR", () => {
        test("função aritmética", () => {
                const ir: string = compileToIR("fn add(a: i64, b: i64): i64 { return a + b }");
                expect(ir.contains("define i64 @add(i64 %a, i64 %b)")).toBe(1);
                expect(ir.contains("add i64")).toBe(1);
                expect(ir.contains("ret i64")).toBe(1);
        });

        test("main sai como i32 (exit code)", () => {
                const ir: string = compileToIR("fn main(): i32 { return 42 }");
                expect(ir.contains("define i32 @main()")).toBe(1);
                expect(ir.contains("trunc i64 42 to i32")).toBe(1);
                expect(ir.contains("ret i32")).toBe(1);
        });

        test("comparações e branches (if)", () => {
                const ir: string = compileToIR("fn f(n: i64): i64 { if (n > 0) { return 1 } return 0 }");
                expect(ir.contains("icmp sgt i64")).toBe(1);
                expect(ir.contains("br i1")).toBe(1);
        });

        test("while gera o laço", () => {
                const ir: string = compileToIR("fn loop(n: i64): i64 { let i: i64 = 0 while (i < n) { i = i + 1 } return i }");
                expect(ir.contains("icmp slt i64")).toBe(1);
                expect(ir.contains("br label")).toBe(1);
                expect(ir.contains("alloca i64")).toBe(1);
        });

        test("chamada de função", () => {
                const ir: string = compileToIR("fn main(): i32 { return sq(7) }");
                expect(ir.contains("call i64 @sq(i64 7)")).toBe(1);
        });

        test("bitwise, shift e ~", () => {
                const ir: string = compileToIR("fn main(): i32 { return (6 & 3) | (1 << 4) ^ ~0 }");
                expect(ir.contains("and i64")).toBe(1);
                expect(ir.contains("or i64")).toBe(1);
                expect(ir.contains("shl i64")).toBe(1);
                expect(ir.contains("xor i64")).toBe(1);
        });

        test("print emite printf da libc", () => {
                const ir: string = compileToIR("fn main(): i32 { print(42) return 0 }");
                expect(ir.contains("declare i32 @printf(ptr, ...)")).toBe(1);
                expect(ir.contains("call i32 (ptr, ...) @printf(ptr @.lex_fmt_int, i64 42)")).toBe(1);
        });
});
