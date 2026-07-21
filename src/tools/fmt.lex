// fmt.lex — formatador do lex, escrito em lex (Fase F6.7).
//
// Estratégia conservadora e SEGURA: só normaliza a indentação (por profundidade
// de {}/[]/()), remove espaço em branco no fim das linhas e colapsa linhas em
// branco. NUNCA reescreve código nem mexe no interior de strings/templates. Como
// o lex usa chaves+quebras (não indentação) pra sintaxe, mudar só o espaço de
// indentação não altera a tokenização → não muda a semântica. Único cuidado: o
// interior de template literais (` `...` `) e de literais de markup
// (`return <p>…</p>`), onde o espaço É texto, sai intacto.
// Trabalha sobre bytes (ASCII p/ os delimitadores; UTF-8 do conteúdo passa direto).

// estado ao varrer uma linha de código (fora de template)
class LineScan {
    opens: i64
    closes: i64
    leadingCloses: i64       // fechadores ANTES de qualquer conteúdo (puxam p/ a esquerda)
    opensTemplate: bool      // a linha terminou dentro de um template aberto?
    markup: i64              // profundidade de markup ainda aberta no fim da linha
    constructor(opens: i64, closes: i64, leadingCloses: i64, opensTemplate: bool, markup: i64) {
        this.opens = opens; this.closes = closes
        this.leadingCloses = leadingCloses; this.opensTemplate = opensTemplate
        this.markup = markup
    }
}

fn isWs(c: i64): bool {
    return c == 32 || c == 9 || c == 13;
}       // espaço/tab/CR

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

// posição do '{' que abre o corpo de uma fn e do '}' que o fecha, na MESMA linha.
class FnBody {
    open: i64
    close: i64
    constructor(open: i64, close: i64) { this.open = open; this.close = close; }
}

// pula o literal que começa em `i` (" ' ou `) e devolve o índice logo após ele;
// -1 se o literal não fecha nesta linha.
fn skipLiteral(s: string, i: i64): i64 {
    const n: i64 = len(s);
    const q: i64 = peek8(s, i);
    let j: i64 = i + 1;
    while (j < n) {
        const c: i64 = peek8(s, j);
        if (c == 92) { j = j + 2; }                 // \escape
        else if (c == q) { return j + 1; }
        else { j = j + 1; }
    }
    return -1;
}

// acha o '{' do corpo (fora de string/comentário e fora de parênteses/colchetes)
// e o '}' que o casa. open == -1 quando não existe par completo nesta linha —
// o que inclui fn já quebrada em várias linhas, literal aberto e comentário
// engolindo a chave. Nesses casos a linha sai intacta.
fn findFnBody(line: string): FnBody {
    const n: i64 = len(line);
    let i: i64 = 0;
    let open: i64 = -1;
    let depth: i64 = 0;
    let paren: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(line, i);
        if (c == 47 && i + 1 < n && peek8(line, i + 1) == 47) { return new FnBody(-1, -1); }  // //
        else if (c == 34 || c == 39 || c == 96) {
            const j: i64 = skipLiteral(line, i);
            if (j < 0) { return new FnBody(-1, -1); }
            i = j;
        }
        else if (c == 40 || c == 91) { paren = paren + 1; i = i + 1; }
        else if (c == 41 || c == 93) { paren = paren - 1; i = i + 1; }
        else if (c == 123) {
            if (open < 0) { if (paren == 0) { open = i; depth = 1; } }
            else { depth = depth + 1; }
            i = i + 1;
        }
        else if (c == 125) {
            if (open >= 0) {
                depth = depth - 1;
                if (depth == 0) { return new FnBody(open, i); }
            }
            i = i + 1;
        }
        else { i = i + 1; }
    }
    return new FnBody(-1, -1);
}

// depois de um '}' de nível 0, começa aqui um statement NOVO? Só quando o que
// vem a seguir é uma palavra que não continua o bloco anterior. Isso mantém
// `} else {` e `} catch {` inteiros, e evita cortar antes de `;` `,` `)` — o
// caso de `{}` usado como expressão (`let m: Map = {};`).
fn startsStatement(body: string, at: i64): bool {
    const n: i64 = len(body);
    let i: i64 = at;
    while (i < n && (peek8(body, i) == 32 || peek8(body, i) == 9)) { i = i + 1; }
    if (i >= n) { return false; }
    const c: i64 = peek8(body, i);
    const isAlpha: bool = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95;
    if (!isAlpha) { return false; }
    let e: i64 = i;
    while (e < n) {
        const k: i64 = peek8(body, e);
        if ((k >= 97 && k <= 122) || (k >= 65 && k <= 90) || k == 95) { e = e + 1; }
        else { break; }
    }
    const w: string = substring(body, i, e);
    return !strEq(w, "else") && !strEq(w, "catch");
}

