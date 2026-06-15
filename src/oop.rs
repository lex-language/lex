//! Classes: metadados compartilhados entre o sema e o codegen.
//!
//! Aqui a hierarquia de herança é resolvida UMA vez e vira uma tabela:
//! - layout de campos: os do pai primeiro, depois os próprios (assim um
//!   `Filho` pode ser passado onde se espera `Pai` — os índices coincidem);
//! - vtable: métodos de instância em ordem estável; um override substitui a
//!   entrada do pai NO MESMO índice (é isso que faz o dispatch dinâmico
//!   funcionar: o índice é decidido em compile-time, a implementação em
//!   runtime, pela vtable que o `new` instalou no objeto).

use std::collections::{HashMap, HashSet};

use crate::ast::*;

/// Um campo no layout do objeto. `slot(nome)` devolve o índice de GEP já
/// contando o slot 0 (a vtable).
#[derive(Clone)]
pub struct FieldMeta {
    pub name: String,
    pub ty: Type,
    pub private: bool,
    /// Classe que declarou o campo (private = visível só nela).
    pub owner: String,
}

/// Um campo `static` resolvido. Não entra no layout do objeto: tem
/// armazenamento global único, nomeado por `mangle(owner, name)`.
#[derive(Clone)]
pub struct StaticFieldMeta {
    pub name: String,
    pub ty: Type,
    pub private: bool,
    pub owner: String,
    /// Inicializador, avaliado uma vez na entrada do programa.
    pub init: Expr,
}

/// Um método resolvido (próprio ou herdado).
#[derive(Clone)]
pub struct MethodMeta {
    pub name: String,
    /// Parâmetros declarados (sem o `this`).
    pub params: Vec<Param>,
    pub ret_type: Type,
    pub fallible: bool,
    pub private: bool,
    /// Classe cuja implementação vale aqui (muda com override).
    pub owner: String,
    /// Índice na vtable (só para métodos de instância).
    pub vtable_index: usize,
}

#[derive(Clone)]
pub struct ClassMeta {
    pub parent: Option<String>,
    /// Parâmetros de tipo da classe (`class Box<T>` → ["T"]). Usados pela
    /// inferência para substituir `T` pelos args reificados do tipo do objeto.
    pub type_params: Vec<String>,
    /// Layout completo (herdados primeiro). O slot de GEP é índice + 1.
    pub fields: Vec<FieldMeta>,
    /// Métodos de instância na ordem da vtable (herdados + próprios).
    pub vtable: Vec<MethodMeta>,
    pub statics: Vec<MethodMeta>,
    /// Campos `static` (herdados + próprios) — estado de classe.
    pub static_fields: Vec<StaticFieldMeta>,
    /// Construtor efetivo: o próprio ou, se não houver, o herdado.
    pub ctor: Option<MethodMeta>,
}

impl ClassMeta {
    /// (índice de GEP no bloco do objeto, metadados) de um campo.
    pub fn slot(&self, name: &str) -> Option<(usize, &FieldMeta)> {
        self.fields
            .iter()
            .position(|f| f.name == name)
            .map(|i| (i + 1, &self.fields[i]))
    }

    /// Método de instância (próprio ou herdado).
    pub fn method(&self, name: &str) -> Option<&MethodMeta> {
        self.vtable.iter().find(|m| m.name == name)
    }

    pub fn static_method(&self, name: &str) -> Option<&MethodMeta> {
        self.statics.iter().find(|m| m.name == name)
    }

    pub fn static_field(&self, name: &str) -> Option<&StaticFieldMeta> {
        self.static_fields.iter().find(|f| f.name == name)
    }

    /// Número de slots do objeto: vtable + campos.
    pub fn n_slots(&self) -> usize {
        1 + self.fields.len()
    }
}

pub struct ClassTable {
    classes: HashMap<String, ClassMeta>,
    /// Ordem topológica (pais antes dos filhos) — deixa o codegen
    /// determinístico e garante que o pai já foi resolvido.
    pub order: Vec<String>,
}

