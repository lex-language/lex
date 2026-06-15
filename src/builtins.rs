//! Tabela única dos builtins do lex: nome lex → símbolo C + aridade + tipo de
//! retorno. É a fonte de verdade compartilhada entre o sema (validação e
//! inferência de tipo) e o codegen (lowering para chamada externa).
//!
//! `len` e `join` têm codegen próprio (dispatch polimórfico / efeitos
//! especiais) — entram aqui só com `c_sym = ""` para a aridade e o nome
//! reservado. Todo o resto é uma chamada direta à função C correspondente,
//! com todos os argumentos passados como i64 e o retorno coagido ao contexto.

use crate::ast::Type;

#[derive(Clone, Copy)]
pub struct Sig {
    pub name: &'static str,
    /// Símbolo C chamado no codegen ("" = tratado à parte).
    pub c_sym: &'static str,
    pub min_args: usize,
    pub max_args: usize,
    /// Retorno void (não produz valor — usável como statement).
    pub void: bool,
}

const fn s(name: &'static str, c_sym: &'static str, n: usize) -> Sig {
    Sig { name, c_sym, min_args: n, max_args: n, void: false }
}
const fn sv(name: &'static str, c_sym: &'static str, n: usize) -> Sig {
    Sig { name, c_sym, min_args: n, max_args: n, void: true }
}

