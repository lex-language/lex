// codegen.lex — backend do compilador-em-lex (Fase 5): AST → LLVM IR TEXTUAL.
//
// Estratégia: tudo é i64 (célula uniforme do lex); cada parâmetro/variável vira
// um `alloca` com load/store (sem SSA/phi à mão — o clang -O0 lida). Comparações
// dão i1, estendidas a i64 com zext. `main` sai como `i32` (exit code).
//
// Cobertura (F6.3 — dados + host, dirigido pela Sema):
//   - escalares: int, bool, e f64 (literal via bitcast; bits trafegam em i64);
//   - strings: literais (globais de bytes), concat/strEq/substring/charAt/str/
//     parseInt/parseFloat/peek8/len — via runtime __lex_*;
//   - arrays `T[]`: literal, .push/.pop/.len, índice `xs[i]` e `xs[i]=v`;
//   - Map: literal `{}`/`{"k":v}`, índice `m[k]`/`m[k]=v`, mapGet/mapSet/len;
//   - template `...${}...` → cadeia de concat com conversão por tipo;
//   - host: Terminal.log (por tipo), readFile/writeFile/system/args;
//   - controle (de F5): if/else, while, break/continue, return; +-*/%, comparações,
//     bitwise, &&/|| (sem curto-circuito), unários.
// Tudo é célula i64 (ponteiros como inteiros); o codegen consulta `Sema.typeOf`
// pra escolher a chamada de runtime certa. Linka `src/runtime.c` via clang.
// TODO: classes/métodos/new/match (F6.4), for, curto-circuito, aritmética f64.
//
// Montamos o TEXTO do LLVM IR e o clang faz o resto — mantendo a identidade
// "compila direto pra LLVM IR".
import { lexSrc, Tok } from "./lexer"
import {
    Expr, IntLit, FloatLit, BoolLit, StrLit, Var, Unary, Binary, Call,
    ArrayLit, Field, MethodCall, Index, MapLit, StructLit, Template, Match, MatchArm, Lambda,
    TryExpr, CatchExpr, SpawnExpr, AwaitExpr, ElementExpr, NewExpr,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt, BreakStmt,
    ContinueStmt, ExprStmt, ForOfStmt, ForStmt, FailStmt, DeferStmt, Func, Param, Program, Parser
} from "./parser"
import { Sema, Scope, ClassInfo, isArrayTy, isMapTy, isClassTy, isFunctionType, isFloatTy, isIntLike, isHtmlTy, baseName, elementTy, addUniq, idxOf, without } from "./sema"

fn boolLit(b: bool): string {
    if (b) { return "1"; }
    return "0";
}

// nome de uma Var, ou "" se a expressão não for uma Var (p/ achar `Terminal.log`).
fn varName(e: Expr): string {
    return match (e) { Var v => v.name, _ => "" };
}

// ── escape de string p/ um literal de IR `c"..."` ────────────────────────────
fn irHex(b: i64): string {
    const HX: string = "0123456789ABCDEF";
    return concat(charAt(HX, b / 16), charAt(HX, b % 16));
}
fn irEscape(s: string): string {
    let out: string = "";
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(s, i);
        if (c < 32 || c > 126 || c == 34 || c == 92) {   // não-imprimível, " ou \
            out = concat(out, concat("\\", irHex(c)));
        } else {
            out = concat(out, charAt(s, i));
        }
        i = i + 1;
    }
    return out;
}

// builtin chamado por função `f(...)` → função de runtime `__lex_*` (1:1).
// "" = não é um builtin direto (len é especial; ver genLen).
fn runtimeFn(name: string): string {
    // DOM (ilhas) — builtins, e não `declare function`, porque o extern emite
    // toda assinatura como i64 e o wasm-ld recusaria os args de ponteiro.
    if (strEq(name, "domQuery")) { return "__lex_dom_query"; }
    if (strEq(name, "domCreate")) { return "__lex_dom_create"; }
    if (strEq(name, "domSetText")) { return "__lex_dom_set_text"; }
    if (strEq(name, "domSetHtml")) { return "__lex_dom_set_html"; }
    if (strEq(name, "domSetAttr")) { return "__lex_dom_set_attr"; }
    if (strEq(name, "domGetAttr")) { return "__lex_dom_get_attr"; }
    if (strEq(name, "domAppend")) { return "__lex_dom_append"; }
    if (strEq(name, "domOn")) { return "__lex_dom_on"; }
    if (strEq(name, "concat")) { return "__lex_concat"; }
    if (strEq(name, "strEq")) { return "__lex_str_eq"; }
    if (strEq(name, "contains")) { return "__lex_contains"; }
    if (strEq(name, "substring")) { return "__lex_substring"; }
    if (strEq(name, "charAt")) { return "__lex_char_at"; }
    if (strEq(name, "str")) { return "__lex_i64_to_str"; }
    if (strEq(name, "parseInt")) { return "__lex_parse_int"; }
    if (strEq(name, "parseFloat")) { return "__lex_parse_float"; }
    if (strEq(name, "peek8")) { return "__lex_peek8"; }
    if (strEq(name, "peek16")) { return "__lex_peek16"; }
    if (strEq(name, "peek32")) { return "__lex_peek32"; }
    if (strEq(name, "peek64")) { return "__lex_peek64"; }
    if (strEq(name, "poke8")) { return "__lex_poke8"; }
    if (strEq(name, "poke16")) { return "__lex_poke16"; }
    if (strEq(name, "poke32")) { return "__lex_poke32"; }
    if (strEq(name, "poke64")) { return "__lex_poke64"; }
    if (strEq(name, "free")) { return "__lex_free"; }
    if (strEq(name, "alloc")) { return "__lex_heap_alloc"; }  // ptr no heap (free-able)
    if (strEq(name, "channel")) { return "__lex_chan_new"; }  // canal de thread
    if (strEq(name, "malloc")) { return "malloc"; }           // libc (ABI ptr-aware)
    // helpers de string também como FUNÇÃO LIVRE (`endsWith(s, x)`), não só método
    if (strEq(name, "contains")) { return "__lex_contains"; }
    if (strEq(name, "startsWith")) { return "__lex_starts_with"; }
    if (strEq(name, "endsWith")) { return "__lex_ends_with"; }
    if (strEq(name, "indexOf")) { return "__lex_index_of"; }
    if (strEq(name, "split")) { return "__lex_split"; }
    if (strEq(name, "trim")) { return "__lex_trim"; }
    if (strEq(name, "toLower")) { return "__lex_to_lower"; }
    if (strEq(name, "toUpper")) { return "__lex_to_upper"; }
    if (strEq(name, "replace")) { return "__lex_str_replace"; }
    if (strEq(name, "charCode")) { return "__lex_char_code"; }
    if (strEq(name, "repeat")) { return "__lex_str_repeat"; }
    if (strEq(name, "readFile")) { return "__lex_fs_read"; }
    if (strEq(name, "getenv")) { return "__lex_getenv"; }
    if (strEq(name, "writeFile")) { return "__lex_fs_write"; }
    if (strEq(name, "system")) { return "__lex_system"; }
    if (strEq(name, "args")) { return "__lex_args"; }
    if (strEq(name, "exists")) { return "__lex_fs_exists"; }
    if (strEq(name, "appendFile")) { return "__lex_fs_append"; }
    if (strEq(name, "isFile")) { return "__lex_fs_is_file"; }
    if (strEq(name, "isDir")) { return "__lex_fs_is_dir"; }
    if (strEq(name, "fileSize")) { return "__lex_fs_size"; }
    if (strEq(name, "remove")) { return "__lex_fs_remove"; }
    if (strEq(name, "rename")) { return "__lex_fs_rename"; }
    if (strEq(name, "mkdir")) { return "__lex_fs_mkdir"; }
    if (strEq(name, "rmdir")) { return "__lex_fs_rmdir"; }
    if (strEq(name, "readDir")) { return "__lex_fs_list"; }
    if (strEq(name, "openFile")) { return "__lex_fs_open"; }
    if (strEq(name, "readStdin")) { return "__lex_read_stdin"; }
    if (strEq(name, "mapGet")) { return "__lex_map_get"; }
    if (strEq(name, "mapSet")) { return "__lex_map_set"; }
    // json / any (boxing comparado por valor)
    if (strEq(name, "jsonEq")) { return "__lex_json_eq"; }
    if (strEq(name, "jsonAsInt")) { return "__lex_json_as_int"; }
    if (strEq(name, "jsonAsFloat")) { return "__lex_json_as_float"; }
    if (strEq(name, "jsonAsStr")) { return "__lex_json_as_str"; }
    if (strEq(name, "jsonStringify")) { return "__lex_json_stringify"; }
    if (strEq(name, "jsonNum")) { return "__lex_json_num"; }
    if (strEq(name, "jsonStr")) { return "__lex_json_str"; }
    if (strEq(name, "jsonFloat")) { return "__lex_json_float"; }
    if (strEq(name, "jsonParse")) { return "__lex_json_parse"; }
    if (strEq(name, "jsonArray")) { return "__lex_json_array"; }
    if (strEq(name, "jsonObject")) { return "__lex_json_object"; }
    if (strEq(name, "jsonPush")) { return "__lex_json_push"; }
    if (strEq(name, "jsonSet")) { return "__lex_json_set"; }
    if (strEq(name, "jsonStringify")) { return "__lex_json_stringify"; }
    if (strEq(name, "jsonGet")) { return "__lex_json_get"; }
    if (strEq(name, "jsonAt")) { return "__lex_json_at"; }
    if (strEq(name, "jsonBool")) { return "__lex_json_bool"; }
    // slots globais + float (usados pelo harness de teste std/test.lex)
    if (strEq(name, "gget")) { return "__lex_gget"; }
    if (strEq(name, "gset")) { return "__lex_gset"; }
    if (strEq(name, "fabs")) { return "__lex_f_abs"; }
    // métodos de ptr (poke/peek) tratados em ptrPoke/ptrPeek (genMethodCall).
    // math f64 (arg/retorno em bits-de-double num i64; ver runtime.c)
    if (strEq(name, "sqrt")) { return "__lex_f_sqrt"; }
    if (strEq(name, "pow")) { return "__lex_f_pow"; }
    if (strEq(name, "floor")) { return "__lex_f_floor"; }
    if (strEq(name, "ceil")) { return "__lex_f_ceil"; }
    if (strEq(name, "round")) { return "__lex_f_round"; }
    if (strEq(name, "sin")) { return "__lex_f_sin"; }
    if (strEq(name, "cos")) { return "__lex_f_cos"; }
    if (strEq(name, "tan")) { return "__lex_f_tan"; }
    if (strEq(name, "exp")) { return "__lex_f_exp"; }
    if (strEq(name, "ln")) { return "__lex_f_ln"; }
    if (strEq(name, "log10")) { return "__lex_f_log10"; }
    return "";
}

