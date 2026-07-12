// strings.test.lex
describe("strings", () => {
        test("helpers", () => {
                expect("le".toUpper()).toBe("LE");
                expect("lex lang").toContain("lang");
                expect("  oi ".trim()).toBe("oi");
        });
        test("floats e arrays", () => {
                expect(7.0 / 2.0).toBeCloseTo(3.5, 0.0001);
                expect([1, 2, 3]).toBe([1, 2, 3]);
        });
});