const TABLE: &[Sig] = &[
    // --- especiais: codegen dedicado -------------------------------------
    s("len", "", 1),            // polimórfico: string/array/map/json
    Sig { name: "join", c_sym: "", min_args: 1, max_args: 2, void: false }, // thread (1) ou array (2)

    // --- strings ---------------------------------------------------------
    s("substring", "__lex_substring", 3),
    s("indexOf", "__lex_index_of", 2),
    s("contains", "__lex_contains", 2),
    s("startsWith", "__lex_starts_with", 2),
    s("endsWith", "__lex_ends_with", 2),
    s("toUpper", "__lex_to_upper", 1),
    s("toLower", "__lex_to_lower", 1),
    s("trim", "__lex_trim", 1),
    s("strEq", "__lex_str_eq", 2),
    s("charAt", "__lex_char_at", 2),
    s("charCode", "__lex_char_code", 2),
    s("parseInt", "__lex_parse_int", 1),
    s("parseFloat", "__lex_parse_float", 1),
    s("str", "__lex_i64_to_str", 1),
    s("repeat", "__lex_str_repeat", 2),
    s("replace", "__lex_str_replace", 3),
    s("concat", "__lex_concat", 2),
    s("split", "__lex_split", 2),

    // --- arrays (get/set por índice; len/join polimórficos) --------------
    sv("push", "__lex_arr_push", 2),
    s("pop", "__lex_arr_pop", 1),
    s("slice", "__lex_arr_slice", 3),

    // --- memória dinâmica (heap, fora da arena) --------------------------
    s("alloc", "__lex_heap_alloc", 1), // devolve ptr (zerado)
    sv("free", "__lex_free", 1),
    sv("poke8", "__lex_poke8", 3),
    sv("poke16", "__lex_poke16", 3),
    sv("poke32", "__lex_poke32", 3),
    sv("poke64", "__lex_poke64", 3),
    sv("poke16be", "__lex_poke16be", 3), // ordem de rede
    sv("poke32be", "__lex_poke32be", 3), // ordem de rede
    s("peek8", "__lex_peek8", 2),
    s("peek16", "__lex_peek16", 2),
    s("peek32", "__lex_peek32", 2),
    s("peek64", "__lex_peek64", 2),

    // --- filesystem ------------------------------------------------------
    s("readFile", "__lex_fs_read", 1),     // string (0/null se não abrir)
    s("writeFile", "__lex_fs_write", 2),   // i64 bytes escritos / -1
    s("appendFile", "__lex_fs_append", 2), // i64
    s("exists", "__lex_fs_exists", 1),     // bool
    s("isFile", "__lex_fs_is_file", 1),    // bool
    s("isDir", "__lex_fs_is_dir", 1),      // bool
    s("fileSize", "__lex_fs_size", 1),     // i64 / -1
    s("remove", "__lex_fs_remove", 1),     // i64 (0 ok / -1)
    s("rename", "__lex_fs_rename", 2),     // i64
    s("mkdir", "__lex_fs_mkdir", 1),       // i64
    s("rmdir", "__lex_fs_rmdir", 1),       // i64
    s("readDir", "__lex_fs_list", 1),      // string[]
    s("openFile", "__lex_fs_open", 2),     // i64 fd (mode 0/1/2)

    // --- host/CLI (self-hosting) -----------------------------------------
    s("args", "__lex_args", 0),            // string[] (argv)
    s("system", "__lex_system", 1),        // i64 (status do comando)
    s("readStdin", "__lex_read_stdin", 1), // string (até n bytes; "" no EOF)

    // --- canais entre threads --------------------------------------------
    s("channel", "__lex_chan_new", 0),
    sv("send", "__lex_chan_send", 2),
    s("recv", "__lex_chan_recv", 1),
    s("chanClose", "__lex_chan_close", 1),

    // --- map (len polimórfico) -------------------------------------------
    s("mapGet", "__lex_map_get", 2),
    sv("mapSet", "__lex_map_set", 3),
    s("mapHas", "__lex_map_has", 2),
    s("keys", "__lex_map_keys", 1),

    // --- ponto flutuante (f64) -------------------------------------------
    s("sqrt", "__lex_f_sqrt", 1),
    s("floor", "__lex_f_floor", 1),
    s("ceil", "__lex_f_ceil", 1),
    s("round", "__lex_f_round", 1),
    s("fabs", "__lex_f_abs", 1),
    s("sin", "__lex_f_sin", 1),
    s("cos", "__lex_f_cos", 1),
    s("tan", "__lex_f_tan", 1),
    s("exp", "__lex_f_exp", 1),
    s("ln", "__lex_f_ln", 1),
    s("log10", "__lex_f_log10", 1),
    s("pow", "__lex_f_pow", 2),
    // min/max: codegen dedicado (polimórfico int/float, preserva o tipo)
    s("min", "", 2),
    s("max", "", 2),

    // --- json ------------------------------------------------------------
    s("jsonParse", "__lex_json_parse", 1),
    s("jsonStringify", "__lex_json_stringify", 1),
    s("jsonGet", "__lex_json_get", 2),
    s("jsonAt", "__lex_json_at", 2),
    s("jsonAsInt", "__lex_json_as_int", 1),
    s("jsonAsStr", "__lex_json_as_str", 1),
    s("jsonAsBool", "__lex_json_as_bool", 1),
    s("jsonTypeof", "__lex_json_typeof", 1),
    s("jsonIsNull", "__lex_json_is_null", 1),
    // --- slots globais (singletons; ver runtime.c) -----------------------
    s("gget", "__lex_gget", 1),
    sv("gset", "__lex_gset", 2),

    s("jsonNum", "__lex_json_num", 1),
    s("jsonFloat", "__lex_json_float", 1),
    s("jsonAsFloat", "__lex_json_as_float", 1),
    s("jsonEq", "__lex_json_eq", 2),
    s("jsonStr", "__lex_json_str", 1),
    s("jsonBool", "__lex_json_bool", 1),
    s("jsonNull", "__lex_json_null", 0),
    s("jsonObject", "__lex_json_object", 0),
    s("jsonArray", "__lex_json_array", 0),
    sv("jsonSet", "__lex_json_set", 3),
    sv("jsonPush", "__lex_json_push", 2),
];

pub fn lookup(name: &str) -> Option<&'static Sig> {
    TABLE.iter().find(|b| b.name == name)
}

