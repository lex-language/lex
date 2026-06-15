//! Testes unitários do front-end: lexer, parser e sema.
//!
//! Não exercitam o codegen (que precisa do LLVM em runtime e do linker) — a
//! execução ponta-a-ponta dos programas fica em `tests/e2e.rs`. Aqui validamos
//! tokenização, parsing e as regras semânticas (o que o lex aceita e recusa).
#![cfg(test)]

use crate::ast::*;
use crate::diag::Source;
use crate::token::Token;
use crate::{lexer, parser, sema};

fn lex_tokens(code: &str) -> Vec<Token> {
    let src = Source::new("test", code);
    lexer::lex(&src).tokens
}

fn parse_program(code: &str) -> Program {
    let src = Source::new("test", code);
    parser::parse(lexer::lex(&src), 0, &src)
}

fn check_ok(code: &str) -> bool {
    let mut p = parse_program(code);
    sema::check(&mut p).is_ok()
}

fn check_errs(code: &str) -> Vec<String> {
    let mut p = parse_program(code);
    sema::check(&mut p)
        .err()
        .unwrap_or_default()
        .into_iter()
        .map(|d| d.message)
        .collect()
}

// ===========================================================================
// Lexer
// ===========================================================================

#[test]
fn lexes_comparison_and_logical_operators() {
    let t = lex_tokens("a <= b >= c == d != e && f || g");
    assert!(t.contains(&Token::Le));
    assert!(t.contains(&Token::Ge));
    assert!(t.contains(&Token::EqEq));
    assert!(t.contains(&Token::Neq));
    assert!(t.contains(&Token::AmpAmp));
    assert!(t.contains(&Token::PipePipe));
}

#[test]
fn lexes_bitwise_and_modulo() {
    let t = lex_tokens("a & b | c ^ d % e << f >> g ~h");
    assert!(t.contains(&Token::Amp));
    assert!(t.contains(&Token::Pipe));
    assert!(t.contains(&Token::Caret));
    assert!(t.contains(&Token::Percent));
    assert!(t.contains(&Token::Shl));
    assert!(t.contains(&Token::Shr));
    assert!(t.contains(&Token::Tilde));
}

#[test]
fn lexes_compound_assign_and_incr() {
    let t = lex_tokens("x += 1 y -= 2 z *= 3 w /= 4 v %= 5 a++ b--");
    assert!(t.contains(&Token::PlusEq));
    assert!(t.contains(&Token::MinusEq));
    assert!(t.contains(&Token::StarEq));
    assert!(t.contains(&Token::SlashEq));
    assert!(t.contains(&Token::PercentEq));
    assert!(t.contains(&Token::PlusPlus));
    assert!(t.contains(&Token::MinusMinus));
}

#[test]
fn lexes_floats_ints_and_ranges() {
    let t = lex_tokens("3.14 1e3 2.5e-2 42 1..10");
    assert!(matches!(t[0], Token::Float(_)));
    assert!(matches!(t[1], Token::Float(_)));
    assert!(matches!(t[2], Token::Float(_)));
    assert!(matches!(t[3], Token::Int(42)));
    // 1..10  ->  Int(1) DotDot Int(10)
    assert!(t.contains(&Token::DotDot));
    // '..' não é confundido com '...'
    assert!(!t.contains(&Token::DotDotDot));
}

#[test]
fn distinguishes_dot_dotdot_dotdotdot() {
    assert!(lex_tokens("a.b").contains(&Token::Dot));
    assert!(lex_tokens("1..2").contains(&Token::DotDot));
    assert!(lex_tokens("...x").contains(&Token::DotDotDot));
}

#[test]
fn lexes_new_keywords() {
    let t = lex_tokens("for break continue match async await");
    assert!(t.contains(&Token::For));
    assert!(t.contains(&Token::Break));
    assert!(t.contains(&Token::Continue));
    assert!(t.contains(&Token::Match));
    assert!(t.contains(&Token::Async));
    assert!(t.contains(&Token::Await));
}

