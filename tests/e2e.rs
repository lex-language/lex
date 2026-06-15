//! Testes ponta-a-ponta: compilam e executam programas .lex de verdade,
//! conferindo o exit code. Cada caso é um `main(): i32` que devolve 0 em
//! sucesso (ou um código != 0 indicando qual verificação falhou).
//!
//! Usa o binário `lex` que o cargo compila (CARGO_BIN_EXE_lex). Como o
//! compilador escreve a runtime num caminho temporário fixo, todos os casos
//! rodam numa ÚNICA função de teste, em sequência — sem corrida de I/O.

use std::path::PathBuf;
use std::process::Command;

const LEX: &str = env!("CARGO_BIN_EXE_lex");

/// Compila `code` para um binário temporário e o executa; devolve o exit code.
fn compile_and_run(code: &str, idx: usize) -> i32 {
    let dir = std::env::temp_dir();
    let lex_file: PathBuf = dir.join(format!("lex_e2e_{}.lex", idx));
    let bin: PathBuf = dir.join(format!("lex_e2e_{}.bin", idx));
    std::fs::write(&lex_file, code).expect("write .lex");

    let out = Command::new(LEX)
        .arg(&lex_file)
        .arg("-o")
        .arg(&bin)
        .output()
        .expect("invoke lex");
    assert!(
        out.status.success(),
        "compilation failed for case {}:\n{}\n--- stderr ---\n{}",
        idx,
        code,
        String::from_utf8_lossy(&out.stderr)
    );

    let run = Command::new(&bin).status().expect("run binary");
    let _ = std::fs::remove_file(&lex_file);
    let _ = std::fs::remove_file(&bin);
    run.code().unwrap_or(-1)
}

