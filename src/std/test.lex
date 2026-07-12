// std/test.lex — biblioteca de testes nativa do lex, escrita em lex.
//
// Os testes são escritos na própria linguagem: você cria um `Test`, faz as
// asserções e devolve `t.done()` como exit code do `main`. Cada asserção sai
// colorida no terminal (verde = passou, vermelho = falhou) via `Terminal`, e o
// processo sai com 0 só se TODAS passarem — pronto para CI.
//
//   import { Test } from "test";
//
//   fn dobro(x: i64): i64 { return x * 2; }
//
//   fn main(): i32 {
//       const t: Test = new Test();
//       t.eq("dobro de 21", dobro(21), 42);
//       t.ok("string começa com", "lex".startsWith("le"));
//       t.eqStr("maiúsculas", "le".toUpper(), "LE");
//       t.near("pi/2", 3.14159 / 2.0, 1.5708, 0.001);
//       return t.done();   // 0 se tudo passou, 1 se algo falhou
//   }
//
// Métodos de asserção (o 1º argumento é sempre o NOME do caso):
//   ok(nome, cond)            cond deve ser verdadeira
//   notOk(nome, cond)         cond deve ser falsa
//   eq(nome, obtido, esperado)        inteiros iguais
//   neq(nome, obtido, naoEsperado)    inteiros diferentes
//   eqStr(nome, obtido, esperado)     strings com o MESMO conteúdo (strEq)
//   near(nome, obtido, esperado, eps) floats dentro da tolerância eps
//   done(): i32               imprime o resumo e devolve o exit code

class Test {
    private passed: i64
    private failed: i64

    constructor() {
        this.passed = 0
        this.failed = 0
    }

    // contabiliza um sucesso e imprime em verde
    private win(name: string) {
        this.passed = this.passed + 1
        Terminal.success(name)
    }

    // cond deve ser verdadeira
    ok(name: string, cond: bool) {
        if (cond) {
            this.win(name)
        } else {
            this.failed = this.failed + 1
            Terminal.error(name, "— esperava verdadeiro")
        }
    }

    // cond deve ser falsa
    notOk(name: string, cond: bool) {
        if (cond) {
            this.failed = this.failed + 1
            Terminal.error(name, "— esperava falso")
        } else {
            this.win(name)
        }
    }

    // inteiros iguais (o Terminal converte os números para texto)
    eq(name: string, got: i64, want: i64) {
        if (got == want) {
            this.win(name)
        } else {
            this.failed = this.failed + 1
            Terminal.error(name, "— esperava", want, "mas obteve", got)
        }
    }

    // inteiros diferentes
    neq(name: string, got: i64, notWant: i64) {
        if (got != notWant) {
            this.win(name)
        } else {
            this.failed = this.failed + 1
            Terminal.error(name, "— não devia ser", notWant)
        }
    }

    // strings com o mesmo conteúdo (== compara endereço; aqui usamos strEq)
    eqStr(name: string, got: string, want: string) {
        if (strEq(got, want)) {
            this.win(name)
        } else {
            this.failed = this.failed + 1
            Terminal.error(name, "— esperava", want, "mas obteve", got)
        }
    }

    // floats: |obtido - esperado| <= eps
    near(name: string, got: f64, want: f64, eps: f64) {
        if (fabs(got - want) <= eps) {
            this.win(name)
        } else {
            this.failed = this.failed + 1
            Terminal.error(name, "— esperava ~", want, "mas obteve", got)
        }
    }

    // quantos testes falharam até agora (0 = tudo bem)
    failures(): i64 {
        return this.failed
    }

    // imprime o resumo e devolve o exit code: 0 se tudo passou, senão 1
    done(): i32 {
        const total: i64 = this.passed + this.failed
        if (this.failed == 0) {
            Terminal.success("todos os", total, "testes passaram")
            return 0
        }
        Terminal.error(this.failed, "de", total, "testes falharam")
        return 1
    }
}