// ===========================================================================
// Parser — forma da AST nos pontos novos
// ===========================================================================

#[test]
fn parses_precedence_mul_before_add() {
    // 1 + 2 * 3  ->  Add(1, Mul(2, 3))
    let p = parse_program("const x: i64 = 1 + 2 * 3;");
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    let StmtKind::Let { value, .. } = &main.body[0].kind else { panic!("esperava let") };
    let Expr::Binary { op: BinOp::Add, rhs, .. } = value else {
        panic!("topo deveria ser Add")
    };
    assert!(matches!(rhs.as_ref(), Expr::Binary { op: BinOp::Mul, .. }));
}

#[test]
fn parses_compound_assign_desugar() {
    // x += 2  vira  x = x + 2
    let p = parse_program("let x: i64 = 0; x += 2;");
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    let StmtKind::Assign { value, .. } = &main.body[1].kind else { panic!("esperava assign") };
    assert!(matches!(value, Expr::Binary { op: BinOp::Add, .. }));
}

#[test]
fn parses_generics_on_function_and_class() {
    let p = parse_program("fn id<T>(x: T): T { return x; }\nclass Box<T> { v: T }");
    let id = p.functions.iter().find(|f| f.name == "id").unwrap();
    assert_eq!(id.type_params, vec!["T".to_string()]);
    assert_eq!(p.classes[0].type_params, vec!["T".to_string()]);
}

#[test]
fn parses_reified_type_args() {
    // const b: Box<i64> = ...  guarda [i64] na Type
    let p = parse_program("type T = { x: i64 }\nfn f(b: Box<i64>): i64 { return 0; }");
    let f = p.functions.iter().find(|f| f.name == "f").unwrap();
    match &f.params[0].ty {
        Type::Named(n, args) => {
            assert_eq!(n, "Box");
            assert_eq!(args, &vec![Type::I64]);
        }
        other => panic!("esperava Named com args, achei {:?}", other),
    }
}

#[test]
fn parses_match_as_expression_with_guard_and_range() {
    let p = parse_program("const r: i64 = match (7) { 0..5 => 1, x if x > 5 => 2, _ => 3 };");
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    let StmtKind::Let { value, .. } = &main.body[0].kind else { panic!("esperava let") };
    let Expr::Match { arms, .. } = value else { panic!("esperava match expr") };
    assert_eq!(arms.len(), 3);
    assert!(matches!(arms[0].pattern, Pattern::Range(0, 5)));
    assert!(arms[1].guard.is_some());
    assert!(matches!(arms[2].pattern, Pattern::Wildcard));
}

// ===========================================================================
// Sema — o que o lex aceita
// ===========================================================================

#[test]
fn accepts_core_features() {
    assert!(check_ok("fn main(): i32 { let x: i64 = (1 + 2) * 3 % 4; return 0; }"));
    assert!(check_ok("fn main(): i32 { for (let i: i64 = 0; i < 3; i++) { } return 0; }"));
    assert!(check_ok("fn main(): i32 { let xs: i64[] = [1,2]; for (const v of xs) { } return 0; }"));
    assert!(check_ok("const r: i64 = match (3) { 1 => 1, _ => 0 };"));
    assert!(check_ok("const a: f64 = 1.5 + sqrt(4.0); const b: f32 = 0.25;"));
}

#[test]
fn parses_async_fn_and_await() {
    let p = parse_program("async fn f(): i64 { return 1; }\nconst x: i64 = await f();");
    assert!(p.functions.iter().find(|f| f.name == "f").unwrap().is_async);
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    let StmtKind::Let { value, .. } = &main.body[0].kind else { panic!("esperava let") };
    assert!(matches!(value, Expr::Await(_)));
}

#[test]
fn accepts_async_await() {
    assert!(check_ok("async fn f(): i64 { return 1; }\nconst x: i64 = await f();"));
}

