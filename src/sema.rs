//! Análise semântica: roda entre o parser e o codegen.
//!
//! É aqui que o lex FORÇA a interpretação de erros: uma chamada a função
//! falível (`!`) sem `try` nem `catch` é erro de compilação, não warning.
//! Também rastreia variáveis por escopo (existência, mutabilidade, tipo de
//! função) e valida `spawn`, `join`, arrow functions e `fail`.

use std::collections::{HashMap, HashSet};

use crate::ast::*;
use crate::builtins;
use crate::oop::{self, ClassTable};

/// Um erro de semântica com a posição (opcional) no fonte. Quando o `span`
/// pertence ao arquivo analisado (`module == 0`), o driver o converte em
/// linha/coluna exata; spans sintéticos (`Span::DUMMY`) ou de módulos
/// importados caem na linha 0.
#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub message: String,
    pub span: Span,
}

impl Diagnostic {
    pub fn at(span: Span, message: String) -> Diagnostic {
        Diagnostic { message, span }
    }
    /// Erro sem posição precisa (cai na linha 0 no editor).
    pub fn nospan(message: String) -> Diagnostic {
        Diagnostic { message, span: Span::DUMMY }
    }
}

/// Coletor de diagnósticos. `push` (sem span) mantém os call-sites antigos
/// funcionando — vira um erro sem posição; `at` anexa um span preciso.
#[derive(Default)]
struct Errors(Vec<Diagnostic>);