// ===========================================================================
// Estilo BDD (Jest/Mocha): describe / test / it / expect(...).toBe(...)
// ===========================================================================
//
// As funções são LIVRES (não precisam de um objeto), no estilo do Jest:
//
//   import { describe, test, expect, testReport } from "test";
//
//   fn dobro(x: i64): i64 { return x * 2; }
//
//   fn main(): i32 {
//       describe("matemática", () => {
//           test("dobro", () => {
//               expect(dobro(21)).toBe(42);
//               expect(dobro(0)).toBe(0);
//           });
//           it("é par", () => {
//               expect(dobro(3) % 2).toBe(0);
//           });
//       });
//       return testReport();   // resumo + exit code (0 = tudo passou)
//   }
//
// Como `expect` é uma função livre, o placar (passou/falhou) vive em SLOTS
// GLOBAIS da runtime (lex não tem estado de módulo) — slot 0 = passaram,
// slot 1 = falharam. Os corpos de `describe`/`test` são arrow functions sem
// captura: podem chamar funções globais (expect, outras funções), mas NÃO
// enxergam variáveis locais de fora (use funções para os dados do teste).

// contadores no placar global (silenciosos no sucesso)
fn lexTestPass() {
    gset(0, gget(0) + 1)
}
fn lexTestFail() {
    gset(1, gget(1) + 1)
}

// agrupa testes — imprime o título do grupo e roda o corpo
fn describe(name: string, body: () => i64): i64 {
    Terminal.info(name)
    body()
    return 0
}

// um caso de teste — imprime o nome e roda o corpo (que faz os expects)
fn test(name: string, body: () => i64): i64 {
    Terminal.log("  •", name)
    body()
    return 0
}

// alias de `test`, ao gosto do Jest
fn it(name: string, body: () => i64): i64 {
    return test(name, body)
}

// expect UNIFICADO: aceita qualquer tipo (int/bool/float/string/array/json).
// O valor é embrulhado em `any` (que carrega a tag de tipo), então o mesmo
// `expect(x).toBe(y)` compara corretamente números, strings (conteúdo), floats
// e até coleções — sem precisar de variantes por tipo.
fn expect(actual: any): Expect {
    return new Expect(actual)
}

// resumo final do BDD: imprime o placar, zera-o e devolve o exit code
fn testReport(): i32 {
    const passed: i64 = gget(0)
    const failed: i64 = gget(1)
    const total: i64 = passed + failed
    gset(0, 0)
    gset(1, 0)
    if (failed == 0) {
        Terminal.success("todas as", total, "asserções passaram")
        return 0
    }
    Terminal.error(failed, "de", total, "asserções falharam")
    return 1
}

// Uma expectativa encadeável. Guarda o valor como `any` (com a tag de tipo),
// e os matchers comparam por valor — o mesmo `expect` serve para tudo.
class Expect {
    private actual: any
    constructor(a: any) {
        this.actual = a
    }

    // igualdade por valor (números, strings por conteúdo, floats, coleções)
    toBe(want: any) {
        if (jsonEq(this.actual, want)) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava", want, "mas obteve", this.actual)
        }
    }
    toEqual(want: any) {
        this.toBe(want)
    }
    notToBe(want: any) {
        if (jsonEq(this.actual, want)) {
            lexTestFail()
            Terminal.error("    não devia ser", want)
        } else {
            lexTestPass()
        }
    }

    // verdade/falsidade (números e booleanos)
    toBeTruthy() {
        if (jsonAsInt(this.actual) != 0) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava verdadeiro, obteve", this.actual)
        }
    }
    toBeFalsy() {
        if (jsonAsInt(this.actual) == 0) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava falso, obteve", this.actual)
        }
    }

    // comparações numéricas
    toBeGreaterThan(n: i64) {
        if (jsonAsInt(this.actual) > n) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava >", n, "obteve", this.actual)
        }
    }
    toBeLessThan(n: i64) {
        if (jsonAsInt(this.actual) < n) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava <", n, "obteve", this.actual)
        }
    }

    // floats com tolerância: |obtido - esperado| <= eps
    toBeCloseTo(want: f64, eps: f64) {
        if (fabs(jsonAsFloat(this.actual) - want) <= eps) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava ~", want, "mas obteve", this.actual)
        }
    }

    // substring (para valores string)
    toContain(part: string) {
        if (contains(jsonAsStr(this.actual), part)) {
            lexTestPass()
        } else {
            lexTestFail()
            Terminal.error("    esperava conter", part, "em", this.actual)
        }
    }
}