#[test]
fn rejects_async_fallible() {
    let e = check_errs("async fn f(): i64! { fail 1; }");
    assert!(e.iter().any(|m| m.contains("async")));
}

#[test]
fn sema_errors_carry_source_spans() {
    // erro no corpo: aponta o statement do arquivo analisado (module 0) com um
    // trecho real (hi > lo) — é o que o `lex lsp` usa para sublinhar a linha.
    let mut p1 = parse_program("fn main(): i32 {\n  const x: i64 = 1\n  x = 2\n  return 0\n}");
    let diags = sema::check(&mut p1)
        .err()
        .expect("esperava erro de reatribuição de const");
    let reassign = diags
        .iter()
        .find(|d| d.message.contains("cannot reassign"))
        .expect("erro de const ausente");
    assert_eq!(reassign.span.module, 0, "span deve ser do arquivo analisado");
    assert!(reassign.span.hi > reassign.span.lo, "span deve cobrir o trecho");

    // erro de definição: aponta o nome da função duplicada (não DUMMY)
    let mut p2 = parse_program("fn f(): i64 { return 0 }\nfn f(): i64 { return 1 }");
    let dup = sema::check(&mut p2)
        .err()
        .expect("esperava função duplicada");
    let d = dup
        .iter()
        .find(|d| d.message.contains("defined more than once"))
        .expect("erro de duplicada ausente");
    assert_ne!(d.span, Span::DUMMY, "definição deveria ter posição");
}

#[test]
fn infers_function_return_types() {
    // retorno sem anotação é inferido do corpo (estilo HM)
    assert!(check_ok("fn double(x: i64) { return x * 2 } fn main(): i32 { return double(3) - 6 }"));
    // float inferido: usar o retorno como f64 deve passar
    assert!(check_ok("fn pi() { return 3.14 } const p: f64 = pi();"));
    // dependência entre inferências (ponto-fixo): g chama f
    assert!(check_ok("fn f(x: i64) { return x + 1 } fn g(x: i64) { return f(x) } const y: i64 = g(1);"));
    // função sem return de valor continua void (não dá erro de void+valor)
    assert!(check_ok("fn noop(x: i64) { let y: i64 = x; } fn main(): i32 { noop(1); return 0 }"));
}

#[test]
fn infers_return_type_is_concrete_after_check() {
    // depois do check, o ret_type inferido fica concreto no AST (f64, não void)
    let mut p = parse_program("fn pi() { return 3.14 }");
    assert!(sema::check(&mut p).is_ok());
    let pi = p.functions.iter().find(|f| f.name == "pi").unwrap();
    assert_eq!(pi.ret_type, Type::F64);
    assert!(!pi.ret_inferred || pi.ret_type == Type::F64);
}

#[test]
fn accepts_generics() {
    assert!(check_ok("fn id<T>(x: T): T { return x; } const a: i64 = id(5);"));
    assert!(check_ok(
        "class Box<T> { v: T; constructor(x: T){this.v=x} get(): T { return this.v } } \
         const b: Box<i64> = new Box<i64>(7); const n: i64 = b.get();"
    ));
}

// ===========================================================================
// Sema — o que o lex recusa (o coração do design: erros em compile-time)
// ===========================================================================

#[test]
fn rejects_break_outside_loop() {
    assert!(check_errs("break;").iter().any(|m| m.contains("break")));
}

#[test]
fn rejects_continue_outside_loop() {
    assert!(check_errs("continue;").iter().any(|m| m.contains("continue")));
}

#[test]
fn rejects_unhandled_fallible_call() {
    let e = check_errs("fn f(): i64! { fail 1; }\nconst x: i64 = f();");
    assert!(!e.is_empty(), "chamada falível sem try/catch deveria falhar");
}

#[test]
fn rejects_const_reassignment() {
    let e = check_errs("const x: i64 = 1;\nx = 2;");
    assert!(e.iter().any(|m| m.contains("const") || m.contains("reassign")));
}