impl ClassTable {
    pub fn get(&self, name: &str) -> Option<&ClassMeta> {
        self.classes.get(name)
    }

    pub fn contains(&self, name: &str) -> bool {
        self.classes.contains_key(name)
    }
}

/// Nome LLVM de um método: `Classe.metodo`. O '.' garante que nunca colide
/// com função do usuário (identificadores lex não têm ponto).
pub fn mangle(class: &str, method: &str) -> String {
    format!("{}.{}", class, method)
}

/// Desugara um método na função de topo equivalente: `this` vira o primeiro
/// parâmetro (métodos estáticos não têm `this`). É assim que o corpo passa
/// pelo sema e pelo codegen sem caminho especial.
pub fn method_fn(class: &str, m: &Method) -> Function {
    let mut params = Vec::with_capacity(m.params.len() + 1);
    if !m.is_static {
        params.push(Param { name: "this".to_string(), ty: Type::Named(class.to_string(), Vec::new()), default: None, variadic: false });
    }
    params.extend(m.params.iter().cloned());
    Function {
        name: mangle(class, &m.name),
        is_async: false,
        type_params: Vec::new(),
        params,
        ret_type: m.ret_type.clone(),
        fallible: m.fallible,
        external: false,
        body: m.body.clone(),
        span: m.span,
        ret_inferred: false,
    }
}

