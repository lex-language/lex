// lexer.lex — o lexer do lex, escrito em lex (Fase 1 do self-hosting).
//
// Espelha src/lexer.rs + src/token.rs: fonte → sequência de tokens. A fonte é
// tratada como bytes (ASCII), lidos em O(1) com peek8 sobre a string (char*).
//
// Pendências (TODO, ver src/README.md):
//   - template literals (`...${}...`) e JSX: por ora um scan ingênuo até a
//     crase de fecho, produzindo um único Tok.Template com o texto cru.

// ── tipos de token ─────────────────────────────────────────────────────────
// enum é declaração GLOBAL (visível dentro das funções) e coage com i64.
enum Tok {
    // palavras-chave
    Function, Declare, Import, From, Const, Let, Return, If, Else, While, For,
    Break, Continue, Match, Type, Try, Catch, Fail, Spawn, Class, Extends,
    Interface, Implements, Enum, New, Static, Private, Super, True, False,
    Defer, Async, Await,
    // identificadores e literais
    Ident, Int, Float, Str, Template,
    // pontuação
    LParen, RParen, LBrace, RBrace, LBracket, RBracket, Colon, Semicolon,
    Comma, Dot, DotDot, DotDotDot, Arrow, FatArrow, Eq, Bang,
    // operadores
    Plus, Minus, Star, Slash, Percent, EqEq, Neq, Lt, Gt, Le, Ge,
    AmpAmp, PipePipe, Amp, Pipe, Caret, Tilde, Shl, Shr,
    PlusEq, MinusEq, StarEq, SlashEq, PercentEq, PlusPlus, MinusMinus,
    // controle
    Newline, Eof
}

// Um token: o tipo, o texto (Ident/Str/Template guardam-no), o valor inteiro
// (só Int) e o valor float (só Float).
class Token {
    kind: Tok
    text: string
    ival: i64
    fval: f64
    pos: i64          // offset de byte de início no fonte (p/ diagnósticos)
    constructor(kind: Tok, text: string, ival: i64, fval: f64, pos: i64) {
        this.kind = kind
        this.text = text
        this.ival = ival
        this.fval = fval
        this.pos = pos
    }
}

// ── fábricas curtas (pos = offset de byte de início) ───────────────────────
fn tk(kind: Tok, pos: i64): Token { return new Token(kind, "", 0, 0.0, pos); }
fn tkText(kind: Tok, text: string, pos: i64): Token { return new Token(kind, text, 0, 0.0, pos); }
fn tkInt(text: string, pos: i64): Token { return new Token(Tok.Int, text, parseInt(text), 0.0, pos); }
fn tkFloat(text: string, pos: i64): Token { return new Token(Tok.Float, text, 0, parseFloat(text), pos); }

// ── classificadores de byte (ASCII) ────────────────────────────────────────
fn isDigit(c: i64): bool { return c >= 48 && c <= 57; }                 // 0-9
fn isAlpha(c: i64): bool {
    if (c >= 97 && c <= 122) { return true; }                          // a-z
    if (c >= 65 && c <= 90) { return true; }                           // A-Z
    return c == 95;                                                    // _
}

// Byte em `i`, ou -1 fora dos limites (evita over-read no lookahead).
fn at(src: string, i: i64, n: i64): i64 {
    if (i >= n) { return -1; }
    return peek8(src, i);
}

// Tipo do último token já emitido (-1 se vazio) — pra colapsar Newlines.
fn lastKind(toks: Token[]): Tok {
    const m: i64 = toks.len();
    if (m == 0) { return Tok.Eof; }
    return toks[m - 1].kind;
}

