// math.test.lex — sem function main; o runner injeta tudo.
fn dobro(x: i64): i64 { return x * 2; }
fn somar(xs: i64[]): i64 {
    let t: i64 = 0;
    for (const v of xs) { t += v; }
    return t;
}

describe("aritmética", () => {
    test("dobro", () => {
        expect(dobro(21)).toBe(42);
        expect(dobro(0)).toBe(0);
    });
    test("soma de lista", () => {
        expect(somar([1, 2, 3, 4])).toBe(10);
    });
    it("comparações", () => {
        expect(10).toBeGreaterThan(5);
        expect(3).toBeLessThan(8);
    });
});
