// diag.lex — diagnósticos estilo rustc em lex (Fase F6.11), espelha src/diag.rs.
// Renderiza um span (índices de byte no fonte) como uma mensagem de erro com
// cabeçalho, `--> arquivo:linha:coluna`, gutter `|`, o trecho da linha e `^^^`
// sob o ponto do erro (com expansão de tab p/ alinhar). Sem cor (o caminho
// não-TTY do diag.rs) — assim a saída é determinística e testável. `hint` vazio
// = sem linha de ajuda. Índices/colunas são por BYTE (correto p/ ASCII).

fn repeatStr(unit: string, k: i64): string {
    let s: string = "";
    let i: i64 = 0;
    while (i < k) { s = concat(s, unit); i = i + 1; }
    return s;
}

fn renderDiag(name: string, text: string, startIn: i64, end: i64, msg: string, hint: string): string {
    const n: i64 = len(text);
    let start: i64 = startIn;
    if (start > n) { start = n; }

    // linha/coluna (1-based) + início da linha do erro
    let line: i64 = 1;
    let col: i64 = 1;
    let lineStart: i64 = 0;
    let i: i64 = 0;
    while (i < start) {
        if (peek8(text, i) == 10) { line = line + 1; col = 1; lineStart = i + 1; }
        else { col = col + 1; }
        i = i + 1;
    }
    // fim da linha (próximo '\n' ou EOF)
    let lineEnd: i64 = n;
    let k: i64 = lineStart;
    while (k < n) { if (peek8(text, k) == 10) { lineEnd = k; break; } k = k + 1; }

    // sublinhado contido na linha; ao menos 1 char
    let spanLen: i64 = end - start;
    const lim: i64 = lineEnd - start;
    if (spanLen > lim) { spanLen = lim; }
    if (spanLen < 1) { spanLen = 1; }

    // expande tabs p/ o caret alinhar com o texto impresso
    let rendered: string = "";
    let caretPad: i64 = 0;
    let caretLen: i64 = 0;
    let off: i64 = 0;
    const lineLen: i64 = lineEnd - lineStart;
    while (off < lineLen) {
        const ch: i64 = peek8(text, lineStart + off);
        let w: i64 = 1;
        if (ch == 9) { w = 4; }
        if (off < col - 1) { caretPad = caretPad + w; }
        else if (off < col - 1 + spanLen) { caretLen = caretLen + w; }
        if (ch == 9) { rendered = concat(rendered, "    "); }
        else { rendered = concat(rendered, charAt(text, lineStart + off)); }
        off = off + 1;
    }
    if (caretLen < 1) { caretLen = 1; }

    const lns: string = str(line);
    const pad: string = repeatStr(" ", len(lns));

    let out: string = `error: ${msg}\n`;
    out = concat(out, `${pad}--> ${name}:${line}:${col}\n`);
    out = concat(out, `${pad} |\n`);
    out = concat(out, `${lns} | ${rendered}\n`);
    out = concat(out, `${pad} | ${repeatStr(" ", caretPad)}${repeatStr("^", caretLen)}\n`);
    if (!strEq(hint, "")) {
        out = concat(out, `${pad} |\n`);
        out = concat(out, `${pad} = help: ${hint}\n`);
    }
    return out;
}