// quebra o corpo em statements: no ';' de nível 0 (o ';' fica no fim do
// statement) e depois do '}' que fecha um bloco de nível 0 (`if (a) { x(); }`
// sem ';'). Ignora ';' dentro de string, de parênteses (`for (;;)`) e de bloco
// aninhado. Um '//' interrompe a quebra: o resto vira uma linha só, pra não
// mover código pra dentro do comentário.
fn splitStmts(body: string): string[] {
    let stmts: string[] = [];
    const n: i64 = len(body);
    let i: i64 = 0;
    let start: i64 = 0;
    let depth: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(body, i);
        if (c == 47 && i + 1 < n && peek8(body, i + 1) == 47) { break; }
        else if (c == 34 || c == 39 || c == 96) {
            const j: i64 = skipLiteral(body, i);
            if (j < 0) { break; }
            i = j;
        }
        else if (c == 123 || c == 40 || c == 91) { depth = depth + 1; i = i + 1; }
        else if (c == 125) {
            depth = depth - 1;
            i = i + 1;
            if (depth == 0 && startsStatement(body, i)) {
                const s: string = trimStart(trimEnd(substring(body, start, i)));
                if (len(s) > 0) { stmts.push(s); }
                start = i;
            }
        }
        else if (c == 41 || c == 93) { depth = depth - 1; i = i + 1; }
        else if (c == 59 && depth == 0) {
            const s: string = trimStart(trimEnd(substring(body, start, i + 1)));
            if (len(s) > 0) { stmts.push(s); }
            i = i + 1;
            start = i;
        }
        else { i = i + 1; }
    }
    const tail: string = trimStart(trimEnd(substring(body, start, n)));
    if (len(tail) > 0) { stmts.push(tail); }
    return stmts;
}