// Palavra-chave → seu Tok; identificador comum → Tok.Ident.
fn keywordKind(s: string): Tok {
    if (strEq(s, "function")) { return Tok.Function; }
    if (strEq(s, "fn")) { return Tok.Function; }   // 'fn' == 'function'
    if (strEq(s, "declare")) { return Tok.Declare; }
    if (strEq(s, "import")) { return Tok.Import; }
    if (strEq(s, "from")) { return Tok.From; }
    if (strEq(s, "const")) { return Tok.Const; }
    if (strEq(s, "let")) { return Tok.Let; }
    if (strEq(s, "return")) { return Tok.Return; }
    if (strEq(s, "if")) { return Tok.If; }
    if (strEq(s, "else")) { return Tok.Else; }
    if (strEq(s, "while")) { return Tok.While; }
    if (strEq(s, "for")) { return Tok.For; }
    if (strEq(s, "break")) { return Tok.Break; }
    if (strEq(s, "continue")) { return Tok.Continue; }
    if (strEq(s, "match")) { return Tok.Match; }
    if (strEq(s, "type")) { return Tok.Type; }
    if (strEq(s, "try")) { return Tok.Try; }
    if (strEq(s, "catch")) { return Tok.Catch; }
    if (strEq(s, "fail")) { return Tok.Fail; }
    if (strEq(s, "spawn")) { return Tok.Spawn; }
    if (strEq(s, "class")) { return Tok.Class; }
    if (strEq(s, "extends")) { return Tok.Extends; }
    if (strEq(s, "interface")) { return Tok.Interface; }
    if (strEq(s, "implements")) { return Tok.Implements; }
    if (strEq(s, "enum")) { return Tok.Enum; }
    if (strEq(s, "new")) { return Tok.New; }
    if (strEq(s, "static")) { return Tok.Static; }
    if (strEq(s, "private")) { return Tok.Private; }
    if (strEq(s, "super")) { return Tok.Super; }
    if (strEq(s, "async")) { return Tok.Async; }
    if (strEq(s, "await")) { return Tok.Await; }
    if (strEq(s, "true")) { return Tok.True; }
    if (strEq(s, "false")) { return Tok.False; }
    if (strEq(s, "defer")) { return Tok.Defer; }
    return Tok.Ident;
}

// resolve um escape \X dentro de string. `e` é o byte após a barra; `orig` é o
// char original (1 char) usado quando o escape é desconhecido.
fn escChar(e: i64, orig: string): string {
    if (e == 110) { return "\n"; }
    if (e == 114) { return "\r"; }
    if (e == 116) { return "\t"; }
    if (e == 92) { return "\\"; }
    if (e == 34) { return "\""; }
    return orig;
}