impl Errors {
    fn new() -> Self {
        Errors(Vec::new())
    }
    /// Erro sem posição (compatível com os `errors.push(format!(...))` antigos).
    fn push(&mut self, message: String) {
        self.0.push(Diagnostic::nospan(message));
    }
    /// Erro apontando um trecho do fonte.
    fn at(&mut self, span: Span, message: String) {
        self.0.push(Diagnostic::at(span, message));
    }
    /// Anexa mensagens sem posição (ex.: erros de hierarquia vindos do `oop`).
    fn extend_nospan(&mut self, msgs: Vec<String>) {
        self.0.extend(msgs.into_iter().map(Diagnostic::nospan));
    }
    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// Coleta os nomes de tipos `Named` referenciados por um tipo (recursivo em
/// array/map/função), para validar que todo tipo nomeado de fato existe.
fn collect_named(ty: &Type, out: &mut Vec<String>) {
    match ty {
        Type::Named(n, args) => {
            out.push(n.clone());
            for a in args {
                collect_named(a, out);
            }
        }
        Type::Array(t) | Type::Map(t) | Type::Chan(t) | Type::Future(t) => collect_named(t, out),
        Type::Fn(ps, r) => {
            for p in ps {
                collect_named(p, out);
            }
            collect_named(r, out);
        }
        _ => {}
    }
}

/// Nome legível de um tipo, para mensagens de erro (`i64[]`, `Map<i64>`, …).
fn ty_str(t: &Type) -> String {
    match t {
        Type::I32 => "i32".into(),
        Type::I64 => "i64".into(),
        Type::I8 => "i8".into(),
        Type::F64 => "f64".into(),
        Type::F32 => "f32".into(),
        Type::Bool => "bool".into(),
        Type::Ptr => "ptr".into(),
        Type::Void => "void".into(),
        Type::Json => "json".into(),
        Type::Any => "any".into(),
        Type::Named(n, args) => {
            if args.is_empty() {
                n.clone()
            } else {
                let a: Vec<String> = args.iter().map(ty_str).collect();
                format!("{}<{}>", n, a.join(", "))
            }
        }
        Type::Array(t) => format!("{}[]", ty_str(t)),
        Type::Map(t) => format!("Map<{}>", ty_str(t)),
        Type::Chan(t) => format!("Channel<{}>", ty_str(t)),
        Type::Future(t) => format!("Future<{}>", ty_str(t)),
        Type::Fn(ps, r) => {
            let ps: Vec<String> = ps.iter().map(ty_str).collect();
            format!("({}) => {}", ps.join(", "), ty_str(r))
        }
    }
}

/// Renderiza uma assinatura `nome(i64, string): tipo!` para mensagens.
fn sig_str(name: &str, params: &[Param], ret: &Type, fallible: bool) -> String {
    let ps: Vec<String> = params.iter().map(|p| ty_str(&p.ty)).collect();
    let ret = if *ret == Type::Void {
        String::new()
    } else {
        format!(": {}", ty_str(ret))
    };
    format!("{}({}){}{}", name, ps.join(", "), ret, if fallible { "!" } else { "" })
}

/// Valida as interfaces e os contratos `implements`.
///
/// Uma interface não tem layout nem vtable própria — é só um contrato. Aqui
/// garantimos que: as assinaturas declaradas usam tipos que existem; toda
/// classe que diz `implements I` tem, para cada método de I, um método de
/// instância público com assinatura IDÊNTICA (próprio ou herdado). Métodos
/// herdados contam: a checagem usa a vtable já resolvida pelo `oop::build`.
fn check_interfaces(
    program: &Program,
    interfaces: &HashMap<String, InterfaceDef>,
    classes: &ClassTable,
    structs: &HashMap<String, StructDef>,
    type_params: &HashSet<String>,
    errors: &mut Errors,
) {
    let named_ok =
        |n: &str| structs.contains_key(n) || classes.contains(n) || type_params.contains(n);

    // assinaturas das interfaces: nomes de tipo válidos, sem método duplicado
    for it in &program.interfaces {
        if program.functions.iter().any(|f| f.name == it.name) {
            errors.at(it.span, format!(
                "'{}' is used both as an interface name and a function name — pick another name",
                it.name
            ));
        }
        let mut seen: HashSet<&str> = HashSet::new();
        for m in &it.methods {
            if !seen.insert(m.name.as_str()) {
                errors.at(m.span, format!(
                    "interface '{}': method '{}' declared more than once",
                    it.name, m.name
                ));
            }
            if m.name == "constructor" {
                errors.at(m.span, format!(
                    "interface '{}': cannot declare a 'constructor' — interfaces only \
                     describe instance methods",
                    it.name
                ));
            }
            let mut refs = Vec::new();
            for p in &m.params {
                collect_named(&p.ty, &mut refs);
            }
            collect_named(&m.ret_type, &mut refs);
            for n in &refs {
                if !named_ok(n) {
                    errors.at(m.span, format!(
                        "interface '{}': method '{}' uses type '{}', which does not exist",
                        it.name, m.name, n
                    ));
                }
            }
        }
    }

    // cada classe cumpre o contrato das interfaces que declara
    for c in &program.classes {
        let mut seen_ifaces: HashSet<&str> = HashSet::new();
        for iname in &c.implements {
            if !seen_ifaces.insert(iname.as_str()) {
                errors.at(c.span, format!(
                    "class '{}': interface '{}' listed more than once in 'implements'",
                    c.name, iname
                ));
                continue;
            }
            let Some(it) = interfaces.get(iname) else {
                let hint = if classes.contains(iname) {
                    format!(" ('{}' is a class — use 'extends' to inherit from it)", iname)
                } else if structs.contains_key(iname) {
                    format!(" ('{}' is a type, not an interface)", iname)
                } else {
                    String::new()
                };
                errors.at(c.span, format!(
                    "class '{}': interface '{}' does not exist{}",
                    c.name, iname, hint
                ));
                continue;
            };
            // a classe já foi resolvida (layout + vtable) pelo oop::build
            let Some(meta) = classes.get(&c.name) else { continue };
            for m in &it.methods {
                let want = sig_str(&m.name, &m.params, &m.ret_type, m.fallible);
                match meta.method(&m.name) {
                    None => {
                        if meta.static_method(&m.name).is_some() {
                            errors.at(c.span, format!(
                                "class '{}' does not satisfy interface '{}': '{}' is static, \
                                 but the interface needs an instance method '{}'",
                                c.name, iname, m.name, want
                            ));
                        } else {
                            errors.at(c.span, format!(
                                "class '{}' does not implement interface '{}': missing method '{}'",
                                c.name, iname, want
                            ));
                        }
                    }
                    Some(cm) => {
                        if cm.private {
                            errors.at(c.span, format!(
                                "class '{}': method '{}' is private, but interface '{}' requires \
                                 it to be public",
                                c.name, m.name, iname
                            ));
                        }
                        let same_sig = cm.params.len() == m.params.len()
                            && cm.params.iter().zip(&m.params).all(|(a, b)| a.ty == b.ty)
                            && cm.ret_type == m.ret_type
                            && cm.fallible == m.fallible;
                        if !same_sig {
                            let got = sig_str(
                                &cm.name,
                                &cm.params,
                                &cm.ret_type,
                                cm.fallible,
                            );
                            errors.at(c.span, format!(
                                "class '{}': method '{}' does not match interface '{}' — \
                                 expected '{}', found '{}'",
                                c.name, m.name, iname, want, got
                            ));
                        }
                    }
                }
            }
        }
    }
}

/// Assinatura mínima de uma função, para validar chamadas.
/// "3 argument(s)" quando a aridade é fixa, "1 to 3 argument(s)" quando há
/// parâmetros opcionais (com valor default).
fn arity_msg(required: usize, total: usize) -> String {
    if required == total {
        format!("{} argument(s)", total)
    } else {
        format!("{} to {} argument(s)", required, total)
    }
}

/// Como `arity_msg`, mas uma assinatura variádica não tem teto: "pelo menos N".
fn arity_msg_v(required: usize, total: usize, variadic: bool) -> String {
    if variadic {
        format!("at least {} argument(s)", required)
    } else {
        arity_msg(required, total)
    }
}

/// Valida as regras de um parâmetro variádico (`...args: T[]`) numa lista:
/// só é permitido onde `allowed`, tem de ser o último e ter tipo array.
fn check_variadic_params(label: &str, params: &[Param], allowed: bool, errors: &mut Errors) {
    let n = params.len();
    for (i, p) in params.iter().enumerate() {
        if !p.variadic {
            continue;
        }
        if !allowed {
            errors.push(format!("{}: a variadic parameter ('...') is not allowed here", label));
        }
        if i != n - 1 {
            errors.push(format!(
                "{}: the variadic parameter '...{}' must be the last one",
                label, p.name
            ));
        }
        if !matches!(p.ty, Type::Array(_)) {
            errors.push(format!(
                "{}: variadic parameter '{}' must have an array type, e.g. 'any[]' (found {})",
                label,
                p.name,
                ty_str(&p.ty)
            ));
        }
    }
}

struct FnSig {
    fallible: bool,
    n_params: usize,
    /// Argumentos obrigatórios (os demais têm valor default).
    required: usize,
    /// Assinatura termina em parâmetro variádico (`...args`) — aridade sem teto.
    variadic: bool,
    ret_type: Type,
    /// Tipos dos parâmetros, para validar struct literals passados como args.
    params: Vec<Type>,
    /// Parâmetros de tipo (`fn id<T>`) — para substituir na inferência.
    type_params: Vec<String>,
    /// `async fn` — a chamada devolve `Future<ret>`.
    is_async: bool,
}

/// O que o sema sabe sobre uma variável declarada.
#[derive(Clone)]
struct VarInfo {
    /// Tipo anotado (None = inferido do contexto, sempre inteiro).
    ty: Option<Type>,
    mutable: bool,
}

/// Símbolos que o codegen declara por conta própria com assinaturas fixas —
/// redefini-los (ou redeclarar via extern) conflitaria com o IR gerado.
const INTERNAL: &[&str] = &["printf", "dprintf", "pthread_create", "pthread_join", "pthread_detach"];

pub fn check(program: &mut Program) -> Result<(), Vec<Diagnostic>> {
    let mut errors = Errors::new();
    let mut sigs: HashMap<String, FnSig> = HashMap::new();

    // structs: registro + validação de nomes duplicados
    let mut structs: HashMap<String, StructDef> = HashMap::new();
    for s in &program.structs {
        if structs.contains_key(&s.name) {
            errors.at(s.span, format!("type '{}' defined more than once", s.name));
        }
        structs.insert(s.name.clone(), s.clone());
    }

    // interfaces: contratos de assinatura (sem layout, não geram código)
    let mut interfaces: HashMap<String, InterfaceDef> = HashMap::new();
    for it in &program.interfaces {
        if interfaces.contains_key(&it.name) {
            errors.at(it.span, format!("interface '{}' defined more than once", it.name));
        } else if structs.contains_key(&it.name) {
            errors.at(it.span, format!(
                "'{}' is defined both as a type and as an interface — pick one",
                it.name
            ));
        }
        interfaces.insert(it.name.clone(), it.clone());
    }

    // classes: hierarquia (herança, vtable, overrides) validada pelo oop
    let (classes, cerrs) = oop::build(&program.classes);
    errors.extend_nospan(cerrs);
    for c in &program.classes {
        if structs.contains_key(&c.name) {
            errors.at(c.span, format!(
                "'{}' is defined both as a type and as a class — pick one",
                c.name
            ));
        }
        if interfaces.contains_key(&c.name) {
            errors.at(c.span, format!(
                "'{}' is defined both as a class and as an interface — pick one",
                c.name
            ));
        }
        if program.functions.iter().any(|f| f.name == c.name) {
            errors.at(c.span, format!(
                "'{}' is used both as a class name and a function name — pick another name",
                c.name
            ));
        }
    }

    // enums: cada um vira um conjunto de constantes inteiras nomeadas. O nome
    // do enum é um tipo de valor (inteiro); `Enum.Variante` resolve a constante.
    let mut enums: HashMap<String, Vec<String>> = HashMap::new();
    for e in &program.enums {
        if enums.contains_key(&e.name)
            || structs.contains_key(&e.name)
            || classes.contains(&e.name)
            || interfaces.contains_key(&e.name)
        {
            errors.at(e.span, format!("'{}' is already defined — pick another name", e.name));
        }
        let mut seen = HashSet::new();
        for v in &e.variants {
            if !seen.insert(v.clone()) {
                errors.at(e.span, format!("enum '{}': variant '{}' listed more than once", e.name, v));
            }
        }
        enums.insert(e.name.clone(), e.variants.clone());
    }

    // parâmetros de tipo declarados em qualquer função/classe genérica. Com
    // type erasure, `T` é um tipo válido (vira i64 no codegen). Coletados num
    // conjunto global e aceitos como tipo nomeado em qualquer lugar — solução
    // simples (não há escopo por declaração), suficiente para a erasure.
    let mut type_params: HashSet<String> = HashSet::new();
    for f in &program.functions {
        for tp in &f.type_params {
            type_params.insert(tp.clone());
        }
    }
    for c in &program.classes {
        for tp in &c.type_params {
            type_params.insert(tp.clone());
        }
    }

    // todo tipo nomeado referenciado num campo precisa existir (struct ou classe).
    // Um nome de interface NÃO é um tipo de valor: só vale com `implements`.
    let named_ok = |n: &str| {
        structs.contains_key(n)
            || classes.contains(n)
            || type_params.contains(n)
            || enums.contains_key(n)
    };
    // Frase que encaixa depois de "... uses ": "type 'X', which does not exist"
    // ou "'I', which is an interface, not a value type — ...".
    let missing_type = |n: &str| -> String {
        if interfaces.contains_key(n) {
            format!(
                "'{}', which is an interface, not a value type — an interface only \
                 works with 'class ... implements {}'",
                n, n
            )
        } else {
            format!("type '{}', which does not exist", n)
        }
    };
    for s in &program.structs {
        for (fname, fty) in &s.fields {
            let mut refs = Vec::new();
            collect_named(fty, &mut refs);
            for n in &refs {
                if !named_ok(n) {
                    errors.at(s.span, format!(
                        "type '{}': field '{}' uses {}",
                        s.name, fname, missing_type(n)
                    ));
                }
            }
        }
    }
    for c in &program.classes {
        for f in &c.fields {
            let mut refs = Vec::new();
            collect_named(&f.ty, &mut refs);
            for n in &refs {
                if !named_ok(n) {
                    errors.at(f.span, format!(
                        "class '{}': field '{}' uses {}",
                        c.name, f.name, missing_type(n)
                    ));
                }
            }
            if f.ty == Type::Void {
                errors.at(f.span, format!(
                    "class '{}': field '{}' cannot be void",
                    c.name, f.name
                ));
            }
        }
    }

    // interfaces + implements: cada método declarado precisa de tipos válidos,
    // e toda classe que diz `implements I` tem de cumprir o contrato de I.
    check_interfaces(program, &interfaces, &classes, &structs, &type_params, &mut errors);
    // interface só declara assinatura — sem variádico no contrato (por ora)
    for it in &program.interfaces {
        for m in &it.methods {
            check_variadic_params(
                &format!("interface '{}': method '{}'", it.name, m.name),
                &m.params,
                false,
                &mut errors,
            );
        }
    }

    for f in &program.functions {
        if builtins::is_builtin(&f.name) {
            errors.at(f.span, format!("'{}' is a name reserved by the language", f.name));
        }
        if INTERNAL.contains(&f.name.as_str()) || f.name.starts_with("__lex_") {
            errors.at(f.span, format!(
                "'{}' is used internally by the compiler — pick another name",
                f.name
            ));
        }
        if sigs.contains_key(&f.name) {
            errors.at(f.span, format!("function '{}' defined more than once", f.name));
        }
        // variádico vale em `function`, não em `declare` (FFI tem ABI fixo).
        let kind = if f.external { "declare function" } else { "function" };
        check_variadic_params(&format!("{} '{}'", kind, f.name), &f.params, !f.external, &mut errors);
        sigs.insert(
            f.name.clone(),
            FnSig {
                fallible: f.fallible,
                n_params: f.params.len(),
                required: required_arity(&f.params),
                variadic: is_variadic(&f.params),
                ret_type: f.ret_type.clone(),
                params: f.params.iter().map(|p| p.ty.clone()).collect(),
                type_params: f.type_params.clone(),
                is_async: f.is_async,
            },
        );
        if f.is_async && f.fallible {
            errors.at(f.span, format!(
                "'{}': an async function cannot be fallible — handle errors inside it \
                 (an error in another thread has no caller to catch it)",
                f.name
            ));
        }
        if f.is_async && is_variadic(&f.params) {
            errors.at(f.span, format!(
                "'{}': an async function cannot be variadic — wrap a fixed call",
                f.name
            ));
        }
        // main PODE ser falível: o codegen gera um embrulho que imprime o
        // erro não tratado e sai com exit code != 0 (padrão Rust/Zig).
    }

    // INFERÊNCIA DE TIPO DE RETORNO (estilo Hindley-Milner): funções sem `: T`
    // têm o retorno inferido do corpo. Reusa `infer_type` (que já resolve
    // variáveis, chamadas, genéricos, campos, etc.) num ponto-fixo: o retorno
    // de uma função inferida pode depender de outra (recursão mútua), então
    // iteramos até estabilizar. Roda ANTES das unidades, então `sigs`, os
    // métodos e o codegen veem o tipo concreto. Preenche `program.functions`.
    infer_return_types(program, &mut sigs, &structs, &interfaces, &classes, &enums, &type_params);

    // unidades de checagem: funções de topo + métodos desugarados (o corpo
    // de um método é checado como função com `this` de primeiro parâmetro)
    let mut units: Vec<(Function, Option<String>)> = program
        .functions
        .iter()
        .map(|f| (f.clone(), None))
        .collect();
    for c in &program.classes {
        // inicializadores dos campos static viram uma "unidade" sintética:
        // cada um é checado como um `let nome: tipo = init` no escopo da classe
        // (sem `this` — init estático não vê instância).
        if !c.statics.is_empty() {
            let body: Vec<Stmt> = c
                .statics
                .iter()
                .map(|sf| Stmt {
                    kind: StmtKind::Let {
                        name: sf.name.clone(),
                        ty: Some(sf.ty.clone()),
                        value: sf.init.clone(),
                        mutable: false,
                    },
                    // erros do init estático apontam o campo `static`
                    span: sf.span,
                })
                .collect();
            let synth = Function {
                name: format!("{}.<static-init>", c.name),
                is_async: false,
                type_params: c.type_params.clone(),
                params: Vec::new(),
                ret_type: Type::Void,
                fallible: false,
                external: false,
                body,
                span: c.span,
                ret_inferred: false,
            };
            units.push((synth, Some(c.name.clone())));
        }
        for m in &c.methods {
            units.push((oop::method_fn(&c.name, m), Some(c.name.clone())));

            // variádico vale em método (estático ou de instância), não no
            // construtor (o `new` tem um caminho de chamada próprio).
            let allowed = m.name != "constructor";
            check_variadic_params(
                &format!("class '{}': method '{}'", c.name, m.name),
                &m.params,
                allowed,
                &mut errors,
            );

            // construtor de classe filha precisa inicializar o pai
            if m.name == "constructor" {
                let parent_ctor = c
                    .parent
                    .as_ref()
                    .and_then(|p| classes.get(p))
                    .and_then(|p| p.ctor.as_ref());
                if parent_ctor.is_some() && !calls_super(&m.body) {
                    errors.push(format!(
                        "the constructor of '{}' must call 'super(...)': the superclass \
                         '{}' has a constructor and its fields would be left uninitialized",
                        c.name,
                        c.parent.as_deref().unwrap_or("?")
                    ));
                }
            }
        }
    }

    // Capturas das arrows, registradas no site de uso (no escopo de fora) e
    // lidas ao checar o corpo da lambda. Por isso a ordem: unidades não-lambda
    // primeiro, depois as lambdas em ordem DECRESCENTE de criação (externa
    // antes da interna), garantindo que o site de uso já rodou.
    let mut lambda_caps: HashMap<String, Vec<(String, Type)>> = HashMap::new();
    let mut order: Vec<usize> =
        (0..units.len()).filter(|&i| !units[i].0.name.starts_with("__lambda_")).collect();
    let mut lams: Vec<usize> =
        (0..units.len()).filter(|&i| units[i].0.name.starts_with("__lambda_")).collect();
    lams.reverse();
    order.extend(lams);

    for idx in order {
        let (f, cls) = &units[idx];
        if f.fallible && f.ret_type == Type::Void {
            errors.push(format!(
                "'{}': a void function cannot be fallible (yet) — return i64",
                f.name
            ));
        }
        if cls.is_none() && f.name == "main" && f.ret_type == Type::Void {
            errors.push("main must return i32 (it becomes the process exit code)".to_string());
        }
        // Não exigimos return em todo caminho: cair no fim de uma função
        // (ou um `return;` vazio) equivale a `return 0` — o valor padrão.

        // a assinatura só pode usar tipos de valor que existem (struct/classe).
        // Uma interface NÃO é tipo de valor: serve só para `implements`.
        {
            let mut refs = Vec::new();
            collect_named(&f.ret_type, &mut refs);
            for p in &f.params {
                collect_named(&p.ty, &mut refs);
            }
            for n in &refs {
                if !named_ok(n) {
                    errors.push(format!("'{}': signature uses {}", f.name, missing_type(n)));
                }
            }
        }

        // escopo inicial: os parâmetros (mutáveis, como no TS)
        let mut params = HashMap::new();
        for p in &f.params {
            if p.ty == Type::Void {
                errors.push(format!(
                    "'{}': parameter '{}' cannot be void",
                    f.name, p.name
                ));
            }
            params.insert(
                p.name.clone(),
                VarInfo { ty: Some(p.ty.clone()), mutable: p.name != "this" },
            );
        }
        // corpo de uma arrow: semeia as variáveis capturadas (registradas no
        // site de uso) para que o corpo as enxergue com o tipo certo.
        if f.name.starts_with("__lambda_") {
            if let Some(caps) = lambda_caps.get(&f.name) {
                for (name, ty) in caps {
                    params.insert(
                        name.clone(),
                        VarInfo { ty: Some(ty.clone()), mutable: true },
                    );
                }
            }
        }
        let in_ctor = cls.is_some() && f.name.ends_with(".constructor");
        let mut cx = Ctx {
            sigs: &sigs,
            structs: &structs,
            interfaces: &interfaces,
            classes: &classes,
            enums: &enums,
            lambda_caps: &mut lambda_caps,
            fun: f,
            cur_class: cls.clone(),
            in_ctor,
            type_params: &type_params,
            loop_depth: 0,
            errors: &mut errors,
            cur_span: f.span,
            scopes: vec![params],
        };
        for s in &f.body {
            cx.check_stmt(s);
        }
    }

    if errors.is_empty() { Ok(()) } else { Err(errors.0) }
}

/// Inferência do tipo de retorno (estilo HM) para funções sem anotação.
/// Reusa `Ctx::infer_type` num ponto-fixo (cobre recursão mútua): cada passada
/// reinfere os retornos com os `sigs` atuais até estabilizar. Atualiza tanto
/// `program.functions[i].ret_type` quanto o `sigs` (para chamadas e codegen).
#[allow(clippy::too_many_arguments)]
fn infer_return_types(
    program: &mut Program,
    sigs: &mut HashMap<String, FnSig>,
    structs: &HashMap<String, StructDef>,
    interfaces: &HashMap<String, InterfaceDef>,
    classes: &ClassTable,
    enums: &HashMap<String, Vec<String>>,
    type_params: &HashSet<String>,
) {
    if !program.functions.iter().any(|f| f.ret_inferred) {
        return;
    }
    // função-fantoche só para preencher o `Ctx` (infer_type não a consulta).
    let dummy = Function {
        name: String::new(),
        is_async: false,
        type_params: Vec::new(),
        params: Vec::new(),
        ret_type: Type::Void,
        fallible: false,
        external: false,
        body: Vec::new(),
        span: Span::DUMMY,
        ret_inferred: false,
    };
    // ponto-fixo com teto (converge em poucas passadas; o teto evita laço).
    for _ in 0..8 {
        let mut updates: Vec<(usize, Type)> = Vec::new();
        {
            let mut scratch_caps: HashMap<String, Vec<(String, Type)>> = HashMap::new();
            let mut scratch_errs = Errors::new();
            let mut cx = Ctx {
                sigs: &*sigs,
                structs,
                interfaces,
                classes,
                enums,
                lambda_caps: &mut scratch_caps,
                type_params,
                fun: &dummy,
                cur_class: None,
                in_ctor: false,
                loop_depth: 0,
                errors: &mut scratch_errs,
                cur_span: Span::DUMMY,
                scopes: Vec::new(),
            };
            for (i, f) in program.functions.iter().enumerate() {
                if !f.ret_inferred {
                    continue;
                }
                // os parâmetros entram no escopo para inferir expressões que os usam
                let mut scope: HashMap<String, VarInfo> = HashMap::new();
                for p in &f.params {
                    scope.insert(
                        p.name.clone(),
                        VarInfo { ty: Some(p.ty.clone()), mutable: true },
                    );
                }
                cx.scopes = vec![scope];

                let mut rets: Vec<&Expr> = Vec::new();
                collect_return_exprs(&f.body, &mut rets);
                let mut inferred: Option<Type> = None;
                for e in rets {
                    // literais inteiros e expressões que o inferidor não resolve
                    // caem na célula universal i64 (correto p/ retornos inteiros).
                    let t = cx.infer_type(e).unwrap_or(Type::I64);
                    inferred = Some(join_ret_type(inferred, t));
                }
                // sem `return <valor>` → a função é void.
                let new_ret = inferred.unwrap_or(Type::Void);
                if new_ret != f.ret_type {
                    updates.push((i, new_ret));
                }
            }
        }
        if updates.is_empty() {
            break;
        }
        for (i, t) in updates {
            program.functions[i].ret_type = t.clone();
            let name = program.functions[i].name.clone();
            if let Some(sig) = sigs.get_mut(&name) {
                sig.ret_type = t;
            }
        }
    }
}

/// Coleta as expressões de `return <valor>` num corpo, descendo nos blocos
/// aninhados (if/while/for/defer, braços de match e blocos de catch). Não entra
/// em closures (que são funções próprias com retorno separado).
fn collect_return_exprs<'a>(body: &'a [Stmt], out: &mut Vec<&'a Expr>) {
    for s in body {
        match &s.kind {
            StmtKind::Return(Some(e)) => out.push(e),
            StmtKind::If { then_body, else_body, .. } => {
                collect_return_exprs(then_body, out);
                collect_return_exprs(else_body, out);
            }
            StmtKind::While { body, .. } | StmtKind::ForOf { body, .. } => {
                collect_return_exprs(body, out)
            }
            StmtKind::For { body, .. } => collect_return_exprs(body, out),
            StmtKind::Defer(inner) => collect_return_exprs(std::slice::from_ref(inner), out),
            StmtKind::Expr(Expr::Match { arms, .. }) => {
                for a in arms {
                    collect_return_exprs(&a.body, out);
                }
            }
            StmtKind::Expr(Expr::Catch { handler: CatchHandler::Block { body, .. }, .. }) => {
                collect_return_exprs(body, out)
            }
            _ => {}
        }
    }
}