/// ABI de ponteiros de um símbolo da runtime C: quais slots de argumento são
/// ponteiros e se o retorno é ponteiro. Devolve `(máscara, ret_é_ptr)`, onde a
/// máscara tem um byte por argumento — `b'p'` = ponteiro, qualquer outro = i64.
///
/// Por quê: o lex carrega tudo como célula i64, mas em **wasm32 um ponteiro é
/// i32**, não i64. Declarar o slot como `ptr` (e não i64) faz o LLVM lowerá-lo
/// para i32 no wasm e i64 no nativo — casando com o ABI real do C nos dois
/// alvos. No nativo `ptr == i64`, então isto é inócuo. Cobre TODOS os símbolos
/// `__lex_*` chamados pelo codegen, inclusive os que não viram builtin de
/// superfície (`__lex_alloc`, `__lex_arr_set`, `__lex_strlen`, `*_len`).
pub fn runtime_abi(sym: &str) -> (&'static [u8], bool) {
    match sym {
        // --- strings ---
        "__lex_substring" => (b"p..", true),
        "__lex_index_of" | "__lex_contains" | "__lex_starts_with"
        | "__lex_ends_with" | "__lex_str_eq" => (b"pp", false),
        "__lex_to_upper" | "__lex_to_lower" | "__lex_trim" => (b"p", true),
        "__lex_char_at" => (b"p.", true),
        "__lex_char_code" => (b"p.", false),
        "__lex_parse_int" | "__lex_strlen" => (b"p", false),
        "__lex_parse_float" => (b"p", false),
        "__lex_i64_to_str" | "__lex_f64_to_str" => (b".", true),
        "__lex_f_sqrt" | "__lex_f_floor" | "__lex_f_ceil" | "__lex_f_round"
        | "__lex_f_abs" | "__lex_f_sin" | "__lex_f_cos" | "__lex_f_tan"
        | "__lex_f_exp" | "__lex_f_ln" | "__lex_f_log10" => (b".", false),
        "__lex_f_pow" => (b"..", false),
        "__lex_str_repeat" => (b"p.", true),
        "__lex_str_replace" => (b"ppp", true),
        "__lex_concat" => (b"pp", true),
        "__lex_split" => (b"pp", true),

        // --- arrays ---
        "__lex_arr_new" => (b".", true),
        "__lex_arr_len" => (b"p", false),
        "__lex_arr_push" => (b"p.", false),
        "__lex_arr_pop" => (b"p", false),
        "__lex_arr_get" => (b"p.", false),
        "__lex_arr_set" => (b"p..", false),
        "__lex_arr_slice" => (b"p..", true),
        "__lex_arr_join" => (b"pp", true),

        // --- map ---
        "__lex_map_new" => (b"", true),
        "__lex_map_len" => (b"p", false),
        "__lex_map_get" => (b"pp", false),
        "__lex_map_set" => (b"pp.", false),
        "__lex_map_has" => (b"pp", false),
        "__lex_map_keys" => (b"p", true),

        // --- memória dinâmica / blocos de registro / poke / peek ---
        "__lex_heap_alloc" | "__lex_alloc" => (b".", true),
        "__lex_free" => (b"p", false),
        "__lex_poke8" | "__lex_poke16" | "__lex_poke32" | "__lex_poke64"
        | "__lex_poke16be" | "__lex_poke32be" => (b"p..", false),
        "__lex_peek8" | "__lex_peek16" | "__lex_peek32" | "__lex_peek64" => (b"p.", false),

        // --- filesystem ---
        "__lex_fs_read" => (b"p", true),
        "__lex_fs_write" | "__lex_fs_append" | "__lex_fs_rename" => (b"pp", false),
        "__lex_fs_exists" | "__lex_fs_is_file" | "__lex_fs_is_dir" | "__lex_fs_size"
        | "__lex_fs_remove" | "__lex_fs_mkdir" | "__lex_fs_rmdir" => (b"p", false),
        "__lex_fs_list" => (b"p", true),
        "__lex_fs_open" => (b"p.", false),
        "__lex_args" => (b"", true),
        "__lex_system" => (b"p", false),
        "__lex_read_stdin" => (b".", true),   // (i64 n) -> char*

        // --- canais ---
        "__lex_chan_new" => (b"", true),
        "__lex_chan_send" => (b"p.", false),
        "__lex_chan_recv" | "__lex_chan_close" => (b"p", false),

        // --- json ---
        "__lex_json_parse" => (b"p", true),
        "__lex_json_stringify" | "__lex_json_as_str" => (b"p", true),
        "__lex_json_get" => (b"pp", true),
        "__lex_json_at" => (b"p.", true),
        "__lex_json_len" | "__lex_json_as_int" | "__lex_json_as_bool"
        | "__lex_json_typeof" | "__lex_json_is_null" => (b"p", false),
        "__lex_json_num" | "__lex_json_bool" | "__lex_json_float" => (b".", true),
        "__lex_json_as_float" => (b"p", false),
        "__lex_json_eq" => (b"pp", false),
        // slots globais: argumentos i64, sem ponteiro
        "__lex_gget" => (b".", false),
        "__lex_gset" => (b"..", false),
        "__lex_json_str" => (b"p", true),
        "__lex_json_null" | "__lex_json_object" | "__lex_json_array" => (b"", true),
        "__lex_json_set" => (b"ppp", false),
        "__lex_json_push" => (b"pp", false),

        // desconhecido: trata tudo como i64 (compatível com o ABI antigo)
        _ => (b"", false),
    }
}

