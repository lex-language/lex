//! Geração de código: AST -> LLVM IR -> arquivo objeto.
//!
//! Aqui é onde o lex "fala" com o LLVM, através do inkwell.
//!
//! Decisões de representação:
//! - Função falível (`-> T !`) retorna a struct `{ i64 erro, T valor }`.
//!   erro == 0 significa sucesso. `try`/`catch` viram extractvalue + branch.
//! - `spawn f(args)` copia os args para um struct no heap (malloc) e chama
//!   `pthread_create` com um "thunk" gerado por função-alvo. Sem runtime:
//!   o binário só depende da libc/libpthread do sistema.

use std::collections::HashMap;
use std::path::Path;

use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::module::Module;
use inkwell::targets::{
    CodeModel, FileType, InitializationConfig, RelocMode, Target, TargetMachine, TargetTriple,
};
use inkwell::basic_block::BasicBlock;
use inkwell::types::{
    BasicMetadataTypeEnum, BasicType, FunctionType, IntType, PointerType, StructType,
};
use inkwell::values::{
    BasicMetadataValueEnum, BasicValueEnum, FunctionValue, GlobalValue, IntValue, PointerValue,
    StructValue,
};
use inkwell::{AddressSpace, FloatPredicate, IntPredicate, OptimizationLevel};

use crate::ast::*;
use crate::builtins;
use crate::oop::{self, ClassTable, MethodMeta};

/// `true` se o tipo é ponto flutuante (viaja na célula i64 como bits do float).
fn is_float(t: &Type) -> bool {
    matches!(t, Type::F64 | Type::F32)
}

/// Alvo de compilação do objeto. `Native` = host; `Wasm` = wasm32; `Cross` =
/// um triple LLVM arbitrário (cross-compile, linkado depois com clang/lld).
pub enum TargetKind {
    Native,
    Wasm,
    Cross(String),
}

/// Uma variável local: um slot na stack (`alloca`) + tipo + mutabilidade.
/// O otimizador do LLVM (mem2reg) promove os slots para registradores.
#[derive(Clone)]
struct VarSlot<'ctx> {
    ptr: PointerValue<'ctx>,
    ty: Type,
    mutable: bool,
}

/// É uma arrow function içada (`__lambda_N`)? Lambdas têm a ABI de closure
/// (recebem o env como 1º parâmetro).
fn is_lambda(name: &str) -> bool {
    name.starts_with("__lambda_")
}

pub struct Codegen<'ctx> {
    context: &'ctx Context,
    module: Module<'ctx>,
    builder: Builder<'ctx>,
    /// Assinaturas das funções (para resolver chamadas e tipos de parâmetros).
    functions: HashMap<String, Function>,
    /// Definições de struct (`type Nome = {...}`), por nome.
    structs: HashMap<String, StructDef>,
    /// Enums: nome → variantes (índice na lista = valor inteiro).
    enums: HashMap<String, Vec<String>>,
    /// Capturas de cada lambda (nome `__lambda_N` → [(var, tipo)]), na ordem do
    /// closure box. Preenchido no site de uso (Closure) e lido no corpo.
    closures: HashMap<String, Vec<(String, Type)>>,
    /// Tipo de retorno de cada lambda inferido do contexto (o `Fn` esperado no
    /// site de uso). Sobrepõe o default `i64` da arrow sem anotação. A
    /// assinatura LLVM não muda (toda célula é i64) — só o contexto do corpo.
    lambda_rets: HashMap<String, Type>,
    /// Thunk `__fnval_F` por função de topo F usada como valor (ignora o env e
    /// chama F) — torna função-nomeada compatível com a ABI de closure.
    fn_thunks: HashMap<String, FunctionValue<'ctx>>,
    /// Tabela de classes resolvida (layout, vtable, herança).
    classes: ClassTable,
    /// Vtable de cada classe: global constante com os endereços dos métodos.
    vtables: HashMap<String, PointerValue<'ctx>>,
    /// Nome LLVM do método ("Classe.metodo") -> classe dona (para `super`).
    method_of: HashMap<String, String>,
    /// Classe do método sendo gerado agora (None em função de topo).
    cur_class: Option<String>,
    /// Os valores LLVM das funções já declaradas.
    fn_values: HashMap<String, FunctionValue<'ctx>>,
    /// Variáveis locais visíveis na função sendo gerada.
    vars: HashMap<String, VarSlot<'ctx>>,
    /// Função sendo gerada agora (para criar blocos e retornos de erro).
    cur_fn: Option<FunctionValue<'ctx>>,
    /// Bloco de entrada da função atual — todo alloca vai para cá, para não
    /// crescer a stack a cada iteração de um while.
    cur_entry: Option<BasicBlock<'ctx>>,
    cur_ret: Type,
    cur_fallible: bool,
    /// Thunks de spawn já gerados, um por função-alvo.
    thunks: HashMap<String, FunctionValue<'ctx>>,
    /// `defer`s registrados na função atual: (flag de "armado", statement).
    /// Rodam em ordem LIFO em todo caminho de saída, cada um sob a sua flag.
    cur_defers: Vec<(PointerValue<'ctx>, Stmt)>,
    /// Pilha de laços ativos: (bloco do `continue`, bloco do `break`). O laço
    /// mais interno é o topo — é a ele que `break`/`continue` se referem.
    cur_loops: Vec<(BasicBlock<'ctx>, BasicBlock<'ctx>)>,
}

impl<'ctx> Codegen<'ctx> {
    pub fn new(context: &'ctx Context, module_name: &str) -> Self {
        let module = context.create_module(module_name);
        let builder = context.create_builder();
        Codegen {
            context,
            module,
            builder,
            functions: HashMap::new(),
            structs: HashMap::new(),
            enums: HashMap::new(),
            closures: HashMap::new(),
            lambda_rets: HashMap::new(),
            fn_thunks: HashMap::new(),
            classes: oop::build(&[]).0,
            vtables: HashMap::new(),
            method_of: HashMap::new(),
            cur_class: None,
            fn_values: HashMap::new(),
            vars: HashMap::new(),
            cur_fn: None,
            cur_entry: None,
            cur_ret: Type::I64,
            cur_fallible: false,
            thunks: HashMap::new(),
            cur_defers: Vec::new(),
            cur_loops: Vec::new(),
        }
    }

    pub fn compile(&mut self, program: &Program) {
        // structs primeiro: tipos precisam estar disponíveis para campos/literais
        for s in &program.structs {
            self.structs.insert(s.name.clone(), s.clone());
        }
        for e in &program.enums {
            self.enums.insert(e.name.clone(), e.variants.clone());
        }
        // classes: a hierarquia já foi validada pelo sema
        let (table, errs) = oop::build(&program.classes);
        debug_assert!(errs.is_empty(), "invalid classes slipped past the semantic checker");
        self.classes = table;

        // métodos viram funções de topo ("Classe.metodo", this de 1º parâmetro)
        let mut all_fns: Vec<Function> = program.functions.clone();
        for c in &program.classes {
            for m in &c.methods {
                let f = oop::method_fn(&c.name, m);
                self.method_of.insert(f.name.clone(), c.name.clone());
                all_fns.push(f);
            }
        }

        // arrow functions (`__lambda_N`) recebem um parâmetro de env (o closure
        // box) na frente — é por ele que as capturas chegam ao corpo.
        for f in &mut all_fns {
            if is_lambda(&f.name) {
                f.params.insert(
                    0,
                    Param { name: "__env".into(), ty: Type::I64, default: None, variadic: false },
                );
            }
        }

        // 1ª passada: declara todas as funções (assim chamadas funcionam
        // independente da ordem de definição no arquivo).
        for f in &all_fns {
            self.declare_function(f);
        }
        // thunks de função-como-valor: um wrapper `__fnval_F(env, args) = F(args)`
        // por função de topo (ignora o env), declarado e definido aqui.
        self.declare_fn_thunks(&all_fns);
        // vtables precisam das funções declaradas (endereços dos métodos)
        self.build_vtables();

        // 2ª passada: corpos. Funções não-lambda primeiro (seus sites de uso de
        // closure registram as capturas), depois as lambdas em ordem DECRESCENTE
        // de criação (a externa antes da interna — garante o registro das
        // capturas de uma lambda aninhada antes de gerar o corpo dela).
        for f in &all_fns {
            if is_lambda(&f.name) {
                continue;
            }
            self.cur_class = self.method_of.get(&f.name).cloned();
            self.gen_function(f);
        }
        self.cur_class = None;
        let lambdas: Vec<&Function> = all_fns.iter().filter(|f| is_lambda(&f.name)).collect();
        for f in lambdas.into_iter().rev() {
            self.gen_function(f);
        }
        self.define_fn_thunks(&all_fns);
        // main falível ganha um embrulho: erro não tratado vira exit code.
        if let Some(m) = self.functions.get("main").cloned() {
            if m.fallible {
                self.gen_main_wrapper();
            }
        }
    }

    /// Uma global constante por classe: o array de endereços (i64) dos
    /// métodos de instância, na ordem da vtable. O `new` grava o endereço
    /// dela no slot 0 do objeto; a chamada de método indexa nela.
    fn build_vtables(&mut self) {
        let ptr_ty = self.ptr_type();
        for cname in self.classes.order.clone() {
            let meta = self.classes.get(&cname).unwrap().clone();
            // a vtable guarda os métodos como ponteiros de FUNÇÃO (não i64): no
            // wasm32 um ponteiro de função é um índice de tabela de 32 bits que
            // o `ptrtoint(... to i64)` não consegue representar num inicializador
            // estático. Guardar `ptr` direto resolve, e no nativo é idêntico.
            let fps: Vec<PointerValue> = meta
                .vtable
                .iter()
                .map(|m| {
                    let fv = self.fn_values[&oop::mangle(&m.owner, &m.name)];
                    fv.as_global_value().as_pointer_value()
                })
                .collect();
            let arr = ptr_ty.const_array(&fps);
            let g = self.module.add_global(
                ptr_ty.array_type(fps.len() as u32),
                None,
                &format!("__lex_vtable_{}", cname),
            );
            g.set_initializer(&arr);
            g.set_constant(true);
            self.vtables.insert(cname, g.as_pointer_value());
        }
    }

    /// Devolve o LLVM IR como texto (útil para depurar e aprender).
    pub fn ir_string(&self) -> String {
        self.module.print_to_string().to_string()
    }