/// Junta os tipos de dois `return` para o retorno inferido: tipos numéricos
/// promovem para o mais largo (bool < i8 < i32 < i64 < f32 < f64); tipos não
/// numéricos divergentes mantêm o primeiro (best-effort — anote se precisar).
fn join_ret_type(acc: Option<Type>, t: Type) -> Type {
    let Some(a) = acc else { return t };
    if a == t {
        return a;
    }
    let rank = |ty: &Type| match ty {
        Type::Bool => Some(0u8),
        Type::I8 => Some(1),
        Type::I32 => Some(2),
        Type::I64 => Some(3),
        Type::F32 => Some(4),
        Type::F64 => Some(5),
        _ => None,
    };
    match (rank(&a), rank(&t)) {
        (Some(ra), Some(rt)) => {
            if ra >= rt {
                a
            } else {
                t
            }
        }
        _ => a,
    }
}

/// O corpo chama `super(...)` em algum statement? (busca rasa + if/while,
/// suficiente para validar a inicialização da superclasse)
fn calls_super(body: &[Stmt]) -> bool {
    body.iter().any(|s| match &s.kind {
        StmtKind::Expr(Expr::SuperCall { method: None, .. }) => true,
        StmtKind::If { then_body, else_body, .. } => {
            calls_super(then_body) || calls_super(else_body)
        }
        StmtKind::While { body, .. } => calls_super(body),
        _ => false,
    })
}