pub fn is_builtin(name: &str) -> bool {
    lookup(name).is_some()
}

fn str_t() -> Type {
    Type::Ptr // string e Component são ponteiros
}

/// Tipo lex que uma chamada de builtin produz, dado o tipo (best-effort) dos
/// argumentos. Cobre os builtins genéricos (pop/slice/map_get/index dependem
/// do tipo do primeiro argumento). `None` = desconhecido (tratado como i64).
pub fn ret_type(name: &str, args: &[Option<Type>]) -> Option<Type> {
    let arg0 = args.first().cloned().flatten();
    match name {
        // i64
        "len" | "indexOf" | "contains" | "startsWith" | "endsWith" | "strEq"
        | "charCode" | "parseInt" | "mapHas" | "jsonAsInt" | "jsonAsBool"
        | "jsonTypeof" | "jsonIsNull" | "jsonEq" | "peek8" | "peek16" | "peek32" | "peek64"
        | "chanClose" => Some(Type::I64),

        // bool
        "exists" | "isFile" | "isDir" => Some(Type::Bool),

        // f64 (ponto flutuante)
        "sqrt" | "floor" | "ceil" | "round" | "fabs" | "sin" | "cos" | "tan" | "exp"
        | "ln" | "log10" | "pow" | "jsonAsFloat" | "parseFloat" => Some(Type::F64),

        // slots globais
        "gget" => Some(Type::I64),

        // min/max: tipo do primeiro argumento (int ou float)
        "min" | "max" => arg0,

        // ptr (memória crua)
        "alloc" => Some(Type::Ptr),

        // string (conteúdo de arquivo)
        "readFile" => Some(str_t()),

        // string[] (entradas de diretório / argumentos de CLI)
        "readDir" | "args" => Some(Type::Array(Box::new(str_t()))),

        // recv: tipo do elemento do canal (Channel<T> -> T)
        "recv" => match arg0 {
            Some(Type::Chan(t)) => Some(*t),
            _ => Some(Type::I64),
        },

        // string
        "substring" | "toUpper" | "toLower" | "trim" | "charAt" | "str" | "repeat"
        | "replace" | "concat" | "jsonStringify" | "jsonAsStr" => Some(str_t()),

        // string[]
        "split" | "keys" => Some(Type::Array(Box::new(str_t()))),

        // json
        "jsonParse" | "jsonGet" | "jsonAt" | "jsonNum" | "jsonFloat" | "jsonStr" | "jsonBool"
        | "jsonNull" | "jsonObject" | "jsonArray" => Some(Type::Json),

        // join: 1 arg = thread (i64); 2 args = array join (string)
        "join" => Some(if args.len() >= 2 { str_t() } else { Type::I64 }),

        // genéricos sobre o primeiro argumento
        "pop" => match arg0 {
            Some(Type::Array(t)) => Some(*t),
            _ => None,
        },
        "slice" => match arg0 {
            Some(t @ Type::Array(_)) => Some(t),
            _ => None,
        },
        "mapGet" => match arg0 {
            Some(Type::Map(t)) => Some(*t),
            _ => None,
        },

        // void
        _ => None,
    }
}
