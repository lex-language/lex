// checker.lex — núcleo do `lex check` (MÓDULO, só declarações). Detecta erros de
// SINTAXE (parser acumula com posição) e VARIÁVEL INDEFINIDA, e imprime o array
// JSON de diagnósticos no formato do `lex check --json` (line/col 0-based).
import { lexSrc } from "../compiler/lexer"
import { Parser, Program } from "../compiler/parser"
import { loadProgram, parseSource } from "../compiler/modloader"
import { checkProgram, Diag } from "../compiler/sema"
import { typeCheck } from "../compiler/typecheck"
import { jEscape } from "./json"

// offset de byte → objeto JSON {line, col, endLine, endCol, message} (0-based).
fn posJson(src: string, pos: i64, span: i64, msg: string): string {
    let line: i64 = 0;
    let lineStart: i64 = 0;
    let i: i64 = 0;
    const n: i64 = len(src);
    while (i < pos && i < n) {
        if (peek8(src, i) == 10) { line = line + 1; lineStart = i + 1; }
        i = i + 1;
    }
    const col: i64 = pos - lineStart;
    const endCol: i64 = col + span;
    return `{"line":${line},"col":${col},"endLine":${line},"endCol":${endCol},"message":"${jEscape(msg)}"}`;
}
fn diagJson(src: string, d: Diag): string {
    return posJson(src, d.pos, d.span, d.msg);
}

// checa `path` e DEVOLVE o array JSON de diagnósticos (não imprime).
// O LSP precisa da string: ele fala JSON-RPC pelo stdout, então qualquer print
// solto corromperia o protocolo.
//
// Sintaxe primeiro (parse do arquivo); se limpo, variável indefinida + tipos (no
// programa MESCLADO, p/ resolver os imports e não acusar nomes de outros módulos).
fn checkJson(path: string): string {
    const src: string = readFile(path);
    const p: Parser = parseSource(path, src);   // .lex ou .lsx, conforme a extensão

    if (p.errs.len() > 0) {
        let out: string = "[";
        let i: i64 = 0;
        while (i < p.errs.len()) {
            if (i > 0) { out = concat(out, ","); }
            out = concat(out, posJson(src, p.errPos[i], 1, concat("syntax error: ", p.errs[i])));
            i = i + 1;
        }
        return concat(out, "]");
    }

    const prog: Program = loadProgram(path);
    let diags: Diag[] = checkProgram(prog);               // variável indefinida
    for (const d of typeCheck(prog)) { diags.push(d); }   // tipos/aridade/campo/const
    let out: string = "[";
    let first: bool = true;
    for (const d of diags) {
        if (!first) { out = concat(out, ","); }
        out = concat(out, diagJson(src, d));
        first = false;
    }
    return concat(out, "]");
}

// `lex check`: imprime o JSON e devolve 1 se houver diagnóstico (0 = limpo).
fn runCheck(path: string): i64 {
    const js: string = checkJson(path);
    Terminal.log(js);
    if (strEq(js, "[]")) { return 0; }
    return 1;
}
