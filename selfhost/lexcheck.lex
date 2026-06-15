// lexcheck.lex — `lex check --json` self-hostado (Fase E, slice). Espelha o
// `lex check --json` do Rust no formato de saída (array JSON de diagnósticos
// com line/col 0-based), pra que o `lexlsp` deixe de depender do Rust.
//
//   lexcheck <arquivo.lex>
//
// Por ora detecta VARIÁVEL INDEFINIDA (o caso do smoke do LSP). Resolve imports
// (modloader) pra não acusar nomes de outros módulos. Sai 1 se houver diagnóstico.
import { loadProgram } from "./modloader"
import { Program } from "./parser"
import { checkProgram, Diag } from "./sema"
import { jEscape } from "./json"

// offset de byte → {line, col} 0-based no fonte.
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

const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lexcheck <arquivo.lex>");
    return 1;
}
const path: string = av[1];
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
out = concat(out, "]");
Terminal.log(out);

if (diags.len() > 0) { return 1; }
return 0;