#[test]
fn programs_run_end_to_end() {
    // cada caso retorna 0 quando todas as verificações passam
    let cases: &[(&str, &str)] = &[
        (
            "operadores e precedência",
            "fn main(): i32 {
                if (2 + 3 * 4 == 14 && 17 % 5 == 2 && (6 & 3) == 2 && (1 << 4) == 16) { return 0; }
                return 1;
            }",
        ),
        (
            "for + break + continue",
            "fn main(): i32 {
                let s: i64 = 0;
                for (let i: i64 = 0; i < 100; i++) {
                    if (i % 2 == 1) { continue; }
                    if (i > 8) { break; }
                    s += i;
                }
                return s - 20;
            }",
        ),
        (
            "for...of sobre array",
            "fn main(): i32 {
                let t: i64 = 0;
                for (const v of [10, 20, 30]) { t += v; }
                return t - 60;
            }",
        ),
        (
            "match expressão + guarda + faixa",
            "fn main(): i32 {
                let r: i64 = match (7) { 0..5 => 1, x if x > 5 => 2, _ => 3 };
                return r - 2;
            }",
        ),
        (
            "floats (f64) e math",
            "fn main(): i32 {
                let a: f64 = 7.0;
                let b: f64 = 2.0;
                let raiz: i64 = round(sqrt(9.0));
                if (a / b == 3.5 && raiz == 3) { return 0; }
                return 1;
            }",
        ),
        (
            "f32 distinto",
            "fn main(): i32 {
                let x: f32 = 0.5;
                if (x + x == 1.0) { return 0; }
                return 1;
            }",
        ),
        (
            "genéricos: função e classe (tipo concreto preservado)",
            "class Box<T> { v: T; constructor(x: T){this.v=x} get(): T { return this.v } }
             fn first<T>(xs: T[]): T { return xs[0]; }
             fn main(): i32 {
                let b: Box<i64> = new Box<i64>(42);
                let xs: i64[] = [10, 20];
                if (b.get() == 42 && first(xs) == 10) { return 0; }
                return 1;
             }",
        ),
        (
            "genérico com float através de T",
            "class Box<T> { v: T; constructor(x: T){this.v=x} get(): T { return this.v } }
             fn main(): i32 {
                let b: Box<f64> = new Box<f64>(3.5);
                if (b.get() == 3.5) { return 0; }
                return 1;
             }",
        ),
        (
            "erros: try/catch",
            "fn d(a: i64, b: i64): i64! { if (b == 0) { fail 1; } return a / b; }
             fn main(): i32 {
                let x: i64 = d(10, 0) catch 99;
                return x - 99;
             }",
        ),
        (
            "OOP: herança + polimorfismo (vtable)",
            "class A { f(): i64 { return 1; } }
             class B extends A { f(): i64 { return 2; } }
             fn main(): i32 {
                let a: A = new B();
                return a.f() - 2;
             }",
        ),
        (
            "async/await (threads reais, sem runtime)",
            "async fn sq(n: i64): i64 { return n * n; }
             fn main(): i32 {
                let a: Future<i64> = sq(6);
                let b: Future<i64> = sq(7);
                return (await a + await b) - 85;
             }",
        ),
        (
            "campos static: contador compartilhado + init não-const + herança",
            "class Counter {
                static count: i64 = 0;
                static base: i64 = 10 * 4 + 2;
                constructor(){ Counter.count = Counter.count + 1; }
             }
             class Sub extends Counter { constructor(){ super(); } }
             fn main(): i32 {
                let a: Counter = new Counter();
                let b: Sub = new Sub();
                Counter.count = Counter.count + 10;
                if (Counter.count == 12 && Counter.base == 42 && Sub.count == 12) { return 0; }
                return 1;
             }",
        ),
        (
            "arrow: tipo de retorno inferido do contexto (float sem anotação)",
            "fn callF(f: () => f64): f64 { return f(); }
             fn applyF(f: (f64) => f64, x: f64): f64 { return f(x); }
             fn main(): i32 {
                let h: () => f64 = () => 2.5 * 2.0;
                let dobro: (f64) => f64 = (x: f64) => x * 2.0;
                if (callF(h) == 5.0 && applyF(dobro, 3.0) == 6.0) { return 0; }
                return 1;
             }",
        ),
        (
            "closures com captura (por valor): simples, this e aninhada",
            "fn run(f: (i64) => i64, x: i64): i64 { return f(x); }
             fn run0(f: () => i64): i64 { return f(); }
             fn makeAdder(a: i64): (i64) => i64 { return (b: i64) => a + b; }
             class Box { v: i64; constructor(x: i64){this.v=x} getter(): () => i64 { return () => this.v; } }
             fn main(): i32 {
                let m: i64 = 10;
                let add: (i64) => i64 = (x: i64) => x + m;
                let add10: (i64) => i64 = makeAdder(10);
                let g: () => i64 = new Box(42).getter();
                m = 99;                               // captura por valor: não afeta 'add'
                if (run(add, 5) == 15 && run(add10, 7) == 17 && run0(g) == 42) { return 0; }
                return 1;
             }",
        ),
        (
            "enum: valor, comparação e match de variante",
            "enum Color { Red, Green, Blue }
             fn rank(c: Color): i64 { return match (c) { Color.Red => 1, Color.Green => 2, _ => 3 }; }
             fn main(): i32 {
                let c: Color = Color.Blue;
                if (Color.Green == 1 && rank(Color.Red) == 1 && rank(c) == 3 && c == 2) { return 0; }
                return 1;
             }",
        ),
        (
            "match sobre tipos (vtable) + destructuring de struct",
            "class Shape { area(): i64 { return 0; } }
             class Circle extends Shape { r: i64; constructor(x: i64){this.r=x} }
             class Square extends Shape { s: i64; constructor(x: i64){this.s=x} }
             type Pt = { x: i64, y: i64 };
             fn kind(sh: Shape): i64 {
                return match (sh) { Circle c => c.r, Square sq => sq.s * 10, _ => -1 };
             }
             fn main(): i32 {
                let a: Shape = new Circle(5);
                let b: Shape = new Square(4);
                let p: Pt = { x: 3, y: 9 };
                let d: i64 = match (p) { {x, y} => x + y };
                if (kind(a) == 5 && kind(b) == 40 && d == 12) { return 0; }
                return 1;
             }",
        ),
        (
            "spawn de método de instância (this na thread)",
            "class Acc { b: i64; constructor(x: i64){this.b=x} add(n: i64): i64 { return this.b + n; } }
             fn main(): i32 {
                let w: Acc = new Acc(100);
                return join(spawn w.add(23)) - 123;
             }",
        ),
        (
            "indexação por [] em Map e JSON (leitura + escrita + encadeado)",
            "fn main(): i32 {
                let m: Map<i64> = { \"a\": 1 };
                m[\"b\"] = 41;
                let j: json = jsonParse(\"{\\\"ns\\\":[7,8,9]}\");
                if (m[\"a\"] + m[\"b\"] == 42 && jsonAsInt(j[\"ns\"][2]) == 9) { return 0; }
                return 1;
             }",
        ),
        (
            "atribuição composta e ++/--",
            "fn main(): i32 {
                let i: i64 = 10;
                i += 5; i *= 2; i--;
                return i - 29;
             }",
        ),
        (
            "biblioteca de testes nativa — classe Test (std/test.lex)",
            "import { Test } from \"test\";
             fn main(): i32 {
                let t: Test = new Test();
                t.eq(\"soma\", 2 + 2, 4);
                t.ok(\"bool\", 1 < 2);
                t.eqStr(\"upper\", \"le\".toUpper(), \"LE\");
                t.near(\"float\", 7.0 / 2.0, 3.5, 0.0001);
                return t.done();
             }",
        ),
        (
            "biblioteca de testes nativa — estilo BDD (describe/test/expect)",
            "import { describe, test, expect, testReport } from \"test\";
             fn dobro(x: i64): i64 { return x * 2; }
             fn main(): i32 {
                describe(\"grupo\", () => {
                    test(\"inteiros\", () => {
                        expect(dobro(21)).toBe(42);
                        expect(10).toBeGreaterThan(5);
                        expect(0).toBeFalsy();
                    });
                    test(\"strings e floats (mesmo expect)\", () => {
                        expect(\"le\".toUpper()).toBe(\"LE\");
                        expect(\"lex lang\").toContain(\"lang\");
                        expect(7.0 / 2.0).toBeCloseTo(3.5, 0.0001);
                    });
                });
                return testReport();
             }",
        ),
    ];

    for (idx, (name, code)) in cases.iter().enumerate() {
        let exit = compile_and_run(code, idx);
        assert_eq!(exit, 0, "caso '{}' retornou {} (esperava 0)", name, exit);
    }

    // --- modo teste: arquivos .test.lex SEM main (describe/test/expect no topo)
    // o compilador injeta a lib e encerra com return testReport().
    let dir = std::env::temp_dir();
    let tfile = dir.join("lex_e2e_mode.test.lex");
    let tbin = dir.join("lex_e2e_mode.testbin");

    let compile_run_test = |src: &str| -> i32 {
        std::fs::write(&tfile, src).expect("write .test.lex");
        let out = Command::new(LEX)
            .arg(&tfile)
            .arg("-o")
            .arg(&tbin)
            .output()
            .expect("invoke lex");
        assert!(
            out.status.success(),
            ".test.lex compile failed:\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let run = Command::new(&tbin).status().expect("run testbin");
        run.code().unwrap_or(-1)
    };

    // todos os asserts passam → exit 0
    assert_eq!(
        compile_run_test(
            "describe(\"g\", () => { test(\"t\", () => { \
             expect(2 + 2).toBe(4); expect(\"x\".toUpper()).toBe(\"X\"); }); });"
        ),
        0,
        ".test.lex que passa deveria sair com 0"
    );
    // um assert falha → exit 1 (sem main, sem testReport explícito)
    assert_eq!(
        compile_run_test("test(\"falha\", () => { expect(1).toBe(2); });"),
        1,
        ".test.lex que falha deveria sair com 1"
    );

    let _ = std::fs::remove_file(&tfile);
    let _ = std::fs::remove_file(&tbin);
}

/// A CLI responde a `help`/`version` e dá erro claro (exit != 0) para
/// comandos/flags desconhecidos, em vez de tratá-los como arquivo de entrada.
/// Não compila nada → não toca a runtime temporária, pode ser teste à parte.
#[test]
fn cli_help_version_and_errors() {
    // `lex` sem argumentos e `lex help` mostram a ajuda e saem com 0
    for args in [&[][..], &["help"], &["-h"], &["--help"]] {
        let out = Command::new(LEX).args(args).output().expect("invoke lex");
        assert!(out.status.success(), "`lex {:?}` deveria sair com 0", args);
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains("USAGE:"), "ajuda deveria listar USAGE");
        assert!(stdout.contains("COMMANDS:"), "ajuda deveria listar COMMANDS");
    }

    // versão: imprime "lex <versão>" e sai com 0
    for flag in ["version", "-v", "--version"] {
        let out = Command::new(LEX).arg(flag).output().expect("invoke lex");
        assert!(out.status.success(), "`lex {}` deveria sair com 0", flag);
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.starts_with("lex "), "`lex {}` deveria imprimir a versão", flag);
    }

    // comando inexistente → erro claro, exit != 0 (não "could not read")
    let out = Command::new(LEX).arg("foobar").output().expect("invoke lex");
    assert!(!out.status.success(), "comando inexistente deveria falhar");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("not a known command"), "erro deveria ser amigável: {}", stderr);

    // flag desconhecida → erro claro, exit != 0
    let out = Command::new(LEX).arg("--nope").output().expect("invoke lex");
    assert!(!out.status.success(), "flag desconhecida deveria falhar");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unknown option"), "erro deveria citar a opção: {}", stderr);

    // help por comando: `lex help <cmd>` e `lex <cmd> --help` mostram o mesmo
    // help focado (e NÃO executam o comando), saindo com 0.
    for cmd in ["test", "fmt", "check", "lsp", "add", "install", "registry"] {
        for invocation in [vec!["help", cmd], vec![cmd, "--help"], vec![cmd, "-h"]] {
            let out = Command::new(LEX).args(&invocation).output().expect("invoke lex");
            assert!(out.status.success(), "`lex {:?}` deveria sair com 0", invocation);
            let stdout = String::from_utf8_lossy(&out.stdout);
            assert!(
                stdout.contains(&format!("lex {}", cmd)),
                "help de `{}` deveria descrever o comando, veio: {}",
                cmd,
                stdout
            );
        }
    }
}