// ── ABI do runtime ───────────────────────────────────────────────────────────
// Assinatura REAL (C) de cada símbolo, como "<args>|<ret>":
//   'p' = ponteiro   '.' = i64 (escalar)   'v' = void (só no retorno)
// Tudo em lex trafega como CÉLULA i64; nas bordas convertemos (inttoptr/ptrtoint).
// No nativo ptr==i64 e isso é inócuo. No **wasm32 ptr==i32** — sem esta tabela a
// assinatura não bate com o objeto da runtime.c e o `wasm-ld` recusa o link.
// (Também importa o `void`: declarar `arr_push` como i64 passa no nativo — a
// linkagem C não checa — mas o wasm-ld checa e quebra.)
fn rtAbi(sym: string): string {
    // DOM (ilhas). Um nó é HANDLE i64, nunca ponteiro — objeto de JS não cabe
    // na memória linear. As strings continuam sendo 'p', e é justamente por
    // isso que estas entradas existem: no wasm32 ptr é i32, e declarar tudo
    // como i64 linkaria no nativo mas o wasm-ld recusaria.
    if (strEq(sym, "__lex_html_escape")) { return "p|p"; }
    if (strEq(sym, "__lex_dom_query")) { return "p|."; }
    if (strEq(sym, "__lex_dom_create")) { return "p|."; }
    if (strEq(sym, "__lex_dom_set_text")) { return ".p|v"; }
    if (strEq(sym, "__lex_dom_set_html")) { return ".p|v"; }
    if (strEq(sym, "__lex_dom_set_attr")) { return ".pp|v"; }
    if (strEq(sym, "__lex_dom_get_attr")) { return ".p|p"; }
    if (strEq(sym, "__lex_dom_append")) { return "..|v"; }
    if (strEq(sym, "__lex_dom_on")) { return ".p..|v"; }
    // strings
    if (strEq(sym, "__lex_concat")) { return "pp|p"; }
    if (strEq(sym, "__lex_strlen")) { return "p|."; }
    if (strEq(sym, "__lex_str_eq")) { return "pp|."; }
    if (strEq(sym, "__lex_contains")) { return "pp|."; }
    if (strEq(sym, "__lex_starts_with")) { return "pp|."; }
    if (strEq(sym, "__lex_ends_with")) { return "pp|."; }
    if (strEq(sym, "__lex_substring")) { return "p..|p"; }
    if (strEq(sym, "__lex_char_at")) { return "p.|p"; }
    if (strEq(sym, "__lex_to_lower")) { return "p|p"; }
    if (strEq(sym, "__lex_to_upper")) { return "p|p"; }
    if (strEq(sym, "__lex_trim")) { return "p|p"; }
    if (strEq(sym, "__lex_str_replace")) { return "ppp|p"; }
    if (strEq(sym, "__lex_i64_to_str")) { return ".|p"; }
    if (strEq(sym, "__lex_f64_to_str")) { return ".|p"; }
    if (strEq(sym, "__lex_parse_int")) { return "p|."; }
    if (strEq(sym, "__lex_parse_float")) { return "p|."; }
    if (strEq(sym, "__lex_index_of")) { return "pp|."; }
    if (strEq(sym, "__lex_split")) { return "pp|p"; }
    if (strEq(sym, "__lex_char_code")) { return "p.|."; }
    if (strEq(sym, "__lex_str_repeat")) { return "p.|p"; }
    // arrays
    if (strEq(sym, "__lex_arr_new")) { return ".|p"; }
    if (strEq(sym, "__lex_arr_len")) { return "p|."; }
    if (strEq(sym, "__lex_arr_push")) { return "p.|v"; }
    if (strEq(sym, "__lex_arr_pop")) { return "p|."; }
    if (strEq(sym, "__lex_arr_get")) { return "p.|."; }
    if (strEq(sym, "__lex_arr_set")) { return "p..|v"; }
    if (strEq(sym, "__lex_arr_join")) { return "pp|p"; }
    // map
    if (strEq(sym, "__lex_map_new")) { return "|p"; }
    if (strEq(sym, "__lex_map_len")) { return "p|."; }
    if (strEq(sym, "__lex_map_get")) { return "pp|."; }
    if (strEq(sym, "__lex_map_set")) { return "pp.|v"; }
    // memória crua
    if (strEq(sym, "__lex_alloc")) { return ".|p"; }
    if (strEq(sym, "__lex_heap_alloc")) { return ".|p"; }
    if (strEq(sym, "__lex_free")) { return "p|v"; }
    if (strEq(sym, "__lex_poke8") || strEq(sym, "__lex_poke16")
        || strEq(sym, "__lex_poke32") || strEq(sym, "__lex_poke64")) { return "p..|v"; }
    if (strEq(sym, "__lex_peek8") || strEq(sym, "__lex_peek16")
        || strEq(sym, "__lex_peek32") || strEq(sym, "__lex_peek64")) { return "p.|."; }
    // json
    if (strEq(sym, "__lex_json_num")) { return ".|p"; }
    if (strEq(sym, "__lex_json_float")) { return ".|p"; }
    if (strEq(sym, "__lex_json_bool")) { return ".|p"; }
    if (strEq(sym, "__lex_json_str")) { return "p|p"; }
    if (strEq(sym, "__lex_json_object")) { return "|p"; }
    if (strEq(sym, "__lex_json_array")) { return "|p"; }
    if (strEq(sym, "__lex_json_push")) { return "pp|v"; }
    if (strEq(sym, "__lex_json_get")) { return "pp|p"; }
    if (strEq(sym, "__lex_json_at")) { return "p.|p"; }
    if (strEq(sym, "__lex_json_parse")) { return "p|p"; }
    if (strEq(sym, "__lex_json_set")) { return "ppp|v"; }
    if (strEq(sym, "__lex_json_eq")) { return "pp|."; }
    if (strEq(sym, "__lex_json_as_int")) { return "p|."; }
    if (strEq(sym, "__lex_json_as_float")) { return "p|."; }
    if (strEq(sym, "__lex_json_as_str")) { return "p|p"; }
    if (strEq(sym, "__lex_json_stringify")) { return "p|p"; }
    // host / io
    if (strEq(sym, "__lex_fs_read")) { return "p|p"; }
    if (strEq(sym, "__lex_getenv")) { return "p|p"; }
    if (strEq(sym, "__lex_fs_write")) { return "pp|."; }
    if (strEq(sym, "__lex_fs_exists")) { return "p|."; }
    if (strEq(sym, "__lex_fs_append") || strEq(sym, "__lex_fs_rename")) { return "pp|."; }
    if (strEq(sym, "__lex_fs_is_file") || strEq(sym, "__lex_fs_is_dir")
        || strEq(sym, "__lex_fs_size") || strEq(sym, "__lex_fs_remove")
        || strEq(sym, "__lex_fs_mkdir") || strEq(sym, "__lex_fs_rmdir")) { return "p|."; }
    if (strEq(sym, "__lex_fs_list")) { return "p|p"; }
    if (strEq(sym, "__lex_fs_open")) { return "p.|."; }
    if (strEq(sym, "__lex_read_stdin")) { return ".|p"; }
    if (strEq(sym, "__lex_system")) { return "p|."; }
    if (strEq(sym, "__lex_args")) { return "|."; }
    // slots globais, erro, math f64 (tudo escalar)
    if (strEq(sym, "__lex_gget")) { return ".|."; }
    if (strEq(sym, "__lex_gset")) { return "..|v"; }
    if (strEq(sym, "__lex_set_err")) { return ".|."; }
    if (strEq(sym, "__lex_has_err")) { return "|."; }
    if (strEq(sym, "__lex_take_err")) { return "|."; }
    if (strEq(sym, "__lex_f_pow")) { return "..|."; }
    if (strEq(sym, "__lex_f_abs") || strEq(sym, "__lex_f_sqrt") || strEq(sym, "__lex_f_floor")
        || strEq(sym, "__lex_f_ceil") || strEq(sym, "__lex_f_round") || strEq(sym, "__lex_f_sin")
        || strEq(sym, "__lex_f_cos") || strEq(sym, "__lex_f_tan") || strEq(sym, "__lex_f_exp")
        || strEq(sym, "__lex_f_ln") || strEq(sym, "__lex_f_log10")) { return ".|."; }
    // canais
    if (strEq(sym, "__lex_chan_new")) { return "|p"; }
    if (strEq(sym, "__lex_chan_send")) { return "p.|v"; }
    if (strEq(sym, "__lex_chan_recv")) { return "p|."; }
    if (strEq(sym, "__lex_chan_close")) { return "p|."; }
    // libc usada pelas threads
    if (strEq(sym, "malloc")) { return ".|p"; }
    if (strEq(sym, "free")) { return "p|v"; }
    return "";
}
// todos os símbolos do runtime, p/ gerar as declarações do preâmbulo.
fn rtSymbols(): string[] {
    return ["__lex_html_escape", "__lex_dom_query", "__lex_dom_create", "__lex_dom_set_text",
        "__lex_dom_set_html", "__lex_dom_set_attr", "__lex_dom_get_attr",
        "__lex_dom_append", "__lex_dom_on",
        "__lex_concat", "__lex_strlen", "__lex_str_eq", "__lex_contains",
        "__lex_starts_with", "__lex_ends_with", "__lex_substring", "__lex_char_at",
        "__lex_to_lower", "__lex_to_upper", "__lex_trim", "__lex_str_replace",
        "__lex_i64_to_str", "__lex_f64_to_str", "__lex_parse_int", "__lex_parse_float",
        "__lex_index_of", "__lex_split", "__lex_char_code", "__lex_str_repeat",
        "__lex_arr_new", "__lex_arr_len", "__lex_arr_push", "__lex_arr_pop",
        "__lex_arr_get", "__lex_arr_set", "__lex_arr_join",
        "__lex_map_new", "__lex_map_len", "__lex_map_get", "__lex_map_set",
        "__lex_alloc", "__lex_heap_alloc", "__lex_free",
        "__lex_poke8", "__lex_poke16", "__lex_poke32", "__lex_poke64",
        "__lex_peek8", "__lex_peek16", "__lex_peek32", "__lex_peek64",
        "__lex_json_num", "__lex_json_float", "__lex_json_bool", "__lex_json_str",
        "__lex_json_object", "__lex_json_array", "__lex_json_push",
        "__lex_json_get", "__lex_json_at", "__lex_json_parse",
        "__lex_json_set", "__lex_json_eq", "__lex_json_as_int",
        "__lex_json_as_float", "__lex_json_as_str", "__lex_json_stringify",
        "__lex_fs_read", "__lex_fs_write", "__lex_fs_exists", "__lex_read_stdin",
        "__lex_fs_append", "__lex_fs_is_file", "__lex_fs_is_dir", "__lex_fs_size",
        "__lex_fs_remove", "__lex_fs_rename", "__lex_fs_mkdir", "__lex_fs_rmdir",
        "__lex_fs_list", "__lex_fs_open",
        "__lex_system", "__lex_args", "__lex_getenv",
        "__lex_gget", "__lex_gset", "__lex_set_err", "__lex_has_err", "__lex_take_err",
        "__lex_f_abs", "__lex_f_sqrt", "__lex_f_pow", "__lex_f_floor", "__lex_f_ceil",
        "__lex_f_round", "__lex_f_sin", "__lex_f_cos", "__lex_f_tan", "__lex_f_exp",
        "__lex_f_ln", "__lex_f_log10",
        "__lex_chan_new", "__lex_chan_send", "__lex_chan_recv", "__lex_chan_close",
        "malloc", "free"];
}
// "pp|p" → parte dos args ("pp") e do retorno ("p")
fn abiArgs(abi: string): string {
    let i: i64 = 0;
    const n: i64 = len(abi);
    while (i < n) {
        if (peek8(abi, i) == 124) { return substring(abi, 0, i); }   // '|'
        i = i + 1;
    }
    return "";
}
fn abiRet(abi: string): string {
    let i: i64 = 0;
    const n: i64 = len(abi);
    while (i < n) {
        if (peek8(abi, i) == 124) { return substring(abi, i + 1, n); }
        i = i + 1;
    }
    return ".";
}
// caractere de ABI → tipo LLVM
fn abiTy(c: i64): string {
    if (c == 112) { return "ptr"; }        // 'p'
    if (c == 118) { return "void"; }       // 'v'
    return "i64";
}

// método de escrita em ptr (off, val) → void; "" se não for poke.
fn ptrPoke(m: string): string {
    if (strEq(m, "poke8")) { return "__lex_poke8"; }
    if (strEq(m, "poke16")) { return "__lex_poke16"; }
    if (strEq(m, "poke32")) { return "__lex_poke32"; }
    if (strEq(m, "poke64")) { return "__lex_poke64"; }
    return "";
}
// método de leitura em ptr (off) → i64; "" se não for peek.
fn ptrPeek(m: string): string {
    if (strEq(m, "peek8")) { return "__lex_peek8"; }
    if (strEq(m, "peek16")) { return "__lex_peek16"; }
    if (strEq(m, "peek32")) { return "__lex_peek32"; }
    if (strEq(m, "peek64")) { return "__lex_peek64"; }
    return "";
}

// ── coleta de variáveis locais (p/ hoistar as alloca pro bloco entry) ────────
// LLVM exige nomes SSA únicos por função; um `let x` em blocos irmãos geraria
// duas `%x.addr = alloca`. Hoistamos uma alloca por nome no entry (domina tudo).
// nomes de const/let DIRETOS do corpo (sem recursão) — viram globais (gget/gset)
// p/ que arrows os enxerguem (captura via global, sem closure/env).
fn directLetNames(stmts: Stmt[]): string[] {
    let names: string[] = [];
    for (const s of stmts) { collectStmtLocal(s, names); }
    return names;
}
// ── variáveis livres de uma arrow (p/ a captura por valor) ──────────────────
// Nomes USADOS no corpo, menos os que o próprio corpo liga (params e locais) e os
// nomes de topo (funções/classes/enums). O que sobra é o que a closure captura.
fn usedInExprs(xs: Expr[], out: string[]) { for (const e of xs) { usedInExpr(e, out); } }
fn usedInExpr(e: Expr, out: string[]) {
    match (e) {
        Var v => addUniq(out, v.name),
        Unary u => usedInExpr(u.operand, out),
        Binary b => usedInBin(b, out),
        Call c => usedInExprs(c.args, out),
        MethodCall m => usedInMC(m, out),
        Field f => usedInExpr(f.base, out),
        Index ix => usedInIndex(ix, out),
        NewExpr ne => usedInExprs(ne.args, out),
        ArrayLit a => usedInExprs(a.items, out),
        MapLit ml => usedInExprs(ml.vals, out),
        StructLit sl => usedInExprs(sl.vals, out),
        Template t => usedInExprs(t.parts, out),
        Match mt => usedInMatch(mt, out),
        TryExpr t => usedInExpr(t.call, out),
        CatchExpr c => usedInCatch(c, out),
        SpawnExpr sp => usedInExpr(sp.call, out),
        AwaitExpr aw => usedInExpr(aw.inner, out),
        Lambda lm => addUniq(out, lm.fnName),   // arrow ANINHADA: expandida depois
        ElementExpr el => usedInElement(el, out),
        _ => 0
    };
}
// `<Card x={v}>{w}</Card>` dentro de uma arrow: v e w são variáveis LIVRES e
// precisam entrar na captura, senão a closure lê lixo do env.
fn usedInElement(el: ElementExpr, out: string[]): i64 {
    usedInExprs(el.vals, out);
    if (el.hasKids) { usedInExpr(el.children, out); }
    return 0;
}
fn usedInBin(b: Binary, out: string[]): i64 { usedInExpr(b.lhs, out); usedInExpr(b.rhs, out); return 0; }
fn usedInMC(m: MethodCall, out: string[]): i64 { usedInExpr(m.base, out); usedInExprs(m.args, out); return 0; }
fn usedInIndex(ix: Index, out: string[]): i64 { usedInExpr(ix.base, out); usedInExpr(ix.index, out); return 0; }
fn usedInCatch(c: CatchExpr, out: string[]): i64 { usedInExpr(c.lhs, out); usedInExpr(c.handler, out); usedInStmts(c.body, out); return 0; }
fn usedInMatch(mt: Match, out: string[]): i64 {
    usedInExpr(mt.subject, out);
    for (const a of mt.arms) {
        if (a.hasGuard) { usedInExpr(a.guard, out); }
        usedInExpr(a.body, out);
    }
    return 0;
}
fn usedInStmts(ss: Stmt[], out: string[]) { for (const s of ss) { usedInStmt(s, out); } }
fn usedInStmt(s: Stmt, out: string[]) {
    match (s) {
        LetStmt l => usedInExpr(l.value, out),
        AssignStmt a => usedInAssign(a, out),
        ReturnStmt r => usedInExpr(r.value, out),
        IfStmt f => usedInIf(f, out),
        WhileStmt w => usedInWhile(w, out),
        ForOfStmt fo => usedInForOf(fo, out),
        ForStmt fr => usedInFor(fr, out),
        ExprStmt e => usedInExpr(e.expr, out),
        FailStmt fs => usedInExpr(fs.value, out),
        DeferStmt d => usedInStmt(d.body, out),
        _ => 0
    };
}
fn usedInAssign(a: AssignStmt, out: string[]): i64 { usedInExpr(a.target, out); usedInExpr(a.value, out); return 0; }
fn usedInIf(f: IfStmt, out: string[]): i64 { usedInExpr(f.cond, out); usedInStmts(f.thenB, out); usedInStmts(f.elseB, out); return 0; }
fn usedInWhile(w: WhileStmt, out: string[]): i64 { usedInExpr(w.cond, out); usedInStmts(w.body, out); return 0; }
fn usedInForOf(fo: ForOfStmt, out: string[]): i64 { usedInExpr(fo.iter, out); usedInStmts(fo.body, out); return 0; }
fn usedInFor(fr: ForStmt, out: string[]): i64 {
    if (fr.hasInit) { usedInStmt(fr.init, out); }
    if (fr.hasCond) { usedInExpr(fr.cond, out); }
    if (fr.hasUpdate) { usedInStmt(fr.update, out); }
    usedInStmts(fr.body, out);
    return 0;
}

// ── contagem de sítios de curto-circuito (&& / ||) ──────────────────────────
// Cada `&&`/`||` precisa de UM slot de resultado provisório. Se o alloca desse
// slot for emitido no PONTO DE USO e o `&&` estiver numa condição de loop, o
// alloca (dinâmico, só liberado no ret) vaza a pilha a cada iteração até estourar.
// Por isso hoistamos um slot por sítio no bloco entry. Contamos os sítios com
// esta varredura — espelho fiel de usedInExpr, que já é COMPLETA. Contar a mais
// só cria slots ociosos; nunca a menos (isso quebraria a IR). Só conta && / ||;
// o corpo de uma arrow é uma função à parte (contada quando ELA é gerada).
fn scCountExprs(xs: Expr[]): i64 { let n: i64 = 0; for (const e of xs) { n = n + scCountExpr(e); } return n; }
fn scCountExpr(e: Expr): i64 {
    return match (e) {
        Unary u => scCountExpr(u.operand),
        Binary b => scCountBin(b),
        Call c => scCountExprs(c.args),
        MethodCall m => scCountExpr(m.base) + scCountExprs(m.args),
        Field f => scCountExpr(f.base),
        Index ix => scCountExpr(ix.base) + scCountExpr(ix.index),
        NewExpr ne => scCountExprs(ne.args),
        ArrayLit a => scCountExprs(a.items),
        MapLit ml => scCountExprs(ml.vals),
        StructLit sl => scCountExprs(sl.vals),
        Template t => scCountExprs(t.parts),
        Match mt => scCountMatch(mt),
        TryExpr t => scCountExpr(t.call),
        CatchExpr c => scCountExpr(c.lhs) + scCountExpr(c.handler) + scCountStmts(c.body),
        SpawnExpr sp => scCountExpr(sp.call),
        AwaitExpr aw => scCountExpr(aw.inner),
        ElementExpr el => scCountElement(el),
        _ => 0
    };
}
// um `&&`/`||` num atributo (`<Card on={a && b} />`) precisa do seu slot
// hoistado no entry — contar a MENOS aqui deixa a IR referenciando um alloca
// que não existe.
fn scCountElement(el: ElementExpr): i64 {
    let n: i64 = scCountExprs(el.vals);
    if (el.hasKids) { n = n + scCountExpr(el.children); }
    return n;
}
fn scCountBin(b: Binary): i64 {
    let n: i64 = scCountExpr(b.lhs) + scCountExpr(b.rhs);
    if (b.op == Tok.AmpAmp || b.op == Tok.PipePipe) { n = n + 1; }
    return n;
}
fn scCountMatch(mt: Match): i64 {
    let n: i64 = scCountExpr(mt.subject);
    for (const a of mt.arms) {
        if (a.hasGuard) { n = n + scCountExpr(a.guard); }
        n = n + scCountExpr(a.body);
    }
    return n;
}
fn scCountStmts(ss: Stmt[]): i64 { let n: i64 = 0; for (const s of ss) { n = n + scCountStmt(s); } return n; }
fn scCountStmt(s: Stmt): i64 {
    return match (s) {
        LetStmt l => scCountExpr(l.value),
        AssignStmt a => scCountExpr(a.target) + scCountExpr(a.value),
        ReturnStmt r => scCountExpr(r.value),
        IfStmt f => scCountExpr(f.cond) + scCountStmts(f.thenB) + scCountStmts(f.elseB),
        WhileStmt w => scCountExpr(w.cond) + scCountStmts(w.body),
        ForOfStmt fo => scCountExpr(fo.iter) + scCountStmts(fo.body),
        ForStmt fr => scCountForC(fr),
        ExprStmt e => scCountExpr(e.expr),
        FailStmt fs => scCountExpr(fs.value),
        DeferStmt d => scCountStmt(d.body),
        _ => 0
    };
}
fn scCountForC(fr: ForStmt): i64 {
    let n: i64 = 0;
    if (fr.hasInit) { n = n + scCountStmt(fr.init); }
    if (fr.hasCond) { n = n + scCountExpr(fr.cond); }
    if (fr.hasUpdate) { n = n + scCountStmt(fr.update); }
    n = n + scCountStmts(fr.body);
    return n;
}

