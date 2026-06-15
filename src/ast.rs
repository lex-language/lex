//! Árvore sintática abstrata (AST) do lex.

/// Trecho de fonte (em índices de char) com o módulo de origem. O `module` é o
/// id que o driver atribui a cada arquivo (`0` = o arquivo principal; `1+` =
/// importados). Os diagnósticos só viram linha/coluna precisa quando o span é
/// do arquivo sendo analisado (module 0); spans de outros módulos (ou `DUMMY`,
/// usado em nós sintéticos) caem na linha 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub lo: usize,
    pub hi: usize,
    pub module: usize,
}

impl Span {
    /// Span "sem posição" — nós sintéticos (gerados pelo compilador, não pelo
    /// fonte). `module: usize::MAX` garante que nunca casa com um módulo real.
    pub const DUMMY: Span = Span { lo: 0, hi: 0, module: usize::MAX };
}

#[derive(Debug, Clone)]
pub struct Program {
    /// `import { a, b } from "módulo";` — resolvidos pelo driver (main.rs).
    pub imports: Vec<ImportDecl>,
    /// `type Nome = { campo: tipo, ... }` — structs (records).
    pub structs: Vec<StructDef>,
    /// `interface Nome { metodo(args): tipo }` — contratos de assinatura.
    pub interfaces: Vec<InterfaceDef>,
    /// `class Nome extends Pai { ... }` — classes (OOP).
    pub classes: Vec<ClassDef>,
    /// `enum Cor { Red, Green }` — constantes inteiras nomeadas.
    pub enums: Vec<EnumDef>,
    pub functions: Vec<Function>,
}

/// `enum Nome { A, B, C }` — cada variante é uma constante inteira (0, 1, 2…).
/// O tipo `Nome` é tratado como inteiro; `Nome.A` resolve para a constante.
#[derive(Debug, Clone)]
pub struct EnumDef {
    pub name: String,
    pub variants: Vec<String>,
    pub span: Span,
}

/// `interface Nome { m(args): tipo  outro(): tipo! }` — só assinaturas, sem
/// corpo. Um `interface` não gera código: é um contrato que o `implements`
/// força a classe a cumprir (checado no sema). O nome NÃO é um tipo de valor.
#[derive(Debug, Clone)]
pub struct InterfaceDef {
    pub name: String,
    pub methods: Vec<InterfaceMethod>,
    pub span: Span,
}