#[test]
fn rejects_unknown_variable() {
    assert!(check_errs("const x: i64 = naoExiste;").iter().any(|m| m.contains("naoExiste")));
}

#[test]
fn rejects_forof_over_non_array() {
    let e = check_errs("const n: i64 = 5;\nfor (const x of n) { }");
    assert!(e.iter().any(|m| m.contains("for...of") || m.contains("array")));
}

// ---------------------------------------------------------------------------
// Sema — checagem de tipos nos argumentos de chamadas
// ---------------------------------------------------------------------------

#[test]
fn rejects_arg_type_mismatch() {
    // string onde i64 é esperado
    let e = check_errs("fn dobro(n: i64): i64 { return n*2; }\nconst x: i64 = dobro(\"oi\");");
    assert!(e.iter().any(|m| m.contains("argument 1") && m.contains("dobro")));
    // objeto onde string é esperado
    let e = check_errs(
        "type P = { nome: string }\nfn saudar(s: string): string { return s; }\n\
         fn main(): i64 { const p: P = { nome: \"x\" }; saudar(p); return 0; }",
    );
    assert!(e.iter().any(|m| m.contains("argument 1") && m.contains("saudar")));
}

#[test]
fn accepts_subclass_arg_for_parent_param() {
    assert!(check_ok(
        "class Animal { fala(): string { return \"...\"; } }\n\
         class Cao extends Animal { fala(): string { return \"au\"; } }\n\
         fn ouvir(a: Animal): string { return a.fala(); }\n\
         fn main(): i64 { ouvir(new Cao()); return 0; }",
    ));
}

#[test]
fn accepts_generic_and_variadic_args() {
    // genérico aceita qualquer tipo concreto
    assert!(check_ok("fn id<T>(x: T): T { return x; }\nconst s: string = id<string>(\"ok\");"));
    // variádico: cada argumento extra casa o tipo do elemento
    assert!(check_ok(
        "fn somaTudo(...ns: i64[]): i64 { return 0; }\nconst t: i64 = somaTudo(1, 2, 3);",
    ));
    // mistura numérica (i64 onde f64 é esperado) é coerção válida
    assert!(check_ok("fn area(r: f64): f64 { return r*r; }\nconst a: f64 = area(2.0);"));
}

// ---------------------------------------------------------------------------
// Sema — indexação por [] em Map e JSON (além de array)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Sema — spawn de método de instância (spawn obj.metodo(args))
// ---------------------------------------------------------------------------

#[test]
fn accepts_spawn_instance_method() {
    assert!(check_ok(
        "class W { b: i64; constructor(x: i64){this.b=x} run(n: i64): i64 { return this.b+n; } }\n\
         fn main(): i64 { const w: W = new W(1); const t: i64 = spawn w.run(2); return join(t); }",
    ));
}

#[test]
fn rejects_spawn_of_fallible_or_unknown_method() {
    let e = check_errs(
        "class C { m(): i64! { fail 1; } }\n\
         fn main(): i64 { const c: C = new C(); spawn c.m(); return 0; }",
    );
    assert!(e.iter().any(|m| m.contains("fallible") && m.contains("C.m")));

    let e = check_errs(
        "class D { m(): i64 { return 1; } }\n\
         fn main(): i64 { const d: D = new D(); spawn d.naoExiste(); return 0; }",
    );
    assert!(e.iter().any(|m| m.contains("no instance method")));
}

// ---------------------------------------------------------------------------
// JSON mínimo (base do lex lsp)
// ---------------------------------------------------------------------------