// "x,y" → ["x", "y"]
fn splitCommas(s: string): string[] {
    let out: string[] = [];
    let cur: string = "";
    let i: i64 = 0;
    const n: i64 = len(s);
    while (i < n) {
        if (peek8(s, i) == 44) { out.push(cur); cur = ""; }      // ','
        else { cur = concat(cur, charAt(s, i)); }
        i = i + 1;
    }
    if (!strEq(cur, "")) { out.push(cur); }
    return out;
}
fn isLambdaName(name: string): bool {
    const pre: string = "__lambda_";
    if (len(name) < len(pre)) { return false; }
    return strEq(substring(name, 0, len(pre)), pre);
}
fn collectStmtLocal(s: Stmt, names: string[]): i64 {
    return match (s) { LetStmt l => addUniq(names, l.name), _ => 0 };
}
// `catch { … }` guarda STATEMENTS dentro de uma expressão, e os `let` deles
// precisam de alloca como quaisquer outros — a varredura de locais tem de
// entrar aí. Como `catch` é o operador de menor precedência, ele só aparece na
// RAIZ da expressão de um statement; basta olhar essas raízes.
fn collectExprLocals(e: Expr, names: string[]): i64 {
    return match (e) { CatchExpr c => collectLocals(c.body, names), _ => 0 };
}
fn collectLetLocal(l: LetStmt, names: string[]): i64 {
    addUniq(names, l.name);
    return collectExprLocals(l.value, names);
}
fn collectLocals(stmts: Stmt[], names: string[]): i64 {
    for (const s of stmts) {
        match (s) {
            LetStmt l => collectLetLocal(l, names),
            AssignStmt a => collectExprLocals(a.value, names),
            ExprStmt e => collectExprLocals(e.expr, names),
            ReturnStmt r => collectExprLocals(r.value, names),
            ForOfStmt fo => collectForOf(fo, names),
            ForStmt fr => collectForC(fr, names),
            IfStmt f => collectIf(f, names),
            WhileStmt w => collectLocals(w.body, names),
            _ => 0
        };
    }
    return 0;
}
fn collectForOf(fo: ForOfStmt, names: string[]): i64 {
    addUniq(names, fo.name);
    return collectLocals(fo.body, names);
}
fn collectForC(fr: ForStmt, names: string[]): i64 {
    if (fr.hasInit) { collectStmtLocal(fr.init, names); }
    return collectLocals(fr.body, names);
}
fn collectIf(f: IfStmt, names: string[]): i64 {
    collectLocals(f.thenB, names);
    return collectLocals(f.elseB, names);
}

class Codegen {
    outParts: string[] // pedaços da IR (juntados 1x no fim — evita concat O(n²))
    tmp: i64           // contador de temporários SSA (%tN)
    lbl: i64           // contador de labels (LN)
    term: bool         // o bloco básico atual já terminou (ret/br)?
    curMain: bool      // estamos gerando o `main` (retorno i32)?
    loopCond: string[] // pilha de labels de condição (continue)
    loopEnd: string[]  // pilha de labels de saída (break)
    sema: Sema         // tabela de classes/tipos (dirige a escolha de runtime)
    scope: Scope       // tipos das variáveis no escopo atual
    strs: string[]     // globais de string literais (emitidos no fim do módulo)
    strN: i64          // contador de string literais
    matchN: i64        // contador de blocos de match (nomes únicos)
    scN: i64           // índice do próximo slot de curto-circuito (&&/||) na função
    bindNames: string[] // pilha de bindings de match (nome → endereço)
    bindAddrs: string[]
    globalNames: string[] // const/let de topo promovidos a slots globais (gget/gset)
    curLocals: string[]   // locais (alloca) da função atual — sombreiam globais
    curClass: string      // classe do método atual ("" fora de método) — p/ super(...)
    curDefers: Stmt[]     // statements adiados (defer) — emitidos antes de cada ret
    thunkNames: string[]  // símbolos que precisam de thunk de thread (spawn/async)
    thunkArity: i64[]     // aridade de cada thunk (paralelo a thunkNames)
    asyncNames: string[]  // funções `async` — chamá-las lança thread (vira Future)
    target: i64           // 0 = nativo, 1 = wasm32 (muda triple/datalayout)
    curRet: string        // tipo de retorno da função atual (p/ coagir o `return`)
    curCaptures: string[] // se a função atual é uma arrow: nomes lidos do env
    lambdaFuncs: Func[]   // as arrows içadas (p/ achar as capturas de cada uma)
    fnValNames: string[]  // funções de topo usadas como VALOR (ganham um wrapper)
    staticClasses: ClassDecl[]  // classes com campos static (inicializados no main)
    toolFuncs: Func[]     // funções marcadas com `tool` (geram JSON Schema)

    constructor(sema: Sema) {
        this.outParts = []
        this.curClass = ""
        this.curDefers = []
        this.thunkNames = []
        this.thunkArity = []
        this.asyncNames = []
        this.target = 0
        this.curRet = ""
        this.curCaptures = []
        this.lambdaFuncs = []
        this.fnValNames = []
        this.staticClasses = []
        this.toolFuncs = []
        this.tmp = 0
        this.lbl = 0
        this.term = false
        this.curMain = false
        this.loopCond = []
        this.loopEnd = []
        this.sema = sema
        this.scope = new Scope()
        this.strs = []
        this.strN = 0
        this.matchN = 0
        this.scN = 0
        this.bindNames = []
        this.bindAddrs = []
        this.globalNames = []
        this.curLocals = []
    }

    // instrução normal: pulada se o bloco já terminou (código morto)
    emit(line: string) {
        if (this.term) { return; }
        this.outParts.push(concat(line, "\n"));
    }
    // linha estrutural (define/label/}): sempre escrita
    raw(line: string) {
        this.outParts.push(concat(line, "\n"));
    }
    newTmp(): string {
        const r: string = concat("%t", str(this.tmp));
        this.tmp = this.tmp + 1;
        return r;
    }
    newLabel(): string {
        const r: string = concat("L", str(this.lbl));
        this.lbl = this.lbl + 1;
        return r;
    }
    label(name: string) {            // inicia um novo bloco básico
        this.outParts.push(concat(name, ":\n"));
        this.term = false;
    }