// `fn f(): T { a(); b(); }` → ["fn f(): T {", "a();", "b();", "}"].
// Devolve a linha inalterada (1 elemento) quando não há o que expandir:
// não é fn, já está em várias linhas, ou o corpo é vazio (`fn f() {}`).
fn expandInlineFn(content: string): string[] {
    let outp: string[] = [];
    if (!content.startsWith("fn ")) { outp.push(content); return outp; }
    const b: FnBody = findFnBody(content);
    if (b.open < 0) { outp.push(content); return outp; }
    const stmts: string[] = splitStmts(substring(content, b.open + 1, b.close));
    if (stmts.len() == 0) { outp.push(content); return outp; }
    outp.push(trimEnd(substring(content, 0, b.open + 1)));       // cabeçalho + '{'
    for (const s of stmts) { outp.push(s); }
    outp.push(trimStart(substring(content, b.close, len(content))));   // '}' + o que sobrar
    return outp;
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

// ── literais de markup (JSX) ───────────────────────────────────────────────
// Espelha as regras do lexer, mas linha a linha: o fmt só precisa saber ONDE o
// markup começa e QUANDO fecha, pra deixar o interior intacto.

fn isTagByte(c: i64): bool {
    if (c >= 97 && c <= 122) { return true; }                       // a-z
    if (c >= 65 && c <= 90) { return true; }                        // A-Z
    if (c >= 48 && c <= 57) { return true; }                        // 0-9
    return c == 45 || c == 95;                                      // - _
}

// tags HTML sem fecho — não abrem profundidade (igual ao lexer)
fn isVoidName(s: string): bool {
    if (strEq(s, "meta") || strEq(s, "link") || strEq(s, "br")) { return true; }
    if (strEq(s, "img") || strEq(s, "hr") || strEq(s, "input")) { return true; }
    if (strEq(s, "col") || strEq(s, "base") || strEq(s, "area")) { return true; }
    if (strEq(s, "embed") || strEq(s, "source") || strEq(s, "track")) { return true; }
    if (strEq(s, "param") || strEq(s, "wbr")) { return true; }
    return false;
}

// A palavra logo antes de `i` é `return`? (único caso em que markup começa
// depois de letras — nos demais o byte anterior já decide.)
fn prevWordIsReturn(line: string, i: i64): bool {
    let e: i64 = i;
    while (e > 0 && isWs(peek8(line, e - 1))) { e = e - 1; }
    let s: i64 = e;
    while (s > 0 && isTagByte(peek8(line, s - 1))) { s = s - 1; }
    return strEq(substring(line, s, e), "return");
}

// `<` em `i` abre um literal de markup? Mesma regra do lexer: posição de
// expressão (o que vem antes não pode terminar uma expressão) + nome de tag.
fn markupStartsAt(line: string, i: i64, n: i64): bool {
    if (i + 1 >= n) { return false; }
    const nx: i64 = peek8(line, i + 1);
    const alpha: bool = (nx >= 97 && nx <= 122) || (nx >= 65 && nx <= 90);
    if (!alpha && nx != 33) { return false; }                       // nem tag nem <!doctype
    let p: i64 = i;
    while (p > 0 && isWs(peek8(line, p - 1))) { p = p - 1; }
    if (p == 0) { return false; }                                   // `<` no início: comparação
    const b: i64 = peek8(line, p - 1);
    if (b == 61 || b == 40 || b == 44 || b == 58) { return true; }  // = ( , :
    if (b == 59 || b == 123 || b == 91) { return true; }            // ; { [
    return prevWordIsReturn(line, i);
}

// Varre markup a partir de `i0` até o literal fechar ou a linha acabar.
// Devolve o índice do primeiro byte APÓS o literal. `dep[0]` entra e sai com a
// profundidade; `dep[1]` sai 1 se o literal ACABOU aqui, 0 se continua na linha
// seguinte. Os dois são independentes: `return <p>x</p>` e `return <!doctype h>`
// terminam a linha com profundidade 0 e mesmo assim continuam — só um texto
// solto fora de tag (o `;`, por exemplo) encerra de fato.
fn scanMarkupOn(line: string, i0: i64, n: i64, dep: i64[]): i64 {
    let depth: i64 = dep[0];
    let i: i64 = i0;
    dep[1] = 0;
    while (i < n) {
        const c: i64 = peek8(line, i);
        if (c == 36 && i + 1 < n && peek8(line, i + 1) == 123) {     // ${ … } de uma linha
            i = i + 2;
            let d: i64 = 1;
            while (i < n && d > 0) {
                const e: i64 = peek8(line, i);
                if (e == 123) { d = d + 1; }
                else if (e == 125) { d = d - 1; }
                i = i + 1;
            }
            continue;
        }
        if (c != 60) {                                               // texto solto
            if (depth <= 0 && !isWs(c)) {                            // acabou o literal
                dep[0] = depth;
                dep[1] = 1;
                return i;
            }
            i = i + 1;
            continue;
        }
        let a: i64 = -1;
        if (i + 1 < n) { a = peek8(line, i + 1); }
        if (a == 33 || a == 63) {                                    // <!doctype, <!--, <?
            while (i < n && peek8(line, i) != 62) { i = i + 1; }
            i = i + 1;
            continue;
        }
        let j: i64 = i + 1;
        let closing: bool = false;
        if (a == 47) { closing = true; j = j + 1; }
        const ns: i64 = j;
        while (j < n && isTagByte(peek8(line, j))) { j = j + 1; }
        const name: string = substring(line, ns, j);
        let selfClose: bool = false;
        while (j < n) {
            const d2: i64 = peek8(line, j);
            if (d2 == 34 || d2 == 39) {
                j = j + 1;
                while (j < n && peek8(line, j) != d2) { j = j + 1; }
                j = j + 1;
                continue;
            }
            if (d2 == 62) { break; }
            if (d2 == 47 && j + 1 < n && peek8(line, j + 1) == 62) { selfClose = true; j = j + 1; break; }
            j = j + 1;
        }
        if (len(name) > 0) {
            if (closing) { depth = depth - 1; }
            else if (!selfClose && !isVoidName(name)) { depth = depth + 1; }
        }
        i = j + 1;
        if (depth < 0) {                                             // fecho a mais: para
            dep[0] = 0;
            dep[1] = 1;
            return i;
        }
    }
    dep[0] = depth;                                                  // fim da linha: continua
    return i;
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
            if (!closed) { return new LineScan(opens, closes, leadingCloses, true, -1); }
            i = i + 1;                                                  // passa a crase de fecho
        }
        else if (c == 60 && markupStartsAt(line, i, n)) {              // literal de markup
            seenContent = true;
            let dep: i64[] = [0, 0];
            i = scanMarkupOn(line, i, n, dep);                         // pula o literal
            // não acabou nesta linha: da próxima em diante é texto, sai intacto
            if (dep[1] == 0) { return new LineScan(opens, closes, leadingCloses, false, dep[0]); }
            // acabou aqui: as chaves de CSS/HTML já ficaram de fora da contagem
        }
        else if (c == 123 || c == 91 || c == 40) { opens = opens + 1; seenContent = true; i = i + 1; }   // { [ (
        else if (c == 125 || c == 93 || c == 41) {                     // } ] )
            closes = closes + 1;
            if (!seenContent) { leadingCloses = leadingCloses + 1; }
            i = i + 1;
        }
        else { seenContent = true; i = i + 1; }
    }
    return new LineScan(opens, closes, leadingCloses, false, -1);
}

