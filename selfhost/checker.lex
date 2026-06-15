// checker.lex — núcleo do `lex check` (MÓDULO, só declarações). Resolve imports,
// roda checkProgram (variável indefinida) e imprime o array JSON de diagnósticos
// no formato do `lex check --json` do Rust (line/col 0-based). Devolve 1 se houver.
import { loadProgram } from "./modloader"
import { Program } from "./parser"
import { checkProgram, Diag } from "./sema"
import { jEscape } from "./json"

// offset de byte → {line, col} 0-based no fonte, como objeto JSON.
fn diagJson(src: string, d: Diag): string {
    let line: i64 = 0;
    let lineStart: i64 = 0;
    let i: i64 = 0;
    const n: i64 = len(src);
    while (i < d.pos && i < n) {
        if (peek8(src, i) == 10) { line = line + 1; lineStart = i + 1; }
        i = i + 1;
    }
    const col: i64 = d.pos - lineStart;
    const endCol: i64 = col + d.span;
    return `{"line":${line},"col":${col},"endLine":${line},"endCol":${endCol},"message":"${jEscape(d.msg)}"}`;
}

// checa `path`, imprime o JSON e devolve 1 se houver diagnóstico (0 = limpo).
fn runCheck(path: string): i64 {
    const src: string = readFile(path);
    const prog: Program = loadProgram(path);
    const diags: Diag[] = checkProgram(prog);
    let out: string = "[";
    let first: bool = true;
    for (const d of diags) {
        if (!first) { out = concat(out, ","); }
        out = concat(out, diagJson(src, d));
        first = false;
    }
    Terminal.log(concat(out, "]"));
    if (diags.len() > 0) { return 1; }
    return 0;
}