struct Ctx<'a> {
    sigs: &'a HashMap<String, FnSig>,
    structs: &'a HashMap<String, StructDef>,
    /// Só para diagnóstico: avisar que um nome de interface não é tipo de valor.
    interfaces: &'a HashMap<String, InterfaceDef>,
    classes: &'a ClassTable,
    /// Enums declarados: nome → variantes (na ordem = valor inteiro).
    enums: &'a HashMap<String, Vec<String>>,
    /// Capturas de cada lambda (`__lambda_N` → [(var, tipo)]), registradas no
    /// site de uso e usadas para semear o escopo ao checar o corpo da lambda.
    lambda_caps: &'a mut HashMap<String, Vec<(String, Type)>>,
    /// Parâmetros de tipo válidos (genéricos) — aceitos como tipo nomeado.
    type_params: &'a HashSet<String>,
    fun: &'a Function,
    /// Classe do método sendo checado (None em função de topo).
    cur_class: Option<String>,
    in_ctor: bool,
    /// Profundidade de laços aninhados — `break`/`continue` exigem > 0.
    loop_depth: usize,
    errors: &'a mut Errors,
    /// Span do statement sendo checado — anexado aos erros do corpo para o
    /// editor apontar a linha/coluna exata. Começa no nome da função.
    cur_span: Span,
    /// Pilha de escopos: cada if/while empilha um novo.
    scopes: Vec<HashMap<String, VarInfo>>,
}