// ── o lexer ────────────────────────────────────────────────────────────────
fn lexSrc(src: string): Token[] {
    const n: i64 = len(src);
    let toks: Token[] = [];
    let i: i64 = 0;

    while (i < n) {
        const c: i64 = peek8(src, i);

        // quebra de linha → token (runs consecutivos colapsam em um)
        if (c == 10) {
            if (lastKind(toks) != Tok.Newline) { toks.push(tk(Tok.Newline, i)); }
            i = i + 1;
            continue;
        }
        // demais espaços (espaço, tab, CR)
        if (c == 32 || c == 9 || c == 13) { i = i + 1; continue; }

        // comentário de linha: // ...
        if (c == 47 && at(src, i + 1, n) == 47) {
            while (i < n && peek8(src, i) != 10) { i = i + 1; }
            continue;
        }

        // string: "..." com escapes \n \r \t \\ \"
        if (c == 34) {
            const strStart: i64 = i;
            i = i + 1;
            let s: string = "";
            while (i < n && peek8(src, i) != 34) {
                const ch: i64 = peek8(src, i);
                if (ch == 92 && i + 1 < n) {           // '\'
                    i = i + 1;
                    s = concat(s, escChar(peek8(src, i), charAt(src, i)));
                } else {
                    s = concat(s, charAt(src, i));
                }
                i = i + 1;
            }
            i = i + 1;                                  // consome o " final
            toks.push(tkText(Tok.Str, s, strStart));
            continue;
        }

        // template literal (TODO: ${} e JSX). Scan ingênuo até a crase de fecho.
        if (c == 96) {
            const tmplStart: i64 = i;
            i = i + 1;
            const tstart: i64 = i;
            while (i < n && peek8(src, i) != 96) {
                if (peek8(src, i) == 92 && i + 1 < n) { i = i + 2; }
                else { i = i + 1; }
            }
            const body: string = substring(src, tstart, i);
            if (i < n) { i = i + 1; }                   // consome a crase
            toks.push(tkText(Tok.Template, body, tmplStart));
            continue;
        }

        // número: int ou float (3.14, 1.0, 2e10).
        if (isDigit(c)) {
            const start: i64 = i;
            while (i < n && isDigit(peek8(src, i))) { i = i + 1; }
            let isFloat: bool = false;
            // parte fracionária: '.' seguido de dígito
            if (at(src, i, n) == 46 && isDigit(at(src, i + 1, n))) {
                isFloat = true;
                i = i + 1;
                while (i < n && isDigit(peek8(src, i))) { i = i + 1; }
            }
            // expoente: e/E [+/-]? dígitos
            const ec: i64 = at(src, i, n);
            if (ec == 101 || ec == 69) {
                let k: i64 = i + 1;
                const sg: i64 = at(src, k, n);
                if (sg == 43 || sg == 45) { k = k + 1; }
                if (isDigit(at(src, k, n))) {
                    isFloat = true;
                    i = k + 1;
                    while (i < n && isDigit(peek8(src, i))) { i = i + 1; }
                }
            }
            const txt: string = substring(src, start, i);
            if (isFloat) { toks.push(tkFloat(txt, start)); }
            else { toks.push(tkInt(txt, start)); }
            continue;
        }

        // identificador ou palavra-chave
        if (isAlpha(c)) {
            const start: i64 = i;
            while (i < n) {
                const a: i64 = peek8(src, i);
                if (isAlpha(a) || isDigit(a)) { i = i + 1; } else { break; }
            }
            const word: string = substring(src, start, i);
            const kind: Tok = keywordKind(word);
            if (kind == Tok.Ident) { toks.push(tkText(Tok.Ident, word, start)); }
            else { toks.push(tk(kind, start)); }
            continue;
        }

        // ── pontuação e operadores (cada ramo encerra com continue) ─────────
        if (c == 40) { toks.push(tk(Tok.LParen, i)); i = i + 1; continue; }
        if (c == 41) { toks.push(tk(Tok.RParen, i)); i = i + 1; continue; }
        if (c == 123) { toks.push(tk(Tok.LBrace, i)); i = i + 1; continue; }
        if (c == 125) { toks.push(tk(Tok.RBrace, i)); i = i + 1; continue; }
        if (c == 91) { toks.push(tk(Tok.LBracket, i)); i = i + 1; continue; }
        if (c == 93) { toks.push(tk(Tok.RBracket, i)); i = i + 1; continue; }
        if (c == 58) { toks.push(tk(Tok.Colon, i)); i = i + 1; continue; }
        if (c == 59) { toks.push(tk(Tok.Semicolon, i)); i = i + 1; continue; }
        if (c == 44) { toks.push(tk(Tok.Comma, i)); i = i + 1; continue; }
        if (c == 94) { toks.push(tk(Tok.Caret, i)); i = i + 1; continue; }
        if (c == 126) { toks.push(tk(Tok.Tilde, i)); i = i + 1; continue; }

        if (c == 46) {                                  // . .. ...
            if (at(src, i + 1, n) == 46 && at(src, i + 2, n) == 46) {
                toks.push(tk(Tok.DotDotDot, i)); i = i + 3; continue;
            }
            if (at(src, i + 1, n) == 46) { toks.push(tk(Tok.DotDot, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Dot, i)); i = i + 1; continue;
        }
        if (c == 43) {                                  // + ++ +=
            if (at(src, i + 1, n) == 43) { toks.push(tk(Tok.PlusPlus, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.PlusEq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Plus, i)); i = i + 1; continue;
        }
        if (c == 45) {                                  // - -> -- -=
            if (at(src, i + 1, n) == 62) { toks.push(tk(Tok.Arrow, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 45) { toks.push(tk(Tok.MinusMinus, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.MinusEq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Minus, i)); i = i + 1; continue;
        }
        if (c == 42) {                                  // * *=
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.StarEq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Star, i)); i = i + 1; continue;
        }
        if (c == 47) {                                  // / /=  (// já tratado)
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.SlashEq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Slash, i)); i = i + 1; continue;
        }
        if (c == 37) {                                  // % %=
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.PercentEq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Percent, i)); i = i + 1; continue;
        }
        if (c == 60) {                                  // < << <=
            if (at(src, i + 1, n) == 60) { toks.push(tk(Tok.Shl, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.Le, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Lt, i)); i = i + 1; continue;
        }
        if (c == 62) {                                  // > >> >=
            if (at(src, i + 1, n) == 62) { toks.push(tk(Tok.Shr, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.Ge, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Gt, i)); i = i + 1; continue;
        }
        if (c == 38) {                                  // & &&
            if (at(src, i + 1, n) == 38) { toks.push(tk(Tok.AmpAmp, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Amp, i)); i = i + 1; continue;
        }
        if (c == 124) {                                 // | ||
            if (at(src, i + 1, n) == 124) { toks.push(tk(Tok.PipePipe, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Pipe, i)); i = i + 1; continue;
        }
        if (c == 61) {                                  // = == =>
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.EqEq, i)); i = i + 2; continue; }
            if (at(src, i + 1, n) == 62) { toks.push(tk(Tok.FatArrow, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Eq, i)); i = i + 1; continue;
        }
        if (c == 33) {                                  // ! !=
            if (at(src, i + 1, n) == 61) { toks.push(tk(Tok.Neq, i)); i = i + 2; continue; }
            toks.push(tk(Tok.Bang, i)); i = i + 1; continue;
        }

        // byte desconhecido: pula (o compilador Rust dá erro aqui; aqui somos
        // tolerantes pra o lexer-em-lex não abortar no PoC).
        i = i + 1;
    }

    toks.push(tk(Tok.Eof, i));
    return toks;
}