    fn int_type(&self, ty: &Type) -> IntType<'ctx> {
        match ty {
            Type::I32 => self.context.i32_type(),
            Type::I64 => self.context.i64_type(),
            Type::I8 => self.context.i8_type(),
            Type::Bool => self.context.bool_type(), // i1
            // float viaja na célula i64 como o padrão de bits (f64 inteiro;
            // f32 nos 32 bits baixos)
            Type::F64 | Type::F32 => self.context.i64_type(),
            // ptr, valor de função, struct, array, map, json e canal =
            // endereço disfarçado de i64 (o mesmo truque do handle de thread
            // no spawn/join; na ABI de 64 bits, ponteiro e i64 viajam igual)
            Type::Ptr
            | Type::Fn(..)
            | Type::Named(..)
            | Type::Array(_)
            | Type::Map(_)
            | Type::Json
            | Type::Any
            | Type::Chan(_)
            | Type::Future(_) => self.context.i64_type(),
            Type::Void => panic!("void is not a value type (the semantic checker should have rejected this)"),
        }
    }

    /// Mapa param→concreto a partir de args de tipo explícitos OU inferidos dos
    /// tipos dos argumentos (unificação). Base da monomorfização na inferência.
    fn type_args_map(
        &self,
        type_params: &[String],
        type_args: &[Type],
        params: &[Param],
        args: &[Expr],
    ) -> HashMap<String, Type> {
        if !type_args.is_empty() {
            return type_param_map(type_params, type_args);
        }
        let mut map = HashMap::new();
        for (i, a) in args.iter().enumerate() {
            if let Some(p) = params.get(i) {
                if let Some(aty) = self.infer_type(a) {
                    unify_type(&p.ty, &aty, type_params, &mut map);
                }
            }
        }
        map
    }

    /// Mapa param→concreto de uma chamada de função genérica (espelha o sema).
    fn generic_call_map(
        &self,
        f: &Function,
        type_args: &[Type],
        args: &[Expr],
    ) -> HashMap<String, Type> {
        self.type_args_map(&f.type_params, type_args, &f.params, args)
    }

    /// Substitui os tipos dos parâmetros segundo o mapa — para gerar os
    /// argumentos de uma chamada genérica no tipo CONCRETO (essencial para
    /// floats, que truncariam se passados como o `T` apagado/i64).
    fn subst_params(&self, params: &[Param], map: &HashMap<String, Type>) -> Vec<Param> {
        if map.is_empty() {
            return params.to_vec();
        }
        params
            .iter()
            .map(|p| Param { ty: subst_type(&p.ty, map), ..p.clone() })
            .collect()
    }

    /// Tipo lex de uma expressão, best-effort — para resolver acesso a campo
    /// e decidir, em template/print, se o valor é ponteiro (string/struct).
    fn infer_type(&self, e: &Expr) -> Option<Type> {
        match e {
            Expr::Str(_) | Expr::Template(_) => Some(Type::Ptr),
            Expr::Float(_) => Some(Type::F64),
            Expr::Bool(_) => Some(Type::Bool),
            Expr::Var(n) => self.vars.get(n).map(|s| s.ty.clone()),
            Expr::Field { base, field } => {
                // `Enum.Variante`
                if let Expr::Var(n) = base.as_ref() {
                    if !self.vars.contains_key(n) && self.enums.contains_key(n) {
                        return Some(Type::Named(n.clone(), Vec::new()));
                    }
                }
                // `Classe.campoEstatico`
                if let Some((_, fty)) = self.static_field_ref(base, field) {
                    return Some(fty);
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
                if let Some(slot) = self.vars.get(name) {
                    if let Type::Fn(_, r) = &slot.ty {
                        return Some((**r).clone());
                    }
                    None
                } else if builtins::is_builtin(name) {
                    let argtys: Vec<Option<Type>> =
                        args.iter().map(|a| self.infer_type(a)).collect();
                    builtins::ret_type(name, &argtys)
                } else {
                    let f = self.functions.get(name)?;
                    let ret = if f.type_params.is_empty() {
                        f.ret_type.clone()
                    } else {
                        let map = self.generic_call_map(f, type_args, args);
                        subst_type(&f.ret_type, &map)
                    };
                    if f.is_async {
                        Some(Type::Future(Box::new(ret)))
                    } else {
                        Some(ret)
                    }
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
                    if !self.vars.contains_key(n) {
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
                // extensão builtin: `receiver.builtin(args)`
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
            Expr::Match { arms, .. } => arms.iter().find_map(|a| match a.body.last() {
                Some(Stmt { kind: StmtKind::Expr(e), .. }) => self.infer_type(e),
                _ => None,
            }),
            _ => None,
        }
    }

    /// O bloco de um struct: N campos de i64 (8 bytes cada). Layout uniforme
    /// — ponteiros/strings/ints todos cabem em 8 bytes na ABI de 64 bits.
    fn struct_block_type(&self, n: usize) -> StructType<'ctx> {
        let i64t = self.context.i64_type();
        let fields: Vec<_> = (0..n).map(|_| i64t.into()).collect();
        self.context.struct_type(&fields, false)
    }

    /// O tipo LLVM da assinatura de um valor de função `(T, ...) => R`,
    /// para a chamada indireta.
    /// Tipo LLVM de um valor-função (closure): `ret(i64 env, params...)`. O
    /// primeiro parâmetro é o "closure box" (env); lambdas e thunks o recebem,
    /// closures sem captura simplesmente o ignoram.
    fn fn_value_llvm_type(&self, params: &[Type], ret: &Type) -> FunctionType<'ctx> {
        let mut p: Vec<BasicMetadataTypeEnum> = vec![self.context.i64_type().into()];
        for t in params {
            p.push(self.int_type(t).into());
        }
        if *ret == Type::Void {
            self.context.void_type().fn_type(&p, false)
        } else {
            self.int_type(ret).fn_type(&p, false)
        }
    }

    /// Chama um valor-função (closure box, um i64): carrega o ponteiro de função
    /// de `box[0]` e chama passando o próprio box como `env` (arg0), seguido dos
    /// argumentos já avaliados. Coage o retorno ao tipo `expected`.
    fn gen_closure_call(
        &mut self,
        box_val: IntValue<'ctx>,
        ptypes: &[Type],
        ret: &Type,
        arg_vals: Vec<IntValue<'ctx>>,
        expected: &Type,
    ) -> IntValue<'ctx> {
        let i64_ty = self.context.i64_type();
        let boxp = self.builder.build_int_to_ptr(box_val, self.ptr_type(), "boxp").unwrap();
        let fn_addr = self.builder.build_load(i64_ty, boxp, "clfn").unwrap().into_int_value();
        let fptr = self.builder.build_int_to_ptr(fn_addr, self.ptr_type(), "clfp").unwrap();
        let mut argv: Vec<BasicMetadataValueEnum> = Vec::with_capacity(arg_vals.len() + 1);
        argv.push(box_val.into());
        for v in arg_vals {
            argv.push(v.into());
        }
        let fn_ty = self.fn_value_llvm_type(ptypes, ret);
        let res = self
            .builder
            .build_indirect_call(fn_ty, fptr, &argv, "clcall")
            .unwrap()
            .try_as_basic_value()
            .left();
        match res {
            Some(v) => self.convert(v.into_int_value(), ret, expected),
            None => self.int_type(expected).const_zero(),
        }
    }

    /// Declara um thunk `__fnval_F(env, args) = F(args)` para cada função de
    /// topo F que possa ser usada como valor (não-lambda, não-externa, não-
    /// método, não-falível, não-async, não-main). O env é ignorado.
    fn declare_fn_thunks(&mut self, all_fns: &[Function]) {
        for f in all_fns {
            if f.external
                || f.fallible
                || f.is_async
                || is_lambda(&f.name)
                || f.name.contains('.')
                || f.name == "main"
            {
                continue;
            }
            let ptypes: Vec<Type> = f.params.iter().map(|p| p.ty.clone()).collect();
            let fn_ty = self.fn_value_llvm_type(&ptypes, &f.ret_type);
            let thunk = self
                .module
                .add_function(&format!("__fnval_{}", f.name), fn_ty, None);
            self.fn_thunks.insert(f.name.clone(), thunk);
        }
    }

    /// Define o corpo dos thunks declarados: chamam F com os args (pulando o env).
    fn define_fn_thunks(&mut self, all_fns: &[Function]) {
        for f in all_fns {
            let Some(&thunk) = self.fn_thunks.get(&f.name) else {
                continue;
            };
            let target = self.fn_values[&f.name];
            let entry = self.context.append_basic_block(thunk, "entry");
            self.builder.position_at_end(entry);
            let n = f.params.len();
            let argv: Vec<BasicMetadataValueEnum> = (0..n)
                .map(|i| thunk.get_nth_param((i + 1) as u32).unwrap().into())
                .collect();
            let res = self
                .builder
                .build_call(target, &argv, "")
                .unwrap()
                .try_as_basic_value()
                .left();
            match res {
                Some(v) => self.builder.build_return(Some(&v)).unwrap(),
                None => self.builder.build_return(None).unwrap(),
            };
        }
    }

    /// Aloca um "closure box" no heap: `[fn_ptr_i64, cap0, cap1, ...]`. Devolve
    /// o endereço do box como i64 (a representação de um valor-função).
    fn make_closure_box(
        &mut self,
        fn_ptr: IntValue<'ctx>,
        caps: &[IntValue<'ctx>],
    ) -> IntValue<'ctx> {
        let i64_ty = self.context.i64_type();
        let n = caps.len() as u64 + 1;
        let malloc = self.extern_fn("malloc", i64_ty.fn_type(&[i64_ty.into()], false));
        let size = i64_ty.const_int(n * 8, false);
        let raw = self
            .builder
            .build_call(malloc, &[size.into()], "clbox")
            .unwrap()
            .try_as_basic_value()
            .left()
            .unwrap()
            .into_int_value();
        let boxp = self.builder.build_int_to_ptr(raw, self.ptr_type(), "clboxp").unwrap();
        // slot 0: ponteiro da função
        let s0 = unsafe {
            self.builder
                .build_in_bounds_gep(i64_ty, boxp, &[i64_ty.const_zero()], "cl0")
                .unwrap()
        };
        self.builder.build_store(s0, fn_ptr).unwrap();
        // slots 1..: capturas
        for (i, c) in caps.iter().enumerate() {
            let idx = i64_ty.const_int(i as u64 + 1, false);
            let sp = unsafe {
                self.builder.build_in_bounds_gep(i64_ty, boxp, &[idx], "clcap").unwrap()
            };
            self.builder.build_store(sp, *c).unwrap();
        }
        raw
    }

    fn ptr_type(&self) -> PointerType<'ctx> {
        self.context.ptr_type(AddressSpace::default())
    }

    /// O tipo LLVM de um retorno falível: `{ i64 erro, T valor }`.
    fn err_union_type(&self, payload: &Type) -> StructType<'ctx> {
        self.context.struct_type(
            &[self.context.i64_type().into(), self.int_type(payload).into()],
            false,
        )
    }

    /// Declara (uma vez só) uma função externa, como printf ou pthread_create.
    fn extern_fn(&self, name: &str, ty: FunctionType<'ctx>) -> FunctionValue<'ctx> {
        self.module
            .get_function(name)
            .unwrap_or_else(|| self.module.add_function(name, ty, None))
    }

    /// Cria um alloca no bloco de ENTRADA da função atual (independente de
    /// onde o builder está) — allocas em corpo de loop cresceriam a stack.
    fn entry_alloca<T: BasicType<'ctx>>(&self, name: &str, ty: T) -> PointerValue<'ctx> {
        let tmp = self.context.create_builder();
        let entry = self.cur_entry.expect("entry_alloca outside a function");
        match entry.get_first_instruction() {
            Some(first) => tmp.position_before(&first),
            None => tmp.position_at_end(entry),
        }
        tmp.build_alloca(ty, name).unwrap()
    }

    /// Aloca a flag i1 de um `defer` no topo do bloco de entrada e a
    /// inicializa com `false` ali mesmo — assim, um `defer` nunca alcançado
    /// (a flag fica `false`) não roda na saída.
    fn alloc_defer_flag(&self) -> PointerValue<'ctx> {
        let tmp = self.context.create_builder();
        let entry = self.cur_entry.expect("defer outside a function");
        match entry.get_first_instruction() {
            Some(first) => tmp.position_before(&first),
            None => tmp.position_at_end(entry),
        }
        let flag = tmp.build_alloca(self.context.bool_type(), "defer.armed").unwrap();
        tmp.build_store(flag, self.context.bool_type().const_zero()).unwrap();
        flag
    }

    /// Emite os `defer`s da função em ordem LIFO, cada um sob a sua flag, no
    /// ponto de inserção atual (chamado logo antes de cada `return`/`fail`).
    fn run_defers(&mut self) {
        if self.cur_defers.is_empty() {
            return;
        }
        let fv = self.cur_fn.unwrap();
        let defers = self.cur_defers.clone();
        for (flag, stmt) in defers.iter().rev() {
            let armed = self
                .builder
                .build_load(self.context.bool_type(), *flag, "armed")
                .unwrap()
                .into_int_value();
            let run_bb = self.context.append_basic_block(fv, "defer.run");
            let cont_bb = self.context.append_basic_block(fv, "defer.cont");
            self.builder
                .build_conditional_branch(armed, run_bb, cont_bb)
                .unwrap();
            self.builder.position_at_end(run_bb);
            self.gen_stmt(stmt);
            if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                self.builder.build_unconditional_branch(cont_bb).unwrap();
            }
            self.builder.position_at_end(cont_bb);
        }
    }

    /// A expressão produz uma string/ponteiro? Decide, nos templates e no
    /// print, entre usar o valor direto ou converter número para texto.
    /// (try/catch já são transparentes no infer_type.)
    fn expr_is_ptr(&self, e: &Expr) -> bool {
        self.infer_type(e) == Some(Type::Ptr)
    }

    /// Ajusta a largura de um inteiro para o tipo esperado (i8/i32/i64/bool).
    /// Booleanos (largura 1) estendem com zero — sign-extend transformaria
    /// `true` (1) em -1 ao alargar; o resto estende com sinal.
    fn coerce(&self, v: IntValue<'ctx>, expected: &Type) -> IntValue<'ctx> {
        let want = self.int_type(expected);
        let have = v.get_type().get_bit_width();
        if have == want.get_bit_width() {
            v
        } else if have < want.get_bit_width() {
            if have == 1 {
                self.builder.build_int_z_extend(v, want, "zext").unwrap()
            } else {
                self.builder.build_int_s_extend(v, want, "sext").unwrap()
            }
        } else {
            self.builder.build_int_truncate(v, want, "trunc").unwrap()
        }
    }

    /// O tipo LLVM de float de um `Type` (`f32`→f32, qualquer outro→f64).
    fn float_llvm(&self, t: &Type) -> inkwell::types::FloatType<'ctx> {
        match t {
            Type::F32 => self.context.f32_type(),
            _ => self.context.f64_type(),
        }
    }

    /// Reinterpreta a célula i64 como o float de tipo `t` (f64 = o i64 inteiro;
    /// f32 = trunca p/ i32 e bitcast).
    fn cell_to_float(&self, v: IntValue<'ctx>, t: &Type) -> inkwell::values::FloatValue<'ctx> {
        let v = self.coerce(v, &Type::I64);
        match t {
            Type::F32 => {
                let i32v = self
                    .builder
                    .build_int_truncate(v, self.context.i32_type(), "tf32")
                    .unwrap();
                self.builder
                    .build_bit_cast(i32v, self.context.f32_type(), "asf32")
                    .unwrap()
                    .into_float_value()
            }
            _ => self
                .builder
                .build_bit_cast(v, self.context.f64_type(), "asf64")
                .unwrap()
                .into_float_value(),
        }
    }

    /// Empacota o float `f` (de tipo `t`) na célula i64.
    fn float_to_cell(&self, f: inkwell::values::FloatValue<'ctx>, t: &Type) -> IntValue<'ctx> {
        match t {
            Type::F32 => {
                let i32v = self
                    .builder
                    .build_bit_cast(f, self.context.i32_type(), "f32bits")
                    .unwrap()
                    .into_int_value();
                self.builder
                    .build_int_z_extend(i32v, self.context.i64_type(), "f32cell")
                    .unwrap()
            }
            _ => self
                .builder
                .build_bit_cast(f, self.context.i64_type(), "ascell")
                .unwrap()
                .into_int_value(),
        }
    }

    /// Atalho: célula → f64 (promovendo se for f32). Usado nas comparações.
    fn cell_to_f64(&self, v: IntValue<'ctx>) -> inkwell::values::FloatValue<'ctx> {
        self.cell_to_float(v, &Type::F64)
    }

    /// Converte um valor da representação de `from` para a de `to`, cuidando das
    /// fronteiras inteiro↔float (sitofp/fptosi) e f32↔f64 (fpext/fptrunc).
    fn convert(&self, v: IntValue<'ctx>, from: &Type, to: &Type) -> IntValue<'ctx> {
        match (is_float(from), is_float(to)) {
            (false, false) => self.coerce(v, to),
            (true, true) => {
                if from == to {
                    v
                } else {
                    // f32 <-> f64
                    let fv = self.cell_to_float(v, from);
                    let conv = if matches!(to, Type::F64) {
                        self.builder
                            .build_float_ext(fv, self.context.f64_type(), "fpext")
                            .unwrap()
                    } else {
                        self.builder
                            .build_float_trunc(fv, self.context.f32_type(), "fptrunc")
                            .unwrap()
                    };
                    self.float_to_cell(conv, to)
                }
            }
            // inteiro → float: pega o valor inteiro real e faz sitofp
            (false, true) => {
                let iv = self.coerce(v, from);
                let fv = self
                    .builder
                    .build_signed_int_to_float(iv, self.float_llvm(to), "sitofp")
                    .unwrap();
                self.float_to_cell(fv, to)
            }
            // float → inteiro: bitcast p/ float e fptosi
            (true, false) => {
                let fv = self.cell_to_float(v, from);
                let iv = self
                    .builder
                    .build_float_to_signed_int(fv, self.context.i64_type(), "fptosi")
                    .unwrap();
                self.coerce(iv, to)
            }
        }
    }

    /// Embrulha uma expressão na caixa marcada de `any` (um `LexJson*`).
    /// Literais de objeto/array (`{ k: v }`, `{ "k": v }`, `[a, b]`) viram json
    /// ESTRUTURADO — cada elemento é embrulhado recursivamente, então
    /// `jsonAsStr` os serializa como `{"k":v}` / `[a,b]`. Qualquer outra
    /// expressão é embrulhada pelo seu tipo estático (`gen_box_value`).
    fn gen_box_any(&mut self, e: &Expr) -> IntValue<'ctx> {
        match e {
            // { campo: v, ... } e { "chave": v, ... } → objeto json
            Expr::StructLit { fields } => {
                let obj = self.call_runtime("__lex_json_object", &[], false);
                for (k, v) in fields {
                    let key = self.gen_expr(&Expr::Str(k.clone()), &Type::I64);
                    let vb = self.gen_box_any(v);
                    self.call_runtime("__lex_json_set", &[obj, key, vb], true);
                }
                obj
            }
            Expr::MapLit(entries) => {
                let obj = self.call_runtime("__lex_json_object", &[], false);
                for (k, v) in entries {
                    let key = self.gen_expr(&Expr::Str(k.clone()), &Type::I64);
                    let vb = self.gen_box_any(v);
                    self.call_runtime("__lex_json_set", &[obj, key, vb], true);
                }
                obj
            }
            // [a, b, c] → array json
            Expr::ArrayLit(items) => {
                let arr = self.call_runtime("__lex_json_array", &[], false);
                for it in items {
                    let vb = self.gen_box_any(it);
                    self.call_runtime("__lex_json_push", &[arr, vb], true);
                }
                arr
            }
            // demais: embrulha pelo tipo estático (escalar/string/struct/json)
            _ => {
                let ty = self.infer_type(e).unwrap_or(Type::I64);
                // float é gerado no seu próprio tipo (a célula carrega os bits);
                // o resto, em i64 (largura uniforme para os construtores json).
                let gen_ty = match &ty {
                    Type::F32 => Type::F32,
                    Type::F64 => Type::F64,
                    _ => Type::I64,
                };
                let v = self.gen_expr(e, &gen_ty);
                self.gen_box_value(v, &ty)
            }
        }
    }

    /// Embrulha um valor JÁ calculado (célula i64) na caixa de `any`, pelo seu
    /// tipo estático: `json`/`any` é identidade; `bool`/inteiro/string viram a
    /// tag correspondente; um struct (record) é lido campo a campo num objeto
    /// json. Array/Map/classe (sem layout escalar conhecido aqui) caem no
    /// endereço como número — limitação consciente: prefira um `json`.
    fn gen_box_value(&mut self, v: IntValue<'ctx>, ty: &Type) -> IntValue<'ctx> {
        match ty {
            // já é uma caixa
            Type::Json | Type::Any => v,
            Type::Bool => self.call_runtime("__lex_json_bool", &[v], false),
            Type::Ptr => self.call_runtime("__lex_json_str", &[v], false),
            Type::F64 => self.call_runtime("__lex_json_float", &[v], false),
            // f32: promove para f64 (a caixa json guarda double)
            Type::F32 => {
                let v64 = self.convert(v, &Type::F32, &Type::F64);
                self.call_runtime("__lex_json_float", &[v64], false)
            }
            Type::I8 | Type::I32 | Type::I64 => self.call_runtime("__lex_json_num", &[v], false),
            // struct (record): monta um objeto json lendo cada campo do bloco
            Type::Named(s, _) if self.structs.contains_key(s) => {
                let def = self.structs[s].clone();
                let i64t = self.context.i64_type();
                let block = self
                    .builder
                    .build_int_to_ptr(v, self.ptr_type(), "boxp")
                    .unwrap();
                let block_ty = self.struct_block_type(def.fields.len());
                let obj = self.call_runtime("__lex_json_object", &[], false);
                for (idx, (fname, fty)) in def.fields.iter().enumerate() {
                    let fp = self
                        .builder
                        .build_struct_gep(block_ty, block, idx as u32, "boxf")
                        .unwrap();
                    let raw = self
                        .builder
                        .build_load(i64t, fp, fname)
                        .unwrap()
                        .into_int_value();
                    let fb = self.gen_box_value(raw, fty);
                    let key = self.gen_expr(&Expr::Str(fname.clone()), &Type::I64);
                    self.call_runtime("__lex_json_set", &[obj, key, fb], true);
                }
                obj
            }
            // array/map/classe/função: guarda o endereço como número (use json)
            _ => self.call_runtime("__lex_json_num", &[v], false),
        }
    }

    fn declare_function(&mut self, func: &Function) {
        let param_types: Vec<BasicMetadataTypeEnum> = func
            .params
            .iter()
            .map(|p| self.int_type(&p.ty).into())
            .collect();

        // Falível retorna { i64, T }; void não retorna; normal retorna T.
        let fn_type = if func.fallible {
            self.err_union_type(&func.ret_type).fn_type(&param_types, false)
        } else if func.ret_type == Type::Void {
            self.context.void_type().fn_type(&param_types, false)
        } else {
            self.int_type(&func.ret_type).fn_type(&param_types, false)
        };
        // main falível vira __lex_main no LLVM; o main de verdade é gerado
        // pelo embrulho em gen_main_wrapper.
        let llvm_name = if func.name == "main" && func.fallible {
            "__lex_main"
        } else {
            func.name.as_str()
        };
        let fv = self.module.add_function(llvm_name, fn_type, None);

        self.fn_values.insert(func.name.clone(), fv);
        self.functions.insert(func.name.clone(), func.clone());
    }

    fn gen_function(&mut self, func: &Function) {
        // extern: só a declaração — o corpo vem da libc ou do .c linkado
        if func.external {
            return;
        }
        let fv = self.fn_values[&func.name];
        let entry = self.context.append_basic_block(fv, "entry");
        self.builder.position_at_end(entry);

        self.cur_fn = Some(fv);
        self.cur_entry = Some(entry);
        // lambda sem anotação de retorno: usa o tipo inferido do contexto (se
        // houver) no lugar do default `i64` — a assinatura LLVM é a mesma.
        self.cur_ret = if is_lambda(&func.name) {
            self.lambda_rets.get(&func.name).cloned().unwrap_or_else(|| func.ret_type.clone())
        } else {
            func.ret_type.clone()
        };
        self.cur_fallible = func.fallible;
        self.cur_defers = Vec::new();
        self.cur_loops = Vec::new();

        // Parâmetros viram variáveis locais (mutáveis, como no TS).
        self.vars.clear();
        for (i, p) in func.params.iter().enumerate() {
            let val = fv
                .get_nth_param(i as u32)
                .expect("parameter index out of range")
                .into_int_value();
            val.set_name(&p.name);
            let slot = self.entry_alloca(&p.name, self.int_type(&p.ty));
            self.builder.build_store(slot, val).unwrap();
            self.vars.insert(
                p.name.clone(),
                VarSlot { ptr: slot, ty: p.ty.clone(), mutable: true },
            );
        }

        // prólogo de closure: liga as capturas, lidas do env (box[1..]), como
        // variáveis locais. O `__env` (1º parâmetro) já está em self.vars.
        if is_lambda(&func.name) {
            if let Some(caps) = self.closures.get(&func.name).cloned() {
                let i64t = self.context.i64_type();
                let env = self
                    .builder
                    .build_load(i64t, self.vars["__env"].ptr, "env")
                    .unwrap()
                    .into_int_value();
                let envp = self.builder.build_int_to_ptr(env, self.ptr_type(), "envp").unwrap();
                for (i, (cname, cty)) in caps.iter().enumerate() {
                    let idx = i64t.const_int(i as u64 + 1, false);
                    let sp = unsafe {
                        self.builder.build_in_bounds_gep(i64t, envp, &[idx], "capp").unwrap()
                    };
                    let raw = self
                        .builder
                        .build_load(i64t, sp, cname)
                        .unwrap()
                        .into_int_value();
                    let slot = self.entry_alloca(cname, i64t);
                    self.builder.build_store(slot, raw).unwrap();
                    self.vars
                        .insert(cname.clone(), VarSlot { ptr: slot, ty: cty.clone(), mutable: true });
                }
            }
        }

        // antes do código do usuário, inicializa os campos static (uma vez).
        if func.name == "main" {
            self.gen_static_inits();
        }

        for stmt in &func.body {
            self.gen_stmt(stmt);
        }

        // Sem terminador no fim: cair no fim da função vale `return 0`
        // (ou nada, se a função for void).
        if self
            .builder
            .get_insert_block()
            .unwrap()
            .get_terminator()
            .is_none()
        {
            self.build_zero_return();
        }
    }

    /// Se `base.field` é `Enum.Variante`, devolve o valor inteiro (índice da
    /// variante na declaração). `base` é o NOME do enum, não uma variável.
    fn enum_const(&self, base: &Expr, field: &str) -> Option<i64> {
        if let Expr::Var(n) = base {
            if !self.vars.contains_key(n) {
                if let Some(vs) = self.enums.get(n) {
                    return vs.iter().position(|v| v == field).map(|i| i as i64);
                }
            }
        }
        None
    }

    /// Se `base.field` é acesso a campo estático de classe (base é o NOME da
    /// classe, não uma variável local), devolve (classe dona, tipo do campo).
    fn static_field_ref(&self, base: &Expr, field: &str) -> Option<(String, Type)> {
        if let Expr::Var(n) = base {
            if !self.vars.contains_key(n) {
                if let Some(meta) = self.classes.get(n) {
                    if let Some(sf) = meta.static_field(field) {
                        return Some((sf.owner.clone(), sf.ty.clone()));
                    }
                }
            }
        }
        None
    }

    /// Global (i64) que guarda um campo estático, criada sob demanda. O nome
    /// `Dono.campo` é único (o '.' não colide com identificador lex).
    fn static_global(&self, owner: &str, field: &str) -> GlobalValue<'ctx> {
        let name = format!("{}.{}", owner, field);
        if let Some(g) = self.module.get_global(&name) {
            return g;
        }
        let i64_ty = self.context.i64_type();
        let g = self.module.add_global(i64_ty, None, &name);
        g.set_initializer(&i64_ty.const_zero());
        g
    }

    /// Avalia os inicializadores de todos os campos static e grava nos globais.
    /// Roda uma vez, no início do `main`, antes de qualquer código do usuário.
    fn gen_static_inits(&mut self) {
        for cname in self.classes.order.clone() {
            let meta = self.classes.get(&cname).unwrap().clone();
            for sf in &meta.static_fields {
                // inicializa só onde foi declarado (não reinicializa em filhas)
                if sf.owner != cname {
                    continue;
                }
                let v = self.gen_expr(&sf.init, &sf.ty);
                let v64 = self.coerce(v, &Type::I64);
                let g = self.static_global(&sf.owner, &sf.name);
                self.builder.build_store(g.as_pointer_value(), v64).unwrap();
            }
        }
    }

    /// Monta o valor de retorno `{ erro, valor }` de uma função falível.
    fn build_err_union(&self, err: IntValue<'ctx>, val: IntValue<'ctx>) -> StructValue<'ctx> {
        let st = self.err_union_type(&self.cur_ret);
        let agg = st.const_zero();
        let agg = self
            .builder
            .build_insert_value(agg, err, 0, "err")
            .unwrap()
            .into_struct_value();
        self.builder
            .build_insert_value(agg, val, 1, "val")
            .unwrap()
            .into_struct_value()
    }

    /// Emite o retorno padrão (sem valor explícito): void não retorna nada,
    /// função normal retorna 0, função falível retorna sucesso com valor 0.
    /// É o que faz `return;` e a queda no fim da função valerem `return 0`.
    fn build_zero_return(&mut self) {
        self.run_defers();
        if self.cur_ret == Type::Void {
            self.builder.build_return(None).unwrap();
        } else if self.cur_fallible {
            let zero = self.context.i64_type().const_zero();
            let payload = self.int_type(&self.cur_ret).const_zero();
            let agg = self.build_err_union(zero, payload);
            self.builder.build_return(Some(&agg)).unwrap();
        } else {
            let z = self.int_type(&self.cur_ret).const_zero();
            self.builder.build_return(Some(&z)).unwrap();
        }
    }

    fn gen_stmt(&mut self, stmt: &Stmt) {
        match &stmt.kind {
            StmtKind::Let { name, ty, value, mutable } => {
                // Sem anotação, tenta inferir do valor (new/método/campo);
                // senão, assume o tipo de retorno da função como contexto
                // (ou i64 quando a função é void).
                let expected = ty
                    .clone()
                    .or_else(|| self.infer_type(value))
                    .unwrap_or_else(|| {
                        if self.cur_ret == Type::Void { Type::I64 } else { self.cur_ret.clone() }
                    });
                let v = self.gen_expr(value, &expected);
                let slot = self.entry_alloca(name, self.int_type(&expected));
                self.builder.build_store(slot, v).unwrap();
                self.vars.insert(
                    name.clone(),
                    VarSlot { ptr: slot, ty: expected, mutable: *mutable },
                );
            }

            StmtKind::Assign { name, value } => {
                let slot = self
                    .vars
                    .get(name)
                    .cloned()
                    .unwrap_or_else(|| panic!("undefined variable: {}", name));
                if !slot.mutable {
                    panic!(
                        "cannot reassign '{}': it was declared with 'const' — use 'let'",
                        name
                    );
                }
                let v = self.gen_expr(value, &slot.ty);
                self.builder.build_store(slot.ptr, v).unwrap();
            }

            // base.campo = valor — grava no slot do campo (objeto ou struct)
            StmtKind::FieldAssign { base, field, value } => {
                // `Classe.campoEstatico = v`: grava no global único da classe.
                if let Some((owner, fty)) = self.static_field_ref(base, field) {
                    let v = self.gen_expr(value, &fty);
                    let v64 = self.coerce(v, &Type::I64);
                    let g = self.static_global(&owner, field);
                    self.builder.build_store(g.as_pointer_value(), v64).unwrap();
                    return;
                }
                let tname = match self.infer_type(base) {
                    Some(Type::Named(s, _)) => s,
                    other => panic!(
                        "field assignment on something that is not an object/struct: {:?}",
                        other
                    ),
                };
                let (gep_idx, fty, n_slots) = if let Some(meta) = self.classes.get(&tname) {
                    let (slot, f) = meta
                        .slot(field)
                        .unwrap_or_else(|| panic!("class '{}' has no field '{}'", tname, field));
                    (slot, f.ty.clone(), meta.n_slots())
                } else {
                    let def = self.structs[&tname].clone();
                    let idx = def
                        .fields
                        .iter()
                        .position(|(n, _)| n == field)
                        .unwrap_or_else(|| panic!("struct '{}' has no field '{}'", tname, field));
                    (idx, def.fields[idx].1.clone(), def.fields.len())
                };

                let v = self.gen_expr(value, &fty);
                // tudo é guardado como i64 (8 bytes); o tipo real volta no load
                let v64 = self.coerce(v, &Type::I64);
                let base_i = self.gen_expr(base, &Type::I64);
                let block = self
                    .builder
                    .build_int_to_ptr(base_i, self.ptr_type(), "objp")
                    .unwrap();
                let block_ty = self.struct_block_type(n_slots);
                let fp = self
                    .builder
                    .build_struct_gep(block_ty, block, gep_idx as u32, field)
                    .unwrap();
                self.builder.build_store(fp, v64).unwrap();
            }

            // base[i] = valor — grava em array (__lex_arr_set) ou Map (__lex_map_set)
            StmtKind::IndexAssign { base, index, value } => {
                if let Some(Type::Map(t)) = self.infer_type(base) {
                    let v = self.gen_expr(value, &t);
                    let v64 = self.coerce(v, &Type::I64);
                    let b = self.gen_expr(base, &Type::I64);
                    let k = self.gen_expr(index, &Type::I64);
                    self.call_runtime("__lex_map_set", &[b, k, v64], true);
                } else {
                    let elem_ty = match self.infer_type(base) {
                        Some(Type::Array(t)) => *t,
                        _ => Type::I64,
                    };
                    let v = self.gen_expr(value, &elem_ty);
                    let v64 = self.coerce(v, &Type::I64);
                    let b = self.gen_expr(base, &Type::I64);
                    let idx = self.gen_expr(index, &Type::I64);
                    self.call_runtime("__lex_arr_set", &[b, idx, v64], true);
                }
            }

            StmtKind::While { cond, body } => {
                let fv = self.cur_fn.unwrap();
                let cond_bb = self.context.append_basic_block(fv, "while.cond");
                let body_bb = self.context.append_basic_block(fv, "while.body");
                let end_bb = self.context.append_basic_block(fv, "while.end");

                self.builder.build_unconditional_branch(cond_bb).unwrap();

                self.builder.position_at_end(cond_bb);
                let c = self.gen_expr(cond, &Type::I64);
                let zero = self.context.i64_type().const_zero();
                let cv = self
                    .builder
                    .build_int_compare(IntPredicate::NE, c, zero, "whilecond")
                    .unwrap();
                self.builder
                    .build_conditional_branch(cv, body_bb, end_bb)
                    .unwrap();

                self.builder.position_at_end(body_bb);
                let saved = self.vars.clone();
                // continue → reavalia a condição; break → sai do laço
                self.cur_loops.push((cond_bb, end_bb));
                for s in body {
                    self.gen_stmt(s);
                }
                self.cur_loops.pop();
                self.vars = saved;
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(cond_bb).unwrap();
                }

                self.builder.position_at_end(end_bb);
            }

            // for (init; cond; update) { ... } — laço estilo C.
            StmtKind::For { init, cond, update, body } => {
                let fv = self.cur_fn.unwrap();
                // a variável do init é escopada ao laço inteiro
                let saved_outer = self.vars.clone();
                if let Some(i) = init {
                    self.gen_stmt(i);
                }
                let cond_bb = self.context.append_basic_block(fv, "for.cond");
                let body_bb = self.context.append_basic_block(fv, "for.body");
                let step_bb = self.context.append_basic_block(fv, "for.step");
                let end_bb = self.context.append_basic_block(fv, "for.end");

                self.builder.build_unconditional_branch(cond_bb).unwrap();
                self.builder.position_at_end(cond_bb);
                match cond {
                    Some(c) => {
                        let cv = self.gen_expr(c, &Type::I64);
                        let zero = self.context.i64_type().const_zero();
                        let b = self
                            .builder
                            .build_int_compare(IntPredicate::NE, cv, zero, "forcond")
                            .unwrap();
                        self.builder.build_conditional_branch(b, body_bb, end_bb).unwrap();
                    }
                    // sem condição: laço infinito (só sai por break/return)
                    None => {
                        self.builder.build_unconditional_branch(body_bb).unwrap();
                    }
                }

                self.builder.position_at_end(body_bb);
                let saved_body = self.vars.clone();
                // continue → bloco de update; break → fim
                self.cur_loops.push((step_bb, end_bb));
                for s in body {
                    self.gen_stmt(s);
                }
                self.cur_loops.pop();
                self.vars = saved_body;
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(step_bb).unwrap();
                }

                self.builder.position_at_end(step_bb);
                if let Some(u) = update {
                    self.gen_stmt(u);
                }
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(cond_bb).unwrap();
                }

                self.builder.position_at_end(end_bb);
                self.vars = saved_outer;
            }

            // for (const x of arr) { ... } — itera um array via índice.
            StmtKind::ForOf { name, mutable, iterable, body } => {
                let fv = self.cur_fn.unwrap();
                let i64t = self.context.i64_type();
                let elem_ty = match self.infer_type(iterable) {
                    Some(Type::Array(t)) => *t,
                    _ => Type::I64,
                };
                let arr_v = self.gen_expr(iterable, &Type::I64);
                let arr_slot = self.entry_alloca("forof.arr", i64t);
                self.builder.build_store(arr_slot, arr_v).unwrap();
                let idx_slot = self.entry_alloca("forof.idx", i64t);
                self.builder.build_store(idx_slot, i64t.const_zero()).unwrap();

                let cond_bb = self.context.append_basic_block(fv, "forof.cond");
                let body_bb = self.context.append_basic_block(fv, "forof.body");
                let step_bb = self.context.append_basic_block(fv, "forof.step");
                let end_bb = self.context.append_basic_block(fv, "forof.end");

                self.builder.build_unconditional_branch(cond_bb).unwrap();
                self.builder.position_at_end(cond_bb);
                let arr_cur = self
                    .builder
                    .build_load(i64t, arr_slot, "arr")
                    .unwrap()
                    .into_int_value();
                let len = self.call_runtime("__lex_arr_len", &[arr_cur], false);
                let idx_cur = self
                    .builder
                    .build_load(i64t, idx_slot, "idx")
                    .unwrap()
                    .into_int_value();
                let b = self
                    .builder
                    .build_int_compare(IntPredicate::SLT, idx_cur, len, "forofcond")
                    .unwrap();
                self.builder.build_conditional_branch(b, body_bb, end_bb).unwrap();

                self.builder.position_at_end(body_bb);
                let arr_b = self
                    .builder
                    .build_load(i64t, arr_slot, "arr")
                    .unwrap()
                    .into_int_value();
                let idx_b = self
                    .builder
                    .build_load(i64t, idx_slot, "idx")
                    .unwrap()
                    .into_int_value();
                let elem = self.call_runtime("__lex_arr_get", &[arr_b, idx_b], false);
                let elem_c = self.coerce(elem, &elem_ty);
                let elem_slot = self.entry_alloca(name, self.int_type(&elem_ty));
                self.builder.build_store(elem_slot, elem_c).unwrap();
                let saved = self.vars.clone();
                self.vars.insert(
                    name.clone(),
                    VarSlot { ptr: elem_slot, ty: elem_ty.clone(), mutable: *mutable },
                );
                self.cur_loops.push((step_bb, end_bb));
                for s in body {
                    self.gen_stmt(s);
                }
                self.cur_loops.pop();
                self.vars = saved;
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(step_bb).unwrap();
                }

                self.builder.position_at_end(step_bb);
                let idx_s = self
                    .builder
                    .build_load(i64t, idx_slot, "idx")
                    .unwrap()
                    .into_int_value();
                let next = self
                    .builder
                    .build_int_add(idx_s, i64t.const_int(1, false), "next")
                    .unwrap();
                self.builder.build_store(idx_slot, next).unwrap();
                self.builder.build_unconditional_branch(cond_bb).unwrap();

                self.builder.position_at_end(end_bb);
            }

            StmtKind::Break => {
                let (_cont, brk) = *self
                    .cur_loops
                    .last()
                    .expect("'break' outside a loop slipped past the semantic checker");
                self.builder.build_unconditional_branch(brk).unwrap();
                // qualquer statement após o break é código morto — vai p/ um bloco isolado
                let fv = self.cur_fn.unwrap();
                let dead = self.context.append_basic_block(fv, "after.break");
                self.builder.position_at_end(dead);
            }
            StmtKind::Continue => {
                let (cont, _brk) = *self
                    .cur_loops
                    .last()
                    .expect("'continue' outside a loop slipped past the semantic checker");
                self.builder.build_unconditional_branch(cont).unwrap();
                let fv = self.cur_fn.unwrap();
                let dead = self.context.append_basic_block(fv, "after.continue");
                self.builder.position_at_end(dead);
            }

            StmtKind::Return(value) => match value {
                None => {
                    // `return;` sem valor = retorno padrão (0, ou nada se void)
                    self.build_zero_return();
                }
                Some(expr) => {
                    let expected = self.cur_ret.clone();
                    let v = self.gen_expr(expr, &expected);
                    // defers rodam depois de avaliar o valor de retorno (Go-style)
                    self.run_defers();
                    if self.cur_fallible {
                        // sucesso: erro = 0
                        let zero = self.context.i64_type().const_zero();
                        let agg = self.build_err_union(zero, v);
                        self.builder.build_return(Some(&agg)).unwrap();
                    } else {
                        self.builder.build_return(Some(&v)).unwrap();
                    }
                }
            },

            StmtKind::Fail(code) => {
                let err = self.gen_expr(code, &Type::I64);
                self.run_defers();
                let payload = self.int_type(&self.cur_ret).const_zero();
                let agg = self.build_err_union(err, payload);
                self.builder.build_return(Some(&agg)).unwrap();
            }

            // defer stmt: arma a flag agora; o stmt roda na saída da função
            StmtKind::Defer(inner) => {
                let flag = self.alloc_defer_flag();
                self.builder
                    .build_store(flag, self.context.bool_type().const_int(1, false))
                    .unwrap();
                self.cur_defers.push((flag, (**inner).clone()));
            }

            StmtKind::If { cond, then_body, else_body } => {
                let c = self.gen_expr(cond, &Type::I64);
                let zero = self.context.i64_type().const_zero();
                let cv = self
                    .builder
                    .build_int_compare(IntPredicate::NE, c, zero, "ifcond")
                    .unwrap();

                let fv = self.cur_fn.unwrap();
                let then_bb = self.context.append_basic_block(fv, "if.then");
                let else_bb = self.context.append_basic_block(fv, "if.else");
                let merge_bb = self.context.append_basic_block(fv, "if.end");
                self.builder
                    .build_conditional_branch(cv, then_bb, else_bb)
                    .unwrap();

                // Cada lado tem escopo próprio: `let` dentro do if não vaza.
                self.builder.position_at_end(then_bb);
                let saved = self.vars.clone();
                for s in then_body {
                    self.gen_stmt(s);
                }
                self.vars = saved;
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(merge_bb).unwrap();
                }

                self.builder.position_at_end(else_bb);
                let saved = self.vars.clone();
                for s in else_body {
                    self.gen_stmt(s);
                }
                self.vars = saved;
                if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                    self.builder.build_unconditional_branch(merge_bb).unwrap();
                }

                self.builder.position_at_end(merge_bb);
            }

            StmtKind::Expr(expr) => {
                // spawn como statement = fire-and-forget: ninguém vai dar
                // join, então a thread é desanexada (libera recursos ao fim).
                if let Expr::Spawn { name, receiver, args } = expr {
                    let tid = self.gen_spawn(name, receiver.as_deref(), args, &Type::I64);
                    let pd = self.extern_fn(
                        "pthread_detach",
                        self.context
                            .i32_type()
                            .fn_type(&[self.context.i64_type().into()], false),
                    );
                    self.builder.build_call(pd, &[tid.into()], "").unwrap();
                } else {
                    let expected =
                        if self.cur_ret == Type::Void { Type::I64 } else { self.cur_ret.clone() };
                    self.gen_expr(expr, &expected);
                }
            }
        }
    }

    /// Gera uma expressão. `expected` define a largura dos literais inteiros
    /// (ex.: `1` vira i32 ou i64 conforme o contexto).
    fn gen_expr(&mut self, expr: &Expr, expected: &Type) -> IntValue<'ctx> {
        // Coerção para `any`: qualquer valor esperado como `any` é embrulhado na
        // caixa marcada (LexJson*). Centralizado aqui, vale em TODO lugar que
        // gera uma expressão com tipo-alvo `any` — argumentos, `let x: any =`,
        // retorno, elemento de array `any[]`, etc. `gen_box_any` chama gen_expr
        // de volta só com tipos não-`any`, então não há recursão infinita.
        if *expected == Type::Any {
            return self.gen_box_any(expr);
        }
        // Coerção para `json`: um literal de objeto/array no contexto `json` vira
        // json ESTRUTURADO (cada valor embrulhado), igual ao `any`. Assim
        // `const r: json = { escola: Aluno.escola(), ok: true }` (ou com chaves
        // string `{ "a": 1 }`, ou um array `[1, 2, 3]`) já nasce como objeto/array
        // json — sem precisar de jsonObject()/jsonSet manuais. Demais expressões
        // (ex.: jsonObject(), uma var json) seguem o caminho normal: já são json.
        if *expected == Type::Json
            && matches!(
                expr,
                Expr::StructLit { .. } | Expr::MapLit(_) | Expr::ArrayLit(_)
            )
        {
            return self.gen_box_any(expr);
        }
        match expr {
            Expr::Int(n) => {
                if is_float(expected) {
                    // contexto float: o literal vira f32/f64 conforme o contexto
                    let f = self.float_llvm(expected).const_float(*n as f64);
                    self.float_to_cell(f, expected)
                } else {
                    self.int_type(expected).const_int(*n as u64, true)
                }
            }

            // literal de ponto flutuante
            Expr::Float(f) => {
                if is_float(expected) {
                    let fv = self.float_llvm(expected).const_float(*f);
                    self.float_to_cell(fv, expected)
                } else {
                    // contexto inteiro: trunca
                    self.int_type(expected).const_int(*f as i64 as u64, true)
                }
            }

            // true/false: 1/0, na largura do contexto (i1 se Bool)
            Expr::Bool(b) => self.int_type(expected).const_int(*b as u64, false),

            // literal vira constante global (terminada em NUL); o valor da
            // expressão é o endereço dela
            Expr::Str(s) => {
                let g = self
                    .builder
                    .build_global_string_ptr(s, ".str")
                    .unwrap()
                    .as_pointer_value();
                let addr = self
                    .builder
                    .build_ptr_to_int(g, self.context.i64_type(), "straddr")
                    .unwrap();
                self.coerce(addr, expected)
            }

            // `a ${x} b`: cada parte vira um ptr (string global, valor ptr,
            // ou inteiro convertido) e tudo é dobrado com __lex_concat.
            Expr::Template(parts) => {
                let mut cur: Option<IntValue<'ctx>> = None;
                for p in parts.clone() {
                    let piece = match &p {
                        TemplatePart::Lit(s) => self.gen_expr(&Expr::Str(s.clone()), &Type::I64),
                        TemplatePart::Expr(e) => {
                            match self.infer_type(e) {
                                // array (ex.: Component[]/string[]) é renderizado
                                // juntando os elementos sem separador — é o que
                                // permite listas/loops de componentes no template
                                Some(Type::Array(_)) => {
                                    let arr = self.gen_expr(e, &Type::I64);
                                    let empty =
                                        self.gen_expr(&Expr::Str(String::new()), &Type::I64);
                                    self.call_runtime("__lex_arr_join", &[arr, empty], false)
                                }
                                // float vira texto com o formatador de double
                                // (f32 é promovido a f64 pelo gen_expr)
                                Some(Type::F64) | Some(Type::F32) => {
                                    let v = self.gen_expr(e, &Type::F64);
                                    self.call_runtime("__lex_f64_to_str", &[v], false)
                                }
                                // bool vira "true"/"false" (igual ao Terminal.log)
                                Some(Type::Bool) => {
                                    let v = self.gen_expr(e, &Type::I64);
                                    let jb = self.call_runtime("__lex_json_bool", &[v], false);
                                    self.call_runtime("__lex_json_as_str", &[jb], false)
                                }
                                _ if self.expr_is_ptr(e) => self.gen_expr(e, &Type::I64),
                                _ => {
                                    // número vira texto na arena
                                    let v = self.gen_expr(e, &Type::I64);
                                    self.call_runtime("__lex_i64_to_str", &[v], false)
                                }
                            }
                        }
                    };
                    cur = Some(match cur {
                        None => piece,
                        Some(acc) => self.call_runtime("__lex_concat", &[acc, piece], false),
                    });
                }
                let res = cur
                    .unwrap_or_else(|| self.gen_expr(&Expr::Str(String::new()), &Type::I64));
                self.coerce(res, expected)
            }

            // valor de arrow: monta o closure box [fn_ptr, capturas...]. As
            // candidatas que são variáveis locais viram capturas (por valor);
            // as globais (funções/classes) são ignoradas.
            Expr::Closure { name, captures } => {
                // tipo de retorno vindo do contexto (o `Fn` esperado): corrige o
                // default `i64` para que o corpo da arrow gere no tipo certo.
                if let Type::Fn(_, ret) = expected {
                    self.lambda_rets.insert(name.clone(), (**ret).clone());
                }
                let fv = self.fn_values[name];
                let fn_addr = self
                    .builder
                    .build_ptr_to_int(
                        fv.as_global_value().as_pointer_value(),
                        self.context.i64_type(),
                        "lamfn",
                    )
                    .unwrap();
                let mut layout: Vec<(String, Type)> = Vec::new();
                let mut vals: Vec<IntValue> = Vec::new();
                for c in captures {
                    if let Some(slot) = self.vars.get(c).cloned() {
                        let v = self
                            .builder
                            .build_load(self.int_type(&slot.ty), slot.ptr, c)
                            .unwrap()
                            .into_int_value();
                        vals.push(self.coerce(v, &Type::I64));
                        layout.push((c.clone(), slot.ty.clone()));
                    }
                }
                self.closures.insert(name.clone(), layout);
                let boxv = self.make_closure_box(fn_addr, &vals);
                self.coerce(boxv, expected)
            }

            Expr::Var(name) => {
                if let Some(slot) = self.vars.get(name).cloned() {
                    let v = self
                        .builder
                        .build_load(self.int_type(&slot.ty), slot.ptr, name)
                        .unwrap()
                        .into_int_value();
                    return self.convert(v, &slot.ty, expected);
                }
                // não é variável: função de topo usada como valor. Embrulha num
                // closure box com o thunk `__fnval_F` (que ignora o env) para
                // ficar compatível com a ABI de closure.
                let thunk = *self
                    .fn_thunks
                    .get(name)
                    .unwrap_or_else(|| panic!("'{}' cannot be used as a value", name));
                let fn_addr = self
                    .builder
                    .build_ptr_to_int(
                        thunk.as_global_value().as_pointer_value(),
                        self.context.i64_type(),
                        "fnvaladdr",
                    )
                    .unwrap();
                let boxv = self.make_closure_box(fn_addr, &[]);
                self.coerce(boxv, expected)
            }

            // base.campo: base é um ponteiro para o bloco [i64 x N]; carrega
            // o campo no índice certo e coage para o tipo pedido. Em objeto
            // de classe, o slot 0 é a vtable — os campos começam no 1.
            Expr::Field { base, field } => {
                // `Enum.Variante`: constante inteira (índice da variante).
                if let Some(v) = self.enum_const(base, field) {
                    let c = self.context.i64_type().const_int(v as u64, true);
                    return self.coerce(c, expected);
                }
                // `Classe.campoEstatico`: lê do global único da classe.
                if let Some((owner, fty)) = self.static_field_ref(base, field) {
                    let g = self.static_global(&owner, field);
                    let i64t = self.context.i64_type();
                    let raw = self
                        .builder
                        .build_load(i64t, g.as_pointer_value(), field)
                        .unwrap()
                        .into_int_value();
                    return self.convert(raw, &fty, expected);
                }
                let sname = match self.infer_type(base) {
                    Some(Type::Named(s, _)) => s,
                    other => panic!("field access on something that is not a struct/object: {:?}", other),
                };
                let (idx, n_slots, fty) = if let Some(meta) = self.classes.get(&sname) {
                    let (slot, f) = meta
                        .slot(field)
                        .unwrap_or_else(|| panic!("class '{}' has no field '{}'", sname, field));
                    (slot, meta.n_slots(), f.ty.clone())
                } else {
                    let def = self.structs[&sname].clone();
                    let idx = def
                        .fields
                        .iter()
                        .position(|(n, _)| n == field)
                        .unwrap_or_else(|| panic!("struct '{}' has no field '{}'", sname, field));
                    (idx, def.fields.len(), def.fields[idx].1.clone())
                };

                let base_i = self.gen_expr(base, &Type::I64);
                let i64t = self.context.i64_type();
                let block = self
                    .builder
                    .build_int_to_ptr(base_i, self.ptr_type(), "structp")
                    .unwrap();
                let block_ty = self.struct_block_type(n_slots);
                let fp = self
                    .builder
                    .build_struct_gep(block_ty, block, idx as u32, "fieldp")
                    .unwrap();
                let raw = self
                    .builder
                    .build_load(i64t, fp, field)
                    .unwrap()
                    .into_int_value();
                self.convert(raw, &fty, expected)
            }

            // { campo: e, ... }: aloca um bloco [i64 x N] na arena e preenche
            // os campos na ordem do type-alvo (vindo de `expected`).
            Expr::StructLit { fields } => {
                let sname = match expected {
                    Type::Named(s, _) => s.clone(),
                    _ => panic!(
                        "struct literal without a known target type — use it in a typed parameter/return"
                    ),
                };
                let def = self
                    .structs
                    .get(&sname)
                    .unwrap_or_else(|| {
                        panic!(
                            "'{}' is not a struct — if it is a class, instantiate it with new {}(...)",
                            sname, sname
                        )
                    })
                    .clone();
                let i64t = self.context.i64_type();
                let n = def.fields.len();

                let size = i64t.const_int((n as u64) * 8, false);
                let block_i = self.call_runtime("__lex_alloc", &[size], false);
                let block = self
                    .builder
                    .build_int_to_ptr(block_i, self.ptr_type(), "structp")
                    .unwrap();
                let block_ty = self.struct_block_type(n);

                for (idx, (fname, fty)) in def.fields.iter().enumerate() {
                    let provided = fields.iter().find(|(n, _)| n == fname);
                    let v = match provided {
                        // armazena tudo como i64 (8 bytes); o tipo real volta no load
                        Some((_, e)) => {
                            let val = self.gen_expr(e, fty);
                            self.coerce(val, &Type::I64)
                        }
                        None => i64t.const_zero(),
                    };
                    let fp = self
                        .builder
                        .build_struct_gep(block_ty, block, idx as u32, fname)
                        .unwrap();
                    self.builder.build_store(fp, v).unwrap();
                }
                self.coerce(block_i, expected)
            }

            // [a, b, c]: aloca um LexArr na arena e dá push em cada elemento.
            // O tipo do elemento vem do contexto (Array(T)) ou é inferido.
            Expr::ArrayLit(elems) => {
                let elem_ty = match expected {
                    Type::Array(t) => (**t).clone(),
                    _ => elems
                        .first()
                        .and_then(|e| self.infer_type(e))
                        .unwrap_or(Type::I64),
                };
                let i64t = self.context.i64_type();
                let cap = i64t.const_int(elems.len().max(4) as u64, false);
                let arr = self.call_runtime("__lex_arr_new", &[cap], false);
                for e in elems {
                    let v = self.gen_expr(e, &elem_ty);
                    let v64 = self.coerce(v, &Type::I64);
                    self.call_runtime("__lex_arr_push", &[arr, v64], true);
                }
                self.coerce(arr, expected)
            }

            // { "k": v, ... }: aloca um LexMap na arena e seta cada chave.
            Expr::MapLit(entries) => {
                let val_ty = match expected {
                    Type::Map(t) => (**t).clone(),
                    _ => entries
                        .first()
                        .and_then(|(_, v)| self.infer_type(v))
                        .unwrap_or(Type::I64),
                };
                let m = self.call_runtime("__lex_map_new", &[], false);
                for (k, v) in entries {
                    let kptr = self.gen_expr(&Expr::Str(k.clone()), &Type::I64);
                    let vv = self.gen_expr(v, &val_ty);
                    let v64 = self.coerce(vv, &Type::I64);
                    self.call_runtime("__lex_map_set", &[m, kptr, v64], true);
                }
                self.coerce(m, expected)
            }

            // base[i]: leitura indexada — array, Map ou JSON
            Expr::Index { base, index } => {
                match self.infer_type(base) {
                    // Map<T>: m[chave] → __lex_map_get, valor é T
                    Some(Type::Map(t)) => {
                        let elem = *t;
                        let b = self.gen_expr(base, &Type::I64);
                        let k = self.gen_expr(index, &Type::I64);
                        let r = self.call_runtime("__lex_map_get", &[b, k], false);
                        self.convert(r, &elem, expected)
                    }
                    // JSON: chave string → membro (json_get); índice int → elemento (json_at)
                    Some(Type::Json) => {
                        let by_key = matches!(self.infer_type(index), Some(Type::Ptr));
                        let sym = if by_key { "__lex_json_get" } else { "__lex_json_at" };
                        let b = self.gen_expr(base, &Type::I64);
                        let k = self.gen_expr(index, &Type::I64);
                        let r = self.call_runtime(sym, &[b, k], false);
                        self.convert(r, &Type::Json, expected)
                    }
                    // array (e tipo desconhecido → trata como array): __lex_arr_get
                    other => {
                        let elem_ty = match other {
                            Some(Type::Array(t)) => *t,
                            _ => Type::I64,
                        };
                        let b = self.gen_expr(base, &Type::I64);
                        let idx = self.gen_expr(index, &Type::I64);
                        let r = self.call_runtime("__lex_arr_get", &[b, idx], false);
                        self.convert(r, &elem_ty, expected)
                    }
                }
            }

            Expr::Binary { op, lhs, rhs } => self.gen_binary(*op, lhs, rhs, expected),

            // match como expressão: o valor é o do braço que casar
            Expr::Match { scrutinee, arms } => self.gen_match(scrutinee, arms, expected),

            // -x / !x / ~x
            Expr::Unary { op, operand } => match op {
                UnOp::Neg => {
                    if is_float(expected) {
                        let vc = self.gen_expr(operand, expected);
                        let v = self.cell_to_float(vc, expected);
                        let neg = self.builder.build_float_neg(v, "fneg").unwrap();
                        self.float_to_cell(neg, expected)
                    } else {
                        let v = self.gen_expr(operand, expected);
                        self.builder.build_int_neg(v, "negtmp").unwrap()
                    }
                }
                UnOp::BitNot => {
                    let v = self.gen_expr(operand, expected);
                    self.builder.build_not(v, "nottmp").unwrap()
                }
                UnOp::Not => {
                    // !x : verdadeiro (1) sse x == 0; resultado vai p/ o contexto
                    let v = self.gen_expr(operand, &Type::I64);
                    let zero = self.context.i64_type().const_zero();
                    let b = self
                        .builder
                        .build_int_compare(IntPredicate::EQ, v, zero, "lnot")
                        .unwrap();
                    self.coerce(b, expected)
                }
            },

            Expr::Call { name, type_args, args } => {
                // chamada através de uma variável (valor de função / closure)?
                if let Some(slot) = self.vars.get(name).cloned() {
                    let Type::Fn(ptypes, ret) = &slot.ty else {
                        panic!("'{}' is not a function (the semantic checker should have rejected this)", name);
                    };
                    let box_val = self
                        .builder
                        .build_load(self.context.i64_type(), slot.ptr, name)
                        .unwrap()
                        .into_int_value();
                    let arg_vals: Vec<IntValue> = args
                        .iter()
                        .enumerate()
                        .map(|(i, a)| self.gen_expr(a, &ptypes[i].clone()))
                        .collect();
                    let (pt, rt) = (ptypes.clone(), (**ret).clone());
                    return self.gen_closure_call(box_val, &pt, &rt, arg_vals, expected);
                }

                if builtins::is_builtin(name) {
                    return self.gen_builtin(name, args, expected);
                }

                let callee = self
                    .functions
                    .get(name)
                    .unwrap_or_else(|| panic!("unknown function: {}", name))
                    .clone();
                // async fn: chamá-la lança uma thread e devolve o Future (handle)
                if callee.is_async {
                    return self.gen_spawn(name, None, args, expected);
                }
                if callee.fallible {
                    // o sema já barrou isso; se chegou aqui, é bug do compilador
                    panic!("fallible call without try/catch slipped past the semantic checker: {}", name);
                }
                // tipo de retorno concreto (substitui T numa função genérica)
                let ret_ty = if callee.type_params.is_empty() {
                    callee.ret_type.clone()
                } else {
                    let map = self.generic_call_map(&callee, type_args, args);
                    subst_type(&callee.ret_type, &map)
                };
                match self.gen_raw_call(&callee, type_args, args) {
                    Some(v) => self.convert(v.into_int_value(), &ret_ty, expected),
                    // chamada void usada como valor vale 0
                    None => self.int_type(expected).const_zero(),
                }
            }

            // try f(): erro != 0? devolve { erro, 0 } para o chamador.
            Expr::Try(inner) => {
                let (agg, _payload_ty) = self.gen_fallible_agg(inner);
                let err = self
                    .builder
                    .build_extract_value(agg, 0, "err")
                    .unwrap()
                    .into_int_value();
                let val = self
                    .builder
                    .build_extract_value(agg, 1, "val")
                    .unwrap()
                    .into_int_value();

                let zero = self.context.i64_type().const_zero();
                let is_err = self
                    .builder
                    .build_int_compare(IntPredicate::NE, err, zero, "iserr")
                    .unwrap();

                let fv = self.cur_fn.unwrap();
                let prop_bb = self.context.append_basic_block(fv, "try.prop");
                let cont_bb = self.context.append_basic_block(fv, "try.cont");
                self.builder
                    .build_conditional_branch(is_err, prop_bb, cont_bb)
                    .unwrap();

                // propaga: mesma struct de erro, payload zerado desta função
                self.builder.position_at_end(prop_bb);
                self.run_defers();
                let payload = self.int_type(&self.cur_ret).const_zero();
                let prop = self.build_err_union(err, payload);
                self.builder.build_return(Some(&prop)).unwrap();

                self.builder.position_at_end(cont_bb);
                self.coerce(val, expected)
            }

            // f() catch ...: erro != 0? trata (valor de fallback ou bloco).
            Expr::Catch { lhs, handler } => {
                let (agg, payload_ty) = self.gen_fallible_agg(lhs);
                let err = self
                    .builder
                    .build_extract_value(agg, 0, "err")
                    .unwrap()
                    .into_int_value();
                let val = self
                    .builder
                    .build_extract_value(agg, 1, "val")
                    .unwrap()
                    .into_int_value();

                let zero = self.context.i64_type().const_zero();
                let is_err = self
                    .builder
                    .build_int_compare(IntPredicate::NE, err, zero, "iserr")
                    .unwrap();

                let fv = self.cur_fn.unwrap();
                let ok_bb = self.builder.get_insert_block().unwrap();
                let err_bb = self.context.append_basic_block(fv, "catch.err");
                let merge_bb = self.context.append_basic_block(fv, "catch.end");
                self.builder
                    .build_conditional_branch(is_err, err_bb, merge_bb)
                    .unwrap();

                self.builder.position_at_end(err_bb);
                // valor produzido no ramo de erro + o bloco onde ele termina
                let err_val: IntValue<'ctx>;
                match handler {
                    CatchHandler::Fallback(fb) => {
                        err_val = self.gen_expr(fb, &payload_ty);
                    }
                    CatchHandler::Block { name, body } => {
                        // novo escopo; `e` (se houver) recebe o código do erro
                        let saved = self.vars.clone();
                        if let Some(n) = name {
                            let slot = self.entry_alloca(n, self.context.i64_type());
                            self.builder.build_store(slot, err).unwrap();
                            self.vars.insert(
                                n.clone(),
                                VarSlot { ptr: slot, ty: Type::I64, mutable: false },
                            );
                        }
                        // todos os statements menos o último; o último, se for
                        // expressão, vira o valor do catch (senão, o valor é 0)
                        let (last, init) = body.split_last().map_or((None, &body[..]), |(l, i)| (Some(l), i));
                        for s in init {
                            self.gen_stmt(s);
                        }
                        err_val = match last {
                            Some(Stmt { kind: StmtKind::Expr(e), .. }) if self.builder.get_insert_block().unwrap().get_terminator().is_none() => {
                                self.gen_expr(e, &payload_ty)
                            }
                            Some(s) => {
                                self.gen_stmt(s);
                                self.int_type(&payload_ty).const_zero()
                            }
                            None => self.int_type(&payload_ty).const_zero(),
                        };
                        self.vars = saved;
                    }
                }
                // o handler pode ter criado blocos novos (ou terminado o fluxo,
                // ex.: `catch e { fail e }`) — só faz merge se ainda houver saída
                let err_open = self.builder.get_insert_block().unwrap().get_terminator().is_none();
                let err_end_bb = self.builder.get_insert_block().unwrap();
                if err_open {
                    self.builder.build_unconditional_branch(merge_bb).unwrap();
                }

                self.builder.position_at_end(merge_bb);
                let phi = self
                    .builder
                    .build_phi(self.int_type(&payload_ty), "catchval")
                    .unwrap();
                if err_open {
                    phi.add_incoming(&[(&val, ok_bb), (&err_val, err_end_bb)]);
                } else {
                    // ramo de erro não cai no merge (terminou com return/fail)
                    phi.add_incoming(&[(&val, ok_bb)]);
                }
                self.coerce(phi.as_basic_value().into_int_value(), expected)
            }

            // spawn f(args): copia os args para o heap e cria a thread.
            Expr::Spawn { name, receiver, args } => {
                self.gen_spawn(name, receiver.as_deref(), args, expected)
            }

            // await fut: espera o Future (handle) resolver — é o join da thread.
            Expr::Await(inner) => self.gen_join(inner, expected),

            // new Classe(args): aloca, instala a vtable e chama o construtor.
            Expr::New { class, type_args, args } => self.gen_new(class, type_args, args, expected),

            // base.metodo(args): dispatch dinâmico (ou estático/campo-função).
            Expr::MethodCall { base, method, args } => {
                // extensão: `receiver.builtin(args)` == `builtin(receiver, args)`.
                if let Some(all) = self.builtin_method_args(base, method, args) {
                    return self.gen_builtin(method, &all, expected);
                }
                let (res, ret_ty, _) = self.gen_method_call(base, method, args);
                match res {
                    Some(v) => self.convert(v.into_int_value(), &ret_ty, expected),
                    // método void usado como valor vale 0
                    None => self.int_type(expected).const_zero(),
                }
            }

            // super(args) / super.metodo(args): chamada direta, sem dispatch.
            Expr::SuperCall { method, args } => {
                let (res, ret_ty, _) = self.gen_super_call(method.as_deref(), args);
                match res {
                    Some(v) => self.convert(v.into_int_value(), &ret_ty, expected),
                    None => self.int_type(expected).const_zero(),
                }
            }
        }
    }

    /// Gera um `match` como expressão: avalia o scrutinee uma vez, testa os
    /// braços em cadeia (padrão + guarda opcional) e junta os valores num phi.
    /// O valor de um braço é o do corpo (última expressão do bloco, como no
    /// `catch`); braços sem corpo-expressão valem 0. Sem nenhum casamento, 0.
    fn gen_match(
        &mut self,
        scrutinee: &Expr,
        arms: &[MatchArm],
        expected: &Type,
    ) -> IntValue<'ctx> {
        let fv = self.cur_fn.unwrap();
        let i64t = self.context.i64_type();
        let sty = self.infer_type(scrutinee).unwrap_or(Type::I64);
        let sval = self.gen_expr(scrutinee, &sty);
        let s64 = self.coerce(sval, &Type::I64);
        let scrut_slot = self.entry_alloca("match.scrut", i64t);
        self.builder.build_store(scrut_slot, s64).unwrap();

        let merge_bb = self.context.append_basic_block(fv, "match.end");
        let mut incoming: Vec<(IntValue<'ctx>, BasicBlock<'ctx>)> = Vec::new();

        for arm in arms {
            // testa o padrão no bloco atual (predecessor do corpo)
            let scrut = self
                .builder
                .build_load(i64t, scrut_slot, "scrut")
                .unwrap()
                .into_int_value();
            let pat_ok: IntValue<'ctx> = match &arm.pattern {
                // irrefutáveis: sempre casam
                Pattern::Wildcard | Pattern::Binding(_) | Pattern::Destructure(_) => {
                    self.context.bool_type().const_int(1, false)
                }
                Pattern::Int(n) => {
                    let c = i64t.const_int(*n as u64, true);
                    self.builder.build_int_compare(IntPredicate::EQ, scrut, c, "marm").unwrap()
                }
                Pattern::Bool(b) => {
                    let c = i64t.const_int(*b as u64, false);
                    self.builder.build_int_compare(IntPredicate::EQ, scrut, c, "marm").unwrap()
                }
                Pattern::Str(s) => {
                    let lit = self.gen_expr(&Expr::Str(s.clone()), &Type::I64);
                    let eq = self.call_runtime("__lex_str_eq", &[scrut, lit], false);
                    let zero = i64t.const_zero();
                    self.builder.build_int_compare(IntPredicate::NE, eq, zero, "marm").unwrap()
                }
                Pattern::Range(lo, hi) => {
                    let loc = i64t.const_int(*lo as u64, true);
                    let hic = i64t.const_int(*hi as u64, true);
                    let ge = self.builder.build_int_compare(IntPredicate::SGE, scrut, loc, "rge").unwrap();
                    let lt = self.builder.build_int_compare(IntPredicate::SLT, scrut, hic, "rlt").unwrap();
                    self.builder.build_and(ge, lt, "rin").unwrap()
                }
                // padrão de enum: casa se o valor for a constante da variante.
                Pattern::EnumVariant { enum_name, variant } => {
                    let idx = self
                        .enums
                        .get(enum_name)
                        .and_then(|vs| vs.iter().position(|v| v == variant))
                        .unwrap_or(0) as u64;
                    let c = i64t.const_int(idx, true);
                    self.builder.build_int_compare(IntPredicate::EQ, scrut, c, "enarm").unwrap()
                }
                // padrão de tipo: o slot 0 do objeto guarda o endereço da vtable
                // (como i64); casa se for o da classe do padrão (tipo exato).
                Pattern::Type { class, .. } => {
                    let objp = self
                        .builder
                        .build_int_to_ptr(scrut, self.ptr_type(), "objp")
                        .unwrap();
                    let vt = self
                        .builder
                        .build_load(i64t, objp, "vt")
                        .unwrap()
                        .into_int_value();
                    let want = self.vtables[class].const_to_int(i64t);
                    self.builder.build_int_compare(IntPredicate::EQ, vt, want, "tymatch").unwrap()
                }
            };

            let body_bb = self.context.append_basic_block(fv, "match.arm");
            let next_bb = self.context.append_basic_block(fv, "match.next");
            self.builder.build_conditional_branch(pat_ok, body_bb, next_bb).unwrap();

            // corpo do braço (com binding e guarda)
            self.builder.position_at_end(body_bb);
            let saved = self.vars.clone();
            match &arm.pattern {
                Pattern::Binding(n) => {
                    let bv = self.coerce(scrut, &sty);
                    let slot = self.entry_alloca(n, self.int_type(&sty));
                    self.builder.build_store(slot, bv).unwrap();
                    self.vars.insert(
                        n.clone(),
                        VarSlot { ptr: slot, ty: sty.clone(), mutable: false },
                    );
                }
                // liga o objeto já tipado como a classe do padrão
                Pattern::Type { class, bind } if bind != "_" => {
                    let cty = Type::Named(class.clone(), Vec::new());
                    let slot = self.entry_alloca(bind, i64t);
                    self.builder.build_store(slot, scrut).unwrap();
                    self.vars.insert(
                        bind.clone(),
                        VarSlot { ptr: slot, ty: cty, mutable: false },
                    );
                }
                // destructuring: carrega cada campo do alvo numa variável
                Pattern::Destructure(names) => {
                    if let Type::Named(tn, _) = &sty {
                        let objp = self
                            .builder
                            .build_int_to_ptr(scrut, self.ptr_type(), "destp")
                            .unwrap();
                        for name in names {
                            let (idx, n_slots, fty) = if let Some(meta) = self.classes.get(tn) {
                                let (slot, f) = meta.slot(name).unwrap_or_else(|| {
                                    panic!("class '{}' has no field '{}'", tn, name)
                                });
                                (slot, meta.n_slots(), f.ty.clone())
                            } else {
                                let def = self.structs[tn].clone();
                                let i = def
                                    .fields
                                    .iter()
                                    .position(|(n, _)| n == name)
                                    .unwrap_or_else(|| {
                                        panic!("struct '{}' has no field '{}'", tn, name)
                                    });
                                (i, def.fields.len(), def.fields[i].1.clone())
                            };
                            let block_ty = self.struct_block_type(n_slots);
                            let fp = self
                                .builder
                                .build_struct_gep(block_ty, objp, idx as u32, name)
                                .unwrap();
                            let raw = self
                                .builder
                                .build_load(i64t, fp, name)
                                .unwrap()
                                .into_int_value();
                            let slot = self.entry_alloca(name, i64t);
                            self.builder.build_store(slot, raw).unwrap();
                            self.vars.insert(
                                name.clone(),
                                VarSlot { ptr: slot, ty: fty, mutable: false },
                            );
                        }
                    }
                }
                _ => {}
            }
            // guarda: se falhar, tenta o próximo braço (vai p/ next_bb)
            if let Some(g) = &arm.guard {
                let gv = self.gen_expr(g, &Type::I64);
                let zero = i64t.const_zero();
                let gtrue = self.builder.build_int_compare(IntPredicate::NE, gv, zero, "guard").unwrap();
                let pass_bb = self.context.append_basic_block(fv, "match.guard");
                self.builder.build_conditional_branch(gtrue, pass_bb, next_bb).unwrap();
                self.builder.position_at_end(pass_bb);
            }

            // valor do corpo: última expressão (como no catch)
            let (last, init) = arm.body.split_last().map_or((None, &arm.body[..]), |(l, i)| (Some(l), i));
            for s in init {
                self.gen_stmt(s);
            }
            let arm_val = match last {
                Some(Stmt { kind: StmtKind::Expr(e), .. })
                    if self.builder.get_insert_block().unwrap().get_terminator().is_none() =>
                {
                    self.gen_expr(e, expected)
                }
                Some(s) => {
                    self.gen_stmt(s);
                    self.int_type(expected).const_zero()
                }
                None => self.int_type(expected).const_zero(),
            };
            // se o corpo não desviou o fluxo, leva o valor ao merge
            if self.builder.get_insert_block().unwrap().get_terminator().is_none() {
                let end = self.builder.get_insert_block().unwrap();
                incoming.push((arm_val, end));
                self.builder.build_unconditional_branch(merge_bb).unwrap();
            }
            self.vars = saved;

            // próximos braços são testados a partir do next_bb
            self.builder.position_at_end(next_bb);
        }

        // fall-through (nenhum braço casou): valor padrão 0
        let default_val = self.int_type(expected).const_zero();
        let default_bb = self.builder.get_insert_block().unwrap();
        incoming.push((default_val, default_bb));
        self.builder.build_unconditional_branch(merge_bb).unwrap();

        self.builder.position_at_end(merge_bb);
        let phi = self.builder.build_phi(self.int_type(expected), "matchval").unwrap();
        let refs: Vec<(&dyn inkwell::values::BasicValue, BasicBlock)> = incoming
            .iter()
            .map(|(v, b)| (v as &dyn inkwell::values::BasicValue, *b))
            .collect();
        phi.add_incoming(&refs);
        phi.as_basic_value().into_int_value()
    }

    /// Gera uma expressão binária. Aritmética e bitwise operam na largura do
    /// contexto; comparações operam em i64 e o resultado vai para o contexto;
    /// `&&`/`||` têm avaliação com curto-circuito (ver `gen_short_circuit`).
    fn gen_binary(
        &mut self,
        op: BinOp,
        lhs: &Expr,
        rhs: &Expr,
        expected: &Type,
    ) -> IntValue<'ctx> {
        use BinOp::*;

        // aritmética em ponto flutuante (f32 ou f64, conforme o contexto)
        if is_float(expected) && matches!(op, Add | Sub | Mul | Div | Mod) {
            let lc = self.gen_expr(lhs, expected);
            let l = self.cell_to_float(lc, expected);
            let rc = self.gen_expr(rhs, expected);
            let r = self.cell_to_float(rc, expected);
            let res = match op {
                Add => self.builder.build_float_add(l, r, "faddtmp").unwrap(),
                Sub => self.builder.build_float_sub(l, r, "fsubtmp").unwrap(),
                Mul => self.builder.build_float_mul(l, r, "fmultmp").unwrap(),
                Div => self.builder.build_float_div(l, r, "fdivtmp").unwrap(),
                Mod => self.builder.build_float_rem(l, r, "fremtmp").unwrap(),
                _ => unreachable!(),
            };
            return self.float_to_cell(res, expected);
        }

        match op {
            Add | Sub | Mul | Div | Mod | BitAnd | BitOr | BitXor | Shl | Shr => {
                let l = self.gen_expr(lhs, expected);
                let r = self.gen_expr(rhs, expected);
                match op {
                    Add => self.builder.build_int_add(l, r, "addtmp").unwrap(),
                    Sub => self.builder.build_int_sub(l, r, "subtmp").unwrap(),
                    Mul => self.builder.build_int_mul(l, r, "multmp").unwrap(),
                    Div => self.builder.build_int_signed_div(l, r, "divtmp").unwrap(),
                    Mod => self.builder.build_int_signed_rem(l, r, "modtmp").unwrap(),
                    BitAnd => self.builder.build_and(l, r, "andtmp").unwrap(),
                    BitOr => self.builder.build_or(l, r, "ortmp").unwrap(),
                    BitXor => self.builder.build_xor(l, r, "xortmp").unwrap(),
                    Shl => self.builder.build_left_shift(l, r, "shltmp").unwrap(),
                    // shift à direita ARITMÉTICO (com sinal), coerente com ints com sinal
                    Shr => self.builder.build_right_shift(l, r, true, "shrtmp").unwrap(),
                    _ => unreachable!(),
                }
            }
            Eq | Ne | Lt | Gt | Le | Ge => {
                // se algum operando é float, compara como double (fcmp ordenado)
                let lf = is_float(&self.infer_type(lhs).unwrap_or(Type::I64));
                let rf = is_float(&self.infer_type(rhs).unwrap_or(Type::I64));
                if lf || rf {
                    let lc = self.gen_expr(lhs, &Type::F64);
                    let l = self.cell_to_f64(lc);
                    let rc = self.gen_expr(rhs, &Type::F64);
                    let r = self.cell_to_f64(rc);
                    let pred = match op {
                        Eq => FloatPredicate::OEQ,
                        Ne => FloatPredicate::ONE,
                        Lt => FloatPredicate::OLT,
                        Gt => FloatPredicate::OGT,
                        Le => FloatPredicate::OLE,
                        Ge => FloatPredicate::OGE,
                        _ => unreachable!(),
                    };
                    let b = self.builder.build_float_compare(pred, l, r, "fcmptmp").unwrap();
                    return self.coerce(b, expected);
                }
                // Comparações inteiras sempre em i64; o resultado (0 ou 1) vai
                // para a largura que o contexto pedir.
                let l = self.gen_expr(lhs, &Type::I64);
                let r = self.gen_expr(rhs, &Type::I64);
                let pred = match op {
                    Eq => IntPredicate::EQ,
                    Ne => IntPredicate::NE,
                    Lt => IntPredicate::SLT,
                    Gt => IntPredicate::SGT,
                    Le => IntPredicate::SLE,
                    Ge => IntPredicate::SGE,
                    _ => unreachable!(),
                };
                let b = self.builder.build_int_compare(pred, l, r, "cmptmp").unwrap();
                self.coerce(b, expected)
            }
            And | Or => self.gen_short_circuit(op, lhs, rhs, expected),
        }
    }

    /// `&&` / `||` com curto-circuito: o lado direito só é avaliado se
    /// necessário. O resultado é booleano (0/1) coagido ao contexto.
    fn gen_short_circuit(
        &mut self,
        op: BinOp,
        lhs: &Expr,
        rhs: &Expr,
        expected: &Type,
    ) -> IntValue<'ctx> {
        let i64t = self.context.i64_type();
        let zero = i64t.const_zero();
        let fv = self.cur_fn.unwrap();

        let l = self.gen_expr(lhs, &Type::I64);
        let lbool = self
            .builder
            .build_int_compare(IntPredicate::NE, l, zero, "lbool")
            .unwrap();
        let entry_bb = self.builder.get_insert_block().unwrap();

        let rhs_bb = self.context.append_basic_block(fv, "sc.rhs");
        let merge_bb = self.context.append_basic_block(fv, "sc.end");

        // &&: avalia rhs só se l for verdadeiro; ||: só se l for falso
        match op {
            BinOp::And => self
                .builder
                .build_conditional_branch(lbool, rhs_bb, merge_bb)
                .unwrap(),
            BinOp::Or => self
                .builder
                .build_conditional_branch(lbool, merge_bb, rhs_bb)
                .unwrap(),
            _ => unreachable!(),
        };

        self.builder.position_at_end(rhs_bb);
        let r = self.gen_expr(rhs, &Type::I64);
        let rbool = self
            .builder
            .build_int_compare(IntPredicate::NE, r, zero, "rbool")
            .unwrap();
        let rhs_end_bb = self.builder.get_insert_block().unwrap();
        self.builder.build_unconditional_branch(merge_bb).unwrap();

        self.builder.position_at_end(merge_bb);
        let bool_ty = self.context.bool_type();
        let phi = self.builder.build_phi(bool_ty, "sc").unwrap();
        // valor quando o curto-circuito pula o rhs
        let short_val = match op {
            BinOp::And => bool_ty.const_zero(),       // l falso → false
            BinOp::Or => bool_ty.const_int(1, false), // l verdadeiro → true
            _ => unreachable!(),
        };
        phi.add_incoming(&[(&short_val, entry_bb), (&rbool, rhs_end_bb)]);
        self.coerce(phi.as_basic_value().into_int_value(), expected)
    }

    /// Chamada falível sob try/catch: devolve o aggregate `{ erro, valor }`
    /// e o tipo do payload — vale para função, método e super.
    fn gen_fallible_agg(&mut self, e: &Expr) -> (StructValue<'ctx>, Type) {
        match e {
            Expr::Call { name, type_args, args } => {
                let callee = self.functions[name].clone();
                let ret_ty = if callee.type_params.is_empty() {
                    callee.ret_type.clone()
                } else {
                    let map = self.generic_call_map(&callee, type_args, args);
                    subst_type(&callee.ret_type, &map)
                };
                let agg = self
                    .gen_raw_call(&callee, type_args, args)
                    .expect("a fallible function always returns a struct")
                    .into_struct_value();
                (agg, ret_ty)
            }
            Expr::MethodCall { base, method, args } => {
                let (res, ret, fallible) = self.gen_method_call(base, method, args);
                if !fallible {
                    panic!("try/catch on a non-fallible method slipped past the semantic checker");
                }
                let agg = res
                    .expect("a fallible method always returns a struct")
                    .into_struct_value();
                (agg, ret)
            }
            Expr::SuperCall { method, args } => {
                let (res, ret, fallible) = self.gen_super_call(method.as_deref(), args);
                if !fallible {
                    panic!("try/catch on a non-fallible super call slipped past the semantic checker");
                }
                let agg = res
                    .expect("a fallible method always returns a struct")
                    .into_struct_value();
                (agg, ret)
            }
            _ => panic!("try/catch without a call slipped past the semantic checker"),
        }
    }

    /// O tipo LLVM de um método de instância para a chamada indireta via
    /// vtable: `this` (i64) + parâmetros; falível retorna { i64, T }.
    fn method_llvm_type(&self, m: &MethodMeta) -> FunctionType<'ctx> {
        let mut p: Vec<BasicMetadataTypeEnum> =
            Vec::with_capacity(m.params.len() + 1);
        p.push(self.context.i64_type().into()); // this
        p.extend(m.params.iter().map(|q| {
            let t: BasicMetadataTypeEnum = self.int_type(&q.ty).into();
            t
        }));
        if m.fallible {
            self.err_union_type(&m.ret_type).fn_type(&p, false)
        } else if m.ret_type == Type::Void {
            self.context.void_type().fn_type(&p, false)
        } else {
            self.int_type(&m.ret_type).fn_type(&p, false)
        }
    }

    /// Gera os argumentos de uma chamada (função, método, estático ou super),
    /// na largura dos parâmetros. Trata o parâmetro variádico final (`...args`):
    /// os argumentos extras são recolhidos num array do tipo do elemento — e se
    /// esse elemento for `any`, cada um é embrulhado automaticamente (gen_expr).
    fn gen_method_args(
        &mut self,
        params: &[Param],
        args: &[Expr],
        argv: &mut Vec<BasicMetadataValueEnum<'ctx>>,
    ) {
        if is_variadic(params) {
            // assinatura variádica não tem defaults (garantido no sema): os
            // parâmetros fixos vêm todos preenchidos, o resto vira o array.
            let n_fixed = params.len() - 1;
            for i in 0..n_fixed {
                let v = self.gen_expr(&args[i], &params[i].ty);
                argv.push(v.into());
            }
            let elem_ty = match &params[n_fixed].ty {
                Type::Array(t) => (**t).clone(),
                // o sema garante tipo array; fallback defensivo
                _ => Type::Any,
            };
            let arr = self.gen_variadic_array(&args[n_fixed..], &elem_ty);
            argv.push(arr.into());
            return;
        }
        for (i, a) in args.iter().enumerate() {
            let pty = params[i].ty.clone();
            let v = self.gen_expr(a, &pty);
            argv.push(v.into());
        }
        self.fill_defaults(params, args.len(), argv);
    }

    /// Empacota os argumentos finais de uma chamada variádica num `LexArr`
    /// novo, com cada elemento coagido ao tipo `elem_ty` (boxing de `any`
    /// incluso, via gen_expr). Devolve o ponteiro do array como i64.
    fn gen_variadic_array(&mut self, rest: &[Expr], elem_ty: &Type) -> IntValue<'ctx> {
        let i64t = self.context.i64_type();
        let cap = i64t.const_int(rest.len().max(4) as u64, false);
        let arr = self.call_runtime("__lex_arr_new", &[cap], false);
        for e in rest {
            let v = self.gen_expr(e, elem_ty);
            let v64 = self.coerce(v, &Type::I64);
            self.call_runtime("__lex_arr_push", &[arr, v64], true);
        }
        arr
    }

    /// Completa os argumentos omitidos (de `from` em diante) com o valor
    /// default de cada parâmetro. A sema já garantiu que todo parâmetro sem
    /// default foi fornecido, então o `expect` aqui nunca dispara.
    fn fill_defaults(
        &mut self,
        params: &[Param],
        from: usize,
        argv: &mut Vec<BasicMetadataValueEnum<'ctx>>,
    ) {
        for p in &params[from..] {
            let pty = p.ty.clone();
            let d = p
                .default
                .clone()
                .expect("argumento faltando para parâmetro obrigatório (a sema deveria ter pego)");
            let v = self.gen_expr(&d, &pty);
            argv.push(v.into());
        }
    }

    /// `base.metodo(args)` — devolve (valor cru, tipo de retorno, falível).
    /// Resolve, nesta ordem: método estático (`Classe.m()`), método de
    /// instância (vtable) e campo com tipo de função.
    /// `receiver.builtin(args)` é açúcar para `builtin(receiver, args)`: vale
    /// quando `method` é um builtin e o receiver não é uma instância de
    /// classe/struct (cujos métodos têm precedência) nem o nome de uma classe
    /// (chamada estática). Devolve os argumentos já com o receiver à frente.
    fn builtin_method_args(&self, base: &Expr, method: &str, args: &[Expr]) -> Option<Vec<Expr>> {
        if !builtins::is_builtin(method) {
            return None;
        }
        // `Classe.metodo(...)` — chamada estática, não é extensão
        if let Expr::Var(n) = base {
            if !self.vars.contains_key(n) && self.classes.get(n).is_some() {
                return None;
            }
        }
        // instância de classe/struct: o dispatch normal tem precedência
        if let Some(Type::Named(..)) = self.infer_type(base) {
            return None;
        }
        let mut all = Vec::with_capacity(args.len() + 1);
        all.push(base.clone());
        all.extend_from_slice(args);
        Some(all)
    }

    fn gen_method_call(
        &mut self,
        base: &Expr,
        method: &str,
        args: &[Expr],
    ) -> (Option<BasicValueEnum<'ctx>>, Type, bool) {
        // estático: a base é o nome de uma classe (sem variável sombreando)
        if let Expr::Var(n) = base {
            if !self.vars.contains_key(n) {
                if let Some(meta) = self.classes.get(n).cloned() {
                    let m = meta
                        .static_method(method)
                        .unwrap_or_else(|| {
                            panic!("unknown static method: {}.{}", n, method)
                        })
                        .clone();
                    let fv = self.fn_values[&oop::mangle(&m.owner, &m.name)];
                    let mut argv: Vec<BasicMetadataValueEnum> = Vec::with_capacity(args.len());
                    self.gen_method_args(&m.params, args, &mut argv);
                    let res = self
                        .builder
                        .build_call(fv, &argv, "scall")
                        .unwrap()
                        .try_as_basic_value()
                        .left();
                    return (res, m.ret_type.clone(), m.fallible);
                }
            }
        }

        let (tname, targs) = match self.infer_type(base) {
            Some(Type::Named(t, a)) => (t, a),
            other => panic!("method call on something that is not an object: {:?}", other),
        };

        if let Some(meta) = self.classes.get(&tname).cloned() {
            // mapa dos args de tipo da instância (`Box<f64>` → T=f64), para
            // gerar argumentos e o retorno no tipo concreto.
            let gmap = type_param_map(&meta.type_params, &targs);
            if let Some(m) = meta.method(method).cloned() {
                // dispatch dinâmico: slot 0 do objeto -> vtable -> método
                let i64t = self.context.i64_type();
                let this_v = self.gen_expr(base, &Type::I64);
                let obj = self
                    .builder
                    .build_int_to_ptr(this_v, self.ptr_type(), "objp")
                    .unwrap();
                let block_ty = self.struct_block_type(meta.n_slots());
                let vslot = self
                    .builder
                    .build_struct_gep(block_ty, obj, 0, "vtblp")
                    .unwrap();
                let vaddr = self
                    .builder
                    .build_load(i64t, vslot, "vtbl")
                    .unwrap()
                    .into_int_value();
                let ptr_ty = self.ptr_type();
                let vptr = self
                    .builder
                    .build_int_to_ptr(vaddr, ptr_ty, "vtblptr")
                    .unwrap();
                // a vtable é um array de `ptr`: indexa e carrega o ponteiro de
                // função direto (sem passar por i64 — casa com o wasm32)
                let idx = i64t.const_int(m.vtable_index as u64, false);
                let entry = unsafe {
                    self.builder
                        .build_gep(ptr_ty, vptr, &[idx], "vslot")
                        .unwrap()
                };
                let fptr = self
                    .builder
                    .build_load(ptr_ty, entry, "fptr")
                    .unwrap()
                    .into_pointer_value();

                let mut argv: Vec<BasicMetadataValueEnum> =
                    Vec::with_capacity(args.len() + 1);
                argv.push(this_v.into());
                let params = self.subst_params(&m.params, &gmap);
                self.gen_method_args(&params, args, &mut argv);
                let fn_ty = self.method_llvm_type(&m);
                let res = self
                    .builder
                    .build_indirect_call(fn_ty, fptr, &argv, "vcall")
                    .unwrap()
                    .try_as_basic_value()
                    .left();
                return (res, subst_type(&m.ret_type, &gmap), m.fallible);
            }
            // sem método: campo com tipo de função
            if let Some((_, f)) = meta.slot(method) {
                let fty = f.ty.clone();
                return self.gen_fn_field_call(base, method, &fty, args);
            }
            panic!("class '{}' has no method '{}'", tname, method);
        }

        // struct: só campo com tipo de função é chamável
        let def = self
            .structs
            .get(&tname)
            .unwrap_or_else(|| panic!("unknown type in method call: '{}'", tname))
            .clone();
        let fty = def
            .fields
            .iter()
            .find(|(n, _)| n == method)
            .map(|(_, t)| t.clone())
            .unwrap_or_else(|| panic!("type '{}' has no field '{}'", tname, method));
        self.gen_fn_field_call(base, method, &fty, args)
    }

    /// `obj.callback(args)` — carrega o campo (endereço de função) e chama
    /// indiretamente, com a assinatura do tipo Fn do campo.
    fn gen_fn_field_call(
        &mut self,
        base: &Expr,
        field: &str,
        fty: &Type,
        args: &[Expr],
    ) -> (Option<BasicValueEnum<'ctx>>, Type, bool) {
        let Type::Fn(ptypes, ret) = fty else {
            panic!("field '{}' does not have a function type (the semantic checker should have rejected this)", field);
        };
        let pt = ptypes.clone();
        let rt = (**ret).clone();
        let arg_vals: Vec<IntValue> = args
            .iter()
            .enumerate()
            .map(|(i, a)| self.gen_expr(a, &pt[i].clone()))
            .collect();
        let box_val = self.gen_expr(
            &Expr::Field { base: Box::new(base.clone()), field: field.to_string() },
            &Type::I64,
        );
        if rt == Type::Void {
            self.gen_closure_call(box_val, &pt, &rt, arg_vals, &Type::I64);
            (None, Type::Void, false)
        } else {
            let v = self.gen_closure_call(box_val, &pt, &rt, arg_vals, &rt);
            (Some(v.into()), rt, false)
        }
    }

    /// `super(args)` / `super.m(args)`: chamada DIRETA à implementação do
    /// pai (sem vtable) — é o que evita recursão infinita num override.
    fn gen_super_call(
        &mut self,
        method: Option<&str>,
        args: &[Expr],
    ) -> (Option<BasicValueEnum<'ctx>>, Type, bool) {
        let cur = self
            .cur_class
            .clone()
            .expect("'super' outside a method slipped past the semantic checker");
        let parent = self
            .classes
            .get(&cur)
            .and_then(|m| m.parent.clone())
            .expect("'super' without a superclass slipped past the semantic checker");
        let pmeta = self.classes.get(&parent).unwrap().clone();
        let this_v = self.gen_expr(&Expr::Var("this".to_string()), &Type::I64);

        match method {
            // super(args): construtor efetivo do pai (se houver)
            None => {
                let Some(ct) = pmeta.ctor.clone() else {
                    return (None, Type::Void, false);
                };
                let fv = self.fn_values[&oop::mangle(&ct.owner, "constructor")];
                let mut argv: Vec<BasicMetadataValueEnum> =
                    Vec::with_capacity(args.len() + 1);
                argv.push(this_v.into());
                self.gen_method_args(&ct.params, args, &mut argv);
                self.builder.build_call(fv, &argv, "").unwrap();
                (None, Type::Void, false)
            }
            Some(mname) => {
                let m = pmeta
                    .method(mname)
                    .unwrap_or_else(|| panic!("superclass '{}' has no '{}'", parent, mname))
                    .clone();
                let fv = self.fn_values[&oop::mangle(&m.owner, &m.name)];
                let mut argv: Vec<BasicMetadataValueEnum> =
                    Vec::with_capacity(args.len() + 1);
                argv.push(this_v.into());
                self.gen_method_args(&m.params, args, &mut argv);
                let res = self
                    .builder
                    .build_call(fv, &argv, "supercall")
                    .unwrap()
                    .try_as_basic_value()
                    .left();
                (res, m.ret_type.clone(), m.fallible)
            }
        }
    }

    /// `new Classe(args)`: aloca o bloco na arena (vtable + campos), zera os
    /// campos, instala a vtable e chama o construtor efetivo. O valor é o
    /// endereço do objeto.
    fn gen_new(
        &mut self,
        class: &str,
        type_args: &[Type],
        args: &[Expr],
        expected: &Type,
    ) -> IntValue<'ctx> {
        let meta = self
            .classes
            .get(class)
            .unwrap_or_else(|| panic!("unknown class: '{}'", class))
            .clone();
        let i64t = self.context.i64_type();
        let n_slots = meta.n_slots();

        let size = i64t.const_int((n_slots as u64) * 8, false);
        let obj_i = self.call_runtime("__lex_alloc", &[size], false);
        let obj = self
            .builder
            .build_int_to_ptr(obj_i, self.ptr_type(), "objp")
            .unwrap();
        let block_ty = self.struct_block_type(n_slots);

        // slot 0: a vtable da classe CONCRETA — é ela que decide o dispatch
        let vt_addr = self.vtables[class].const_to_int(i64t);
        let vslot = self
            .builder
            .build_struct_gep(block_ty, obj, 0, "vtblp")
            .unwrap();
        self.builder.build_store(vslot, vt_addr).unwrap();

        // campos zerados (a arena não zera a memória)
        for i in 1..n_slots {
            let fp = self
                .builder
                .build_struct_gep(block_ty, obj, i as u32, "f0")
                .unwrap();
            self.builder.build_store(fp, i64t.const_zero()).unwrap();
        }

        // construtor efetivo (próprio ou herdado). Numa classe genérica, os
        // parâmetros são substituídos pelos args de tipo concretos (ou inferidos
        // dos argumentos) para floats não truncarem ao virar `T`.
        if let Some(ct) = meta.ctor.clone() {
            let fv = self.fn_values[&oop::mangle(&ct.owner, "constructor")];
            let params = if meta.type_params.is_empty() {
                ct.params.clone()
            } else {
                let map = self.type_args_map(&meta.type_params, type_args, &ct.params, args);
                self.subst_params(&ct.params, &map)
            };
            let mut argv: Vec<BasicMetadataValueEnum> = Vec::with_capacity(args.len() + 1);
            argv.push(obj_i.into());
            self.gen_method_args(&params, args, &mut argv);
            self.builder.build_call(fv, &argv, "").unwrap();
        }

        self.coerce(obj_i, expected)
    }

    /// `spawn f(args)`: copia os args para um struct no heap, cria a thread
    /// via pthread_create e devolve o handle (i64).
    fn gen_spawn(
        &mut self,
        name: &str,
        receiver: Option<&Expr>,
        args: &[Expr],
        expected: &Type,
    ) -> IntValue<'ctx> {
        // `spawn obj.metodo(args)`: a função-alvo é `Owner.metodo` (despacho
        // estático pelo tipo declarado de obj) e `obj` entra como o `this`
        // (arg0). `spawn f(args)`: função de topo, args como vieram.
        let (callee, owned_args): (Function, Vec<Expr>) = match receiver {
            Some(recv) => {
                let cls = match self.infer_type(recv) {
                    Some(Type::Named(c, _)) => c,
                    _ => panic!("spawn de método em não-instância (a sema deveria ter pego)"),
                };
                let owner = self
                    .classes
                    .get(&cls)
                    .and_then(|m| m.method(name))
                    .map(|m| m.owner.clone())
                    .unwrap_or(cls);
                let mangled = oop::mangle(&owner, name);
                let mut all = Vec::with_capacity(args.len() + 1);
                all.push(recv.clone());
                all.extend(args.iter().cloned());
                (self.functions[&mangled].clone(), all)
            }
            None => (self.functions[name].clone(), args.to_vec()),
        };
        let args: &[Expr] = &owned_args;
        let ptr_ty = self.ptr_type();
        let i64_ty = self.context.i64_type();

        // struct com uma cópia de cada argumento
        let argp = if callee.params.is_empty() {
            ptr_ty.const_null()
        } else {
            let st = self.arg_struct_type(&callee);
            // malloc declarado como (i64) -> i64 para ser compatível com um
            // possível `extern function malloc(n: i64): ptr;` do usuário
            // (em lex, ptr = i64) — na ABI dá no mesmo.
            let malloc = self.extern_fn("malloc", i64_ty.fn_type(&[i64_ty.into()], false));
            let size = st.size_of().unwrap();
            let mp_int = self
                .builder
                .build_call(malloc, &[size.into()], "args")
                .unwrap()
                .try_as_basic_value()
                .left()
                .unwrap()
                .into_int_value();
            let mp = self
                .builder
                .build_int_to_ptr(mp_int, ptr_ty, "argsp")
                .unwrap();
            for (i, a) in args.iter().enumerate() {
                let pty = callee.params[i].ty.clone();
                let v = self.gen_expr(a, &pty);
                let fp = self
                    .builder
                    .build_struct_gep(st, mp, i as u32, "argf")
                    .unwrap();
                self.builder.build_store(fp, v).unwrap();
            }
            // parâmetros omitidos: usa o valor default de cada um
            for i in args.len()..callee.params.len() {
                let pty = callee.params[i].ty.clone();
                let d = callee.params[i]
                    .default
                    .clone()
                    .expect("argumento faltando para parâmetro obrigatório (a sema deveria ter pego)");
                let v = self.gen_expr(&d, &pty);
                let fp = self
                    .builder
                    .build_struct_gep(st, mp, i as u32, "argf")
                    .unwrap();
                self.builder.build_store(fp, v).unwrap();
            }
            mp
        };

        let thunk = self.get_or_make_thunk(&callee);

        let pc = self.extern_fn(
            "pthread_create",
            self.context.i32_type().fn_type(
                &[ptr_ty.into(), ptr_ty.into(), ptr_ty.into(), ptr_ty.into()],
                false,
            ),
        );
        let tid_slot = self.entry_alloca("tid", i64_ty);
        self.builder
            .build_call(
                pc,
                &[
                    tid_slot.into(),
                    ptr_ty.const_null().into(),
                    thunk.as_global_value().as_pointer_value().into(),
                    argp.into(),
                ],
                "",
            )
            .unwrap();
        let tid = self
            .builder
            .build_load(i64_ty, tid_slot, "tidval")
            .unwrap()
            .into_int_value();
        self.coerce(tid, expected)
    }

    /// Chamada crua a uma função do usuário (sem desempacotar erro).
    /// Devolve None quando a função é void.
    fn gen_raw_call(
        &mut self,
        callee: &Function,
        type_args: &[Type],
        args: &[Expr],
    ) -> Option<inkwell::values::BasicValueEnum<'ctx>> {
        let fv = self.fn_values[&callee.name];
        // função genérica: gera os argumentos no tipo concreto (substituído),
        // para que floats não trunquem ao passar por um parâmetro `T`.
        let params = if callee.type_params.is_empty() {
            callee.params.clone()
        } else {
            let map = self.generic_call_map(callee, type_args, args);
            self.subst_params(&callee.params, &map)
        };
        let mut arg_vals: Vec<BasicMetadataValueEnum> = Vec::with_capacity(params.len());
        self.gen_method_args(&params, args, &mut arg_vals);
        self.builder
            .build_call(fv, &arg_vals, "calltmp")
            .unwrap()
            .try_as_basic_value()
            .left()
    }

    /// Despacha um builtin: `len`/`join` têm tratamento próprio; o resto
    /// vira uma chamada direta à função C da runtime (tabela em builtins.rs).
    fn gen_builtin(&mut self, name: &str, args: &[Expr], expected: &Type) -> IntValue<'ctx> {
        match name {
            // math em ponto flutuante (1 arg): o argumento é uma célula f64
            // (bits do double), não i64 — gera no contexto F64 e devolve bits.
            "sqrt" | "floor" | "ceil" | "round" | "fabs" | "sin" | "cos" | "tan"
            | "exp" | "ln" | "log10" => {
                let v = self.gen_expr(&args[0], &Type::F64);
                let sym = builtins::lookup(name).unwrap().c_sym;
                let r = self.call_runtime(sym, &[v], false);
                return self.convert(r, &Type::F64, expected);
            }
            // pow(base, exp): dois floats
            "pow" => {
                let a = self.gen_expr(&args[0], &Type::F64);
                let b = self.gen_expr(&args[1], &Type::F64);
                let r = self.call_runtime("__lex_f_pow", &[a, b], false);
                return self.convert(r, &Type::F64, expected);
            }
            // min/max: polimórfico (int ou float), preserva o tipo via select
            "min" | "max" => {
                let ty = self
                    .infer_type(&args[0])
                    .or_else(|| self.infer_type(&args[1]))
                    .unwrap_or(Type::I64);
                let a = self.gen_expr(&args[0], &ty);
                let b = self.gen_expr(&args[1], &ty);
                let want_min = name == "min";
                let cond = if is_float(&ty) {
                    let af = self.cell_to_float(a, &ty);
                    let bf = self.cell_to_float(b, &ty);
                    let pred = if want_min { FloatPredicate::OLT } else { FloatPredicate::OGT };
                    self.builder.build_float_compare(pred, af, bf, "mmcmp").unwrap()
                } else {
                    let pred = if want_min { IntPredicate::SLT } else { IntPredicate::SGT };
                    self.builder.build_int_compare(pred, a, b, "mmcmp").unwrap()
                };
                let sel = self
                    .builder
                    .build_select(cond, a, b, "mm")
                    .unwrap()
                    .into_int_value();
                return self.convert(sel, &ty, expected);
            }
            // parseFloat(s): texto → double. O arg é uma string (ptr, célula
            // i64); o runtime devolve os BITS do double, convertidos ao contexto.
            "parseFloat" => {
                let v = self.gen_expr(&args[0], &Type::I64);
                let r = self.call_runtime("__lex_parse_float", &[v], false);
                return self.convert(r, &Type::F64, expected);
            }
            // jsonFloat(x): empacota um double (célula f64) num json
            "jsonFloat" => {
                let v = self.gen_expr(&args[0], &Type::F64);
                let r = self.call_runtime("__lex_json_float", &[v], false);
                return self.coerce(r, expected);
            }
            "len" => return self.gen_len(&args[0], expected),
            "join" => {
                // 2 args = join de array (string sep); 1 arg = join de thread
                if args.len() == 2 {
                    return self.gen_extern_builtin("__lex_arr_join", args, expected, false);
                }
                return self.gen_join(&args[0], expected);
            }
            _ => {}
        }
        let sig = builtins::lookup(name).expect("gen_builtin com nome não-builtin");
        self.gen_extern_builtin(sig.c_sym, args, expected, sig.void)
    }

    /// Chamada genérica a um builtin (função C da runtime): avalia os argumentos
    /// como células i64, chama via `call_runtime` (que aplica o ABI de ponteiros
    /// por alvo) e coage o retorno ao tipo esperado.
    fn gen_extern_builtin(
        &mut self,
        c_sym: &str,
        args: &[Expr],
        expected: &Type,
        is_void: bool,
    ) -> IntValue<'ctx> {
        let argv: Vec<IntValue<'ctx>> =
            args.iter().map(|a| self.gen_expr(a, &Type::I64)).collect();
        let r = self.call_runtime(c_sym, &argv, is_void);
        if is_void {
            return self.int_type(expected).const_zero();
        }
        self.coerce(r, expected)
    }

    /// Fronteira lex(i64) ↔ runtime C: chama `sym` com `args` (células i64),
    /// convertendo para `ptr` os slots que `builtins::runtime_abi` marca como
    /// ponteiro (i32 no wasm32, i64 no nativo) e voltando o retorno a i64. É o
    /// ponto ÚNICO por onde toda chamada à runtime passa — garante que o ABI
    /// declarado bate com o da runtime.c compilada para o alvo. Devolve o
    /// retorno como i64 (0 se `is_void`).
    fn call_runtime(
        &mut self,
        sym: &str,
        args: &[IntValue<'ctx>],
        is_void: bool,
    ) -> IntValue<'ctx> {
        let i64t = self.context.i64_type();
        let (mask, ret_ptr) = builtins::runtime_abi(sym);
        let is_p = |i: usize| mask.get(i) == Some(&b'p');

        let param_tys: Vec<BasicMetadataTypeEnum> = (0..args.len())
            .map(|i| {
                if is_p(i) {
                    self.ptr_type().into()
                } else {
                    i64t.into()
                }
            })
            .collect();
        let fn_ty = if is_void {
            self.context.void_type().fn_type(&param_tys, false)
        } else if ret_ptr {
            self.ptr_type().fn_type(&param_tys, false)
        } else {
            i64t.fn_type(&param_tys, false)
        };
        let f = self.extern_fn(sym, fn_ty);

        let argv: Vec<BasicMetadataValueEnum> = args
            .iter()
            .enumerate()
            .map(|(i, &v)| {
                if is_p(i) {
                    self.builder
                        .build_int_to_ptr(v, self.ptr_type(), "argp")
                        .unwrap()
                        .into()
                } else {
                    v.into()
                }
            })
            .collect();
        let call = self.builder.build_call(f, &argv, "rt").unwrap();
        if is_void {
            return i64t.const_zero();
        }
        let bv = call.try_as_basic_value().left().unwrap();
        if ret_ptr {
            self.builder
                .build_ptr_to_int(bv.into_pointer_value(), i64t, "retp")
                .unwrap()
        } else {
            bv.into_int_value()
        }
    }

    /// len(x): polimórfico — string, array, map ou json, conforme o tipo de x.
    fn gen_len(&mut self, arg: &Expr, expected: &Type) -> IntValue<'ctx> {
        let sym = match self.infer_type(arg) {
            Some(Type::Array(_)) => "__lex_arr_len",
            Some(Type::Map(_)) => "__lex_map_len",
            Some(Type::Json) => "__lex_json_len",
            // string/ptr/desconhecido: trata como string C
            _ => "__lex_strlen",
        };
        self.gen_extern_builtin(sym, std::slice::from_ref(arg), expected, false)
    }

    /// join(h): espera a thread h e devolve o valor retornado por ela.
    fn gen_join(&mut self, arg: &Expr, expected: &Type) -> IntValue<'ctx> {
        let h = self.gen_expr(arg, &Type::I64);
        let ptr_ty = self.ptr_type();
        let i64_ty = self.context.i64_type();

        let pj = self.extern_fn(
            "pthread_join",
            self.context
                .i32_type()
                .fn_type(&[i64_ty.into(), ptr_ty.into()], false),
        );
        let slot = self.entry_alloca("joinret", ptr_ty);
        self.builder
            .build_call(pj, &[h.into(), slot.into()], "")
            .unwrap();
        let raw = self
            .builder
            .build_load(ptr_ty, slot, "rawret")
            .unwrap()
            .into_pointer_value();
        // a thread devolve o resultado disfarçado de ponteiro; desfaz aqui
        let r = self
            .builder
            .build_ptr_to_int(raw, i64_ty, "joinval")
            .unwrap();
        self.coerce(r, expected)
    }

    /// O main de verdade quando o do usuário é falível: chama __lex_main e,
    /// se o erro escapar, imprime "erro: N" no stderr e sai com código 1.
    fn gen_main_wrapper(&mut self) {
        let i32_ty = self.context.i32_type();
        let i64_ty = self.context.i64_type();

        let main_fn = self
            .module
            .add_function("main", i32_ty.fn_type(&[], false), None);
        let entry = self.context.append_basic_block(main_fn, "entry");
        self.builder.position_at_end(entry);

        let inner = self.fn_values["main"]; // no LLVM, chama-se __lex_main
        let agg = self
            .builder
            .build_call(inner, &[], "r")
            .unwrap()
            .try_as_basic_value()
            .left()
            .unwrap()
            .into_struct_value();
        let err = self
            .builder
            .build_extract_value(agg, 0, "err")
            .unwrap()
            .into_int_value();
        let val = self
            .builder
            .build_extract_value(agg, 1, "val")
            .unwrap()
            .into_int_value();

        let is_err = self
            .builder
            .build_int_compare(IntPredicate::NE, err, i64_ty.const_zero(), "iserr")
            .unwrap();
        let err_bb = self.context.append_basic_block(main_fn, "main.err");
        let ok_bb = self.context.append_basic_block(main_fn, "main.ok");
        self.builder
            .build_conditional_branch(is_err, err_bb, ok_bb)
            .unwrap();

        // dprintf(2, ...) escreve direto no fd 2 (stderr), sem precisar do
        // símbolo `stderr` (que muda de nome entre macOS e Linux).
        self.builder.position_at_end(err_bb);
        let dprintf = self.extern_fn(
            "dprintf",
            i32_ty.fn_type(&[i32_ty.into(), self.ptr_type().into()], true),
        );
        let fmt = self
            .builder
            .build_global_string_ptr("error: %lld\n", ".fmt.err")
            .unwrap()
            .as_pointer_value();
        self.builder
            .build_call(
                dprintf,
                &[i32_ty.const_int(2, false).into(), fmt.into(), err.into()],
                "",
            )
            .unwrap();
        self.builder
            .build_return(Some(&i32_ty.const_int(1, false)))
            .unwrap();

        self.builder.position_at_end(ok_bb);
        let code = self.coerce(val, &Type::I32);
        self.builder.build_return(Some(&code)).unwrap();
    }

    /// O struct que carrega os argumentos copiados para a thread.
    fn arg_struct_type(&self, callee: &Function) -> StructType<'ctx> {
        let fields: Vec<_> = callee
            .params
            .iter()
            .map(|p| self.int_type(&p.ty).into())
            .collect();
        self.context.struct_type(&fields, false)
    }

    /// Gera (uma vez por função-alvo) o thunk com a assinatura que o
    /// pthread_create espera: `ptr thunk(ptr args)`.
    fn get_or_make_thunk(&mut self, callee: &Function) -> FunctionValue<'ctx> {
        if let Some(t) = self.thunks.get(&callee.name) {
            return *t;
        }

        // guarda onde o builder estava para voltar depois
        let saved_block = self.builder.get_insert_block().unwrap();

        let ptr_ty = self.ptr_type();
        let i64_ty = self.context.i64_type();
        let tfn = self.module.add_function(
            &format!("__lex_thunk_{}", callee.name),
            ptr_ty.fn_type(&[ptr_ty.into()], false),
            None,
        );
        let entry = self.context.append_basic_block(tfn, "entry");
        self.builder.position_at_end(entry);

        // desempacota os argumentos copiados e libera o struct
        let argp = tfn.get_nth_param(0).unwrap().into_pointer_value();
        let mut vals: Vec<BasicMetadataValueEnum> = Vec::new();
        if !callee.params.is_empty() {
            let st = self.arg_struct_type(callee);
            for (i, p) in callee.params.iter().enumerate() {
                let fp = self
                    .builder
                    .build_struct_gep(st, argp, i as u32, &p.name)
                    .unwrap();
                let v = self
                    .builder
                    .build_load(self.int_type(&p.ty), fp, &p.name)
                    .unwrap()
                    .into_int_value();
                vals.push(v.into());
            }
            // free como (i64) -> void pelo mesmo motivo do malloc acima
            let free = self.extern_fn(
                "free",
                self.context.void_type().fn_type(&[i64_ty.into()], false),
            );
            let argi = self
                .builder
                .build_ptr_to_int(argp, i64_ty, "argi")
                .unwrap();
            self.builder.build_call(free, &[argi.into()], "").unwrap();
        }

        let target = self.fn_values[&callee.name];
        let res = self
            .builder
            .build_call(target, &vals, "res")
            .unwrap()
            .try_as_basic_value()
            .left();

        // devolve o resultado disfarçado de ponteiro (o join desfaz);
        // função void devolve null
        let rp = match res {
            Some(v) => {
                let r = v.into_int_value();
                let r64 = if r.get_type().get_bit_width() < 64 {
                    self.builder.build_int_s_extend(r, i64_ty, "r64").unwrap()
                } else {
                    r
                };
                self.builder.build_int_to_ptr(r64, ptr_ty, "retp").unwrap()
            }
            None => ptr_ty.const_null(),
        };

        // fim da thread = fim da arena de strings dela (no servidor:
        // uma arena por requisição, liberada inteira aqui)
        let af = self.extern_fn(
            "__lex_arena_free",
            self.context.void_type().fn_type(&[], false),
        );
        self.builder.build_call(af, &[], "").unwrap();

        self.builder.build_return(Some(&rp)).unwrap();

        self.builder.position_at_end(saved_block);
        self.thunks.insert(callee.name.clone(), tfn);
        tfn
    }

    /// Compila o módulo já gerado para um arquivo objeto, mirando `target`.
    pub fn emit_object(&self, path: &Path, target: &TargetKind) -> Result<(), String> {
        let (triple, cpu, features, reloc) = match target {
            TargetKind::Wasm => {
                Target::initialize_webassembly(&InitializationConfig::default());
                (
                    TargetTriple::create("wasm32-unknown-unknown"),
                    "generic".to_string(),
                    String::new(),
                    RelocMode::Static,
                )
            }
            TargetKind::Native => {
                Target::initialize_native(&InitializationConfig::default())
                    .map_err(|e| format!("failed to initialize the native target: {}", e))?;
                (
                    TargetMachine::get_default_triple(),
                    TargetMachine::get_host_cpu_name().to_str().unwrap().to_string(),
                    TargetMachine::get_host_cpu_features().to_str().unwrap().to_string(),
                    RelocMode::PIC,
                )
            }
            // cross-compile: um triple LLVM arbitrário (ex.: x86_64-unknown-
            // linux-gnu). Precisa de todos os backends inicializados; o link // o link depois é clang+lld (freestanding no Linux/Windows).
            TargetKind::Cross(triple) => {
                Target::initialize_all(&InitializationConfig::default());
                (
                    TargetTriple::create(triple),
                    "generic".to_string(),
                    String::new(),
                    RelocMode::PIC,
                )
            }
        };

        let target = Target::from_triple(&triple).map_err(|e| e.to_string())?;
        let machine = target
            .create_target_machine(
                &triple,
                &cpu,
                &features,
                OptimizationLevel::Default,
                reloc,
                CodeModel::Default,
            )
            .ok_or("failed to create the target machine")?;

        // alinha o módulo com o alvo (triple + data layout) para o wasm sair
        // com o layout certo e sem avisos de incompatibilidade
        self.module.set_triple(&triple);
        self.module.set_data_layout(&machine.get_target_data().get_data_layout());

        machine
            .write_to_file(&self.module, FileType::Object, path)
            .map_err(|e| e.to_string())
    }
}