/// Monta a tabela de classes validando a hierarquia. Os erros voltam junto
/// com a tabela (best-effort) para o sema reportar todos de uma vez.
pub fn build(defs: &[ClassDef]) -> (ClassTable, Vec<String>) {
    let mut errors = Vec::new();
    let mut by_name: HashMap<String, &ClassDef> = HashMap::new();
    for d in defs {
        if by_name.insert(d.name.clone(), d).is_some() {
            errors.push(format!("class '{}' defined more than once", d.name));
        }
    }

    // ordena pais antes dos filhos, detectando ciclo e pai inexistente
    let mut order: Vec<String> = Vec::new();
    let mut done: HashSet<String> = HashSet::new();
    for d in defs {
        let mut chain: Vec<String> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        let mut cur = Some(d.name.clone());
        while let Some(c) = cur {
            if done.contains(&c) {
                break;
            }
            if !seen.insert(c.clone()) {
                errors.push(format!("cyclic inheritance involving class '{}'", c));
                break;
            }
            chain.push(c.clone());
            cur = match by_name.get(&c).and_then(|def| def.parent.clone()) {
                Some(p) if by_name.contains_key(&p) => Some(p),
                Some(p) => {
                    errors.push(format!("class '{}': superclass '{}' does not exist", c, p));
                    None
                }
                None => None,
            };
        }
        for c in chain.into_iter().rev() {
            if done.insert(c.clone()) {
                order.push(c);
            }
        }
    }

    let mut classes: HashMap<String, ClassMeta> = HashMap::new();
    for cname in &order {
        let def = by_name[cname];

        // herda o que o pai já resolveu (ele vem antes na ordem topológica)
        let base = def
            .parent
            .as_ref()
            .and_then(|p| classes.get(p))
            .cloned();
        let mut fields = base.as_ref().map(|b| b.fields.clone()).unwrap_or_default();
        let mut vtable = base.as_ref().map(|b| b.vtable.clone()).unwrap_or_default();
        let mut statics = base.as_ref().map(|b| b.statics.clone()).unwrap_or_default();
        let mut static_fields =
            base.as_ref().map(|b| b.static_fields.clone()).unwrap_or_default();
        let mut ctor = base.as_ref().and_then(|b| b.ctor.clone());

        for sf in &def.statics {
            if static_fields.iter().any(|e| e.name == sf.name) {
                errors.push(format!(
                    "class '{}': static field '{}' declared more than once (or shadows an inherited one)",
                    cname, sf.name
                ));
                continue;
            }
            static_fields.push(StaticFieldMeta {
                name: sf.name.clone(),
                ty: sf.ty.clone(),
                private: sf.private,
                owner: cname.clone(),
                init: sf.init.clone(),
            });
        }

        for f in &def.fields {
            if let Some(prev) = fields.iter().find(|e| e.name == f.name) {
                if prev.owner == *cname {
                    errors.push(format!(
                        "class '{}': field '{}' declared more than once",
                        cname, f.name
                    ));
                } else {
                    errors.push(format!(
                        "class '{}': field '{}' already exists (inherited from '{}')",
                        cname, f.name, prev.owner
                    ));
                }
                continue;
            }
            fields.push(FieldMeta {
                name: f.name.clone(),
                ty: f.ty.clone(),
                private: f.private,
                owner: cname.clone(),
            });
        }

        let mut own: HashSet<String> = HashSet::new();
        for m in &def.methods {
            if !own.insert(m.name.clone()) {
                errors.push(format!(
                    "class '{}': method '{}' defined more than once",
                    cname, m.name
                ));
                continue;
            }
            let meta = MethodMeta {
                name: m.name.clone(),
                params: m.params.clone(),
                ret_type: m.ret_type.clone(),
                fallible: m.fallible,
                private: m.private,
                owner: cname.clone(),
                vtable_index: usize::MAX,
            };

            if m.name == "constructor" {
                if m.is_static {
                    errors.push(format!("class '{}': constructor cannot be static", cname));
                }
                if m.private {
                    errors.push(format!("class '{}': constructor cannot be private", cname));
                }
                if m.fallible {
                    errors.push(format!("class '{}': constructor cannot be fallible ('!')", cname));
                }
                if m.ret_type != Type::Void {
                    errors.push(format!(
                        "class '{}': constructor does not declare a return type",
                        cname
                    ));
                }
                ctor = Some(meta);
                continue;
            }

            if m.is_static {
                if vtable.iter().any(|e| e.name == m.name) {
                    errors.push(format!(
                        "class '{}': static method '{}' conflicts with an instance method",
                        cname, m.name
                    ));
                    continue;
                }
                // redefinição em filho substitui (resolução é estática)
                statics.retain(|e| e.name != m.name);
                statics.push(meta);
                continue;
            }

            if statics.iter().any(|e| e.name == m.name) {
                errors.push(format!(
                    "class '{}': method '{}' conflicts with an inherited static method",
                    cname, m.name
                ));
                continue;
            }

            match vtable.iter().position(|e| e.name == m.name) {
                // override: mesma assinatura, mesmo índice na vtable
                Some(idx) => {
                    let prev = &vtable[idx];
                    if prev.private {
                        errors.push(format!(
                            "class '{}': cannot override '{}', which is private to '{}'",
                            cname, m.name, prev.owner
                        ));
                        continue;
                    }
                    if m.private {
                        errors.push(format!(
                            "class '{}': '{}' overrides a public method of '{}' — \
                             it cannot reduce visibility",
                            cname, m.name, prev.owner
                        ));
                    }
                    let same_sig = prev.params.len() == m.params.len()
                        && prev
                            .params
                            .iter()
                            .zip(&m.params)
                            .all(|(a, b)| a.ty == b.ty)
                        && prev.ret_type == m.ret_type
                        && prev.fallible == m.fallible;
                    if !same_sig {
                        errors.push(format!(
                            "class '{}': the signature of '{}' differs from the one inherited from '{}' — \
                             an override needs identical parameters, return type and '!'",
                            cname, m.name, prev.owner
                        ));
                        continue;
                    }
                    let mut meta = meta;
                    meta.vtable_index = idx;
                    vtable[idx] = meta;
                }
                None => {
                    let mut meta = meta;
                    meta.vtable_index = vtable.len();
                    vtable.push(meta);
                }
            }
        }

        classes.insert(
            cname.clone(),
            ClassMeta {
                parent: def.parent.clone(),
                type_params: def.type_params.clone(),
                fields,
                vtable,
                statics,
                static_fields,
                ctor,
            },
        );
    }

    (ClassTable { classes, order }, errors)
}