#[test]
fn json_parses_nested_and_escapes() {
    use crate::json;
    let v = json::parse(r#"{"method":"x","params":{"items":[1,2],"s":"a\"b\n"}}"#).unwrap();
    assert_eq!(v.get("method").and_then(|m| m.as_str()), Some("x"));
    let items = v.path(&["params", "items"]).and_then(|i| i.as_array()).unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(v.path(&["params", "s"]).and_then(|s| s.as_str()), Some("a\"b\n"));
    assert!(json::parse("não é json {").is_none());
}

#[test]
fn json_escape_roundtrips_specials() {
    use crate::json;
    let s = "linha1\n\"aspas\"\tfim";
    let escaped = json::escape(s);
    // re-parse como string JSON deve recuperar o original
    let back = json::parse(&format!("\"{}\"", escaped)).unwrap();
    assert_eq!(back.as_str(), Some(s));
}

// ---------------------------------------------------------------------------
// Closures com captura
// ---------------------------------------------------------------------------

#[test]
fn closure_records_free_vars() {
    // o parser anota as variáveis livres candidatas na Closure
    let p = parse_program(
        "fn run(f: (i64)=>i64, x: i64): i64 { return f(x); }\n\
         fn main(): i64 { const m: i64 = 3; const g: (i64)=>i64 = (x: i64) => x + m; return run(g, 1); }",
    );
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    // const g: ... = <Closure>
    let StmtKind::Let { value, .. } = &main.body[1].kind else { panic!("esperava let g") };
    let Expr::Closure { captures, .. } = value else { panic!("esperava Closure") };
    assert!(captures.contains(&"m".to_string()), "deveria capturar 'm'");
}

#[test]
fn accepts_capturing_arrow() {
    assert!(check_ok(
        "fn run(f: (i64)=>i64, x: i64): i64 { return f(x); }\n\
         fn main(): i64 { const m: i64 = 10; const add: (i64)=>i64 = (x: i64) => x + m; return run(add, 5); }",
    ));
    // captura de this dentro de método
    assert!(check_ok(
        "fn run(f: ()=>i64): i64 { return f(); }\n\
         class B { v: i64; constructor(x: i64){this.v=x} getter(): ()=>i64 { return () => this.v; } }\n\
         fn main(): i64 { return run(new B(1).getter()); }",
    ));
}

#[test]
fn rejects_truly_undefined_in_arrow() {
    let e = check_errs("fn main(): i64 { const f: ()=>i64 = () => naoExiste; return f(); }");
    assert!(e.iter().any(|m| m.contains("naoExiste")));
}

// ---------------------------------------------------------------------------
// Formatador (lex fmt)
// ---------------------------------------------------------------------------

#[test]
fn fmt_reindents_by_brace_depth() {
    let src = "fn f(): i64 {\nlet x: i64 = 1;\nif (x > 0) {\nreturn x;\n}\nreturn 0;\n}\n";
    let out = crate::fmt::format_source(src);
    let expected = "fn f(): i64 {\n    let x: i64 = 1;\n    if (x > 0) {\n        return x;\n    }\n    return 0;\n}\n";
    assert_eq!(out, expected);
}

#[test]
fn fmt_is_idempotent_and_preserves_templates() {
    // o interior de um template multi-linha NÃO pode ser reindentado
    let src = "fn p(): string {\nconst h: string = `\n        <div>x</div>\n`;\nreturn h;\n}\n";
    let once = crate::fmt::format_source(src);
    let twice = crate::fmt::format_source(&once);
    assert_eq!(once, twice, "formatador deve ser idempotente");
    assert!(once.contains("        <div>x</div>"), "interior do template foi alterado");
    assert!(once.contains("    const h"), "linha de código não foi reindentada");
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

#[test]
fn parses_enum_decl() {
    let p = parse_program("enum Color { Red, Green, Blue }");
    assert_eq!(p.enums.len(), 1);
    assert_eq!(p.enums[0].name, "Color");
    assert_eq!(p.enums[0].variants, vec!["Red", "Green", "Blue"]);
}

#[test]
fn accepts_enum_use() {
    assert!(check_ok(
        "enum Color { Red, Green }\nfn main(): i64 { const c: Color = Color.Green; return c; }",
    ));
    // enum em match com padrão de variante
    assert!(check_ok(
        "enum S { A, B }\nfn f(s: S): i64 { return match (s) { S.A => 1, S.B => 2, _ => 0 }; }",
    ));
}

#[test]
fn rejects_unknown_enum_variant() {
    let e = check_errs("enum E { A, B }\nfn main(): i64 { return E.C; }");
    assert!(e.iter().any(|m| m.contains("variant")));
    let e = check_errs("enum E { A }\nfn f(x: E): i64 { return match (x) { E.Z => 1, _ => 0 }; }");
    assert!(e.iter().any(|m| m.contains("variant")));
}

// ---------------------------------------------------------------------------
// Sema/parser — match sobre tipos e destructuring
// ---------------------------------------------------------------------------

#[test]
fn parses_type_and_destructure_patterns() {
    let p = parse_program(
        "class A {}\nconst r: i64 = match (new A()) { A a => 1, {x, y} => 2, _ => 0 };",
    );
    let main = p.functions.iter().find(|f| f.name == "main").unwrap();
    let StmtKind::Let { value, .. } = &main.body[0].kind else { panic!("esperava let") };
    let Expr::Match { arms, .. } = value else { panic!("esperava match") };
    assert!(matches!(&arms[0].pattern, Pattern::Type { class, bind } if class == "A" && bind == "a"));
    assert!(matches!(&arms[1].pattern, Pattern::Destructure(ns) if ns == &vec!["x".to_string(), "y".to_string()]));
}

#[test]
fn accepts_type_and_destructure_match() {
    assert!(check_ok(
        "class Shape {}\nclass Circle extends Shape { r: f64; constructor(x: f64){this.r=x} }\n\
         fn d(s: Shape): f64 { return match (s) { Circle c => c.r, _ => 0.0 }; }",
    ));
    assert!(check_ok(
        "type P = { x: i64, y: i64 }\nfn main(): i64 { const p: P = {x:1,y:2}; \
         return match (p) { {x, y} => x + y }; }",
    ));
}

#[test]
fn rejects_bad_type_or_destructure_pattern() {
    let e = check_errs("fn main(): i64 { return match (5) { Foo f => 1, _ => 0 }; }");
    assert!(e.iter().any(|m| m.contains("not a class")));
    let e = check_errs(
        "type P = { x: i64 }\nfn main(): i64 { const p: P = {x:1}; \
         return match (p) { {x, z} => x }; }",
    );
    assert!(e.iter().any(|m| m.contains("destructure")));
}

// ---------------------------------------------------------------------------
// Sema — campos static em classes
// ---------------------------------------------------------------------------

#[test]
fn accepts_static_fields() {
    assert!(check_ok(
        "class Counter { static count: i64 = 0; constructor(){ Counter.count = Counter.count + 1; } }\n\
         fn main(): i64 { const c: Counter = new Counter(); return Counter.count; }",
    ));
    // private acessível de dentro da própria classe
    assert!(check_ok(
        "class A { private static n: i64 = 5; static get(): i64 { return A.n; } }\n\
         fn main(): i64 { return A.get(); }",
    ));
}

#[test]
fn rejects_bad_static_field_access() {
    let e = check_errs("class A { static x: i64 = 1; }\nfn main(): i64 { return A.y; }");
    assert!(e.iter().any(|m| m.contains("no static field")));

    let e = check_errs(
        "class A { private static x: i64 = 1; }\nfn main(): i64 { return A.x; }",
    );
    assert!(e.iter().any(|m| m.contains("private")));
}

#[test]
fn accepts_index_on_map_and_json() {
    assert!(check_ok(
        "const m: Map<i64> = { \"a\": 1 };\nconst v: i64 = m[\"a\"];\nm[\"b\"] = 2;",
    ));
    assert!(check_ok(
        "const j: json = jsonParse(\"{}\");\nconst a: json = j[\"k\"];\nconst b: json = j[0];",
    ));
}
