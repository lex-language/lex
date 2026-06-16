// Testes do renderizador de diagnósticos (F6.11). Rode com:  lex test selfhost
// Caminho sem-cor (determinístico), igual ao não-TTY do src/diag.rs.
import { renderDiag } from "./diag"

describe("diag: render estilo rustc", () => {
        test("erro numa linha, caret sob o token", () => {
                expect(renderDiag("test.lex", "x = 1 +", 6, 7, "token inesperado", ""))
                .toBe("error: token inesperado\n --> test.lex:1:7\n  |\n1 | x = 1 +\n  |       ^\n");
        });

        test("com dica (help)", () => {
                expect(renderDiag("test.lex", "x = 1 +", 6, 7, "token inesperado", "use ;"))
                .toBe("error: token inesperado\n --> test.lex:1:7\n  |\n1 | x = 1 +\n  |       ^\n  |\n  = help: use ;\n");
        });

        test("erro na 2ª linha, span de 2 chars", () => {
                expect(renderDiag("f.lex", "aa\nbbbb\n", 3, 5, "erro aqui", ""))
                .toBe("error: erro aqui\n --> f.lex:2:1\n  |\n2 | bbbb\n  | ^^\n");
        });
});