impl Ctx<'_> {
    fn err(&mut self, msg: String) {
        let onde = if self.fun.name.starts_with("__lambda") {
            "in an arrow function".to_string()
        } else {
            format!("in '{}'", self.fun.name)
        };
        self.errors.at(self.cur_span, format!("{}: {}", onde, msg));
    }

    fn lookup_var(&self, name: &str) -> Option<&VarInfo> {
        self.scopes.iter().rev().find_map(|s| s.get(name))
    }

    /// Todo tipo `Named` numa anotação tem de ser um tipo de valor existente
    /// (struct ou classe). Um nome de interface chega aqui como `Named`, mas
    /// não é tipo de valor — só vale com `implements`.
    fn check_named_exists(&mut self, ty: &Type) {
        let mut refs = Vec::new();
        collect_named(ty, &mut refs);
        for n in &refs {
            if self.structs.contains_key(n)
                || self.classes.contains(n)
                || self.type_params.contains(n)
                || self.enums.contains_key(n)
            {
                continue;
            }
            if self.interfaces.contains_key(n) {
                self.err(format!(
                    "'{}' is an interface, not a value type — an interface only works \
                     with 'class ... implements {}'",
                    n, n
                ));
            } else {
                self.err(format!("type '{}' does not exist", n));
            }
        }
    }

    fn declare_var(&mut self, name: &str, ty: Option<Type>, mutable: bool) {
        self.scopes
            .last_mut()
            .unwrap()
            .insert(name.to_string(), VarInfo { ty, mutable });
    }

    fn check_block(&mut self, body: &[Stmt]) {
        self.scopes.push(HashMap::new());
        for s in body {
            self.check_stmt(s);
        }
        self.scopes.pop();
    }

    fn check_stmt(&mut self, stmt: &Stmt) {
        // os erros do corpo passam a apontar o statement atual; nós sintéticos
        // (DUMMY) não sobrescrevem o span herdado (ex.: o da função).
        if stmt.span != Span::DUMMY {
            self.cur_span = stmt.span;
        }
        match &stmt.kind {
            StmtKind::Let { name, ty, value, mutable } => {
                self.check_expr(value);

                if builtins::is_builtin(name) {
                    self.err(format!("'{}' is a name reserved by the language", name));
                }
                if name == "this" {
                    self.err("'this' is reserved — it cannot be a variable name".to_string());
                }
                if *ty == Some(Type::Void) {
                    self.err(format!("variable '{}' cannot be void", name));
                }
                if let Some(t) = ty {
                    self.check_named_exists(t);
                }

                // struct literal não instancia classe — isso é papel do new
                if let (Some(Type::Named(n, _)), Expr::StructLit { .. }) = (ty, value) {
                    if self.classes.contains(n) {
                        self.err(format!(
                            "'{}' is a class: instantiate it with new {}(...), \
                             not with a struct literal",
                            n, n
                        ));
                    }
                }

                // valor de função exige anotação de tipo de função: sem ela o
                // endereço seria tratado como inteiro do contexto (e truncado
                // se o contexto for i32).
                if let Expr::Var(vname) = value {
                    let referencia_funcao =
                        self.lookup_var(vname).is_none() && self.sigs.contains_key(vname);
                    if referencia_funcao && !matches!(ty, Some(Type::Fn(..))) {
                        self.err(format!(
                            "'{}' holds a function: annotate the type, e.g.: \
                             const {}: (i64) => i64 = ...",
                            name, name
                        ));
                    }
                }

                // com anotação de struct, valida os campos do struct literal
                if let Some(t) = ty {
                    self.propagate(t, value);
                }

                // sem anotação, guarda o tipo inferido do valor (é o que faz
                // `const p = new Pessoa(...)` enxergar campos e métodos)
                let vty = ty.clone().or_else(|| self.infer_type(value));
                self.declare_var(name, vty, *mutable);
            }

            StmtKind::Assign { name, value } => {
                if name == "this" {
                    self.err("cannot reassign 'this'".to_string());
                } else {
                    match self.lookup_var(name).cloned() {
                        Some(info) => {
                            if !info.mutable {
                                self.err(format!(
                                    "cannot reassign '{}': it was declared with 'const' — use 'let'",
                                    name
                                ));
                            }
                        }
                        None => {
                            if self.sigs.contains_key(name) {
                                self.err(format!("cannot reassign function '{}'", name));
                            } else {
                                self.err(format!("undefined variable: '{}'", name));
                            }
                        }
                    }
                }
                self.check_expr(value);
            }

            // `base.campo = expr` — objeto, struct ou campo estático de classe
            StmtKind::FieldAssign { base, field, value } => {
                // `Classe.campoEstatico = v` — escrita no estado da classe.
                if let Some(cls) = self.static_base_class(base) {
                    self.check_expr(value);
                    match self.classes.get(&cls).and_then(|m| m.static_field(field).cloned()) {
                        None => self.err(format!(
                            "class '{}' has no static field '{}'",
                            cls, field
                        )),
                        Some(sf) => {
                            if sf.private && self.cur_class.as_deref() != Some(sf.owner.as_str()) {
                                self.err(format!(
                                    "static field '{}.{}' is private to '{}'",
                                    cls, field, sf.owner
                                ));
                            }
                        }
                    }
                    return;
                }
                self.check_expr(base);
                self.check_expr(value);
                // tipo da base desconhecido: deixa passar (best-effort,
                // mesma postura do acesso de leitura)
                if let Some(Type::Named(tname, _)) = self.infer_type(base) {
                    if let Some(meta) = self.classes.get(&tname) {
                        match meta.slot(field) {
                            None => {
                                if meta.method(field).is_some() {
                                    self.err(format!(
                                        "'{}' is a method of '{}', not a field — \
                                         methods cannot be reassigned",
                                        field, tname
                                    ));
                                } else {
                                    self.err(format!(
                                        "class '{}' has no field '{}'",
                                        tname, field
                                    ));
                                }
                            }
                            Some((_, f)) => {
                                let f = f.clone();
                                self.check_private_field(&f);
                            }
                        }
                    } else if let Some(def) = self.structs.get(&tname) {
                        if !def.fields.iter().any(|(n, _)| n == field) {
                            self.err(format!(
                                "type '{}' has no field '{}'",
                                tname, field
                            ));
                        }
                    }
                }
            }

            // `base[i] = expr` — atribuição por índice (array)
            StmtKind::IndexAssign { base, index, value } => {
                self.check_expr(base);
                self.check_expr(index);
                self.check_expr(value);
                match self.infer_type(base) {
                    Some(Type::Array(_)) | Some(Type::Map(_)) | None => {}
                    Some(_) => self.err(
                        "index assignment 'base[i] = v' works on arrays and maps".to_string(),
                    ),
                }
            }

            StmtKind::While { cond, body } => {
                self.check_expr(cond);
                self.loop_depth += 1;
                self.check_block(body);
                self.loop_depth -= 1;
            }

            // for (init; cond; update) { ... } — init/cond/update e o corpo
            // compartilham um escopo: a variável do init é visível no corpo.
            StmtKind::For { init, cond, update, body } => {
                self.scopes.push(HashMap::new());
                if let Some(i) = init {
                    self.check_stmt(i);
                }
                if let Some(c) = cond {
                    self.check_expr(c);
                }
                if let Some(u) = update {
                    self.check_stmt(u);
                }
                self.loop_depth += 1;
                for s in body {
                    self.check_stmt(s);
                }
                self.loop_depth -= 1;
                self.scopes.pop();
            }

            // for (const x of arr) { ... } — só itera arrays
            StmtKind::ForOf { name, mutable, iterable, body } => {
                self.check_expr(iterable);
                let elem_ty = match self.infer_type(iterable) {
                    Some(Type::Array(t)) => Some(*t),
                    Some(other) => {
                        self.err(format!(
                            "'for...of' only iterates over arrays (found {})",
                            ty_str(&other)
                        ));
                        None
                    }
                    None => None,
                };
                if builtins::is_builtin(name) || name == "this" {
                    self.err(format!("'{}' is a reserved name", name));
                }
                self.scopes.push(HashMap::new());
                self.declare_var(name, elem_ty, *mutable);
                self.loop_depth += 1;
                for s in body {
                    self.check_stmt(s);
                }
                self.loop_depth -= 1;
                self.scopes.pop();
            }

            StmtKind::Break => {
                if self.loop_depth == 0 {
                    self.err("'break' can only appear inside a loop ('while'/'for')".to_string());
                }
            }
            StmtKind::Continue => {
                if self.loop_depth == 0 {
                    self.err(
                        "'continue' can only appear inside a loop ('while'/'for')".to_string(),
                    );
                }
            }

            // `return;` vazio (None): em função não-void equivale a `return 0`
            StmtKind::Return(value) => {
                if let Some(e) = value {
                    if self.fun.ret_type == Type::Void {
                        self.err(
                            "this function is void (returns no value) — use 'return;' without a value"
                                .to_string(),
                        );
                    }
                    self.check_expr(e);
                    let rt = self.fun.ret_type.clone();
                    self.propagate(&rt, e);
                }
            }

            StmtKind::Expr(e) => {
                // `f() catch v;` solto (forma de valor): o valor é jogado fora,
                // ou seja, o erro seria silenciado fingindo tratamento — recusa.
                // A forma em bloco (`catch e { ... }`) trata de fato o erro, então
                // é permitida como statement.
                if let Expr::Catch { handler: CatchHandler::Fallback(_), .. } = e {
                    self.err(
                        "the value of the 'catch' is being discarded — that would silence the error; \
                         store the result (const x = f() catch v), handle it with \
                         'f(...) catch e { ... }', or use 'try f(...)'"
                            .to_string(),
                    );
                }
                self.check_expr(e);
            }

            // `defer stmt;` — agenda o stmt para a saída da função. O corpo
            // não pode redirecionar o fluxo (return/fail) nem aninhar defer.
            StmtKind::Defer(inner) => {
                match &inner.kind {
                    StmtKind::Return(_) | StmtKind::Fail(_) => self.err(
                        "a 'defer' cannot 'return' or 'fail' — it runs on the way out".to_string(),
                    ),
                    StmtKind::Defer(_) => {
                        self.err("a 'defer' cannot contain another 'defer'".to_string())
                    }
                    _ => self.check_stmt(inner),
                }
            }

            StmtKind::Fail(code) => {
                if !self.fun.fallible {
                    self.err(
                        "'fail' can only appear in a fallible function — mark the return type with '!'"
                            .to_string(),
                    );
                }
                if let Expr::Int(0) = code {
                    self.err("the error code must be different from 0 (0 means success)".to_string());
                }
                self.check_expr(code);
            }

            StmtKind::If { cond, then_body, else_body } => {
                self.check_expr(cond);
                self.check_block(then_body);
                self.check_block(else_body);
            }
        }
    }

    fn check_expr(&mut self, expr: &Expr) {
        match expr {
            Expr::Int(_) | Expr::Float(_) | Expr::Str(_) | Expr::Bool(_) => {}

            // valor de arrow function: as candidatas a captura que forem
            // variáveis locais do escopo viram capturas (por valor, com o tipo
            // de agora); as globais (funções/classes/enums/builtins) são
            // ignoradas; qualquer outra é variável inexistente.
            Expr::Closure { name, captures } => {
                let mut real: Vec<(String, Type)> = Vec::new();
                for c in captures {
                    if let Some(info) = self.lookup_var(c) {
                        real.push((c.clone(), info.ty.clone().unwrap_or(Type::I64)));
                    } else if self.sigs.contains_key(c)
                        || self.classes.contains(c)
                        || self.enums.contains_key(c)
                        || builtins::is_builtin(c)
                    {
                        // global: não é captura
                    } else {
                        self.err(format!(
                            "undefined variable '{}' used by the arrow function",
                            c
                        ));
                    }
                }
                self.lambda_caps.insert(name.clone(), real);
            }

            Expr::Template(parts) => {
                for p in parts {
                    if let TemplatePart::Expr(e) = p {
                        self.check_expr(e);
                    }
                }
            }

            Expr::Var(name) => {
                if self.lookup_var(name).is_some() {
                    return;
                }
                // não é variável: pode ser uma função usada como valor
                match self.sigs.get(name) {
                    Some(sig) => {
                        if sig.fallible {
                            self.err(format!(
                                "fallible function '{}' cannot be used as a value (yet)",
                                name
                            ));
                        }
                    }
                    None => {
                        if builtins::is_builtin(name) {
                            self.err(format!("'{}' cannot be used as a value", name));
                        } else if self.classes.contains(name) {
                            self.err(format!(
                                "class '{}' cannot be used as a value — \
                                 instantiate it with new {}(...) or call a static method",
                                name, name
                            ));
                        } else if name == "this" {
                            self.err(
                                "'this' only exists inside a class method (static \
                                 methods have no 'this')"
                                    .to_string(),
                            );
                        } else {
                            self.err(format!("undefined variable: '{}'", name));
                        }
                    }
                }
            }

            Expr::Binary { lhs, rhs, .. } => {
                self.check_expr(lhs);
                self.check_expr(rhs);
            }

            Expr::Unary { operand, .. } => {
                self.check_expr(operand);
            }

            // await fut — espera o Future resolver (join)
            Expr::Await(inner) => self.check_expr(inner),

            // match (expr) { padrão [if guarda] => corpo } — cada braço roda em
            // escopo próprio; um padrão de binding liga o valor a uma variável.
            Expr::Match { scrutinee, arms } => {
                self.check_expr(scrutinee);
                let sty = self.infer_type(scrutinee);
                for arm in arms {
                    self.scopes.push(HashMap::new());
                    match &arm.pattern {
                        Pattern::Binding(n) => {
                            if builtins::is_builtin(n) || n == "this" {
                                self.err(format!("'{}' is a reserved name", n));
                            }
                            self.declare_var(n, sty.clone(), false);
                        }
                        Pattern::Type { class, bind } => {
                            if !self.classes.contains(class) {
                                self.err(format!(
                                    "match: '{}' is not a class — type patterns match a class instance",
                                    class
                                ));
                            }
                            if bind != "_" {
                                self.declare_var(
                                    bind,
                                    Some(Type::Named(class.clone(), Vec::new())),
                                    false,
                                );
                            }
                        }
                        Pattern::EnumVariant { enum_name, variant } => {
                            match self.enums.get(enum_name) {
                                None => self.err(format!(
                                    "match: '{}' is not an enum",
                                    enum_name
                                )),
                                Some(vs) if !vs.iter().any(|v| v == variant) => self.err(format!(
                                    "enum '{}' has no variant '{}'",
                                    enum_name, variant
                                )),
                                _ => {}
                            }
                        }
                        Pattern::Destructure(names) => {
                            // o alvo tem de ser um struct/classe; cada nome liga
                            // o campo correspondente.
                            for n in names {
                                let fty = match &sty {
                                    Some(Type::Named(tn, _)) => self
                                        .classes
                                        .get(tn)
                                        .and_then(|m| m.slot(n).map(|(_, f)| f.ty.clone()))
                                        .or_else(|| {
                                            self.structs.get(tn).and_then(|d| {
                                                d.fields
                                                    .iter()
                                                    .find(|(fn_, _)| fn_ == n)
                                                    .map(|(_, t)| t.clone())
                                            })
                                        }),
                                    _ => None,
                                };
                                if fty.is_none() {
                                    self.err(format!(
                                        "match: cannot destructure field '{}' — the value is not a \
                                         struct/object with that field",
                                        n
                                    ));
                                }
                                self.declare_var(n, fty, false);
                            }
                        }
                        _ => {}
                    }
                    if let Some(g) = &arm.guard {
                        self.check_expr(g);
                    }
                    for s in &arm.body {
                        self.check_stmt(s);
                    }
                    self.scopes.pop();
                }
            }

            // Chamada "nua": se o alvo for falível, é erro — o ponto central do design.
            Expr::Call { name, args, .. } => self.check_call(name, args, false),

            Expr::Try(inner) => {
                if !self.fun.fallible {
                    self.err(
                        "'try' propagates the error to the caller, so the function also \
                         needs to be fallible ('!') — or use 'catch' to handle it here"
                            .to_string(),
                    );
                }
                match inner.as_ref() {
                    Expr::Call { name, args, .. } => self.check_call(name, args, true),
                    Expr::MethodCall { base, method, args } => {
                        self.check_method_call(base, method, args, true)
                    }
                    Expr::SuperCall { method, args } => {
                        self.check_super_call(method.as_deref(), args, true)
                    }
                    _ => self.err("'try' only applies to a call to a fallible function".to_string()),
                }
            }

            Expr::Catch { lhs, handler } => {
                match lhs.as_ref() {
                    Expr::Call { name, args, .. } => self.check_call(name, args, true),
                    Expr::MethodCall { base, method, args } => {
                        self.check_method_call(base, method, args, true)
                    }
                    Expr::SuperCall { method, args } => {
                        self.check_super_call(method.as_deref(), args, true)
                    }
                    _ => self.err(
                        "'catch' only applies directly to a call to a fallible function"
                            .to_string(),
                    ),
                }
                match handler {
                    CatchHandler::Fallback(fb) => self.check_expr(fb),
                    CatchHandler::Block { name, body } => {
                        // o bloco roda em escopo próprio; `e` (se houver) liga
                        // o código do erro a uma variável i64 imutável
                        self.scopes.push(HashMap::new());
                        if let Some(n) = name {
                            if builtins::is_builtin(n) || n == "this" {
                                self.err(format!("'{}' is a reserved name", n));
                            }
                            self.declare_var(n, Some(Type::I64), false);
                        }
                        for s in body {
                            self.check_stmt(s);
                        }
                        self.scopes.pop();
                    }
                }
            }

            // spawn obj.metodo(args): roda o método na thread com obj como this
            Expr::Spawn { name, receiver: Some(recv), args } => {
                self.check_expr(recv);
                match self.infer_type(recv) {
                    Some(Type::Named(cls, _)) if self.classes.contains(&cls) => {
                        let meta = self.classes.get(&cls).unwrap();
                        match meta.method(name) {
                            None => self.err(format!(
                                "spawn: class '{}' has no instance method '{}'",
                                cls, name
                            )),
                            Some(m) if m.fallible => self.err(format!(
                                "cannot spawn the fallible method '{}.{}': an error in another \
                                 thread would have no one to handle it",
                                cls, name
                            )),
                            Some(m) => {
                                let ptypes: Vec<Type> = m.params.iter().map(|p| p.ty.clone()).collect();
                                if args.len() != ptypes.len() {
                                    self.err(format!(
                                        "method '{}.{}' expects {} argument(s), got {}",
                                        cls, name, ptypes.len(), args.len()
                                    ));
                                } else {
                                    let label = format!("{}.{}", cls, name);
                                    self.check_arg_types(&label, &ptypes, false, args);
                                }
                            }
                        }
                    }
                    Some(_) | None => self.err(format!(
                        "spawn: '{}' can only spawn a method on a class instance",
                        name
                    )),
                }
                for a in args {
                    self.check_expr(a);
                }
            }

            Expr::Spawn { name, receiver: None, args } => {
                if self.lookup_var(name).is_some() {
                    self.err(format!(
                        "'spawn {}': for now spawn requires the name of a declared \
                         function, not a function value",
                        name
                    ));
                } else {
                    match self.sigs.get(name) {
                        None => self.err(format!("spawn of unknown function: '{}'", name)),
                        Some(sig) => {
                            if sig.fallible {
                                self.err(format!(
                                    "cannot spawn the fallible function '{}': an error in another \
                                     thread would have no one to handle it — handle the errors inside it",
                                    name
                                ));
                            }
                            if sig.variadic {
                                self.err(format!(
                                    "cannot spawn the variadic function '{}': pass a fixed \
                                     argument list — wrap the call in a non-variadic function",
                                    name
                                ));
                            }
                            if args.len() < sig.required || args.len() > sig.n_params {
                                self.err(format!(
                                    "'{}' expects {}, got {}",
                                    name, arity_msg_v(sig.required, sig.n_params, sig.variadic), args.len()
                                ));
                            }
                        }
                    }
                }
                for a in args {
                    self.check_expr(a);
                }
            }

            Expr::Field { base, field } => {
                // `Enum.Variante` — constante inteira nomeada.
                if let Some(en) = self.enum_base(base) {
                    if !self.enums[&en].iter().any(|v| v == field) {
                        self.err(format!("enum '{}' has no variant '{}'", en, field));
                    }
                    return;
                }
                // `Classe.campoEstatico` — acesso estático (base é o NOME da
                // classe, não uma instância). Tratado antes do check_expr da
                // base, que recusaria a classe como valor.
                if let Some(cls) = self.static_base_class(base) {
                    match self.classes.get(&cls).and_then(|m| m.static_field(field).cloned()) {
                        None => self.err(format!(
                            "class '{}' has no static field '{}'",
                            cls, field
                        )),
                        Some(sf) => {
                            if sf.private && self.cur_class.as_deref() != Some(sf.owner.as_str()) {
                                self.err(format!(
                                    "static field '{}.{}' is private to '{}'",
                                    cls, field, sf.owner
                                ));
                            }
                        }
                    }
                    return;
                }
                self.check_expr(base);
                // se dá para inferir o tipo da base, valida o campo
                if let Some(Type::Named(sname, _)) = self.infer_type(base) {
                    if let Some(meta) = self.classes.get(&sname) {
                        match meta.slot(field) {
                            None => {
                                if meta.method(field).is_some() {
                                    self.err(format!(
                                        "'{}' is a method of '{}' — call it with {}(...); \
                                         using a method as a value is not supported yet",
                                        field, sname, field
                                    ));
                                } else {
                                    self.err(format!(
                                        "class '{}' has no field '{}'",
                                        sname, field
                                    ));
                                }
                            }
                            Some((_, f)) => {
                                let f = f.clone();
                                self.check_private_field(&f);
                            }
                        }
                    } else if let Some(def) = self.structs.get(&sname) {
                        if !def.fields.iter().any(|(n, _)| n == field) {
                            self.err(format!(
                                "type '{}' has no field '{}'",
                                sname, field
                            ));
                        }
                    }
                }
            }

            Expr::StructLit { fields } => {
                for (_, v) in fields {
                    self.check_expr(v);
                }
            }

            Expr::ArrayLit(elems) => {
                for e in elems {
                    self.check_expr(e);
                }
            }

            Expr::MapLit(entries) => {
                for (_, v) in entries {
                    self.check_expr(v);
                }
            }

            // `base[i]` — array (índice int), Map (chave string) ou JSON
            // (chave string → membro, índice int → elemento do array).
            Expr::Index { base, index } => {
                self.check_expr(base);
                self.check_expr(index);
                match self.infer_type(base) {
                    Some(Type::Array(_)) | Some(Type::Map(_)) | Some(Type::Json) | None => {}
                    Some(Type::Ptr) => self.err(
                        "indexing with [] works on arrays; for a string use \
                         charAt(s, i) or charCode(s, i)"
                            .to_string(),
                    ),
                    Some(_) => {
                        self.err("indexing with [] works on arrays, maps and JSON".to_string())
                    }
                }
            }

            Expr::New { class, args, .. } => {
                for a in args {
                    self.check_expr(a);
                }
                if self.structs.contains_key(class) {
                    self.err(format!(
                        "'{}' is a type (struct) — create it with the literal {{ field: value }}, \
                         not with 'new'",
                        class
                    ));
                    return;
                }
                let Some(meta) = self.classes.get(class) else {
                    self.err(format!("unknown class: '{}'", class));
                    return;
                };
                match &meta.ctor {
                    Some(ct) => {
                        let required = required_arity(&ct.params);
                        if args.len() < required || args.len() > ct.params.len() {
                            let err = format!(
                                "the constructor of '{}' expects {}, got {}",
                                class,
                                arity_msg(required, ct.params.len()),
                                args.len()
                            );
                            self.err(err);
                        }
                        // valida struct literals passados ao construtor
                        let ptypes: Vec<Type> = ct.params.iter().map(|p| p.ty.clone()).collect();
                        for (i, a) in args.iter().enumerate() {
                            if let Some(pty) = ptypes.get(i) {
                                self.propagate(pty, a);
                            }
                        }
                    }
                    None => {
                        if !args.is_empty() {
                            self.err(format!(
                                "'{}' has no constructor — 'new {}()' takes no arguments",
                                class, class
                            ));
                        }
                    }
                }
            }

            Expr::MethodCall { base, method, args } => {
                self.check_method_call(base, method, args, false)
            }

            Expr::SuperCall { method, args } => {
                self.check_super_call(method.as_deref(), args, false)
            }
        }
    }

    /// Acesso a um campo privado só vale dentro da classe que o declarou.
    fn check_private_field(&mut self, f: &oop::FieldMeta) {
        if f.private && self.cur_class.as_deref() != Some(f.owner.as_str()) {
            let err = format!(
                "field '{}' is private to '{}' — only methods of '{}' can access it",
                f.name, f.owner, f.owner
            );
            self.err(err);
        }
    }

    /// Valida `base.metodo(args)`. `handled` = true sob try/catch.
    /// Cobre método estático (`Classe.m()`), método de instância e campo
    /// com tipo de função (`obj.callback(...)`).
    fn check_method_call(&mut self, base: &Expr, method: &str, args: &[Expr], handled: bool) {
        for a in args {
            self.check_expr(a);
        }

        // `Classe.metodo(...)` — estático (desde que nenhuma variável sombreie)
        if let Expr::Var(n) = base {
            if self.lookup_var(n).is_none() {
                if let Some(meta) = self.classes.get(n) {
                    let Some(m) = meta.static_method(method).cloned() else {
                        if meta.method(method).is_some() {
                            self.err(format!(
                                "'{}' is an instance method of '{}' — call it on an object \
                                 (new {}(...)).{}(...)",
                                method, n, n, method
                            ));
                        } else {
                            self.err(format!(
                                "class '{}' has no static method '{}'",
                                n, method
                            ));
                        }
                        return;
                    };
                    self.check_method_sig(&m, args.len(), handled);
                    return;
                }
            }
        }

        self.check_expr(base);
        match self.infer_type(base) {
            Some(Type::Named(tname, _)) => {
                if let Some(meta) = self.classes.get(&tname) {
                    if let Some(m) = meta.method(method).cloned() {
                        if m.private && self.cur_class.as_deref() != Some(m.owner.as_str()) {
                            self.err(format!(
                                "method '{}' is private to '{}' — only methods of '{}' \
                                 can call it",
                                method, m.owner, m.owner
                            ));
                        }
                        self.check_method_sig(&m, args.len(), handled);
                        return;
                    }
                    // campo com tipo de função?
                    if let Some((_, f)) = meta.slot(method) {
                        let f = f.clone();
                        self.check_private_field(&f);
                        self.check_fn_field_call(&tname, method, &f.ty, args.len(), handled);
                        return;
                    }
                    if meta.static_method(method).is_some() {
                        self.err(format!(
                            "'{}' is a static method — call it on the class: {}.{}(...)",
                            method, tname, method
                        ));
                        return;
                    }
                    self.err(format!(
                        "class '{}' has no method '{}'",
                        tname, method
                    ));
                } else if let Some(def) = self.structs.get(&tname).cloned() {
                    // struct: só campo com tipo de função é "chamável"
                    match def.fields.iter().find(|(n, _)| n == method) {
                        Some((_, ty)) => {
                            let ty = ty.clone();
                            self.check_fn_field_call(&tname, method, &ty, args.len(), handled);
                        }
                        None => self.err(format!(
                            "type '{}' has no field '{}' (structs have no methods — \
                             use a class)",
                            tname, method
                        )),
                    }
                }
            }
            // base primitiva (string/array/map/json/...): os helpers builtin
            // podem ser chamados como método — `s.split(",")` == `split(s, ",")`.
            other => {
                if builtins::is_builtin(method) {
                    self.check_builtin_method(method, args.len(), handled);
                } else if other.is_some() {
                    self.err(format!(
                        "'{}' is not a method here — only the built-in helpers \
                         (push, pop, split, len, …) can be called with method syntax \
                         on strings/arrays/maps",
                        method
                    ));
                }
                // tipo da base desconhecido: best-effort, não acusa
            }
        }
    }

    /// Valida `receiver.builtin(args)` (extensão): a aridade conta o receiver
    /// como primeiro argumento e os builtins nunca são falíveis.
    fn check_builtin_method(&mut self, method: &str, n_args: usize, handled: bool) {
        let sig = builtins::lookup(method).expect("check_builtin_method com não-builtin");
        let total = n_args + 1; // + receiver (a base antes do ponto)
        if total < sig.min_args || total > sig.max_args {
            // a aridade do builtin inclui o receiver; reporta em termos dos
            // argumentos depois do ponto para a mensagem fazer sentido
            let lo = sig.min_args.saturating_sub(1);
            let hi = sig.max_args.saturating_sub(1);
            if lo == hi {
                self.err(format!(
                    "'.{}' expects {} argument(s), got {}",
                    method, lo, n_args
                ));
            } else {
                self.err(format!(
                    "'.{}' expects between {} and {} arguments, got {}",
                    method, lo, hi, n_args
                ));
            }
        }
        if handled {
            self.err(format!(
                "'{}' is not fallible: 'try'/'catch' does not apply",
                method
            ));
        }
    }

    /// Chamada de um campo com tipo de função: `obj.callback(args)`.
    fn check_fn_field_call(
        &mut self,
        tname: &str,
        field: &str,
        ty: &Type,
        n_args: usize,
        handled: bool,
    ) {
        match ty {
            Type::Fn(params, _) => {
                if params.len() != n_args {
                    self.err(format!(
                        "'{}' expects {} argument(s), got {}",
                        field,
                        params.len(),
                        n_args
                    ));
                }
                if handled {
                    self.err(format!(
                        "'{}' holds a non-fallible function: 'try'/'catch' does not apply",
                        field
                    ));
                }
            }
            _ => self.err(format!(
                "field '{}' of '{}' does not have a function type — it cannot be called",
                field, tname
            )),
        }
    }

    /// Aridade e regra de falibilidade de um método (vale para estático).
    fn check_method_sig(&mut self, m: &oop::MethodMeta, n_args: usize, handled: bool) {
        let required = required_arity(&m.params);
        let variadic = is_variadic(&m.params);
        let too_many = !variadic && n_args > m.params.len();
        if n_args < required || too_many {
            self.err(format!(
                "'{}' expects {}, got {}",
                m.name,
                arity_msg_v(required, m.params.len(), variadic),
                n_args
            ));
        }
        if m.fallible && !handled {
            self.err(format!(
                "'{}' can fail: use 'try obj.{}(...)' to propagate the error \
                 or 'obj.{}(...) catch value' to handle it",
                m.name, m.name, m.name
            ));
        }
        if !m.fallible && handled {
            self.err(format!(
                "'{}' is not fallible: 'try'/'catch' here is unnecessary",
                m.name
            ));
        }
    }

    /// Valida `super(args)` e `super.metodo(args)`.
    fn check_super_call(&mut self, method: Option<&str>, args: &[Expr], handled: bool) {
        for a in args {
            self.check_expr(a);
        }
        let Some(cur) = self.cur_class.clone() else {
            self.err("'super' can only be used inside a class method".to_string());
            return;
        };
        if self.fun.params.first().map(|p| p.name.as_str()) != Some("this") {
            self.err("'super' cannot be used in a static method".to_string());
            return;
        }
        let parent = match self.classes.get(&cur).and_then(|m| m.parent.clone()) {
            Some(p) => p,
            None => {
                self.err(format!("class '{}' has no superclass ('extends')", cur));
                return;
            }
        };
        let Some(pmeta) = self.classes.get(&parent) else {
            return; // superclasse inexistente: o oop::build já acusou
        };

        match method {
            // super(args): construtor do pai, só dentro do construtor
            None => {
                if !self.in_ctor {
                    self.err(
                        "'super(...)' can only be called inside the constructor — \
                         for a parent method, use super.method(...)"
                            .to_string(),
                    );
                    return;
                }
                if handled {
                    self.err("a constructor is not fallible: 'try'/'catch' does not apply".to_string());
                }
                match &pmeta.ctor {
                    Some(ct) => {
                        let required = required_arity(&ct.params);
                        if args.len() < required || args.len() > ct.params.len() {
                            let err = format!(
                                "the constructor of '{}' expects {}, got {}",
                                parent,
                                arity_msg(required, ct.params.len()),
                                args.len()
                            );
                            self.err(err);
                        }
                    }
                    None => {
                        if !args.is_empty() {
                            self.err(format!(
                                "'{}' has no constructor — 'super()' takes no arguments",
                                parent
                            ));
                        }
                    }
                }
            }
            // super.metodo(args): implementação do pai, sem dispatch
            Some(mname) => {
                let Some(m) = pmeta.method(mname).cloned() else {
                    self.err(format!(
                        "superclass '{}' has no method '{}'",
                        parent, mname
                    ));
                    return;
                };
                if m.private && self.cur_class.as_deref() != Some(m.owner.as_str()) {
                    self.err(format!(
                        "method '{}' is private to '{}' — it cannot be called via super",
                        mname, m.owner
                    ));
                }
                self.check_method_sig(&m, args.len(), handled);
            }
        }
    }

    /// Mapa param→concreto de uma chamada genérica: usa os args de tipo
    /// explícitos (`f<i64>(x)`) ou os infere dos tipos dos argumentos (`f(5)`).
    fn generic_call_map(
        &self,
        sig: &FnSig,
        type_args: &[Type],
        args: &[Expr],
    ) -> HashMap<String, Type> {
        if !type_args.is_empty() {
            return type_param_map(&sig.type_params, type_args);
        }
        let mut map = HashMap::new();
        for (i, a) in args.iter().enumerate() {
            if let Some(pty) = sig.params.get(i) {
                if let Some(aty) = self.infer_type(a) {
                    unify_type(pty, &aty, &sig.type_params, &mut map);
                }
            }
        }
        map
    }

    /// Inferência de tipo best-effort, só o necessário para validar campos,
    /// métodos e o tipo de variáveis declaradas sem anotação.
    fn infer_type(&self, e: &Expr) -> Option<Type> {
        match e {
            Expr::Str(_) | Expr::Template(_) => Some(Type::Ptr),
            Expr::Float(_) => Some(Type::F64),
            Expr::Bool(_) => Some(Type::Bool),
            Expr::Var(n) => self.lookup_var(n).and_then(|v| v.ty.clone()),
            Expr::Field { base, field } => {
                // `Enum.Variante` — o tipo é o próprio enum (inteiro nomeado)
                if let Some(en) = self.enum_base(base) {
                    return Some(Type::Named(en, Vec::new()));
                }
                // `Classe.campoEstatico`
                if let Some(cls) = self.static_base_class(base) {
                    return self
                        .classes
                        .get(&cls)
                        .and_then(|m| m.static_field(field))
                        .map(|f| f.ty.clone());
                }
                if let Some(Type::Named(s, args)) = self.infer_type(base) {
                    if let Some(meta) = self.classes.get(&s) {
                        let map = type_param_map(&meta.type_params, &args);
                        return meta.slot(field).map(|(_, f)| subst_type(&f.ty, &map));
                    }
                    self.structs
                        .get(&s)
                        .and_then(|d| d.fields.iter().find(|(n, _)| n == field))
                        .map(|(_, t)| t.clone())
                } else {
                    None
                }
            }
            Expr::Call { name, type_args, args } => {
                if self.lookup_var(name).is_some() {
                    // valor de função: o tipo de retorno vem da anotação Fn
                    if let Some(Type::Fn(_, r)) = self.lookup_var(name).and_then(|v| v.ty.clone()) {
                        return Some(*r);
                    }
                    return None;
                }
                if builtins::is_builtin(name) {
                    let argtys: Vec<Option<Type>> =
                        args.iter().map(|a| self.infer_type(a)).collect();
                    return builtins::ret_type(name, &argtys);
                }
                let sig = self.sigs.get(name)?;
                // tipo de retorno (com substituição genérica, se houver)
                let ret = if sig.type_params.is_empty() {
                    sig.ret_type.clone()
                } else {
                    let map = self.generic_call_map(sig, type_args, args);
                    subst_type(&sig.ret_type, &map)
                };
                // chamar uma async fn devolve um Future<ret> (resolve com await)
                if sig.is_async {
                    Some(Type::Future(Box::new(ret)))
                } else {
                    Some(ret)
                }
            }
            Expr::Await(inner) => match self.infer_type(inner) {
                Some(Type::Future(t)) => Some(*t),
                other => other,
            },
            Expr::ArrayLit(elems) => {
                let elem = elems
                    .first()
                    .and_then(|e| self.infer_type(e))
                    .unwrap_or(Type::I64);
                Some(Type::Array(Box::new(elem)))
            }
            Expr::MapLit(entries) => {
                let val = entries
                    .first()
                    .and_then(|(_, v)| self.infer_type(v))
                    .unwrap_or(Type::I64);
                Some(Type::Map(Box::new(val)))
            }
            Expr::Index { base, .. } => match self.infer_type(base) {
                Some(Type::Array(t)) | Some(Type::Map(t)) => Some(*t),
                Some(Type::Json) => Some(Type::Json),
                _ => None,
            },
            Expr::New { class, type_args, .. } => {
                Some(Type::Named(class.clone(), type_args.clone()))
            }
            Expr::MethodCall { base, method, args } => {
                // estático: Classe.m()
                if let Expr::Var(n) = base.as_ref() {
                    if self.lookup_var(n).is_none() {
                        if let Some(meta) = self.classes.get(n) {
                            return meta.static_method(method).map(|m| m.ret_type.clone());
                        }
                    }
                }
                let bt = self.infer_type(base);
                if let Some(Type::Named(t, targs)) = &bt {
                    if let Some(meta) = self.classes.get(t) {
                        let map = type_param_map(&meta.type_params, targs);
                        if let Some(m) = meta.method(method) {
                            return Some(subst_type(&m.ret_type, &map));
                        }
                        if let Some((_, f)) = meta.slot(method) {
                            if let Type::Fn(_, r) = &f.ty {
                                return Some(subst_type(r, &map));
                            }
                        }
                        return None;
                    }
                    return self.structs.get(t).and_then(|d| {
                        d.fields.iter().find(|(n, _)| n == method).and_then(
                            |(_, ty)| match ty {
                                Type::Fn(_, r) => Some((**r).clone()),
                                _ => None,
                            },
                        )
                    });
                }
                // extensão builtin: `receiver.builtin(args)` — o tipo de retorno
                // depende do receiver (1º arg) para os builtins polimórficos.
                if builtins::is_builtin(method) {
                    let mut argtys = vec![bt];
                    argtys.extend(args.iter().map(|a| self.infer_type(a)));
                    return builtins::ret_type(method, &argtys);
                }
                None
            }
            Expr::SuperCall { method: Some(m), .. } => {
                let parent = self
                    .cur_class
                    .as_ref()
                    .and_then(|c| self.classes.get(c))
                    .and_then(|c| c.parent.clone())?;
                self.classes
                    .get(&parent)
                    .and_then(|p| p.method(m))
                    .map(|m| m.ret_type.clone())
            }
            // try/catch são transparentes para o tipo do payload
            Expr::Try(inner) => self.infer_type(inner),
            Expr::Catch { lhs, .. } => self.infer_type(lhs),
            // comparações/lógicos → bool; aritmética → f64 se algum lado for
            // float, senão o tipo do operando esquerdo.
            Expr::Binary { op, lhs, rhs } => {
                if op.is_bool_result() {
                    Some(Type::Bool)
                } else {
                    let lt = self.infer_type(lhs);
                    let rt = self.infer_type(rhs);
                    // promoção: f64 vence f32 vence inteiro
                    if lt == Some(Type::F64) || rt == Some(Type::F64) {
                        Some(Type::F64)
                    } else if lt == Some(Type::F32) || rt == Some(Type::F32) {
                        Some(Type::F32)
                    } else {
                        lt.or(rt)
                    }
                }
            }
            Expr::Unary { op, operand } => match op {
                UnOp::Not => Some(Type::Bool),
                _ => self.infer_type(operand),
            },
            // match: tipo do valor do primeiro braço que termina em expressão
            Expr::Match { arms, .. } => arms.iter().find_map(|a| match a.body.last() {
                Some(Stmt { kind: StmtKind::Expr(e), .. }) => self.infer_type(e),
                _ => None,
            }),
            _ => None,
        }
    }

    /// Quando o tipo-alvo é um struct conhecido e o valor é um struct literal,
    /// valida os campos: nenhum desconhecido, nenhum duplicado, nenhum
    /// faltando. Recursivo nos campos que também são structs.
    fn propagate(&mut self, expected: &Type, value: &Expr) {
        if let (Type::Named(sname, _), Expr::StructLit { fields }) = (expected, value) {
            // classe instanciada por struct literal já é barrada em outro lugar
            let Some(def) = self.structs.get(sname).cloned() else {
                return;
            };
            let mut seen: Vec<&str> = Vec::new();
            for (fname, fval) in fields {
                match def.fields.iter().find(|(n, _)| n == fname) {
                    None => self.err(format!(
                        "type '{}' has no field '{}'",
                        sname, fname
                    )),
                    Some((_, fty)) => {
                        if seen.contains(&fname.as_str()) {
                            self.err(format!(
                                "field '{}' given more than once in '{}'",
                                fname, sname
                            ));
                        }
                        seen.push(fname);
                        // valida struct aninhado
                        self.propagate(fty, fval);
                    }
                }
            }
            for (fname, _) in &def.fields {
                // `children` é opcional (componente usado self-closing não
                // passa filhos) — vira string vazia. O resto é obrigatório.
                if fname != "children" && !fields.iter().any(|(n, _)| n == fname) {
                    self.err(format!(
                        "field '{}' is missing in the '{}' literal",
                        fname, sname
                    ));
                }
            }
        }
    }

    /// Se `base` é o NOME de uma classe (e não uma variável local), devolve o
    /// nome — ou seja, `base.x` é acesso estático (`Classe.x`), não acesso a
    /// campo de instância.
    fn static_base_class(&self, base: &Expr) -> Option<String> {
        if let Expr::Var(n) = base {
            if self.lookup_var(n).is_none() && self.classes.contains(n) {
                return Some(n.clone());
            }
        }
        None
    }

    /// Se `base` é o NOME de um enum (e não uma variável), devolve o nome —
    /// ou seja, `base.x` é `Enum.Variante`.
    fn enum_base(&self, base: &Expr) -> Option<String> {
        if let Expr::Var(n) = base {
            if self.lookup_var(n).is_none() && self.enums.contains_key(n) {
                return Some(n.clone());
            }
        }
        None
    }

    /// `sub` é `sup` ou uma subclasse dele (cadeia de heranças). Usado para
    /// aceitar polimorfismo na checagem de argumentos (passar um `Cachorro`
    /// onde se espera um `Animal`).
    fn is_subclass(&self, sub: &str, sup: &str) -> bool {
        let mut cur = Some(sub.to_string());
        while let Some(c) = cur {
            if c == sup {
                return true;
            }
            cur = self.classes.get(&c).and_then(|m| m.parent.clone());
        }
        false
    }

    /// Um argumento de tipo `actual` é aceitável onde se espera `expected`?
    /// Conservador de propósito: só recusa quando os tipos estão em "famílias"
    /// claramente disjuntas (um escalar não é um ponteiro, uma string não é um
    /// objeto), porque a representação uniforme (tudo i64) e as coerções do
    /// codegen tornam muitas misturas inócuas. Casos ambíguos passam — a meta
    /// é pegar erros reais sem rejeitar programa válido.
    fn arg_compatible(&self, expected: &Type, actual: &Type) -> bool {
        use Type::*;
        // `any`/`json` são a mesma caixa marcada: convertem com qualquer coisa.
        if matches!(expected, Any | Json) || matches!(actual, Any | Json) {
            return true;
        }
        // parâmetro de tipo genérico (`T`) aceita qualquer argumento.
        if let Named(n, _) = expected {
            if self.type_params.contains(n) {
                return true;
            }
        }
        if let Named(n, _) = actual {
            if self.type_params.contains(n) {
                return true;
            }
        }
        // igualdade estrutural exata.
        if expected == actual {
            return true;
        }
        // escalares numéricos/bool convertem livremente entre si no codegen.
        let scalar = |t: &Type| matches!(t, I8 | I32 | I64 | F32 | F64 | Bool);
        if scalar(expected) && scalar(actual) {
            return true;
        }
        match (expected, actual) {
            // mesma classe/struct (args genéricos reificados podem diferir) ou
            // subclasse passada onde o pai é esperado.
            (Named(e, _), Named(a, _)) => e == a || self.is_subclass(a, e),
            // contêineres: mesmo construtor, frouxo no elemento.
            (Array(e), Array(a))
            | (Map(e), Map(a))
            | (Chan(e), Chan(a))
            | (Future(e), Future(a)) => self.arg_compatible(e, a),
            // tipos de função: não confere a assinatura a fundo (evita falso
            // positivo com arrows/inferência), só exige que ambos sejam função.
            (Fn(..), Fn(..)) => true,
            _ => false,
        }
    }

    /// Confere os argumentos de uma chamada contra os tipos dos parâmetros:
    /// valida struct literals (campos) via `propagate` e o tipo de cada
    /// argumento via `arg_compatible`. Num parâmetro variádico (`...args: T[]`)
    /// cada argumento extra casa o tipo do elemento `T`. Tipos que a inferência
    /// não conhece (retorno `None`) são deixados passar — best-effort.
    fn check_arg_types(&mut self, callee: &str, params: &[Type], variadic: bool, args: &[Expr]) {
        let last = params.len().saturating_sub(1);
        for (i, a) in args.iter().enumerate() {
            let expected = if variadic && i >= last {
                match params.last() {
                    Some(Type::Array(elem)) => Some((**elem).clone()),
                    other => other.cloned(),
                }
            } else {
                params.get(i).cloned()
            };
            let Some(expected) = expected else { continue };
            // struct literal: validado campo a campo por propagate
            self.propagate(&expected, a);
            if let Some(actual) = self.infer_type(a) {
                if !self.arg_compatible(&expected, &actual) {
                    self.err(format!(
                        "argument {} of '{}' expects {}, got {}",
                        i + 1,
                        callee,
                        ty_str(&expected),
                        ty_str(&actual)
                    ));
                }
            }
        }
    }

    /// Valida uma chamada. `handled` = true quando está sob `try` ou `catch`.
    fn check_call(&mut self, name: &str, args: &[Expr], handled: bool) {
        // chamada através de uma variável (valor de função)?
        if let Some(info) = self.lookup_var(name).cloned() {
            if handled {
                self.err(format!(
                    "'{}' holds a non-fallible function: 'try'/'catch' does not apply",
                    name
                ));
            }
            match info.ty {
                Some(Type::Fn(ref params, _)) => {
                    if params.len() != args.len() {
                        self.err(format!(
                            "'{}' expects {} argument(s), got {}",
                            name, params.len(), args.len()
                        ));
                    } else {
                        let ptypes = params.clone();
                        self.check_arg_types(name, &ptypes, false, args);
                    }
                }
                _ => self.err(format!(
                    "'{}' is not a function — to store a function, annotate the type: \
                     const {}: (i64) => i64 = ...",
                    name, name
                )),
            }
            for a in args {
                self.check_expr(a);
            }
            return;
        }

        if let Some(sig) = builtins::lookup(name) {
            if handled {
                self.err(format!("'{}' is not fallible: 'try'/'catch' does not apply", name));
            }
            if args.len() < sig.min_args || args.len() > sig.max_args {
                if sig.min_args == sig.max_args {
                    self.err(format!(
                        "'{}' expects {} argument(s), got {}",
                        name, sig.min_args, args.len()
                    ));
                } else {
                    self.err(format!(
                        "'{}' expects between {} and {} arguments, got {}",
                        name, sig.min_args, sig.max_args, args.len()
                    ));
                }
            }
        } else {
            match self.sigs.get(name) {
                None => {
                    // dentro de método, `metodo()` sem this é erro comum
                    let method_da_classe = self
                        .cur_class
                        .as_ref()
                        .and_then(|c| self.classes.get(c))
                        .map(|m| m.method(name).is_some() || m.static_method(name).is_some())
                        .unwrap_or(false);
                    if method_da_classe {
                        self.err(format!(
                            "'{}' is a method of the class — call it with this.{}(...) \
                             (or {}.{}(...) if it is static)",
                            name,
                            name,
                            self.cur_class.as_deref().unwrap_or("Class"),
                            name
                        ));
                    } else {
                        self.err(format!("unknown function: '{}'", name));
                    }
                }
                Some(sig) => {
                    let too_many = !sig.variadic && args.len() > sig.n_params;
                    if args.len() < sig.required || too_many {
                        self.err(format!(
                            "'{}' expects {}, got {}",
                            name, arity_msg_v(sig.required, sig.n_params, sig.variadic), args.len()
                        ));
                    }
                    // valida tipo e struct literals dos argumentos (clona o que
                    // precisa de sig para soltar o empréstimo de self)
                    let ptypes: Vec<Type> = sig.params.clone();
                    let variadic = sig.variadic;
                    self.check_arg_types(name, &ptypes, variadic, args);
                    if sig.fallible && !handled {
                        self.err(format!(
                            "'{}' can fail: use 'try {}(...)' to propagate the error \
                             or '{}(...) catch value' to handle it",
                            name, name, name
                        ));
                    }
                    if !sig.fallible && handled {
                        self.err(format!(
                            "'{}' is not fallible: 'try'/'catch' here is unnecessary",
                            name
                        ));
                    }
                }
            }
        }
        for a in args {
            self.check_expr(a);
        }
    }
}
