// Testes do lexer-em-lex (Fase 1). Rode com:  lex test selfhost
import { lexSrc, Token, Tok } from "./lexer"

// Compara a sequência de tipos de token elemento a elemento. (Comparar o array
// inteiro de uma vez não dá: o expect só estrutura arrays LITERAIS; um array
// vindo de função vira ponteiro-como-número — ver selfhost/README.md.)
fn expectKinds(got: Token[], want: Tok[]) {
    expect(got.len()).toBe(want.len());
    for (let i: i64 = 0; i < want.len(); i = i + 1) {
        expect(got[i].kind).toBe(want[i]);
    }
}

describe("lexer", () => {
    test("palavras-chave, identificadores e '='", () => {
        const t: Token[] = lexSrc("const x = fn");
        expectKinds(t, [Tok.Const, Tok.Ident, Tok.Eq, Tok.Function, Tok.Eof]);
        expect(t[1].text).toBe("x");
    });

    test("operadores de um e vários chars", () => {
        const t: Token[] = lexSrc("== != <= >= && || << >> ++ -- += -> => ...");
        expectKinds(t, [
            Tok.EqEq, Tok.Neq, Tok.Le, Tok.Ge, Tok.AmpAmp, Tok.PipePipe,
            Tok.Shl, Tok.Shr, Tok.PlusPlus, Tok.MinusMinus, Tok.PlusEq,
            Tok.Arrow, Tok.FatArrow, Tok.DotDotDot, Tok.Eof
        ]);
    });

    test("números int e float", () => {
        const t: Token[] = lexSrc("42 3.14 2e10 7");
        expectKinds(t, [Tok.Int, Tok.Float, Tok.Float, Tok.Int, Tok.Eof]);
        expect(t[0].ival).toBe(42);
        expect(t[0].text).toBe("42");
        expect(t[1].text).toBe("3.14");
        expect(t[1].fval).toBeCloseTo(3.14, 0.0001);   // valor float real (parseFloat)
    });

    test("strings com escapes (\\n e \\t viram bytes de verdade)", () => {
        const t: Token[] = lexSrc("\"ab\\ncd\" \"x\\ty\"");
        expect(t[0].kind).toBe(Tok.Str);
        expect(t[0].text).toBe("ab\ncd");
        expect(t[1].text).toBe("x\ty");
    });

    test("newlines colapsam e comentários // somem", () => {
        const t: Token[] = lexSrc("a\n\n\nb // nota\nc");
        expectKinds(t, [
            Tok.Ident, Tok.Newline, Tok.Ident, Tok.Newline, Tok.Ident, Tok.Eof
        ]);
    });

    test("trecho real de lex", () => {
        const t: Token[] = lexSrc("fn add(a: i64): i64 { return a + 1; }");
        expectKinds(t, [
            Tok.Function, Tok.Ident, Tok.LParen, Tok.Ident, Tok.Colon, Tok.Ident,
            Tok.RParen, Tok.Colon, Tok.Ident, Tok.LBrace, Tok.Return, Tok.Ident,
            Tok.Plus, Tok.Int, Tok.Semicolon, Tok.RBrace, Tok.Eof
        ]);
    });
});