/// Assinatura de um método de interface (sem corpo, sempre pública/instância).
#[derive(Debug, Clone)]
pub struct InterfaceMethod {
    pub name: String,
    pub params: Vec<Param>,
    pub ret_type: Type,
    /// `m(): i64!` — o implementador também tem de ser falível.
    pub fallible: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct StructDef {
    pub name: String,
    pub fields: Vec<(String, Type)>,
    pub span: Span,
}

/// `class Nome extends Pai { campos, constructor, métodos }`.
/// No codegen, um objeto é um bloco na arena: slot 0 = vtable (dispatch
/// dinâmico), slots seguintes = campos (8 bytes cada, como nos structs).
#[derive(Debug, Clone)]
pub struct ClassDef {
    pub name: String,
    /// Parâmetros de tipo: `class Box<T> { ... }`. São apagados no codegen
    /// (type erasure): toda célula é i64, então `T` vira i64.
    pub type_params: Vec<String>,
    pub parent: Option<String>,
    /// `class C implements I, J` — interfaces que a classe promete cumprir.
    /// Verificado no sema: cada método da interface precisa existir aqui
    /// (próprio ou herdado), público, de instância e com assinatura idêntica.
    pub implements: Vec<String>,
    pub fields: Vec<ClassField>,
    /// Campos `static`: estado compartilhado da classe (não vão no layout do
    /// objeto). Cada um exige um inicializador (`static n: i64 = 0`).
    pub statics: Vec<StaticField>,
    /// Métodos e o construtor (nome "constructor").
    pub methods: Vec<Method>,
    pub span: Span,
}

/// `static nome: tipo = init;` numa classe — uma "variável de classe" com
/// armazenamento global único, acessada por `Classe.nome`.
#[derive(Debug, Clone)]
pub struct StaticField {
    pub name: String,
    pub ty: Type,
    pub private: bool,
    pub init: Expr,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ClassField {
    pub name: String,
    pub ty: Type,
    /// `private campo: tipo` — acessível só dentro da própria classe.
    pub private: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Method {
    pub name: String,
    /// Parâmetros declarados (sem o `this` implícito).
    pub params: Vec<Param>,
    pub ret_type: Type,
    /// `metodo(): i64!` — método falível, usado com try/catch.
    pub fallible: bool,
    pub private: bool,
    /// `static metodo()` — chamado na classe (`Nome.metodo()`), sem `this`.
    pub is_static: bool,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ImportDecl {
    pub names: Vec<String>,
    /// O especificador entre aspas: "./shim" (relativo) ou "libc" (std/).
    pub module: String,
}

#[derive(Debug, Clone)]
pub struct Function {
    pub name: String,
    /// `async fn` — chamá-la lança uma thread (via spawn) e devolve um
    /// `Future<T>`; `await` espera o resultado (via join). Sem runtime de
    /// async: a concorrência é a de threads reais do SO.
    pub is_async: bool,
    /// Parâmetros de tipo: `fn identidade<T>(x: T): T`. Apagados no codegen
    /// (type erasure): `T` vira a célula i64 uniforme.
    pub type_params: Vec<String>,
    pub params: Vec<Param>,
    pub ret_type: Type,
    /// `true` se o retorno é marcado com `!` (a função pode falhar).
    pub fallible: bool,
    /// `true` quando o tipo de retorno NÃO foi anotado e deve ser inferido do
    /// corpo (inferência estilo HM). O passo `sema` resolve `ret_type` antes do
    /// resto da checagem; funções `declare` (FFI) e sintéticas não inferem.
    pub ret_inferred: bool,
    /// `true` para `declare function ...;` (ambient declaration, como num
    /// .d.ts) — definida na libc ou num .c linkado junto. Sem corpo.
    pub external: bool,
    pub body: Vec<Stmt>,
    /// Posição do nome da função no fonte (para diagnósticos do sema).
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub ty: Type,
    /// Valor usado quando o argumento é omitido na chamada (`x: i64 = 0`).
    /// `None` = obrigatório. Defaults são sempre finais (garantido no parser),
    /// e só valem em chamadas diretas a `function`/método (não em ponteiros
    /// de função nem em FFI `declare`).
    pub default: Option<Expr>,
    /// `...args: T[]` — parâmetro variádico (rest). Recolhe todos os argumentos
    /// finais num array `T[]`. É sempre o último parâmetro, sem default, e cada
    /// argumento extra é coagido ao tipo do elemento (`T`) na chamada — quando
    /// `T` é `any`, isso significa boxing automático. Carrega o tipo já como
    /// `Array(T)`, então dentro do corpo o parâmetro é um array comum.
    pub variadic: bool,
}

/// `true` se a assinatura termina num parâmetro variádico (`...args`).
pub fn is_variadic(params: &[Param]) -> bool {
    params.last().is_some_and(|p| p.variadic)
}

/// Substitui parâmetros de tipo numa `Type` segundo o mapa (nome → concreto).
/// Recursivo. Um `Named(tp, [])` cujo nome está no mapa vira o tipo concreto —
/// é o que faz `Box<i64>.get()` (cujo retorno é `T`) inferir `i64`.
pub fn subst_type(ty: &Type, map: &std::collections::HashMap<String, Type>) -> Type {
    match ty {
        Type::Named(n, args) => {
            if args.is_empty() {
                if let Some(t) = map.get(n) {
                    return t.clone();
                }
            }
            Type::Named(n.clone(), args.iter().map(|a| subst_type(a, map)).collect())
        }
        Type::Array(t) => Type::Array(Box::new(subst_type(t, map))),
        Type::Map(t) => Type::Map(Box::new(subst_type(t, map))),
        Type::Chan(t) => Type::Chan(Box::new(subst_type(t, map))),
        Type::Future(t) => Type::Future(Box::new(subst_type(t, map))),
        Type::Fn(ps, r) => Type::Fn(
            ps.iter().map(|p| subst_type(p, map)).collect(),
            Box::new(subst_type(r, map)),
        ),
        other => other.clone(),
    }
}

/// Mapa (param → arg) a partir de uma lista de parâmetros de tipo e os args
/// concretos correspondentes (zip; sobras de qualquer lado são ignoradas).
pub fn type_param_map(
    params: &[String],
    args: &[Type],
) -> std::collections::HashMap<String, Type> {
    params.iter().cloned().zip(args.iter().cloned()).collect()
}

/// Unifica um tipo declarado (que pode conter params) com um tipo concreto,
/// preenchendo o mapa param→concreto. Best-effort: usado para inferir os args
/// de tipo de uma chamada genérica sem `<...>` explícito (ex.: `first(xs)`).
pub fn unify_type(
    declared: &Type,
    actual: &Type,
    params: &[String],
    map: &mut std::collections::HashMap<String, Type>,
) {
    match (declared, actual) {
        (Type::Named(n, dargs), _) if dargs.is_empty() && params.contains(n) => {
            map.entry(n.clone()).or_insert_with(|| actual.clone());
        }
        (Type::Array(d), Type::Array(a))
        | (Type::Map(d), Type::Map(a))
        | (Type::Chan(d), Type::Chan(a))
        | (Type::Future(d), Type::Future(a)) => unify_type(d, a, params, map),
        (Type::Named(_, dargs), Type::Named(_, aargs)) => {
            for (d, a) in dargs.iter().zip(aargs) {
                unify_type(d, a, params, map);
            }
        }
        (Type::Fn(dp, dr), Type::Fn(ap, ar)) => {
            for (d, a) in dp.iter().zip(ap) {
                unify_type(d, a, params, map);
            }
            unify_type(dr, ar, params, map);
        }
        _ => {}
    }
}

/// Aridade mínima: parâmetros antes do primeiro com valor default (ou do
/// variádico). Como defaults e o variádico são sempre finais, isso é o nº de
/// argumentos obrigatórios — o variádico aceita zero ou mais e não conta.
pub fn required_arity(params: &[Param]) -> usize {
    params
        .iter()
        .take_while(|p| p.default.is_none() && !p.variadic)
        .count()
}

/// Um corpo precisa ser falível (`!`) se contém `try` (propaga o erro) ou
/// `fail`. `catch` NÃO conta: trata o erro ali mesmo. Usado para sintetizar o
/// `main` a partir de statements de topo com a fallibilidade certa.
pub fn stmts_need_fallible(stmts: &[Stmt]) -> bool {
    stmts.iter().any(stmt_needs_fallible)
}

fn stmt_needs_fallible(s: &Stmt) -> bool {
    match &s.kind {
        StmtKind::Fail(_) => true,
        StmtKind::Let { value, .. } | StmtKind::Assign { value, .. } => expr_has_try(value),
        StmtKind::FieldAssign { base, value, .. } => expr_has_try(base) || expr_has_try(value),
        StmtKind::IndexAssign { base, index, value } => {
            expr_has_try(base) || expr_has_try(index) || expr_has_try(value)
        }
        StmtKind::While { cond, body } => expr_has_try(cond) || stmts_need_fallible(body),
        StmtKind::For { init, cond, update, body } => {
            init.as_deref().is_some_and(stmt_needs_fallible)
                || cond.as_ref().is_some_and(expr_has_try)
                || update.as_deref().is_some_and(stmt_needs_fallible)
                || stmts_need_fallible(body)
        }
        StmtKind::ForOf { iterable, body, .. } => {
            expr_has_try(iterable) || stmts_need_fallible(body)
        }
        StmtKind::Break | StmtKind::Continue => false,
        StmtKind::Return(Some(e)) => expr_has_try(e),
        StmtKind::Return(None) => false,
        StmtKind::Defer(inner) => stmt_needs_fallible(inner),
        StmtKind::If { cond, then_body, else_body } => {
            expr_has_try(cond)
                || stmts_need_fallible(then_body)
                || stmts_need_fallible(else_body)
        }
        StmtKind::Expr(e) => expr_has_try(e),
    }
}

fn expr_has_try(e: &Expr) -> bool {
    match e {
        Expr::Try(_) => true,
        Expr::Await(inner) => expr_has_try(inner),
        Expr::Int(_) | Expr::Float(_) | Expr::Bool(_) | Expr::Str(_) | Expr::Var(_) => false,
        Expr::Template(parts) => parts.iter().any(|p| match p {
            TemplatePart::Expr(e) => expr_has_try(e),
            TemplatePart::Lit(_) => false,
        }),
        Expr::Binary { lhs, rhs, .. } => expr_has_try(lhs) || expr_has_try(rhs),
        Expr::Unary { operand, .. } => expr_has_try(operand),
        Expr::Match { scrutinee, arms } => {
            expr_has_try(scrutinee)
                || arms.iter().any(|a| {
                    a.guard.as_ref().is_some_and(expr_has_try) || stmts_need_fallible(&a.body)
                })
        }
        Expr::Call { args, .. }
        | Expr::Spawn { args, .. }
        | Expr::New { args, .. }
        | Expr::SuperCall { args, .. } => args.iter().any(expr_has_try),
        Expr::Catch { lhs, handler } => {
            expr_has_try(lhs)
                || match handler {
                    CatchHandler::Fallback(e) => expr_has_try(e),
                    CatchHandler::Block { body, .. } => stmts_need_fallible(body),
                }
        }
        Expr::Field { base, .. } => expr_has_try(base),
        Expr::StructLit { fields } | Expr::MapLit(fields) => {
            fields.iter().any(|(_, e)| expr_has_try(e))
        }
        Expr::ArrayLit(items) => items.iter().any(expr_has_try),
        Expr::Index { base, index } => expr_has_try(base) || expr_has_try(index),
        Expr::MethodCall { base, args, .. } => {
            expr_has_try(base) || args.iter().any(expr_has_try)
        }
        // o corpo da arrow já foi içado; o `try` dentro dela é problema dela
        Expr::Closure { .. } => false,
    }
}

/// Variáveis livres candidatas de uma arrow function: nomes usados no corpo
/// que NÃO são parâmetros nem ligados dentro dele. Pode incluir nomes globais
/// (funções/classes/enums), que o sema e o codegen filtram depois — o que
/// importa é não perder nenhuma captura real nem incluir um nome ligado
/// localmente. Uma `Closure` aninhada contribui suas próprias capturas como
/// "usadas" aqui (elas vêm deste escopo).
pub fn lambda_free_vars(params: &[Param], body: &[Stmt]) -> Vec<String> {
    let mut used: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut bound: std::collections::HashSet<String> =
        params.iter().map(|p| p.name.clone()).collect();
    for s in body {
        fv_stmt(s, &mut used, &mut seen, &mut bound);
    }
    used.into_iter().filter(|n| !bound.contains(n)).collect()
}

fn fv_add(n: &str, used: &mut Vec<String>, seen: &mut std::collections::HashSet<String>) {
    if seen.insert(n.to_string()) {
        used.push(n.to_string());
    }
}

fn fv_stmt(
    s: &Stmt,
    used: &mut Vec<String>,
    seen: &mut std::collections::HashSet<String>,
    bound: &mut std::collections::HashSet<String>,
) {
    match &s.kind {
        StmtKind::Let { name, value, .. } => {
            fv_expr(value, used, seen, bound);
            bound.insert(name.clone());
        }
        StmtKind::Assign { name, value } => {
            fv_add(name, used, seen);
            fv_expr(value, used, seen, bound);
        }
        StmtKind::FieldAssign { base, value, .. } => {
            fv_expr(base, used, seen, bound);
            fv_expr(value, used, seen, bound);
        }
        StmtKind::IndexAssign { base, index, value } => {
            fv_expr(base, used, seen, bound);
            fv_expr(index, used, seen, bound);
            fv_expr(value, used, seen, bound);
        }
        StmtKind::While { cond, body } => {
            fv_expr(cond, used, seen, bound);
            for s in body {
                fv_stmt(s, used, seen, bound);
            }
        }
        StmtKind::For { init, cond, update, body } => {
            if let Some(i) = init {
                fv_stmt(i, used, seen, bound);
            }
            if let Some(c) = cond {
                fv_expr(c, used, seen, bound);
            }
            if let Some(u) = update {
                fv_stmt(u, used, seen, bound);
            }
            for s in body {
                fv_stmt(s, used, seen, bound);
            }
        }
        StmtKind::ForOf { name, iterable, body, .. } => {
            fv_expr(iterable, used, seen, bound);
            bound.insert(name.clone());
            for s in body {
                fv_stmt(s, used, seen, bound);
            }
        }
        StmtKind::Return(Some(e)) | StmtKind::Fail(e) => fv_expr(e, used, seen, bound),
        StmtKind::Defer(inner) => fv_stmt(inner, used, seen, bound),
        StmtKind::If { cond, then_body, else_body } => {
            fv_expr(cond, used, seen, bound);
            for s in then_body {
                fv_stmt(s, used, seen, bound);
            }
            for s in else_body {
                fv_stmt(s, used, seen, bound);
            }
        }
        StmtKind::Expr(e) => fv_expr(e, used, seen, bound),
        StmtKind::Break | StmtKind::Continue | StmtKind::Return(None) => {}
    }
}

fn fv_expr(
    e: &Expr,
    used: &mut Vec<String>,
    seen: &mut std::collections::HashSet<String>,
    bound: &mut std::collections::HashSet<String>,
) {
    match e {
        Expr::Var(n) => fv_add(n, used, seen),
        Expr::Int(_) | Expr::Float(_) | Expr::Bool(_) | Expr::Str(_) => {}
        Expr::Template(parts) => {
            for p in parts {
                if let TemplatePart::Expr(e) = p {
                    fv_expr(e, used, seen, bound);
                }
            }
        }
        Expr::Binary { lhs, rhs, .. } => {
            fv_expr(lhs, used, seen, bound);
            fv_expr(rhs, used, seen, bound);
        }
        Expr::Unary { operand, .. } => fv_expr(operand, used, seen, bound),
        Expr::Match { scrutinee, arms } => {
            fv_expr(scrutinee, used, seen, bound);
            for a in arms {
                match &a.pattern {
                    Pattern::Binding(n) => {
                        bound.insert(n.clone());
                    }
                    Pattern::Type { bind, .. } if bind != "_" => {
                        bound.insert(bind.clone());
                    }
                    Pattern::Destructure(names) => {
                        for n in names {
                            bound.insert(n.clone());
                        }
                    }
                    _ => {}
                }
                if let Some(g) = &a.guard {
                    fv_expr(g, used, seen, bound);
                }
                for s in &a.body {
                    fv_stmt(s, used, seen, bound);
                }
            }
        }
        // o nome de uma chamada pode ser uma função global (filtrada depois) ou
        // um valor de função capturado — incluir nos candidatos é seguro.
        Expr::Call { name, args, .. } => {
            fv_add(name, used, seen);
            for a in args {
                fv_expr(a, used, seen, bound);
            }
        }
        // uma arrow aninhada traz suas capturas como usadas neste escopo
        Expr::Closure { captures, .. } => {
            for c in captures {
                fv_add(c, used, seen);
            }
        }
        Expr::Try(inner) | Expr::Await(inner) => fv_expr(inner, used, seen, bound),
        Expr::Catch { lhs, handler } => {
            fv_expr(lhs, used, seen, bound);
            match handler {
                CatchHandler::Fallback(e) => fv_expr(e, used, seen, bound),
                CatchHandler::Block { name, body } => {
                    if let Some(n) = name {
                        bound.insert(n.clone());
                    }
                    for s in body {
                        fv_stmt(s, used, seen, bound);
                    }
                }
            }
        }
        Expr::Spawn { receiver, args, .. } => {
            if let Some(r) = receiver {
                fv_expr(r, used, seen, bound);
            }
            for a in args {
                fv_expr(a, used, seen, bound);
            }
        }
        Expr::Field { base, .. } => fv_expr(base, used, seen, bound),
        Expr::StructLit { fields } | Expr::MapLit(fields) => {
            for (_, e) in fields {
                fv_expr(e, used, seen, bound);
            }
        }
        Expr::ArrayLit(items) => {
            for e in items {
                fv_expr(e, used, seen, bound);
            }
        }
        Expr::Index { base, index } => {
            fv_expr(base, used, seen, bound);
            fv_expr(index, used, seen, bound);
        }
        Expr::New { args, .. } | Expr::SuperCall { args, .. } => {
            for a in args {
                fv_expr(a, used, seen, bound);
            }
        }
        Expr::MethodCall { base, args, .. } => {
            fv_expr(base, used, seen, bound);
            for a in args {
                fv_expr(a, used, seen, bound);
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    I32,
    I64,
    /// Inteiro de 8 bits (um byte). No codegen é i8, armazenado em slot i64.
    I8,
    /// Ponto flutuante de 64 bits (`f64` / `float`). No codegen viaja na célula
    /// i64 como o padrão de bits do `double`; as operações fazem bitcast.
    F64,
    /// Ponto flutuante de 32 bits (`f32`). Viaja na célula i64 com o padrão de
    /// bits do `float` nos 32 bits baixos (zext); as operações usam f32 e os
    /// builtins de math promovem para f64.
    F32,
    /// Booleano (`true`/`false`). No codegen é i1; estende com zero (0/1).
    Bool,
    /// Ponteiro opaco (buffers, strings): um endereço. No codegen é i64.
    Ptr,
    /// Só para retorno: a função não devolve valor.
    /// `function f() {}` e `function f(): void {}` são equivalentes.
    Void,
    /// Tipo de função, estilo TS: `(i64, i64) => i64`.
    /// No codegen vira um endereço (i64) chamado indiretamente.
    Fn(Vec<Type>, Box<Type>),
    /// Tipo nomeado (struct, classe ou parâmetro de tipo). O `Vec<Type>` são
    /// os argumentos genéricos reificados: `Box<i64>` = `Named("Box", [I64])`,
    /// `Pessoa` = `Named("Pessoa", [])`. No codegen é sempre um ponteiro (i64)
    /// — os args não mudam o layout (representação uniforme), mas a inferência
    /// de tipo os substitui nos campos/métodos/retornos genéricos.
    Named(String, Vec<Type>),
    /// Array dinâmico tipado: `T[]` (ex.: `i64[]`, `string[]`, `i64[][]`).
    /// No codegen é um ponteiro (i64) para um header `LexArr` na arena.
    Array(Box<Type>),
    /// Dicionário de chave string → valor `T`: `Map<T>`.
    /// No codegen é um ponteiro (i64) para um `LexMap` na arena.
    Map(Box<Type>),
    /// Valor JSON dinâmico (tagged union: null/bool/número/string/array/objeto).
    /// No codegen é um ponteiro (i64) para um `LexJson` na arena.
    Json,
    /// Valor de qualquer tipo (`any`). No runtime é a MESMA caixa marcada do
    /// `json` (um `LexJson*`): converter para `any` faz boxing automático do
    /// escalar/string (tag + payload), e `json`↔`any` é identidade. Convertê-lo
    /// de volta a texto usa `jsonAsStr`. No codegen é um ponteiro (i64).
    Any,
    /// Canal de mensagens entre threads: `Channel<T>`. No codegen é um
    /// ponteiro (i64) para um `LexChan` no heap (compartilhado, não na arena).
    Chan(Box<Type>),
    /// `Future<T>` — o resultado pendente de uma `async fn`. No codegen é o
    /// handle (i64) da thread; `await` o resolve para `T` (join).
    Future(Box<Type>),
}

/// Um statement com a sua posição no fonte. O `span` é usado pelo sema para
/// apontar a linha/coluna exata do erro (e pelo `lex lsp`).
#[derive(Debug, Clone)]
pub struct Stmt {
    pub kind: StmtKind,
    pub span: Span,
}

impl Stmt {
    /// Statement sintético (sem posição) — usado quando o compilador gera um
    /// statement que não veio do fonte.
    pub fn synthetic(kind: StmtKind) -> Stmt {
        Stmt { kind, span: Span::DUMMY }
    }
}

#[derive(Debug, Clone)]
pub enum StmtKind {
    /// Declaração de variável: `const` (imutável) ou `let` (mutável).
    Let {
        name: String,
        ty: Option<Type>,
        value: Expr,
        mutable: bool,
    },
    /// Reatribuição: `x = expr;` — só para variáveis `let`.
    Assign {
        name: String,
        value: Expr,
    },
    /// Atribuição de campo: `base.campo = expr;` (objeto ou struct).
    FieldAssign {
        base: Expr,
        field: String,
        value: Expr,
    },
    /// Atribuição por índice: `base[index] = expr;` (array).
    IndexAssign {
        base: Expr,
        index: Expr,
        value: Expr,
    },
    While {
        cond: Expr,
        body: Vec<Stmt>,
    },
    /// `for (init; cond; update) { ... }` — laço estilo C. Cada parte é
    /// opcional: `for (;;) {}` é um laço infinito. `init`/`update` são
    /// statements (tipicamente `let`/atribuição); `cond` é uma expressão.
    For {
        init: Option<Box<Stmt>>,
        cond: Option<Expr>,
        update: Option<Box<Stmt>>,
        body: Vec<Stmt>,
    },
    /// `for (const x of arr) { ... }` — itera sobre um array `T[]`, ligando
    /// `x` a cada elemento. `mutable` reflete `let` vs `const` na variável.
    ForOf {
        name: String,
        mutable: bool,
        iterable: Expr,
        body: Vec<Stmt>,
    },
    /// `break;` — sai do laço mais interno.
    Break,
    /// `continue;` — pula para a próxima iteração do laço mais interno.
    Continue,
    /// `return expr;` ou `return;` (None, só em função void).
    Return(Option<Expr>),
    /// Sai da função com um código de erro (≠ 0). Só em funções falíveis.
    Fail(Expr),
    /// `defer stmt;` — executa `stmt` na saída da função (qualquer caminho),
    /// em ordem LIFO. Roda só se o fluxo passou pelo `defer` (guarda runtime).
    Defer(Box<Stmt>),
    If {
        cond: Expr,
        then_body: Vec<Stmt>,
        else_body: Vec<Stmt>,
    },
    Expr(Expr),
}

#[derive(Debug, Clone)]
pub enum Expr {
    Int(i64),
    /// Literal de ponto flutuante: `3.14`.
    Float(f64),
    /// `true` / `false` — booleano.
    Bool(bool),
    /// Literal de string: vira uma constante global no binário (terminada
    /// em NUL, como em C). Nenhuma alocação dinâmica.
    Str(String),
    /// Template literal: `a ${x} b` — concatenado na arena da thread.
    /// Interpolação de inteiro é convertida para texto automaticamente.
    Template(Vec<TemplatePart>),
    Var(String),
    Binary {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
    /// Operador unário prefixo: `-x`, `!x`, `~x`.
    Unary {
        op: UnOp,
        operand: Box<Expr>,
    },
    /// `match (expr) { padrão [if guarda] => corpo, _ => corpo }`. É uma
    /// expressão: o valor é o do corpo do braço que casar (a última expressão
    /// do bloco, como no `catch`). Como statement, o valor é descartado.
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<MatchArm>,
    },
    Call {
        name: String,
        /// Argumentos de tipo explícitos (`id<i64>(x)`) — vazios se omitidos.
        type_args: Vec<Type>,
        args: Vec<Expr>,
    },
    /// Valor de uma arrow function içada: `name` é a função de topo `__lambda_N`
    /// e `captures` são as variáveis livres candidatas (usadas no corpo e não
    /// ligadas nele). No codegen, as que forem locais do escopo viram capturas
    /// (copiadas por valor para o "closure box"); as globais são ignoradas.
    Closure {
        name: String,
        captures: Vec<String>,
    },
    /// `try f(...)` — se f falhar, propaga o erro para quem chamou.
    Try(Box<Expr>),
    /// `await fut` — espera o `Future<T>` de uma `async fn` resolver (join),
    /// devolvendo `T`.
    Await(Box<Expr>),
    /// `f(...) catch ...` — se f falhar, trata o erro. Duas formas:
    /// um valor de fallback (`catch 0`) ou um bloco que pode inspecionar o
    /// código do erro (`catch e { ... }`).
    Catch {
        lhs: Box<Expr>,
        handler: CatchHandler,
    },
    /// `spawn f(args)` — roda f em outra thread; devolve o handle (i64).
    /// Os argumentos são copiados para a thread (sem memória compartilhada).
    /// `receiver` presente = `spawn obj.metodo(args)`: o método roda na thread
    /// com `obj` como `this` (despacho estático pelo tipo declarado de `obj`).
    Spawn {
        name: String,
        receiver: Option<Box<Expr>>,
        args: Vec<Expr>,
    },
    /// Acesso a campo de struct: `base.campo`.
    Field {
        base: Box<Expr>,
        field: String,
    },
    /// Struct literal por nome de campo: `{ titulo: e, pontos: e }`.
    /// O tipo concreto é resolvido pelo contexto (parâmetro/retorno).
    /// Também é o que o JSX `<Card .../>` gera para os atributos.
    StructLit {
        fields: Vec<(String, Expr)>,
    },
    /// Array literal: `[a, b, c]` ou `[]`. O tipo do elemento vem do contexto
    /// (anotação/parâmetro/retorno) ou é inferido do primeiro elemento.
    ArrayLit(Vec<Expr>),
    /// Map literal de chave string: `{ "titulo": e, "x": e }` ou `{}`.
    /// O tipo do valor vem do contexto `Map<T>` ou é inferido.
    MapLit(Vec<(String, Expr)>),
    /// Indexação de array: `base[index]` (leitura).
    Index {
        base: Box<Expr>,
        index: Box<Expr>,
    },
    /// `new Classe(args)` — aloca o objeto na arena, instala a vtable e
    /// chama o construtor. O valor é o endereço do objeto.
    New {
        class: String,
        /// Argumentos de tipo explícitos (`new Box<i64>()`) — vazios se omitidos.
        type_args: Vec<Type>,
        args: Vec<Expr>,
    },
    /// `base.metodo(args)` — dispatch dinâmico pela vtable do objeto.
    /// Quando `base` é o nome de uma classe, é chamada de método estático.
    /// Também cobre `valor.campo(args)` quando o campo tem tipo de função.
    MethodCall {
        base: Box<Expr>,
        method: String,
        args: Vec<Expr>,
    },
    /// `super(args)` (construtor do pai) ou `super.metodo(args)` (chamada
    /// direta, sem dispatch — a implementação do pai).
    SuperCall {
        method: Option<String>,
        args: Vec<Expr>,
    },
}

#[derive(Debug, Clone)]
pub enum TemplatePart {
    Lit(String),
    Expr(Expr),
}

/// Um braço de `match`: `pattern [if guarda] => { stmts }` ou `pattern => expr`.
#[derive(Debug, Clone)]
pub struct MatchArm {
    pub pattern: Pattern,
    /// Guarda opcional: `padrão if cond => ...` — só casa se `cond` for verdade.
    pub guard: Option<Expr>,
    pub body: Vec<Stmt>,
}

/// Padrão de um braço de `match`. Os padrões literais comparam por igualdade
/// (string usa comparação de conteúdo); `lo..hi` casa o intervalo `[lo, hi)`;
/// `_` é o curinga e um identificador liga o valor a uma variável (casa tudo).
#[derive(Debug, Clone)]
pub enum Pattern {
    Int(i64),
    Bool(bool),
    Str(String),
    /// `lo..hi` — inteiro no intervalo semiaberto `[lo, hi)`.
    Range(i64, i64),
    Wildcard,
    Binding(String),
    /// `Classe nome` — casa se o tipo de runtime do objeto for exatamente
    /// `Classe` (compara a vtable), ligando `nome` ao objeto já tipado como
    /// `Classe`. `nome == "_"` não liga variável.
    Type { class: String, bind: String },
    /// `{ campo1, campo2 }` — destructuring: liga cada campo do struct/objeto
    /// alvo a uma variável de mesmo nome. Irrefutável (sempre casa).
    Destructure(Vec<String>),
    /// `Enum.Variante` — casa se o valor for essa constante do enum.
    EnumVariant { enum_name: String, variant: String },
}

/// Como um `catch` trata o erro.
#[derive(Debug, Clone)]
pub enum CatchHandler {
    /// `catch valor` — usa esse valor no lugar do resultado falho.
    Fallback(Box<Expr>),
    /// `catch e { ... }` (ou `catch { ... }`) — roda o bloco; `name` (se
    /// houver) liga o código do erro a uma variável i64. O valor do `catch`
    /// é o da última expressão do bloco (ou 0 se a última não for expressão).
    Block {
        name: Option<String>,
        body: Vec<Stmt>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    /// `&&` / `||` — avaliação com curto-circuito (codegen com branch).
    And,
    Or,
    /// bitwise: `&`, `|`, `^`, `<<`, `>>` (shift aritmético com sinal).
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}

impl BinOp {
    /// `true` para operadores cujo resultado é booleano (compara/lógico) —
    /// usado pela inferência de tipo para `let b = a < c`.
    pub fn is_bool_result(self) -> bool {
        matches!(
            self,
            BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Gt | BinOp::Le | BinOp::Ge
                | BinOp::And | BinOp::Or
        )
    }
}

#[derive(Debug, Clone, Copy)]
pub enum UnOp {
    /// `-x` — negação aritmética.
    Neg,
    /// `!x` — negação lógica (resultado bool).
    Not,
    /// `~x` — complemento de bits.
    BitNot,
}