    // ── expressões → devolve o operando (um %tN ou um imediato como "42") ────
    bin(opc: string, l: string, r: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = ${opc} i64 ${l}, ${r}`);
        return t;
    }
    cmp(pred: string, l: string, r: string): string {
        const c: string = this.newTmp();
        this.emit(`  ${c} = icmp ${pred} i64 ${l}, ${r}`);
        const t: string = this.newTmp();
        this.emit(`  ${t} = zext i1 ${c} to i64`);
        return t;
    }
    // normaliza um i64 qualquer para 0/1 (verdade lógica)
    truth(v: string): string {
        const c: string = this.newTmp();
        this.emit(`  ${c} = icmp ne i64 ${v}, 0`);
        const t: string = this.newTmp();
        this.emit(`  ${t} = zext i1 ${c} to i64`);
        return t;
    }

    // endereço de uma variável: binding de match (se houver) ou `%nome.addr`.
    varAddrOf(name: string): string {
        let i: i64 = this.bindNames.len() - 1;
        while (i >= 0) {
            if (strEq(this.bindNames[i], name)) { return this.bindAddrs[i]; }
            i = i - 1;
        }
        return concat("%", concat(name, ".addr"));
    }
    bindIndex(name: string): i64 {
        let i: i64 = this.bindNames.len() - 1;
        while (i >= 0) { if (strEq(this.bindNames[i], name)) { return i; } i = i - 1; }
        return -1;
    }
    // é um global promovido (e não está sombreado por bind/local da função)?
    isGlobalVar(name: string): bool {
        if (this.bindIndex(name) >= 0) { return false; }
        if (idxOf(this.curLocals, name) >= 0) { return false; }
        return idxOf(this.globalNames, name) >= 0;
    }
    slotOfGlobal(name: string): i64 { return idxOf(this.globalNames, name) + 2; }   // 0/1 = harness
    bindPush(name: string, addr: string, ty: string) {
        this.bindNames.push(name);
        this.bindAddrs.push(addr);
        if (!strEq(name, "")) { this.scope.set(name, ty); }
    }
    bindPop() {
        const n: i64 = this.bindNames.len();
        if (n > 0) { this.bindNames.pop(); this.bindAddrs.pop(); }
    }

    // slot de uma captura no env da closure (1.. ; slot 0 = ponteiro da função), ou -1
    captureSlot(name: string): i64 {
        const i: i64 = idxOf(this.curCaptures, name);
        if (i < 0) { return -1; }
        return i + 1;
    }
    genLoad(name: string): string {
        const cs: i64 = this.captureSlot(name);
        if (cs >= 0) {                                  // variável capturada: lê do env
            const p: string = this.newTmp();
            this.emit(`  ${p} = inttoptr i64 %__env to ptr`);
            const ep: string = this.newTmp();
            this.emit(`  ${ep} = getelementptr i64, ptr ${p}, i64 ${cs}`);
            const v: string = this.newTmp();
            this.emit(`  ${v} = load i64, ptr ${ep}`);
            return v;
        }
        if (this.isGlobalVar(name)) {
            return this.rtCall("__lex_gget", [str(this.slotOfGlobal(name))]);
        }
        // FUNÇÃO DE TOPO usada como VALOR (`srv.start(handle)`): vira uma closure
        // sem capturas. Como o valor-função é sempre uma closure — e a chamada
        // indireta passa o env como 1º argumento —, a closure aponta para um
        // WRAPPER que engole o env e repassa os args à função de verdade.
        if (this.bindIndex(name) < 0 && idxOf(this.curLocals, name) < 0
            && this.sema.funcIndex(name) >= 0) {
            return this.genFnValue(name);
        }
        const t: string = this.newTmp();
        this.emit(`  ${t} = load i64, ptr ${this.varAddrOf(name)}`);
        return t;
    }
    // closure de 1 slot apontando p/ o wrapper @__fnval_<name>.
    genFnValue(name: string): string {
        addUniq(this.fnValNames, name);
        const env: string = this.rtCall("__lex_heap_alloc", [str(8)]);
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${env} to ptr`);
        this.emit(`  store i64 ptrtoint (ptr @__fnval_${name} to i64), ptr ${p}`);
        return env;
    }
    // define i64 @__fnval_f(i64 %__env, i64 %p0, …) { ret @f(%p0, …) }
    genFnValWrapper(name: string) {
        this.tmp = 0;
        const n: i64 = this.sema.funcParamTypes(name).len();
        let ps: string = "i64 %__env";
        let ar: string = "";
        let i: i64 = 0;
        while (i < n) {
            ps = concat(ps, `, i64 %p${i}`);
            if (i > 0) { ar = concat(ar, ", "); }
            ar = concat(ar, `i64 %p${i}`);
            i = i + 1;
        }
        this.raw(`define i64 @__fnval_${name}(${ps}) {`);
        this.term = false;
        const r: string = this.newTmp();
        this.emit(`  ${r} = call i64 @${name}(${ar})`);
        this.emit(`  ret i64 ${r}`);
        this.term = true;
        this.raw("}");
        this.raw("");
    }

    genUnary(u: Unary): string {
        const v: string = this.genExpr(u.operand);
        if (u.op == Tok.Minus) { return this.bin("sub", "0", v); }
        if (u.op == Tok.Tilde) { return this.bin("xor", v, "-1"); }   // ~v = v ^ -1
        if (u.op == Tok.Bang) {
            const c: string = this.newTmp();
            this.emit(`  ${c} = icmp eq i64 ${v}, 0`);
            const t: string = this.newTmp();
            this.emit(`  ${t} = zext i1 ${c} to i64`);
            return t;
        }
        return v;
    }

    genBinary(b: Binary): string {
        // `&&`/`||` ANTES de gerar os operandos: o rhs só pode ser avaliado
        // condicionalmente (curto-circuito).
        if (b.op == Tok.AmpAmp || b.op == Tok.PipePipe) { return this.genAndOr(b); }
        // aritmética/comparação f64: se qualquer operando é f64, vai pro caminho float.
        const lt: string = this.sema.typeOf(b.lhs, this.scope);
        const rt: string = this.sema.typeOf(b.rhs, this.scope);
        if (isFloatTy(lt) || isFloatTy(rt)) { return this.genFloatBin(b, lt, rt); }
        const l: string = this.genExpr(b.lhs);
        const r: string = this.genExpr(b.rhs);
        const op: Tok = b.op;
        if (op == Tok.Plus) { return this.bin("add", l, r); }
        if (op == Tok.Minus) { return this.bin("sub", l, r); }
        if (op == Tok.Star) { return this.bin("mul", l, r); }
        if (op == Tok.Slash) { return this.bin("sdiv", l, r); }
        if (op == Tok.Percent) { return this.bin("srem", l, r); }
        if (op == Tok.EqEq) { return this.cmp("eq", l, r); }
        if (op == Tok.Neq) { return this.cmp("ne", l, r); }
        if (op == Tok.Lt) { return this.cmp("slt", l, r); }
        if (op == Tok.Gt) { return this.cmp("sgt", l, r); }
        if (op == Tok.Le) { return this.cmp("sle", l, r); }
        if (op == Tok.Ge) { return this.cmp("sge", l, r); }
        // bitwise
        if (op == Tok.Amp) { return this.bin("and", l, r); }
        if (op == Tok.Pipe) { return this.bin("or", l, r); }
        if (op == Tok.Caret) { return this.bin("xor", l, r); }
        if (op == Tok.Shl) { return this.bin("shl", l, r); }
        if (op == Tok.Shr) { return this.bin("ashr", l, r); }   // shift aritmético (sinal)
        return "0";
    }

    // `a && b` / `a || b` com CURTO-CIRCUITO: `b` só é avaliado se necessário.
    // Sem isso, um guarda como `i >= 0 && xs[i].campo` avalia xs[-1] e quebra —
    // era o comportamento antigo (and/or puros).
    genAndOr(b: Binary): string {
        // slot HOISTADO no entry (ver scCount*): um por sítio de &&/||. Antes o
        // alloca vinha aqui, no ponto de uso — dentro de um loop isso vazava a
        // pilha a cada iteração (alloca dinâmico só é liberado no ret).
        const id: i64 = this.scN;
        this.scN = this.scN + 1;
        const ra: string = `%sc${id}.addr`;
        const lv: string = this.truth(this.genExpr(b.lhs));
        this.emit(`  store i64 ${lv}, ptr ${ra}`);      // resultado provisório = lhs
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${lv}, 0`);
        const lrhs: string = this.newLabel();
        const lend: string = this.newLabel();
        if (b.op == Tok.AmpAmp) {                       // && : só avalia rhs se lhs=1
            this.emit(`  br i1 ${cb}, label %${lrhs}, label %${lend}`);
        } else {                                        // || : só avalia rhs se lhs=0
            this.emit(`  br i1 ${cb}, label %${lend}, label %${lrhs}`);
        }
        this.term = true;
        this.label(lrhs);
        const rv: string = this.truth(this.genExpr(b.rhs));
        this.emit(`  store i64 ${rv}, ptr ${ra}`);
        this.emit(`  br label %${lend}`);
        this.term = true;
        this.label(lend);
        const res: string = this.newTmp();
        this.emit(`  ${res} = load i64, ptr ${ra}`);
        return res;
    }

    // Converte a CÉLULA `v` do tipo `ftm` para o tipo `to`, nas bordas (let com
    // anotação, atribuição, argumento, return). Um f64 trafega como os BITS do
    // double num i64: `let x: i64 = round(...)` precisa de fptosi de VERDADE —
    // senão guardaria o padrão de bits (um número gigante).
    coerce(v: string, ftm: string, to: string): string {
        const fFloat: bool = isFloatTy(ftm);
        const tFloat: bool = isFloatTy(to);
        if (fFloat == tFloat) { return v; }
        if (fFloat) {                                  // f64 → inteiro
            if (!isIntLike(to)) { return v; }
            const d: string = this.newTmp();
            this.emit(`  ${d} = bitcast i64 ${v} to double`);
            const r: string = this.newTmp();
            this.emit(`  ${r} = fptosi double ${d} to i64`);
            return r;
        }
        if (!isIntLike(ftm)) { return v; }             // inteiro → f64
        const d2: string = this.newTmp();
        this.emit(`  ${d2} = sitofp i64 ${v} to double`);
        const r2: string = this.newTmp();
        this.emit(`  ${r2} = bitcast double ${d2} to i64`);
        return r2;
    }

    // operando f64: f64 trafega como bits-do-double num i64 → bitcast p/ double;
    // um i64 numérico vira double via sitofp (permite misturar int e float).
    toDouble(v: string, ty: string): string {
        const t: string = this.newTmp();
        if (isFloatTy(ty)) { this.emit(`  ${t} = bitcast i64 ${v} to double`); }
        else { this.emit(`  ${t} = sitofp i64 ${v} to double`); }
        return t;
    }
    // op aritmético float → resultado double rebitcastado p/ i64 (modelo do runtime).
    fbin(opc: string, ld: string, rd: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = ${opc} double ${ld}, ${rd}`);
        const ti: string = this.newTmp();
        this.emit(`  ${ti} = bitcast double ${t} to i64`);
        return ti;
    }
    // comparação float → i1 ampliado p/ i64 (0/1).
    fcmp(pred: string, ld: string, rd: string): string {
        const c: string = this.newTmp();
        this.emit(`  ${c} = fcmp ${pred} double ${ld}, ${rd}`);
        const t: string = this.newTmp();
        this.emit(`  ${t} = zext i1 ${c} to i64`);
        return t;
    }
    genFloatBin(b: Binary, lt: string, rt: string): string {
        const lv: string = this.genExpr(b.lhs);
        const rv: string = this.genExpr(b.rhs);
        const ld: string = this.toDouble(lv, lt);
        const rd: string = this.toDouble(rv, rt);
        const op: Tok = b.op;
        if (op == Tok.Plus) { return this.fbin("fadd", ld, rd); }
        if (op == Tok.Minus) { return this.fbin("fsub", ld, rd); }
        if (op == Tok.Star) { return this.fbin("fmul", ld, rd); }
        if (op == Tok.Slash) { return this.fbin("fdiv", ld, rd); }
        if (op == Tok.Percent) { return this.fbin("frem", ld, rd); }
        if (op == Tok.EqEq) { return this.fcmp("oeq", ld, rd); }
        if (op == Tok.Neq) { return this.fcmp("une", ld, rd); }
        if (op == Tok.Lt) { return this.fcmp("olt", ld, rd); }
        if (op == Tok.Gt) { return this.fcmp("ogt", ld, rd); }
        if (op == Tok.Le) { return this.fcmp("ole", ld, rd); }
        if (op == Tok.Ge) { return this.fcmp("oge", ld, rd); }
        return "0";
    }

    // float literal → bits do double como i64 (modelo do runtime: f64 trafega em
    // i64). `${value}` formata o f64 em decimal (o compilador host lê via double).
    // OBS: exige literal exatamente representável (0.0, 2.5, …); aritmética f64
    // não é suportada no subset (o compilador-fonte só carrega/imprime floats).
    genFloatLit(value: f64): string {
        return `bitcast (double ${value} to i64)`;
    }

    // template `...${e}...` → cadeia de concat; cada interpolação é convertida a
    // string conforme o tipo (string como está; f64 via f64_to_str; resto i64_to_str).
    // bool → "true"/"false" (select entre dois literais; sem runtime dedicado).
    boolToStr(v: string): string {
        const t: string = this.genStrLit("true");
        const f: string = this.genStrLit("false");
        const c: string = this.newTmp();
        this.emit(`  ${c} = icmp ne i64 ${v}, 0`);
        const r: string = this.newTmp();
        this.emit(`  ${r} = select i1 ${c}, i64 ${t}, i64 ${f}`);
        return r;
    }
    // `esc` = o template é corpo de .lsx (Template.escapes). Aí toda parte que
    // NÃO for `Html` sai por __lex_html_escape.
    //
    // Os literais do próprio markup são StrLit e chegam aqui como parte — mas
    // quem os cria é o front-end .lsx, não o usuário, então eles são Html por
    // construção e passam intactos (ver genTemplate).
    tplPart(e: Expr, esc: bool): string {
        const ty: string = this.sema.typeOf(e, this.scope);
        const v: string = this.genExpr(e);
        if (isHtmlTy(ty)) { return v; }                      // já é markup
        if (strEq(ty, "string")) {
            if (esc) { return this.rtCall("__lex_html_escape", [v]); }
            return v;
        }
        if (isFloatTy(ty)) { return this.rtCall("__lex_f64_to_str", [v]); }
        if (strEq(ty, "bool")) { return this.boolToStr(v); }
        // número: não há o que escapar, e evitar a chamada mantém o caso comum
        // (contadores, índices) sem custo.
        if (isIntLike(ty)) { return this.rtCall("__lex_i64_to_str", [v]); }
        if (esc) { return this.rtCall("__lex_html_escape", [this.rtCall("__lex_i64_to_str", [v])]); }
        return this.rtCall("__lex_i64_to_str", [v]);
    }
    genTemplate(t: Template): string {
        if (t.parts.len() == 0) { return this.genStrLit(""); }
        let acc: string = this.tplLit(t.parts[0], t.escapes);
        let i: i64 = 1;
        while (i < t.parts.len()) {
            const p: string = this.tplLit(t.parts[i], t.escapes);
            acc = this.rtCall("__lex_concat", [acc, p]);
            i = i + 1;
        }
        return acc;
    }
    // um StrLit dentro de um corpo .lsx é o markup literal escrito no arquivo —
    // nunca escapa. Só as INTERPOLAÇÕES escapam.
    tplLit(e: Expr, esc: bool): string {
        return match (e) {
            StrLit s => this.genStrLit(s.value),
            _ => this.tplPart(e, esc)
        };
    }

    // string literal → global de bytes; devolve o operando i64 (ponteiro).
    genStrLit(value: string): string {
        const name: string = concat("@.str", str(this.strN));
        this.strN = this.strN + 1;
        const nbytes: i64 = len(value) + 1;
        this.strs.push(`${name} = private unnamed_addr constant [${nbytes} x i8] c"${irEscape(value)}\\00"`);
        return `ptrtoint (ptr ${name} to i64)`;
    }

    // ── ponte com a ABI do runtime (ver rtAbi) ──────────────────────────────
    // célula i64 → operando tipado do parâmetro ("ptr %tN" ou "i64 %tN").
    abiArg(v: string, c: i64): string {
        if (c != 112) { return concat("i64 ", v); }        // '.' escalar
        const t: string = this.newTmp();
        this.emit(`  ${t} = inttoptr i64 ${v} to ptr`);
        return concat("ptr ", t);
    }
    // chamada a uma função do runtime, ciente da ABI. `args` = células i64;
    // devolve a célula i64 do resultado ("0" se void).
    rtCall(sym: string, args: string[]): string {
        const abi: string = rtAbi(sym);
        const aks: string = abiArgs(abi);
        const rk: string = abiRet(abi);
        let argStr: string = "";
        let i: i64 = 0;
        for (const a of args) {
            let c: i64 = 46;                               // '.' se a ABI não disser
            if (i < len(aks)) { c = peek8(aks, i); }
            if (i > 0) { argStr = concat(argStr, ", "); }
            argStr = concat(argStr, this.abiArg(a, c));
            i = i + 1;
        }
        if (strEq(rk, "v")) {
            this.emit(`  call void @${sym}(${argStr})`);
            return "0";
        }
        const t: string = this.newTmp();
        if (strEq(rk, "p")) {
            this.emit(`  ${t} = call ptr @${sym}(${argStr})`);
            const cell: string = this.newTmp();
            this.emit(`  ${cell} = ptrtoint ptr ${t} to i64`);
            return cell;
        }
        this.emit(`  ${t} = call i64 @${sym}(${argStr})`);
        return t;
    }
    // `declare <ret> @sym(<tipos>)` derivado da ABI.
    rtDecl(sym: string): string {
        const abi: string = rtAbi(sym);
        const aks: string = abiArgs(abi);
        let ps: string = "";
        let i: i64 = 0;
        while (i < len(aks)) {
            if (i > 0) { ps = concat(ps, ", "); }
            ps = concat(ps, abiTy(peek8(aks, i)));
            i = i + 1;
        }
        const rk: string = abiRet(abi);
        let rt: string = "i64";
        if (strEq(rk, "p")) { rt = "ptr"; }
        if (strEq(rk, "v")) { rt = "void"; }
        return `declare ${rt} @${sym}(${ps})`;
    }

    // printf("%s\n", s): o operando é um PONTEIRO e tem que entrar no vararg como
    // `ptr`. No nativo daria no mesmo, mas no wasm32 o va_arg lê 4 bytes — passar
    // i64 desalinha a lista e imprime lixo.
    printfStr(cell: string) {
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${cell} to ptr`);
        this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_str, ptr ${p}) nobuiltin`);
    }

    // emite `%t = call i64 @rfn(argStr)` e devolve o temporário.
    emitCall(rfn: string, argStr: string): string {
        const t: string = this.newTmp();
        this.emit(`  ${t} = call i64 @${rfn}(${argStr})`);
        return t;
    }
    // gera cada arg como i64 e junta em "i64 a, i64 b, …".
    argList(args: Expr[]): string {
        let s: string = "";
        let first: bool = true;
        for (const a of args) {
            const v: string = this.genExpr(a);
            if (!first) { s = concat(s, ", "); }
            s = concat(s, concat("i64 ", v));
            first = false;
        }
        return s;
    }
    // builtin do runtime: gera cada arg como CÉLULA i64 e chama pela ABI.
    callRuntime(rfn: string, args: Expr[]): string {
        let cells: string[] = [];
        for (const a of args) { cells.push(this.genExpr(a)); }
        return this.rtCall(rfn, cells);
    }
    // método de string com 1 arg: rfn(base, arg0).
    strMethod1(rfn: string, bv: string, args: Expr[]): string {
        let a: string = "0";
        if (args.len() >= 1) { a = this.genExpr(args[0]); }
        return this.rtCall(rfn, [bv, a]);
    }

    // se `a` é um ARRAY LITERAL, constrói o json array correspondente; senão "".
    boxArrayLit(a: Expr): string {
        return match (a) { ArrayLit al => this.genJsonArray(al), _ => "" };
    }
    genJsonArray(al: ArrayLit): string {
        const arr: string = this.rtCall("__lex_json_array", []);
        for (const it of al.items) {
            this.rtCall("__lex_json_push", [arr, this.boxArg(it, "any")]);
        }
        return arr;
    }

    // gera um arg; se o parâmetro é `any` e o valor é concreto, BOX num LexJson
    // do runtime (tag+payload) — assim `jsonEq` compara por valor (int/str/float).
    boxArg(a: Expr, paramTy: string): string {
        // `[a, b, c]` num parâmetro `any`: vira um ARRAY JSON de verdade (cada item
        // boxado). Antes passávamos o ponteiro cru do LexArr — e o __lex_json_eq
        // lia aquilo como se fosse um LexJson (tag de string) e caía num strcmp em
        // lixo → SEGV.
        if (strEq(paramTy, "any")) {
            const boxed: string = this.boxArrayLit(a);
            if (!strEq(boxed, "")) { return boxed; }
        }
        const at: string = this.sema.typeOf(a, this.scope);
        const v: string = this.genExpr(a);
        if (!strEq(paramTy, "any")) { return this.coerce(v, at, paramTy); }
        if (strEq(at, "any")) { return v; }                                  // já é any
        if (strEq(at, "string") || isHtmlTy(at)) { return this.rtCall("__lex_json_str", [v]); }
        if (strEq(at, "f64")) { return this.rtCall("__lex_json_float", [v]); }
        if (strEq(at, "bool")) { return this.rtCall("__lex_json_bool", [v]); }
        if (strEq(at, "i64")) { return this.rtCall("__lex_json_num", [v]); }
        // FALLBACK: tipo desconhecido/classe/array-não-literal. NUNCA devolver o
        // valor cru — o consumidor de `any` o trata como LexJson* e faria deref de
        // um inteiro (SEGV). Empacota como número (`_ => json_num`): a comparação
        // vira por valor/ponteiro, mas não quebra.
        return this.rtCall("__lex_json_num", [v]);
    }
    // lista de args com boxing por tipo de parâmetro (ptypes[i]); "" = sem box.
    argListBoxed(args: Expr[], ptypes: string[]): string {
        let s: string = "";
        let first: bool = true;
        let i: i64 = 0;
        for (const a of args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            if (!first) { s = concat(s, ", "); }
            s = concat(s, concat("i64 ", this.boxArg(a, pt)));
            first = false;
            i = i + 1;
        }
        return s;
    }

    // len(x): strlen / arr_len / map_len conforme o tipo de x.
    genLen(c: Call): string {
        const ty: string = this.sema.typeOf(c.args[0], this.scope);
        let rfn: string = "__lex_strlen";
        if (isArrayTy(ty)) { rfn = "__lex_arr_len"; }
        else if (isMapTy(ty)) { rfn = "__lex_map_len"; }
        return this.callRuntime(rfn, c.args);
    }

    // converte um valor ao texto conforme o tipo (p/ Terminal.*): string como
    // está; f64→f64_to_str; any/bool→json_as_str; resto→i64_to_str.
    toText(a: Expr): string {
        const ty: string = this.sema.typeOf(a, this.scope);
        const v: string = this.genExpr(a);
        if (strEq(ty, "string") || isHtmlTy(ty)) { return v; }   // Html = mesma célula
        if (isFloatTy(ty)) { return this.rtCall("__lex_f64_to_str", [v]); }
        if (strEq(ty, "any")) { return this.rtCall("__lex_json_as_str", [v]); }
        if (strEq(ty, "bool")) {
            const j: string = this.rtCall("__lex_json_bool", [v]);
            return this.rtCall("__lex_json_as_str", [j]);
        }
        return this.rtCall("__lex_i64_to_str", [v]);
    }
    // Terminal.<qualquer>(a, b, …): concatena os args (por tipo), separa por
    // espaço, imprime + \n. (Builtin de prelúdio — evita compilar std/terminal.lex;
    // sem cor/rótulos: o símbolo/bullet vem dos próprios args do chamador.)
    genTerminalPrint(args: Expr[]): string {
        if (args.len() == 0) {
            this.printfStr(this.genStrLit(""));
            return "0";
        }
        let acc: string = "";
        let i: i64 = 0;
        for (const a of args) {
            const piece: string = this.toText(a);
            if (i == 0) { acc = piece; }
            else {
                const sp: string = this.rtCall("__lex_concat", [acc, this.genStrLit(" ")]);
                acc = this.rtCall("__lex_concat", [sp, piece]);
            }
            i = i + 1;
        }
        this.printfStr(acc);
        return "0";
    }

    // super(args): chama o constructor da superclasse no MESMO `this` (não aloca).
    genSuperCall(c: Call): string {
        const ci: ClassInfo = this.sema.classes.find(this.curClass);
        if (strEq(ci.parent, "")) { return "0"; }
        const owner: string = this.sema.classes.methodOwner(ci.parent, "constructor");
        if (strEq(owner, "")) { return "0"; }
        const thisV: string = this.genLoad("this");
        const ptypes: string[] = this.sema.methodParamTypes(ci.parent, "constructor");
        let argStr: string = concat("i64 ", thisV);
        let i: i64 = 0;
        for (const a of c.args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
            i = i + 1;
        }
        this.emitCall(concat(owner, ".constructor"), argStr);
        return "0";
    }

    // min/max: polimórficos (int ou float). Compara no tipo certo e escolhe a
    // CÉLULA original via `select` — assim o f64 volta com os bits intactos.
    genMinMax(c: Call): string {
        if (c.args.len() < 2) { return "0"; }
        const lt: string = this.sema.typeOf(c.args[0], this.scope);
        const rt: string = this.sema.typeOf(c.args[1], this.scope);
        const a: string = this.genExpr(c.args[0]);
        const b: string = this.genExpr(c.args[1]);
        const wantMin: bool = strEq(c.name, "min");
        const cb: string = this.newTmp();
        if (isFloatTy(lt) || isFloatTy(rt)) {
            const ad: string = this.toDouble(a, lt);
            const bd: string = this.toDouble(b, rt);
            let pred: string = "ogt";
            if (wantMin) { pred = "olt"; }
            this.emit(`  ${cb} = fcmp ${pred} double ${ad}, ${bd}`);
        } else {
            let pred: string = "sgt";
            if (wantMin) { pred = "slt"; }
            this.emit(`  ${cb} = icmp ${pred} i64 ${a}, ${b}`);
        }
        const r: string = this.newTmp();
        this.emit(`  ${r} = select i1 ${cb}, i64 ${a}, i64 ${b}`);
        return r;
    }

    genCall(c: Call): string {
        // `html(s)` — só retipa: promete que `s` já é markup e não deve ser
        // escapado no corpo de um .lsx. Não emite chamada nenhuma (o custo do
        // opt-out de segurança tem de ser zero, senão ninguém o usa).
        if (strEq(c.name, "html") && c.args.len() == 1) {
            return this.genExpr(c.args[0]);
        }
        // chamada INDIRETA: c.name é uma variável de tipo função (arrow recebido)
        if (isFunctionType(this.scope.get(c.name))) {
            const env: string = this.genLoad(c.name);            // a closure
            const ep: string = this.newTmp();
            this.emit(`  ${ep} = inttoptr i64 ${env} to ptr`);
            const fp: string = this.newTmp();
            this.emit(`  ${fp} = load i64, ptr ${ep}`);          // slot 0 = ponteiro da função
            const fpp: string = this.newTmp();
            this.emit(`  ${fpp} = inttoptr i64 ${fp} to ptr`);
            let ar: string = concat("i64 ", env);                // env é o 1º argumento
            for (const a of c.args) { ar = concat(ar, concat(", i64 ", this.genExpr(a))); }
            const t: string = this.newTmp();
            this.emit(`  ${t} = call i64 ${fpp}(${ar})`);
            return t;
        }
        // print(x): imprime um i64 via printf da libc (saída de verdade).
        if (strEq(c.name, "print")) {
            let v: string = "0";
            if (c.args.len() >= 1) { v = this.genExpr(c.args[0]); }
            this.emit(`  call i32 (ptr, ...) @printf(ptr @.lex_fmt_int, i64 ${v}) nobuiltin`);
            return "0";
        }
        if (strEq(c.name, "len")) { return this.genLen(c); }
        if (strEq(c.name, "super")) { return this.genSuperCall(c); }
        if (strEq(c.name, "min") || strEq(c.name, "max")) { return this.genMinMax(c); }
        // join(h) com 1 arg = espera a thread; com 2 = join de array (runtimeFn)
        if (strEq(c.name, "join") && c.args.len() == 1) { return this.joinCell(this.genExpr(c.args[0])); }
        if (idxOf(this.asyncNames, c.name) >= 0) { return this.spawnCall(c); }   // async: lança thread
        const rt: string = runtimeFn(c.name);
        if (!strEq(rt, "")) { return this.callRuntime(rt, c.args); }
        // chamada a função do usuário (boxando args `any`)
        return this.emitCall(c.name, this.argListBoxed(c.args, this.sema.funcParamTypes(c.name)));
    }

    // Dispatch DINÂMICO (polimorfismo): o método é sobrescrito, então a impl certa
    // depende da CLASSE REAL do objeto. Lê a tag (slot 0) e compara com a de cada
    // classe que tem impl própria; o fallback é a resolução estática (subclasse que
    // herda sem sobrescrever). Os args são gerados UMA vez, antes dos branches.
    genDynDispatch(m: MethodCall, bv: string, baseTy: string, ovs: string[]): string {
        const ptypes: string[] = this.sema.methodParamTypes(baseTy, m.method);
        let argStr: string = concat("i64 ", bv);
        let i: i64 = 0;
        for (const a of m.args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
            i = i + 1;
        }
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const ra: string = `%dyn${id}.addr`;
        this.emit(`  ${ra} = alloca i64`);
        const sp: string = this.newTmp();
        this.emit(`  ${sp} = inttoptr i64 ${bv} to ptr`);
        const tag: string = this.newTmp();
        this.emit(`  ${tag} = load i64, ptr ${sp}`);
        const lend: string = this.newLabel();
        for (const oc of ovs) {
            const t: i64 = this.sema.classes.indexOfDecl(oc);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp eq i64 ${tag}, ${t}`);
            const lyes: string = this.newLabel();
            const lno: string = this.newLabel();
            this.emit(`  br i1 ${cb}, label %${lyes}, label %${lno}`);
            this.term = true;
            this.label(lyes);
            const rv: string = this.emitCall(concat(oc, concat(".", m.method)), argStr);
            this.emit(`  store i64 ${rv}, ptr ${ra}`);
            this.emit(`  br label %${lend}`);
            this.term = true;
            this.label(lno);
        }
        const so: string = this.sema.classes.methodOwner(baseTy, m.method);
        const fv: string = this.emitCall(concat(so, concat(".", m.method)), argStr);
        this.emit(`  store i64 ${fv}, ptr ${ra}`);
        this.emit(`  br label %${lend}`);
        this.term = true;
        this.label(lend);
        const r: string = this.newTmp();
        this.emit(`  ${r} = load i64, ptr ${ra}`);
        return r;
    }

    // chamadas de método: Terminal.log e (Stage B/C) coleções; resto → F6.4.
    genMethodCall(m: MethodCall): string {
        if (strEq(varName(m.base), "Terminal")) {
            return this.genTerminalPrint(m.args);
        }
        // método ESTÁTICO: `Classe.metodo(args)` — a base é o NOME de uma classe,
        // não uma variável (scope.get devolve "" p/ ela). O parser descarta o
        // `static`, então o método tem o param `this` — passamos 0 (não é usado).
        const bn: string = varName(m.base);
        if (!strEq(bn, "") && strEq(this.scope.get(bn), "?")
            && this.sema.classes.findInfo(bn) >= 0) {
            const sowner: string = this.sema.classes.methodOwner(bn, m.method);
            if (!strEq(sowner, "")) {
                const sptypes: string[] = this.sema.methodParamTypes(bn, m.method);
                let sargs: string = "i64 0";
                let si: i64 = 0;
                for (const a of m.args) {
                    let pt: string = "";
                    if (si < sptypes.len()) { pt = sptypes[si]; }
                    sargs = concat(sargs, concat(", i64 ", this.boxArg(a, pt)));
                    si = si + 1;
                }
                return this.emitCall(concat(sowner, concat(".", m.method)), sargs);
            }
        }
        const baseTy: string = this.sema.typeOf(m.base, this.scope);
        const bv: string = this.genExpr(m.base);
        // Método de CLASSE tem prioridade sobre os builtins de mesmo nome: uma
        // classe do usuário com `.push`/`.send`/`.free` (ex.: Pilha<T>) não pode
        // virar __lex_arr_push. Dispatch estático @Dono.metodo(this, args…), ou
        // DINÂMICO (pela tag) se o método for sobrescrito em alguma subclasse.
        if (isClassTy(baseTy) && this.sema.classes.findInfo(baseTy) >= 0) {
            const owner: string = this.sema.classes.methodOwner(baseTy, m.method);
            if (!strEq(owner, "")) {
                const ovs: string[] = this.sema.classes.overridersOf(baseTy, m.method);
                if (ovs.len() > 1) { return this.genDynDispatch(m, bv, baseTy, ovs); }
                const ptypes: string[] = this.sema.methodParamTypes(baseTy, m.method);
                let argStr: string = concat("i64 ", bv);
                let i: i64 = 0;
                for (const a of m.args) {
                    let pt: string = "";
                    if (i < ptypes.len()) { pt = ptypes[i]; }
                    argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
                    i = i + 1;
                }
                return this.emitCall(concat(owner, concat(".", m.method)), argStr);
            }
        }
        if (strEq(m.method, "len")) {
            let rfn: string = "__lex_strlen";
            if (isArrayTy(baseTy)) { rfn = "__lex_arr_len"; }
            else if (isMapTy(baseTy)) { rfn = "__lex_map_len"; }
            return this.rtCall(rfn, [bv]);
        }
        if (strEq(m.method, "push")) {
            let v: string = "0";
            if (m.args.len() >= 1) { v = this.genExpr(m.args[0]); }
            this.rtCall("__lex_arr_push", [bv, v]);
            return "0";
        }
        if (strEq(m.method, "pop")) {
            return this.rtCall("__lex_arr_pop", [bv]);
        }
        if (strEq(m.method, "join")) {                     // string[].join(sep) → string
            let sep: string = this.genStrLit("");
            if (m.args.len() >= 1) { sep = this.genExpr(m.args[0]); }
            return this.rtCall("__lex_arr_join", [bv, sep]);
        }
        // métodos de string (s.contains(x)/startsWith/endsWith)
        if (strEq(m.method, "contains")) { return this.strMethod1("__lex_contains", bv, m.args); }
        if (strEq(m.method, "startsWith")) { return this.strMethod1("__lex_starts_with", bv, m.args); }
        if (strEq(m.method, "endsWith")) { return this.strMethod1("__lex_ends_with", bv, m.args); }
        if (strEq(m.method, "split")) { return this.strMethod1("__lex_split", bv, m.args); }
        if (strEq(m.method, "indexOf")) { return this.strMethod1("__lex_index_of", bv, m.args); }
        if (strEq(m.method, "repeat")) { return this.strMethod1("__lex_str_repeat", bv, m.args); }
        if (strEq(m.method, "charCode")) { return this.strMethod1("__lex_char_code", bv, m.args); }
        if (strEq(m.method, "trim")) { return this.rtCall("__lex_trim", [bv]); }
        if (strEq(m.method, "toLower")) { return this.rtCall("__lex_to_lower", [bv]); }
        if (strEq(m.method, "toUpper")) { return this.rtCall("__lex_to_upper", [bv]); }
        if (strEq(m.method, "replace")) {                  // s.replace(frm, to) → string
            let frm: string = this.genStrLit("");
            let to: string = this.genStrLit("");
            if (m.args.len() >= 1) { frm = this.genExpr(m.args[0]); }
            if (m.args.len() >= 2) { to = this.genExpr(m.args[1]); }
            return this.rtCall("__lex_str_replace", [bv, frm, to]);
        }
        // json: j.jsonSet(k, v) / j.jsonStringify()
        if (strEq(m.method, "jsonSet")) {
            let k: string = "0";
            let v: string = "0";
            if (m.args.len() >= 1) { k = this.genExpr(m.args[0]); }
            if (m.args.len() >= 2) { v = this.boxArg(m.args[1], "any"); }
            this.rtCall("__lex_json_set", [bv, k, v]);
            return "0";
        }
        if (strEq(m.method, "jsonStringify")) {
            return this.rtCall("__lex_json_stringify", [bv]);
        }
        // Map: m.mapSet(k, v) / m.mapGet(k)
        if (strEq(m.method, "mapSet")) {
            let k: string = "0";
            let v: string = "0";
            if (m.args.len() >= 1) { k = this.genExpr(m.args[0]); }
            if (m.args.len() >= 2) { v = this.genExpr(m.args[1]); }
            this.rtCall("__lex_map_set", [bv, k, v]);
            return "0";
        }
        if (strEq(m.method, "mapGet")) {
            let k: string = "0";
            if (m.args.len() >= 1) { k = this.genExpr(m.args[0]); }
            return this.rtCall("__lex_map_get", [bv, k]);
        }
        // canais de thread: ch.send(v) / ch.recv() / ch.close()
        if (strEq(m.method, "send")) {
            let v: string = "0";
            if (m.args.len() >= 1) { v = this.genExpr(m.args[0]); }
            this.rtCall("__lex_chan_send", [bv, v]);
            return "0";
        }
        if (strEq(m.method, "recv")) { return this.rtCall("__lex_chan_recv", [bv]); }
        if (strEq(m.method, "close")) { return this.rtCall("__lex_chan_close", [bv]); }
        // memória crua: métodos em ptr — buf.free() / buf.poke*(off,v) / buf.peek*(off)
        if (strEq(m.method, "free")) { this.rtCall("__lex_free", [bv]); return "0"; }
        const pk: string = ptrPoke(m.method);
        if (!strEq(pk, "")) {
            let o: string = "0";
            let v: string = "0";
            if (m.args.len() >= 1) { o = this.genExpr(m.args[0]); }
            if (m.args.len() >= 2) { v = this.genExpr(m.args[1]); }
            this.emit(`  call void @${pk}(i64 ${bv}, i64 ${o}, i64 ${v})`);
            return "0";
        }
        const pe: string = ptrPeek(m.method);
        if (!strEq(pe, "")) {
            let o: string = "0";
            if (m.args.len() >= 1) { o = this.genExpr(m.args[0]); }
            return this.rtCall(pe, [bv, o]);
        }
        return "0";
    }

    // [a, b, c] → arr_new(n) + arr_push por item; devolve o ponteiro do array.
    genArrayLit(a: ArrayLit): string {
        const arr: string = this.rtCall("__lex_arr_new", [str(a.items.len())]);
        for (const it of a.items) {
            const v: string = this.genExpr(it);
            this.rtCall("__lex_arr_push", [arr, v]);
        }
        return arr;
    }

    // { chave: v, … } (chaves identificadoras) → literal `json`: cria o objeto e
    // seta cada campo com o valor EMBRULHADO por tipo (string→jsonStr, i64→jsonNum…).
    genStructLit(sl: StructLit): string {
        const obj: string = this.rtCall("__lex_json_object", []);
        let i: i64 = 0;
        while (i < sl.fields.len()) {
            const k: string = this.genStrLit(sl.fields[i]);
            const v: string = this.boxArg(sl.vals[i], "any");
            this.rtCall("__lex_json_set", [obj, k, v]);
            i = i + 1;
        }
        return obj;
    }

    // {} / {"k": v, …} → map_new + map_set por entrada; devolve o ponteiro do map.
    genMapLit(ml: MapLit): string {
        const m: string = this.rtCall("__lex_map_new", []);
        let i: i64 = 0;
        while (i < ml.mapKeys.len()) {
            const k: string = this.genStrLit(ml.mapKeys[i]);
            const v: string = this.genExpr(ml.vals[i]);
            this.rtCall("__lex_map_set", [m, k, v]);
            i = i + 1;
        }
        return m;
    }

    // base[idx]: arr_get / map_get / char_at conforme o tipo da base.
    genIndex(ix: Index): string {
        const baseTy: string = this.sema.typeOf(ix.base, this.scope);
        const idxTy: string = this.sema.typeOf(ix.index, this.scope);
        const b: string = this.genExpr(ix.base);
        const i: string = this.genExpr(ix.index);
        let rfn: string = "__lex_arr_get";
        if (isMapTy(baseTy)) { rfn = "__lex_map_get"; }
        else if (strEq(baseTy, "string")) { rfn = "__lex_char_at"; }
        else if (strEq(baseTy, "any") || strEq(baseTy, "json")) {
            // JSON: chave string → membro (json_get); índice int → elemento (json_at)
            if (strEq(idxTy, "string")) { rfn = "__lex_json_get"; }
            else { rfn = "__lex_json_at"; }
        }
        return this.rtCall(rfn, [b, i]);
    }

    // base[idx] = valor: arr_set / map_set (base, idx, valor) — nessa ordem.
    genIndexAssign(ix: Index, valExpr: Expr): i64 {
        const baseTy: string = this.sema.typeOf(ix.base, this.scope);
        const b: string = this.genExpr(ix.base);
        const i: string = this.genExpr(ix.index);
        const v: string = this.genExpr(valExpr);
        let rfn: string = "__lex_arr_set";
        if (isMapTy(baseTy)) { rfn = "__lex_map_set"; }
        this.emit(`  call i64 @${rfn}(i64 ${b}, i64 ${i}, i64 ${v})`);
        return 0;
    }

    // endereço do slot `slot` do objeto `objVal` (i64 ptr). slot 0 = a própria base.
    slotAddr(objVal: string, slot: i64): string {
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${objVal} to ptr`);
        if (slot == 0) { return p; }
        const ep: string = this.newTmp();
        this.emit(`  ${ep} = getelementptr i64, ptr ${p}, i64 ${slot}`);
        return ep;
    }

    // obj.campo: membro de enum (Tok.Newline → inteiro) ou load do slot do campo.
    // "Classe.campo" — a chave do slot global de um campo static (a classe é a
    // DONA, resolvida por herança: Sub.count e Counter.count batem no mesmo slot).
    staticKey(cls: string, field: string): string {
        const own: string = this.sema.classes.staticOwner(cls, field);
        if (strEq(own, "")) { return ""; }
        return concat(own, concat(".", field));
    }
    // nome da classe se `e` for o NOME de uma classe (base de acesso static), senão "".
    staticBase(e: Expr): string {
        const n: string = varName(e);
        if (strEq(n, "")) { return ""; }
        if (!strEq(this.scope.get(n), "?")) { return ""; }     // é variável, não classe
        if (this.sema.classes.findInfo(n) < 0) { return ""; }
        return n;
    }

    genField(f: Field): string {
        const ev: i64 = this.sema.enums.value(varName(f.base), f.field);
        if (ev >= 0) { return str(ev); }
        // campo static: mora num slot global, não no objeto
        const sb: string = this.staticBase(f.base);
        if (!strEq(sb, "")) {
            const k: string = this.staticKey(sb, f.field);
            if (!strEq(k, "")) {
                return this.rtCall("__lex_gget", [str(this.slotOfGlobal(k))]);
            }
        }
        const baseTy: string = this.sema.typeOf(f.base, this.scope);
        const b: string = this.genExpr(f.base);
        const slot: i64 = this.sema.classes.fieldSlot(baseTy, f.field);
        const addr: string = this.slotAddr(b, slot);
        const v: string = this.newTmp();
        this.emit(`  ${v} = load i64, ptr ${addr}`);
        return v;
    }

    // obj.campo = valor: store no slot do campo.
    genFieldAssign(f: Field, valExpr: Expr): i64 {
        const sb: string = this.staticBase(f.base);
        if (!strEq(sb, "")) {
            const k: string = this.staticKey(sb, f.field);
            if (!strEq(k, "")) {
                const sv: string = this.boxArg(valExpr, this.sema.classes.staticType(sb, f.field));
                this.rtCall("__lex_gset", [str(this.slotOfGlobal(k)), sv]);
                return 0;
            }
        }
        const baseTy: string = this.sema.typeOf(f.base, this.scope);
        const b: string = this.genExpr(f.base);
        const slot: i64 = this.sema.classes.fieldSlot(baseTy, f.field);
        const v: string = this.boxArg(valExpr, this.sema.classes.fieldType(baseTy, f.field));  // boxa se o campo é `any`
        const addr: string = this.slotAddr(b, slot);
        this.emit(`  store i64 ${v}, ptr ${addr}`);
        return 0;
    }

    // new C(args): aloca nslots*8 bytes, grava a tag no slot 0, chama o constructor.
    genNew(ne: NewExpr): string {
        // classe desconhecida (import não resolvido, typo): `find` indexaria infos[-1]
        // e segfaultaria o COMPILADOR. O `lex check` já reporta isso como erro.
        if (this.sema.classes.findInfo(ne.cls) < 0) { return "0"; }
        const ci: ClassInfo = this.sema.classes.find(ne.cls);
        const obj: string = this.rtCall("__lex_alloc", [str(ci.nslots * 8)]);
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${obj} to ptr`);
        this.emit(`  store i64 ${ci.tag}, ptr ${p}`);
        const owner: string = this.sema.classes.methodOwner(ne.cls, "constructor");
        if (!strEq(owner, "")) {
            const ptypes: string[] = this.sema.methodParamTypes(ne.cls, "constructor");
            let argStr: string = concat("i64 ", obj);
            let i: i64 = 0;
            for (const a of ne.args) {
                let pt: string = "";
                if (i < ptypes.len()) { pt = ptypes[i]; }
                argStr = concat(argStr, concat(", i64 ", this.boxArg(a, pt)));
                i = i + 1;
            }
            this.emitCall(concat(owner, ".constructor"), argStr);
        }
        return obj;
    }

    genExpr(e: Expr): string {
        return match (e) {
            IntLit n => str(n.value),
            FloatLit f => this.genFloatLit(f.value),
            BoolLit b => boolLit(b.value),
            StrLit s => this.genStrLit(s.value),
            Template t => this.genTemplate(t),
            Var v => this.genLoad(v.name),
            Unary u => this.genUnary(u),
            Binary b => this.genBinary(b),
            Call c => this.genCall(c),
            MethodCall m => this.genMethodCall(m),
            ArrayLit a => this.genArrayLit(a),
            MapLit ml => this.genMapLit(ml),
            StructLit sl => this.genStructLit(sl),
            Index ix => this.genIndex(ix),
            NewExpr ne => this.genNew(ne),
            Field f => this.genField(f),
            Match mt => this.genMatch(mt),
            Lambda lm => this.genClosure(lm),
            TryExpr t => this.genTry(t),
            CatchExpr c => this.genCatch(c),
            SpawnExpr s => this.genSpawnExpr(s),
            AwaitExpr a => this.genAwait(a),
            ElementExpr el => this.genElement(el),
            _ => "0"
        };
    }

    // `<Card titulo="x" pontos={42} />` → `Card(new CardProps("x", 42))`.
    //
    // O DESUGAR É AQUI, e não no parser, porque a ordem posicional do
    // constructor de CardProps só existe depois que o ModuleLoader mesclou
    // todos os módulos — na hora de parsear o .lsx que USA a tag, o .lsx que a
    // DEFINE ainda não foi lido.
    //
    // Erros (componente inexistente, prop faltando) já saíram no typecheck com
    // mensagem decente; aqui só evitamos quebrar, emitindo um valor inócuo.
    genElement(el: ElementExpr): string {
        const fi: i64 = this.sema.funcIndex(el.name);
        if (fi < 0) { return this.genStrLit(""); }
        const ps: Param[] = this.sema.funcs[fi].params;
        let args: Expr[] = [];
        if (ps.len() > 0) {
            const pty: string = ps[0].ty;
            let vals: Expr[] = [];
            // a ordem é a do CONSTRUCTOR, que é o contrato posicional real
            for (const cp of this.sema.methodParams(pty, "constructor")) {
                vals.push(this.propValue(el, cp));
            }
            const ne: NewExpr = new NewExpr(pty, vals);
            ne.pos = el.pos;
            args.push(ne);
        }
        const c: Call = new Call(el.name, args);
        c.pos = el.pos;
        if (!el.island) { return this.genCall(c); }

        // ILHA (`client:load`): o HTML do SSR sai embrulhado num marcador, que é
        // o que o host procura no browser p/ chamar `<Nome>_hydrate`. O servidor
        // continua devolvendo HTML completo — a página funciona sem wasm, e a
        // hidratação só acrescenta comportamento.
        let ps: Expr[] = [];
        ps.push(new StrLit(concat(concat("<lsx-island data-c=\"", el.name), "\">")));
        ps.push(c);
        ps.push(new StrLit("</lsx-island>"));
        return this.genTemplate(new Template(ps));
    }

    // valor de uma prop: o atributo escrito na tag, o conteúdo (`children`, que
    // é o slot), ou um zero do tipo certo quando falta — o typecheck já acusou.
    propValue(el: ElementExpr, cp: Param): Expr {
        let i: i64 = 0;
        while (i < el.attrs.len()) {
            if (strEq(el.attrs[i], cp.name)) { return el.vals[i]; }
            i = i + 1;
        }
        if (strEq(cp.name, "children")) {
            if (el.hasKids) { return el.children; }
            return new StrLit("");
        }
        if (strEq(cp.ty, "string")) { return new StrLit(""); }
        if (isFloatTy(cp.ty)) { return new FloatLit(0.0); }
        if (strEq(cp.ty, "bool")) { return new BoolLit(false); }
        return new IntLit(0);
    }

    // ── statements (devolvem i64 dummy p/ caberem no match-expressão) ────────
    storeVar(name: string, v: string): i64 {
        if (this.isGlobalVar(name)) {
            this.rtCall("__lex_gset", [str(this.slotOfGlobal(name)), v]);
            return 0;
        }
        this.emit(`  store i64 ${v}, ptr ${this.varAddrOf(name)}`);
        return 0;
    }

    genLet(l: LetStmt): i64 {
        // tipo: anotação, ou inferido do valor (com o escopo ANTES de l)
        let ty: string = l.ty;
        const vt: string = this.sema.typeOf(l.value, this.scope);
        if (strEq(ty, "")) { ty = vt; }
        let v: string = this.genExpr(l.value);
        v = this.coerce(v, vt, ty);        // `let x: i64 = round(...)` → fptosi
        this.storeVar(l.name, v);          // gset se global promovido; senão store na alloca
        this.scope.set(l.name, ty);
        return 0;
    }

    genAssign(a: AssignStmt): i64 {
        return match (a.target) {
            Var vv => this.storeVar(vv.name, this.genAssignVal(a.value, this.scope.get(vv.name))),
            Index ix => this.genIndexAssign(ix, a.value),
            Field f => this.genFieldAssign(f, a.value),
            _ => 0
        };
    }
    // valor de uma atribuição, coagido ao tipo do destino.
    genAssignVal(e: Expr, want: string): string {
        const vt: string = this.sema.typeOf(e, this.scope);
        return this.coerce(this.genExpr(e), vt, want);
    }

    // emite os statements adiados (defer) em ordem LIFO. Chamado antes de cada
    // ret — assim defer roda em qualquer saída (return/fail/try-propaga/fim).
    flushDefers() {
        let i: i64 = this.curDefers.len() - 1;
        while (i >= 0) { this.genStmt(this.curDefers[i]); i = i - 1; }
    }
    genDefer(d: DeferStmt): i64 { this.curDefers.push(d.body); return 0; }

    // retorna um i64 respeitando a convenção (main devolve i32 truncado).
    emitReturnVal(val: string) {
        this.flushDefers();
        if (this.curMain) {
            const t: string = this.newTmp();
            this.emit(`  ${t} = trunc i64 ${val} to i32`);
            this.emit(`  ret i32 ${t}`);
        } else {
            this.emit(`  ret i64 ${val}`);
        }
        this.term = true;
    }
    genReturn(r: ReturnStmt): i64 {
        let val: string = "0";
        if (r.hasValue) {
            const vt: string = this.sema.typeOf(r.value, this.scope);
            val = this.coerce(this.genExpr(r.value), vt, this.curRet);
        }
        this.emitReturnVal(val);
        return 0;
    }
    // fail expr: seta o flag de erro com o valor e sai da função (sentinela 0).
    genFail(fs: FailStmt): i64 {
        const v: string = this.genExpr(fs.value);
        this.rtCall("__lex_set_err", [v]);
        this.emitReturnVal("0");
        return 0;
    }

    genStmts(list: Stmt[]): i64 {
        for (const s of list) { this.genStmt(s); }
        return 0;
    }

    genIf(f: IfStmt): i64 {
        const c: string = this.genExpr(f.cond);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
        const lt: string = this.newLabel();
        const lend: string = this.newLabel();
        const hasElse: bool = f.elseB.len() > 0;
        let le: string = lend;
        if (hasElse) { le = this.newLabel(); }
        this.emit(`  br i1 ${cb}, label %${lt}, label %${le}`);
        this.term = true;

        this.label(lt);
        this.genStmts(f.thenB);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }

        if (hasElse) {
            this.label(le);
            this.genStmts(f.elseB);
            if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
        }
        this.label(lend);
        return 0;
    }

    genWhile(w: WhileStmt): i64 {
        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`);
        this.term = true;

        this.label(lcond);
        const c: string = this.genExpr(w.cond);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
        this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`);
        this.term = true;

        this.label(lbody);
        this.loopCond.push(lcond);
        this.loopEnd.push(lend);
        this.genStmts(w.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) { this.emit(`  br label %${lcond}`); this.term = true; }

        this.label(lend);
        return 0;
    }

    // for (const x of xs) { ... } → i=0; while i<len(xs) { x=xs[i]; corpo; i++ }
    genForOf(fo: ForOfStmt): i64 {
        const iterTy: string = this.sema.typeOf(fo.iter, this.scope);
        const iter: string = this.genExpr(fo.iter);       // ponteiro do array (SSA, domina o laço)
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const ia: string = `%fo${id}.i.addr`;
        const xa: string = this.varAddrOf(fo.name);     // alloca hoistada no entry
        this.emit(`  ${ia} = alloca i64`);
        this.emit(`  store i64 0, ptr ${ia}`);
        this.scope.set(fo.name, elementTy(iterTy));

        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lincr: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lcond);
        const iv: string = this.newTmp();
        this.emit(`  ${iv} = load i64, ptr ${ia}`);
        const nv: string = this.rtCall("__lex_arr_len", [iter]);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp slt i64 ${iv}, ${nv}`);
        this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`); this.term = true;

        this.label(lbody);
        const ev: string = this.rtCall("__lex_arr_get", [iter, iv]);
        this.emit(`  store i64 ${ev}, ptr ${xa}`);
        // `continue` salta para o INCREMENTO, não para a condição. Se saltasse para
        // a condição, o índice nunca avançaria — `continue` num for-of era um LOOP
        // INFINITO. (O for C-style já fazia certo: ele salta para o `update`.)
        this.loopCond.push(lincr);
        this.loopEnd.push(lend);
        this.genStmts(fo.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) { this.emit(`  br label %${lincr}`); this.term = true; }

        this.label(lincr);
        const i2: string = this.newTmp();
        this.emit(`  ${i2} = load i64, ptr ${ia}`);
        const i3: string = this.bin("add", i2, "1");
        this.emit(`  store i64 ${i3}, ptr ${ia}`);
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lend);
        return 0;
    }

    // for (init; cond; update) { ... } — continue salta p/ o update.
    genFor(fr: ForStmt): i64 {
        if (fr.hasInit) { this.genStmt(fr.init); }
        const lcond: string = this.newLabel();
        const lbody: string = this.newLabel();
        const lupd: string = this.newLabel();
        const lend: string = this.newLabel();
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lcond);
        if (fr.hasCond) {
            const c: string = this.genExpr(fr.cond);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp ne i64 ${c}, 0`);
            this.emit(`  br i1 ${cb}, label %${lbody}, label %${lend}`);
        } else {
            this.emit(`  br label %${lbody}`);
        }
        this.term = true;

        this.label(lbody);
        this.loopCond.push(lupd);
        this.loopEnd.push(lend);
        this.genStmts(fr.body);
        this.loopCond.pop();
        this.loopEnd.pop();
        if (!this.term) { this.emit(`  br label %${lupd}`); this.term = true; }

        this.label(lupd);
        if (fr.hasUpdate) { this.genStmt(fr.update); }
        this.emit(`  br label %${lcond}`); this.term = true;

        this.label(lend);
        return 0;
    }

    genBreak(): i64 {
        const n: i64 = this.loopEnd.len();
        if (n > 0) { this.emit(`  br label %${this.loopEnd[n - 1]}`); this.term = true; }
        return 0;
    }
    genContinue(): i64 {
        const n: i64 = this.loopCond.len();
        if (n > 0) { this.emit(`  br label %${this.loopCond[n - 1]}`); this.term = true; }
        return 0;
    }
    genExprStmt(e: ExprStmt): i64 {
        const v: string = this.genExpr(e.expr);
        // `spawn f(...)` como STATEMENT: ninguém vai esperar a thread → detach,
        // senão o handle vaza. Como EXPRESSÃO (join/await), o handle fica vivo.
        const isSpawn: bool = match (e.expr) { SpawnExpr sp => true, _ => false };
        if (isSpawn) { this.emit(`  call i32 @pthread_detach(i64 ${v})`); }
        return 0;
    }

    genStmt(s: Stmt): i64 {
        return match (s) {
            LetStmt l => this.genLet(l),
            AssignStmt a => this.genAssign(a),
            ReturnStmt r => this.genReturn(r),
            IfStmt f => this.genIf(f),
            WhileStmt w => this.genWhile(w),
            ForOfStmt fo => this.genForOf(fo),
            ForStmt fr => this.genFor(fr),
            BreakStmt b => this.genBreak(),
            ContinueStmt c => this.genContinue(),
            ExprStmt e => this.genExprStmt(e),
            FailStmt fs => this.genFail(fs),
            DeferStmt d => this.genDefer(d),
            _ => 0
        };
    }

    // spawn de uma chamada f(args): copia os args num struct no heap (malloc),
    // cria a thread via pthread_create e devolve o handle (pthread_t como i64).
    // Registra o thunk de `f` (emitido no fim do módulo).
    // registra o thunk de `sym` (com sua aridade) — emitido no fim do módulo.
    needThunk(sym: string, arity: i64) {
        if (idxOf(this.thunkNames, sym) >= 0) { return; }
        this.thunkNames.push(sym);
        this.thunkArity.push(arity);
    }
    // copia as células dos args num struct do heap e cria a thread; devolve o
    // handle (pthread_t como i64). `sym` é a função-alvo já resolvida (uma função
    // de topo, ou `Dono.metodo` — nesse caso `cells[0]` é o `this`).
    spawnSym(sym: string, cells: string[]): string {
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        let argp: string = "null";
        if (cells.len() > 0) {
            const argi: string = this.rtCall("malloc", [str(cells.len() * 8)]);
            const p: string = this.newTmp();
            this.emit(`  ${p} = inttoptr i64 ${argi} to ptr`);
            let i: i64 = 0;
            for (const cv of cells) {
                const fp: string = this.newTmp();
                this.emit(`  ${fp} = getelementptr i64, ptr ${p}, i64 ${i}`);
                this.emit(`  store i64 ${cv}, ptr ${fp}`);
                i = i + 1;
            }
            argp = p;
        }
        this.needThunk(sym, cells.len());
        const ts: string = `%tid${id}.addr`;
        this.emit(`  ${ts} = alloca i64`);
        this.emit(`  call i32 @pthread_create(ptr ${ts}, ptr null, ptr @__lex_thunk_${sym}, ptr ${argp})`);
        const tid: string = this.newTmp();
        this.emit(`  ${tid} = load i64, ptr ${ts}`);
        return tid;
    }
    // spawn f(args) — função de topo
    spawnCall(c: Call): string {
        const ptypes: string[] = this.sema.funcParamTypes(c.name);
        let cells: string[] = [];
        let i: i64 = 0;
        for (const a of c.args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            cells.push(this.boxArg(a, pt));
            i = i + 1;
        }
        return this.spawnSym(c.name, cells);
    }
    // spawn obj.metodo(args) — o alvo é @Dono.metodo e o `this` entra como arg0.
    spawnMethod(m: MethodCall): string {
        const bt: string = this.sema.typeOf(m.base, this.scope);
        const owner: string = this.sema.classes.methodOwner(bt, m.method);
        if (strEq(owner, "")) { return "0"; }
        const bv: string = this.genExpr(m.base);
        const ptypes: string[] = this.sema.methodParamTypes(bt, m.method);
        let cells: string[] = [bv];
        let i: i64 = 0;
        for (const a of m.args) {
            let pt: string = "";
            if (i < ptypes.len()) { pt = ptypes[i]; }
            cells.push(this.boxArg(a, pt));
            i = i + 1;
        }
        return this.spawnSym(concat(owner, concat(".", m.method)), cells);
    }
    // spawn f(args) / spawn obj.m(args) — devolve o HANDLE. NÃO faz detach aqui:
    // `join(spawn ...)` / `await` precisam do handle vivo. O detach (fire-and-forget)
    // acontece só quando o spawn é um STATEMENT — ver genExprStmt.
    genSpawnExpr(s: SpawnExpr): string {
        return match (s.call) {
            Call c => this.spawnCall(c),
            MethodCall mc => this.spawnMethod(mc),
            _ => "0"
        };
    }
    // await fut: pthread_join no handle; o resultado volta disfarçado de ponteiro.
    genAwait(a: AwaitExpr): string { return this.joinCell(this.genExpr(a.inner)); }
    // pthread_join num handle: o resultado volta disfarçado de ponteiro.
    joinCell(h: string): string {
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const slot: string = `%join${id}.addr`;
        this.emit(`  ${slot} = alloca ptr`);
        this.emit(`  call i32 @pthread_join(i64 ${h}, ptr ${slot})`);
        const raw: string = this.newTmp();
        this.emit(`  ${raw} = load ptr, ptr ${slot}`);
        const r: string = this.newTmp();
        this.emit(`  ${r} = ptrtoint ptr ${raw} to i64`);
        return r;
    }
    // thunk de thread p/ `fn`: ptr(ptr) — desempacota os args, chama fn, devolve
    // o resultado como ponteiro (o await desfaz). free no struct (se houver args).
    genThunk(fnName: string, n: i64) {
        this.tmp = 0;
        this.raw(`define ptr @__lex_thunk_${fnName}(ptr %argp) {`);
        this.term = false;
        let argStr: string = "";
        let i: i64 = 0;
        while (i < n) {
            const fp: string = this.newTmp();
            this.emit(`  ${fp} = getelementptr i64, ptr %argp, i64 ${i}`);
            const av: string = this.newTmp();
            this.emit(`  ${av} = load i64, ptr ${fp}`);
            if (i > 0) { argStr = concat(argStr, ", "); }
            argStr = concat(argStr, concat("i64 ", av));
            i = i + 1;
        }
        if (n > 0) {
            const argi: string = this.newTmp();
            this.emit(`  ${argi} = ptrtoint ptr %argp to i64`);
            this.rtCall("free", [argi]);
        }
        const r: string = this.emitCall(fnName, argStr);
        const rp: string = this.newTmp();
        this.emit(`  ${rp} = inttoptr i64 ${r} to ptr`);
        this.emit(`  ret ptr ${rp}`);
        this.term = true;
        this.raw("}");
        this.raw("");
    }

    // capturas declaradas da arrow `name` (vazio se não achar)
    lambdaCaptures(name: string): string[] {
        for (const f of this.lambdaFuncs) {
            if (strEq(f.name, name)) { return f.captures; }
        }
        let empty: string[] = [];
        return empty;
    }
    // arrow como VALOR → uma CLOSURE: bloco no heap com o ponteiro da função no
    // slot 0 e uma CÓPIA de cada variável capturada nos slots 1.. (captura POR
    // VALOR: mudar a original depois não afeta a closure). O `f(x)` indireto lê o
    // ponteiro do slot 0 e passa o próprio env como 1º argumento.
    genClosure(lm: Lambda): string {
        const caps: string[] = this.lambdaCaptures(lm.fnName);
        const n: i64 = caps.len() + 1;
        const env: string = this.rtCall("__lex_heap_alloc", [str(n * 8)]);
        const p: string = this.newTmp();
        this.emit(`  ${p} = inttoptr i64 ${env} to ptr`);
        this.emit(`  store i64 ptrtoint (ptr @${lm.fnName} to i64), ptr ${p}`);
        let i: i64 = 0;
        for (const c of caps) {
            const v: string = this.genLoad(c);          // valor ATUAL, no escopo de criação
            const ep: string = this.newTmp();
            this.emit(`  ${ep} = getelementptr i64, ptr ${p}, i64 ${i + 1}`);
            this.emit(`  store i64 ${v}, ptr ${ep}`);
            i = i + 1;
        }
        return env;
    }

    // try <call>: avalia; se o callee setou o flag de erro, PROPAGA (retorna da
    // função atual com o flag ainda setado). Senão, o valor é o do callee.
    genTry(t: TryExpr): string {
        const v: string = this.genExpr(t.call);
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const lprop: string = concat("Ltprop", str(id));
        const lok: string = concat("Ltok", str(id));
        const has: string = this.rtCall("__lex_has_err", []);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${has}, 0`);
        this.emit(`  br i1 ${cb}, label %${lprop}, label %${lok}`);
        this.term = true;
        this.label(lprop);
        this.emitReturnVal("0");          // propaga (flag segue setado pro chamador)
        this.label(lok);
        return v;
    }
    // <lhs> catch <handler>: se lhs falhou, LIMPA o erro e usa handler; senão lhs.
    genCatch(c: CatchExpr): string {
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const ra: string = `%catch${id}.addr`;
        this.emit(`  ${ra} = alloca i64`);
        const v: string = this.genExpr(c.lhs);
        this.emit(`  store i64 ${v}, ptr ${ra}`);
        const lcatch: string = concat("Lcatch", str(id));
        const lok: string = concat("Lcok", str(id));
        const has: string = this.rtCall("__lex_has_err", []);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = icmp ne i64 ${has}, 0`);
        this.emit(`  br i1 ${cb}, label %${lcatch}, label %${lok}`);
        this.term = true;
        this.label(lcatch);
        this.rtCall("__lex_take_err", []);   // consome/limpa o erro
        // `catch { … }`: roda os statements. Se o bloco desviar (return/fail),
        // `emit` já vira no-op daí em diante e o `br` abaixo não sai — LLVM
        // aceita um terminador só por bloco.
        if (c.isBlock) {
            this.genStmts(c.body);
            this.emit(`  store i64 0, ptr ${ra}`);   // bloco que cai fora: vale 0
        } else {
            const h: string = this.genExpr(c.handler);
            this.emit(`  store i64 ${h}, ptr ${ra}`);
        }
        this.emit(`  br label %${lok}`);
        this.term = true;
        this.label(lok);
        const r: string = this.newTmp();
        this.emit(`  ${r} = load i64, ptr ${ra}`);
        return r;
    }

    // match (subj) { Classe bind => corpo, _ => corpo } como EXPRESSÃO.
    // Carrega a tag (slot 0 do objeto) e compara com a tag de cada classe; o
    // resultado do braço que casar vai p/ um alloca, lido no fim (sem phi).
    // condição estrutural de um braço (i1): tag de classe, literal int/string ou faixa.
    matchCond(arm: MatchArm, subj: string, tag: string): string {
        if (arm.kind == 0) {                                  // tag de classe
            const at: i64 = this.sema.classes.indexOfDecl(arm.pat);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp eq i64 ${tag}, ${at}`);
            return cb;
        }
        if (arm.kind == 1) {                                  // literal int
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp eq i64 ${subj}, ${arm.lo}`);
            return cb;
        }
        if (arm.kind == 2) {                                  // literal string
            const sp: string = this.genStrLit(arm.pat);
            const eq: string = this.rtCall("__lex_str_eq", [subj, sp]);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp ne i64 ${eq}, 0`);
            return cb;
        }
        if (arm.kind == 5) {                                  // variante de enum
            const ev: i64 = this.sema.enums.value(arm.pat, arm.bind);
            const cb: string = this.newTmp();
            this.emit(`  ${cb} = icmp eq i64 ${subj}, ${ev}`);
            return cb;
        }
        const ge: string = this.newTmp();                     // faixa [lo, hi)
        this.emit(`  ${ge} = icmp sge i64 ${subj}, ${arm.lo}`);
        const lt: string = this.newTmp();
        this.emit(`  ${lt} = icmp slt i64 ${subj}, ${arm.hi}`);
        const cb: string = this.newTmp();
        this.emit(`  ${cb} = and i1 ${ge}, ${lt}`);
        return cb;
    }
    // braço com literal/faixa e/ou guarda. (Os casos tag-de-classe e curinga SEM
    // guarda ficam no caminho antigo do genMatch, byte-idêntico p/ o bootstrap.)
    // `{x, y} =>` — destructuring. O struct-literal já nasce OBJETO JSON, então cada
    // campo sai por json_get + jsonAsInt. (Campos não-numéricos precisariam dos tipos
    // do `type X = {...}`, que hoje é erasure.)
    genDestructure(arm: MatchArm, subj: string, ra: string, lend: string) {
        const names: string[] = splitCommas(arm.pat);
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        let nb: i64 = 0;
        for (const nm of names) {
            const kj: string = this.rtCall("__lex_json_get", [subj, this.genStrLit(nm)]);
            const iv: string = this.rtCall("__lex_json_as_int", [kj]);
            const ad: string = `%ds${id}_${nb}.addr`;
            this.emit(`  ${ad} = alloca i64`);
            this.emit(`  store i64 ${iv}, ptr ${ad}`);
            this.bindPush(nm, ad, "i64");
            nb = nb + 1;
        }
        const v: string = this.genExpr(arm.body);
        let k: i64 = 0;
        while (k < nb) { this.bindPop(); k = k + 1; }
        this.emit(`  store i64 ${v}, ptr ${ra}`);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
    }

    genMatchArm(arm: MatchArm, subj: string, sa: string, tag: string, ra: string, lend: string) {
        if (arm.kind == 6) { this.genDestructure(arm, subj, ra, lend); return; }
        const lno: string = this.newLabel();
        if (arm.kind != 4) {                     // curinga/binding casa sempre
            const cb: string = this.matchCond(arm, subj, tag);
            const lyes: string = this.newLabel();
            this.emit(`  br i1 ${cb}, label %${lyes}, label %${lno}`);
            this.term = true;
            this.label(lyes);
        }
        let bnd: string = arm.bind;
        if (arm.kind == 5) { bnd = ""; }         // `Color.Red` não liga variável
        this.bindPush(bnd, sa, "?");             // liga ANTES da guarda (`x if x < 10`)
        if (arm.hasGuard) {
            const g: string = this.genExpr(arm.guard);
            const gc: string = this.newTmp();
            this.emit(`  ${gc} = icmp ne i64 ${g}, 0`);
            const lg: string = this.newLabel();
            this.emit(`  br i1 ${gc}, label %${lg}, label %${lno}`);
            this.term = true;
            this.label(lg);
        }
        const v: string = this.genExpr(arm.body);
        this.bindPop();
        this.emit(`  store i64 ${v}, ptr ${ra}`);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
        this.label(lno);
    }

    genMatch(mt: Match): string {
        const subj: string = this.genExpr(mt.subject);
        const id: i64 = this.matchN;
        this.matchN = this.matchN + 1;
        const sa: string = `%msubj${id}.addr`;
        const ra: string = `%mres${id}.addr`;
        this.emit(`  ${sa} = alloca i64`);
        this.emit(`  store i64 ${subj}, ptr ${sa}`);
        this.emit(`  ${ra} = alloca i64`);
        // a tag (slot 0) só existe em OBJETO: carrega só se houver braço de classe.
        // (`match (n)` com n inteiro faria `inttoptr 3; load` → SEGV.)
        let hasClassArm: bool = false;
        for (const arm of mt.arms) { if (arm.kind == 0) { hasClassArm = true; } }
        let tag: string = "";
        if (hasClassArm) {
            const sp: string = this.newTmp();
            this.emit(`  ${sp} = inttoptr i64 ${subj} to ptr`);
            tag = this.newTmp();
            this.emit(`  ${tag} = load i64, ptr ${sp}`);
        }

        const lend: string = this.newLabel();
        for (const arm of mt.arms) {
            if (arm.kind == 4 && !arm.hasGuard) {             // curinga `_` / binding
                this.bindPush(arm.bind, sa, "?");
                const v: string = this.genExpr(arm.body);
                this.bindPop();
                this.emit(`  store i64 ${v}, ptr ${ra}`);
                if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
            } else if (arm.kind == 0 && !arm.hasGuard) {      // tag de classe
                const at: i64 = this.sema.classes.indexOfDecl(arm.pat);
                const cb: string = this.newTmp();
                this.emit(`  ${cb} = icmp eq i64 ${tag}, ${at}`);
                const lyes: string = this.newLabel();
                const lno: string = this.newLabel();
                this.emit(`  br i1 ${cb}, label %${lyes}, label %${lno}`);
                this.term = true;
                this.label(lyes);
                this.bindPush(arm.bind, sa, arm.pat);
                const v: string = this.genExpr(arm.body);
                this.bindPop();
                this.emit(`  store i64 ${v}, ptr ${ra}`);
                if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
                this.label(lno);
            } else {                                          // literal/faixa/guarda
                this.genMatchArm(arm, subj, sa, tag, ra, lend);
            }
        }
        // nenhum braço casou (sem curinga): resultado 0
        this.emit(`  store i64 0, ptr ${ra}`);
        if (!this.term) { this.emit(`  br label %${lend}`); this.term = true; }
        this.label(lend);
        const res: string = this.newTmp();
        this.emit(`  ${res} = load i64, ptr ${ra}`);
        return res;
    }

    // emite, no bloco entry, um slot de alloca por sítio de curto-circuito (&&/||)
    // do corpo — e zera o índice. genAndOr consome esses slots em ordem.
    emitScSlots(body: Stmt[]) {
        this.scN = 0;
        const nsc: i64 = scCountStmts(body);
        let si: i64 = 0;
        while (si < nsc) { this.emit(`  %sc${si}.addr = alloca i64`); si = si + 1; }
    }

    // método de classe: como genFunc, mas com `this` como 1º parâmetro.
    genMethod(cls: string, f: Func): i64 {
        this.tmp = 0;
        this.lbl = 0;
        this.term = false;
        this.curMain = false;
        this.curRet = f.ret;
        this.curCaptures = [];
        this.curClass = cls;         // p/ resolver super(...) ao pai
        this.curDefers = [];
        this.scope = new Scope();
        this.scope.set("this", cls);
        for (const p of f.params) { this.scope.set(p.name, p.ty); }

        let ps: string = "i64 %this";
        for (const p of f.params) { ps = concat(ps, concat(", i64 %", p.name)); }
        this.raw(`define i64 @${cls}.${f.name}(${ps}) {`);
        this.term = false;   // 1º bloco implícito
        let locals: string[] = [];
        addUniq(locals, "this");
        for (const p of f.params) { addUniq(locals, p.name); }
        collectLocals(f.body, locals);
        this.curLocals = locals;       // método nunca é main: tudo é local
        for (const lnm of this.curLocals) { this.emit(`  %${lnm}.addr = alloca i64`); }
        this.emitScSlots(f.body);
        this.emit(`  store i64 %this, ptr %this.addr`);
        for (const p of f.params) {
            this.emit(`  store i64 %${p.name}, ptr %${p.name}.addr`);
        }
        this.genStmts(f.body);
        if (!this.term) { this.emit("  ret i64 0"); this.term = true; }
        this.raw("}");
        this.raw("");
        return 0;
    }

    genFunc(f: Func): i64 {
        this.tmp = 0;
        this.lbl = 0;
        this.term = false;
        this.curMain = strEq(f.name, "main");
        this.curRet = f.ret;
        this.curClass = "";          // função livre: fora de classe
        this.curDefers = [];
        this.scope = new Scope();
        // arrow: o 1º parâmetro é o ENV da closure, e as capturas são lidas dele
        const isLam: bool = isLambdaName(f.name);
        if (isLam) { this.curCaptures = f.captures; } else { this.curCaptures = []; }
        // `this` capturado: sem o tipo, um `this.campo` dentro da arrow não acharia
        // o slot do campo. O parser anota a classe onde a arrow foi escrita.
        if (isLam && !strEq(f.ownerClass, "")) { this.scope.set("this", f.ownerClass); }
        for (const p of f.params) { this.scope.set(p.name, p.ty); }

        let ps: string = "";
        let first: bool = true;
        if (isLam) { ps = "i64 %__env"; first = false; }
        for (const p of f.params) {
            if (!first) { ps = concat(ps, ", "); }
            ps = concat(ps, concat("i64 %", p.name));
            first = false;
        }
        let retTy: string = "i64";
        if (this.curMain) { retTy = "i32"; }

        this.raw(`define ${retTy} @${f.name}(${ps}) {`);
        this.term = false;   // 1º bloco é implícito (não rotular: 'entry' colidiria c/ params)

        // hoista uma alloca por nome de local (params + lets + for-of) no entry.
        // No `main`, os const/let de TOPO são globais promovidos (gget/gset) → fora
        // dos allocas; fora do main tudo é local (e sombreia qualquer global).
        let locals: string[] = [];
        for (const p of f.params) { addUniq(locals, p.name); }
        collectLocals(f.body, locals);
        // main e lambdas: globais promovidos ficam fora dos allocas (são gget/gset);
        // funções normais: tudo é local (param/local sombreia qualquer global homônimo).
        this.curLocals = without(locals, this.curCaptures);   // capturas vêm do env
        // No main, um `const` de TOPO não pode virar alloca: ele é slot global
        // (gget/gset), e uma alloca homônima o sombrearia — o main escreveria na
        // pilha e as demais funções leriam o slot, sempre zerado.
        if (this.curMain) { this.curLocals = without(this.curLocals, this.globalNames); }
        for (const lnm of this.curLocals) { this.emit(`  %${lnm}.addr = alloca i64`); }
        this.emitScSlots(f.body);
        for (const p of f.params) {
            this.emit(`  store i64 %${p.name}, ptr %${p.name}.addr`);
        }

        // campos static são inicializados UMA vez, no topo do main (o init pode ser
        // uma expressão qualquer — `static base: i64 = 10 * 4 + 2`).
        if (this.curMain) {
            for (const c of this.staticClasses) {
                let si: i64 = 0;
                while (si < c.statics.len()) {
                    const key: string = concat(c.name, concat(".", c.statics[si].name));
                    const iv: string = this.boxArg(c.staticInits[si], c.statics[si].ty);
                    this.rtCall("__lex_gset", [str(this.slotOfGlobal(key)), iv]);
                    si = si + 1;
                }
            }
        }
        this.genStmts(f.body);

        if (!this.term) { this.emitReturnVal("0"); }   // fall-through (roda defers)
        this.raw("}");
        this.raw("");
        return 0;
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TOOL FUNCTION JSON SCHEMA GENERATION
    // ══════════════════════════════════════════════════════════════════════════════

    /// Converte tipo Lex para tipo JSON Schema
    lexTypeToJsonType(ty: string): string {
        if (strEq(ty, "i64") || strEq(ty, "i32") || strEq(ty, "i16") || strEq(ty, "i8")) {
            return "integer";
        }
        if (strEq(ty, "f64") || strEq(ty, "f32")) {
            return "number";
        }
        if (strEq(ty, "bool")) {
            return "boolean";
        }
        if (strEq(ty, "string")) {
            return "string";
        }
        if (isArrayTy(ty)) {
            return "array";
        }
        // default: objeto ou tipo complexo
        return "object";
    }

    /// Gera o JSON Schema para uma tool function como string literal
    genToolSchemaStr(f: Func): string {
        // Montar o schema de parâmetros
        let props: string = "";
        let required: string = "";
        let firstProp: bool = true;
        let firstReq: bool = true;

        for (const p of f.params) {
            if (!firstProp) { props = concat(props, ","); }
            firstProp = false;

            const jsonType: string = this.lexTypeToJsonType(p.ty);
            const desc: string = p.description;
            if (strEq(desc, "")) {
                props = concat(props, `"${p.name}":{"type":"${jsonType}"}`);
            } else {
                props = concat(props, `"${p.name}":{"type":"${jsonType}","description":"${desc}"}`);
            }

            // Todos os parâmetros são required por padrão (sem defaults = obrigatório)
            if (!firstReq) { required = concat(required, ","); }
            firstReq = false;
            required = concat(required, `"${p.name}"`);
        }

        // Descrição da tool
        const desc: string = f.toolDesc;

        // Montar o schema completo
        let schema: string = `{"name":"${f.name}"`;
        if (!strEq(desc, "")) {
            schema = concat(schema, `,"description":"${desc}"`);
        }
        schema = concat(schema, `,"input_schema":{"type":"object","properties":{${props}},"required":[${required}]}}`);

        return schema;
    }

    /// Gera uma função que retorna o JSON Schema da tool
    genToolSchemaFunc(f: Func) {
        const schemaStr: string = this.genToolSchemaStr(f);
        const funcName: string = concat("__tool_schema_", f.name);

        // Registrar a string literal
        const strIdx: string = this.genStrLit(schemaStr);

        // Gerar função que retorna a string
        this.raw(`define i64 @${funcName}() {`);
        this.raw(`  ret i64 ${strIdx}`);
        this.raw("}");
        this.raw("");
    }

    /// Gera a função __tool_list que retorna um array com os nomes das tools
    genToolRegistry() {
        if (this.toolFuncs.len() == 0) { return; }

        // Gerar array de nomes
        let names: string = "";
        let first: bool = true;
        for (const f of this.toolFuncs) {
            if (!first) { names = concat(names, ","); }
            first = false;
            names = concat(names, `"${f.name}"`);
        }
        const listStr: string = concat(concat("[", names), "]");
        const strIdx: string = this.genStrLit(listStr);

        this.raw("define i64 @__tool_list() {");
        this.raw(`  ret i64 ${strIdx}`);
        this.raw("}");
        this.raw("");

        // Gerar função __tool_count que retorna o número de tools
        this.raw("define i64 @__tool_count() {");
        this.raw(`  ret i64 ${str(this.toolFuncs.len())}`);
        this.raw("}");
        this.raw("");
    }

    genProgram(prog: Program): i64 {
        // const/let de topo (do main) E os DIRETOS de cada lambda viram globais
        // promovidos (gget/gset) — assim arrows os capturam (sem closure/env),
        // inclusive captura aninhada. Definido ANTES de gerar funcs/lambdas/main.
        this.staticClasses = prog.classes;
        // Nomes de TOPO (não são capturáveis: funções, classes, enums, prelúdio).
        let topNames: string[] = [];
        addUniq(topNames, "Terminal");
        for (const fl of prog.funcs) { addUniq(topNames, fl.name); }
        for (const c of prog.classes) { addUniq(topNames, c.name); }
        for (const en of prog.enums) { addUniq(topNames, en.name); }
        // Capturas de cada arrow = nomes USADOS no corpo, menos os que ela mesma
        // liga (params + locais) e os de topo. Capturados POR VALOR no env.
        for (const fl of prog.funcs) {
            if (isLambdaName(fl.name)) {
                this.lambdaFuncs.push(fl);
                let used: string[] = [];
                usedInStmts(fl.body, used);
                let bound: string[] = [];
                for (const p of fl.params) { addUniq(bound, p.name); }
                collectLocals(fl.body, bound);
                // uma arrow ANINHADA aparece em `used` pelo NOME: o que ELA captura
                // também é livre AQUI (a externa precisa carregar o valor p/ montar o
                // env da interna). As internas são içadas ANTES, então já têm captures.
                let expanded: string[] = [];
                for (const u of used) {
                    if (isLambdaName(u)) {
                        for (const ic of this.lambdaCaptures(u)) { addUniq(expanded, ic); }
                    } else { addUniq(expanded, u); }
                }
                let caps: string[] = [];
                for (const u of expanded) {
                    if (idxOf(bound, u) < 0 && idxOf(topNames, u) < 0) { addUniq(caps, u); }
                }
                fl.captures = caps;
            }
            if (fl.isAsync) { addUniq(this.asyncNames, fl.name); }   // chamada → spawn
        }
        this.globalNames = [];   // a captura de lambda é por env, não por global
        // campos `static`: um SLOT GLOBAL por campo, na classe que o DECLARA.
        for (const c of prog.classes) {
            for (const sf of c.statics) { addUniq(this.globalNames, concat(c.name, concat(".", sf.name))); }
        }
        // `const`/`let` de TOPO também são slots globais. Sem isto eles viravam
        // locais do main, e uma FUNÇÃO que os lesse não achava símbolo nenhum:
        // o clang acusava "use of undefined value '%PORT.addr'", que não diz
        // nada sobre o que houve. Só os de topo — um `const` dentro de um bloco
        // continua local.
        for (const s of prog.main) {
            match (s) { LetStmt gl => addUniq(this.globalNames, gl.name), _ => 0 };
        }
        // A tabela de slots do runtime é fixa (LEX_NGLOBAL), e um índice fora
        // dela é ignorado em SILÊNCIO — a leitura devolveria 0 e o programa
        // rodaria com o valor errado. Melhor recusar.
        if (this.globalNames.len() > 254) {
            Terminal.log(`erro: ${this.globalNames.len()} globais (const/let de topo + campos static); o maximo e 254`);
        }
        // preâmbulo. As declarações do runtime saem da TABELA DE ABI (rtAbi): tipos
        // certos p/ ponteiro e void — é o que faz o mesmo .ll servir no nativo (ptr
        // = 64 bits) E no wasm32 (ptr = 32 bits). Os valores em lex seguem células
        // i64; a conversão acontece só na borda da chamada (ver rtCall).
        // Sem `target triple`/`datalayout`: a IR é AGNÓSTICA de alvo. Ela usa `ptr`
        // opaco e células i64, e quem fixa o alvo é o `clang --target=…` que compila
        // o .ll. O mesmo arquivo serve p/ nativo, wasm32, linux e windows.
        this.raw("@.lex_fmt_int = private unnamed_addr constant [6 x i8] c\"%lld\\0A\\00\"");
        this.raw("@.lex_fmt_str = private unnamed_addr constant [4 x i8] c\"%s\\0A\\00\"");
        this.raw("declare i32 @printf(ptr, ...)");
        for (const sym of rtSymbols()) { this.raw(this.rtDecl(sym)); }
        // símbolos EXTERNOS (`declare function` — libc, SO). Tudo trafega em célula
        // i64: no ABI de 64 bits um ponteiro e um inteiro vão no mesmo registrador.
        for (const e of prog.externs) {
            // já declarado pela tabela de ABI (ex.: `malloc`)? não redeclarar.
            if (strEq(rtAbi(e.name), "")) {
                let ps: string = "";
                let i: i64 = 0;
                while (i < e.params.len()) {
                    if (i > 0) { ps = concat(ps, ", "); }
                    ps = concat(ps, "i64");
                    i = i + 1;
                }
                let rt: string = "i64";
                if (strEq(e.ret, "void")) { rt = "void"; }
                this.raw(`declare ${rt} @${e.name}(${ps})`);
            }
        }
        // threads (só nativo; no wasm o spawn precisaria do host)
        this.raw("declare i32 @pthread_create(ptr, ptr, ptr, ptr)");
        this.raw("declare i32 @pthread_join(i64, ptr)");
        this.raw("declare i32 @pthread_detach(i64)");
        this.raw("");
        // métodos de classe (dispatch estático): @Classe.metodo(i64 %this, …)
        for (const c of prog.classes) {
            for (const mm of c.methods) { this.genMethod(c.name, mm); }
        }
        // Os DOIS podem coexistir: um `const` de módulo ao lado de um `fn main`
        // explícito. Nesse caso os statements de topo são o INICIALIZADOR do
        // módulo e rodam ANTES do corpo do main — é o que dá valor aos slots
        // globais. Antes daqui o programa saía com dois `@main` na mesma IR.
        let mainIdx: i64 = 0 - 1;
        let mi: i64 = 0;
        while (mi < prog.funcs.len()) {
            if (strEq(prog.funcs[mi].name, "main")) { mainIdx = mi; }
            mi = mi + 1;
        }
        if (mainIdx >= 0 && prog.main.len() > 0) {
            let fundido: Stmt[] = [];
            for (const s of prog.main) { fundido.push(s); }
            for (const s of prog.funcs[mainIdx].body) { fundido.push(s); }
            prog.funcs[mainIdx].body = fundido;
            let vazio: Stmt[] = [];
            prog.main = vazio;
        }
        for (const f of prog.funcs) {
            this.genFunc(f);
            // Coletar funções marcadas como tool
            if (f.isTool) { this.toolFuncs.push(f); }
        }
        // script-mode: statements de topo viram o `main` (i32), quando não há
        // um `fn main` explícito (o caso misto já foi fundido acima).
        if (prog.main.len() > 0) {
            let pp: Param[] = [];
            const mainFn: Func = new Func("main", pp, "i32", false, prog.main);
            this.genFunc(mainFn);
        }
        // gerar JSON Schema para cada tool function
        for (const tf of this.toolFuncs) { this.genToolSchemaFunc(tf); }
        this.genToolRegistry();
        // thunks de thread (1 por função spawnada/async) — depois que tudo existe.
        let ti: i64 = 0;
        while (ti < this.thunkNames.len()) {
            this.genThunk(this.thunkNames[ti], this.thunkArity[ti]);
            ti = ti + 1;
        }
        for (const fv of this.fnValNames) { this.genFnValWrapper(fv); }
        // globais de string literais (ordem livre no módulo → no fim)
        for (const g of this.strs) { this.raw(g); }
        return 0;
    }
}

// Program já parseado → texto do LLVM IR. `target`: 0 = nativo, 1 = wasm32.
fn compileProgramToIRT(prog: Program, target: i64): string {
    const sema: Sema = new Sema(prog);
    const cg: Codegen = new Codegen(sema);
    cg.target = target;
    cg.genProgram(prog);
    return cg.outParts.join("");   // junta toda a IR de uma vez (StrBuf O(n))
}
fn compileProgramToIR(prog: Program): string { return compileProgramToIRT(prog, 0); }

// Conveniência: fonte lex (um módulo) → texto do LLVM IR.
fn compileToIR(src: string): string {
    const p: Parser = new Parser(lexSrc(src));
    return compileProgramToIR(p.parseModule());
}
