// fmt.lex — formatador do lex, escrito em lex (Fase F6.7). Espelha src/fmt.rs.
//
// Estratégia conservadora e SEGURA: só normaliza a indentação (por profundidade
// de {}/[]/()), remove espaço em branco no fim das linhas e colapsa linhas em
// branco. NUNCA reescreve código nem mexe no interior de strings/templates. Como
// o lex usa chaves+quebras (não indentação) pra sintaxe, mudar só o espaço de
// indentação não altera a tokenização → não muda a semântica. Único cuidado: o
// interior de template literais (` `...` `), onde o espaço É texto, sai intacto.
// Trabalha sobre bytes (ASCII p/ os delimitadores; UTF-8 do conteúdo passa direto).

// estado ao varrer uma linha de código (fora de template)
class LineScan {
    opens: i64
    closes: i64
    leadingCloses: i64       // fechadores ANTES de qualquer conteúdo (puxam p/ a esquerda)
    opensTemplate: bool      // a linha terminou dentro de um template aberto?
    constructor(opens: i64, closes: i64, leadingCloses: i64, opensTemplate: bool) {
        this.opens = opens; this.closes = closes
        this.leadingCloses = leadingCloses; this.opensTemplate = opensTemplate
    }
}

fn isWs(c: i64): bool { return c == 32 || c == 9 || c == 13; }       // espaço/tab/CR

fn trimEnd(s: string): string {
    let e: i64 = len(s);
    while (e > 0 && isWs(peek8(s, e - 1))) { e = e - 1; }
    return substring(s, 0, e);
}
fn trimStart(s: string): string {
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n && (peek8(s, i) == 32 || peek8(s, i) == 9)) { i = i + 1; }
    return substring(s, i, n);
}
fn indentStr(depth: i64): string {
    let s: string = "";
    let i: i64 = 0;
    while (i < depth) { s = concat(s, "    "); i = i + 1; }     // 4 espaços
    return s;
}

// quebra a fonte em linhas (split em '\n', descartando o '\n' final como .lines()).
fn splitLines(src: string): string[] {
    let lines: string[] = [];
    const n: i64 = len(src);
    let start: i64 = 0;
    let i: i64 = 0;
    while (i < n) {
        if (peek8(src, i) == 10) {
            lines.push(substring(src, start, i));
            start = i + 1;
        }
        i = i + 1;
    }
    if (start < n) { lines.push(substring(src, start, n)); }
    return lines;
}

// a crase de fecho aparece nesta linha?
fn templateClosesOn(line: string): bool {
    const n: i64 = len(line);
    let i: i64 = 0;
    while (i < n) { if (peek8(line, i) == 96) { return true; } i = i + 1; }
    return false;
}

// conta delimitadores que afetam a indentação, pulando strings/chars/comentário
// e o interior de templates de uma linha só.
fn scanCodeLine(line: string): LineScan {
    const n: i64 = len(line);
    let i: i64 = 0;
    let opens: i64 = 0;
    let closes: i64 = 0;
    let leadingCloses: i64 = 0;
    let seenContent: bool = false;
    while (i < n) {
        const c: i64 = peek8(line, i);
        if (c == 32 || c == 9) { i = i + 1; }                          // espaço/tab
        else if (c == 47 && i + 1 < n && peek8(line, i + 1) == 47) { break; }  // //
        else if (c == 34 || c == 39) {                                 // " ou '
            seenContent = true;
            const q: i64 = c;
            i = i + 1;
            while (i < n) {
                if (peek8(line, i) == 92) { i = i + 2; }               // \escape
                else if (peek8(line, i) == q) { break; }
                else { i = i + 1; }
            }
            i = i + 1;                                                  // passa a aspa de fecho
        }
        else if (c == 96) {                                            // template `
            seenContent = true;
            i = i + 1;
            let closed: bool = false;
            while (i < n) {
                if (peek8(line, i) == 96) { closed = true; }
                if (closed) { break; }
                i = i + 1;
            }
            if (!closed) { return new LineScan(opens, closes, leadingCloses, true); }
            i = i + 1;                                                  // passa a crase de fecho
        }
        else if (c == 123 || c == 91 || c == 40) { opens = opens + 1; seenContent = true; i = i + 1; }   // { [ (
        else if (c == 125 || c == 93 || c == 41) {                     // } ] )
            closes = closes + 1;
            if (!seenContent) { leadingCloses = leadingCloses + 1; }
            i = i + 1;
        }
        else { seenContent = true; i = i + 1; }
    }
    return new LineScan(opens, closes, leadingCloses, false);
}

// formata a fonte inteira. Idempotente.
fn formatSource(src: string): string {
    let out: string[] = [];
    let depth: i64 = 0;
    let inTemplate: bool = false;
    let blankRun: i64 = 0;

    for (const raw of splitLines(src)) {
        if (inTemplate) {
            out.push(raw);                                  // interior de template: intacto
            if (templateClosesOn(raw)) { inTemplate = false; }
        } else {
            const content: string = trimStart(trimEnd(raw));
            if (len(content) == 0) {
                blankRun = blankRun + 1;
                if (blankRun == 1) { out.push(""); }        // colapsa em ≤1 linha em branco
            } else {
                blankRun = 0;
                const scan: LineScan = scanCodeLine(content);
                let thisDepth: i64 = depth - scan.leadingCloses;
                if (thisDepth < 0) { thisDepth = 0; }
                out.push(concat(indentStr(thisDepth), content));
                depth = depth + scan.opens - scan.closes;
                if (depth < 0) { depth = 0; }
                if (scan.opensTemplate) { inTemplate = true; }
            }
        }
    }

    // remove linhas em branco do fim
    while (out.len() > 0 && len(out[out.len() - 1]) == 0) { out.pop(); }

    // junta com '\n' (1x, StrBuf O(n)) e garante exatamente uma quebra no fim
    return concat(out.join("\n"), "\n");
}