// formata a fonte inteira. Idempotente.
fn formatSource(src: string): string {
    let out: string[] = [];
    let depth: i64 = 0;
    let inTemplate: bool = false;
    let markup: i64 = -1;                                   // >= 0: markup aberto de linhas atrás
    let blankRun: i64 = 0;

    for (const raw of splitLines(src)) {
        if (markup >= 0) {
            out.push(raw);                                  // interior de markup: intacto
            let dep: i64[] = [markup, 0];
            scanMarkupOn(raw, 0, len(raw), dep);
            if (dep[1] == 1) { markup = -1; } else { markup = dep[0]; }
        } else if (inTemplate) {
            out.push(raw);                                  // interior de template: intacto
            if (templateClosesOn(raw)) { inTemplate = false; }
        } else {
            const content: string = trimStart(trimEnd(raw));
            if (len(content) == 0) {
                blankRun = blankRun + 1;
                if (blankRun == 1) { out.push(""); }        // colapsa em ≤1 linha em branco
            } else {
                blankRun = 0;
                // fn de uma linha vira várias; o resto passa como 1 elemento só
                for (const piece of expandInlineFn(content)) {
                    const scan: LineScan = scanCodeLine(piece);
                    let thisDepth: i64 = depth - scan.leadingCloses;
                    if (thisDepth < 0) { thisDepth = 0; }
                    out.push(concat(indentStr(thisDepth), piece));
                    depth = depth + scan.opens - scan.closes;
                    if (depth < 0) { depth = 0; }
                    if (scan.opensTemplate) { inTemplate = true; }
                    if (scan.markup >= 0) { markup = scan.markup; }
                }
            }
        }
    }

    // remove linhas em branco do fim
    while (out.len() > 0 && len(out[out.len() - 1]) == 0) { out.pop(); }

    // junta com '\n' (1x, StrBuf O(n)) e garante exatamente uma quebra no fim
    return concat(out.join("\n"), "\n");
}

// ── .lsx: formata SÓ o frontmatter ──────────────────────────────────────────
// No corpo de um componente o espaço É conteúdo (é HTML), então reindentá-lo
// mudaria a saída — dentro de um <pre>, visivelmente. Aqui só o bloco entre os
// `---` passa pelo formatador; o resto sai byte a byte como veio.
//
// A varredura do `---` é local de propósito: o fmt não depende de nenhum outro
// módulo (trabalha sobre bytes), e é o que o mantém utilizável isoladamente.
fn lsxDashLine(src: string, i: i64, n: i64): bool {
    if (i + 3 > n) { return false; }
    if (peek8(src, i) != 45 || peek8(src, i + 1) != 45 || peek8(src, i + 2) != 45) { return false; }
    let j: i64 = i + 3;
    while (j < n && peek8(src, j) != 10) {
        const c: i64 = peek8(src, j);
        if (c != 32 && c != 9 && c != 13) { return false; }
        j = j + 1;
    }
    return true;
}
fn lsxAfterLine(src: string, i: i64, n: i64): i64 {
    let j: i64 = i;
    while (j < n && peek8(src, j) != 10) { j = j + 1; }
    if (j < n) { j = j + 1; }
    return j;
}

fn formatLsx(src: string): string {
    const n: i64 = len(src);
    let i: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(src, i);
        if (c != 32 && c != 9 && c != 10 && c != 13) { break; }
        i = i + 1;
    }
    if (!lsxDashLine(src, i, n)) { return src; }          // sem frontmatter: intacto
    const fmStart: i64 = lsxAfterLine(src, i, n);
    let j: i64 = fmStart;
    let fmEnd: i64 = -1;
    while (j < n) {
        if (lsxDashLine(src, j, n)) { fmEnd = j; break; }
        j = lsxAfterLine(src, j, n);
    }
    if (fmEnd < 0) { return src; }                        // frontmatter aberto: intacto
    const head: string = substring(src, 0, fmStart);
    const fm: string = substring(src, fmStart, fmEnd);
    const tail: string = substring(src, fmEnd, n);
    return concat(head, concat(formatSource(fm), tail));
}
