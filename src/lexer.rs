//! Lexer: transforma o código-fonte em uma sequência de tokens.
//!
//! Cada token sai acompanhado do seu span (início/fim em índices de char no
//! fonte), para o parser apontar o trecho exato nos erros de compilação.

use crate::diag::{self, Source};
use crate::token::{Token, TplPart};

/// Resultado do lexer: tokens + spans paralelos (início, fim em chars).
pub struct Lexed {
    pub tokens: Vec<Token>,
    pub spans: Vec<(usize, usize)>,
}

type Spanned = (Token, usize, usize);

pub fn lex(src: &Source) -> Lexed {
    let chars: Vec<char> = src.text.chars().collect();
    let n = chars.len();
    let out = lex_range(src, &chars, 0, n);
    let mut tokens = Vec::with_capacity(out.len());
    let mut spans = Vec::with_capacity(out.len());
    for (t, s, e) in out {
        tokens.push(t);
        spans.push((s, e));
    }
    Lexed { tokens, spans }
}

/// Onde o corpo de um template termina: na crase de fecho ou na tag de fecho
/// de um componente (`</Nome>`).
enum Stop<'s> {
    Backtick,
    Close(&'s str),
}

/// `chars[i..]` começa com `</nome>`? (case-sensitive, dentro dos limites)
fn matches_close_tag(chars: &[char], i: usize, hi: usize, name: &str) -> bool {
    let nm: Vec<char> = name.chars().collect();
    let end = i + 2 + nm.len() + 1; // </ + nome + >
    if end > hi || chars[i] != '<' || chars[i + 1] != '/' {
        return false;
    }
    for (k, c) in nm.iter().enumerate() {
        if chars[i + 2 + k] != *c {
            return false;
        }
    }
    chars[i + 2 + nm.len()] == '>'
}

/// Lê o corpo de um template — texto fixo, `${expr}` e componentes JSX
/// (`<Nome ... />` ou `<Nome ...>filhos</Nome>`) — parando no marcador `stop`.
/// Devolve as partes e o índice logo após o marcador. Reusado pela crase e
/// pelos filhos de um componente (por isso filhos podem ter mais JSX e `${}`).
fn lex_template_body(
    src: &Source,
    chars: &[char],
    mut i: usize,
    hi: usize,
    stop: Stop,
) -> (Vec<TplPart>, usize) {
    let mut parts: Vec<TplPart> = Vec::new();
    let mut lit = String::new();
    loop {
        // marcador de fim?
        let ended = match &stop {
            Stop::Backtick => i < hi && chars[i] == '`',
            Stop::Close(name) => matches_close_tag(chars, i, hi, name),
        };
        if ended {
            i += match &stop {
                Stop::Backtick => 1,
                Stop::Close(name) => name.chars().count() + 3, // </nome>
            };
            break;
        }
        if i >= hi {
            match &stop {
                Stop::Backtick => diag::fatal(
                    src,
                    (hi.saturating_sub(1), hi),
                    "unterminated template literal (missing closing backtick)",
                    Some("the template is never closed — add ` at the end"),
                ),
                Stop::Close(name) => diag::fatal(
                    src,
                    (hi.saturating_sub(1), hi),
                    &format!("component <{}> is missing its closing </{}>", name, name),
                    Some(&format!("close the children with </{}>", name)),
                ),
            }
        }

        let ch = chars[i];
        if ch == '\\' && i + 1 < hi {
            i += 1;
            lit.push(match chars[i] {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '`' => '`',
                '$' => '$',
                '"' => '"',
                '0' => '\0',
                e => diag::fatal(
                    src,
                    (i - 1, i + 1),
                    &format!("unknown escape in template: \\{}", e),
                    Some("valid escapes: \\n \\r \\t \\\\ \\` \\$ \\\" \\0"),
                ),
            });
            i += 1;
            continue;
        }
        if ch == '$' && i + 1 < hi && chars[i + 1] == '{' {
            if !lit.is_empty() {
                parts.push(TplPart::Lit(std::mem::take(&mut lit)));
            }
            let dollar = i;
            i += 2;
            let start = i;
            let mut depth = 1;
            while i < hi && depth > 0 {
                match chars[i] {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    _ => {}
                }
                if depth > 0 {
                    i += 1;
                }
            }
            if depth != 0 {
                diag::fatal(
                    src,
                    (dollar, dollar + 2),
                    "'${' without '}' in template literal",
                    Some("close the interpolation with }"),
                );
            }
            let inner_end = i;
            i += 1; // consome '}'
            let mut toks: Vec<Token> = lex_range(src, chars, start, inner_end)
                .into_iter()
                .map(|(t, _, _)| t)
                .collect();
            toks.pop(); // tira o Eof
            if toks.is_empty() {
                diag::fatal(
                    src,
                    (dollar, inner_end + 1),
                    "empty interpolation in template literal",
                    Some("put an expression inside ${...} or remove the interpolation"),
                );
            }
            parts.push(TplPart::Expr(toks));
            continue;
        }
        // componente JSX: `<Maiúscula ... />` ou `<Maiúscula ...>filhos</...>`
        // vira a chamada Nome({ attr: val, ... }). Componentes aninhados são
        // consumidos recursivamente aqui, então o `</Nome>` que sobra é o nosso.
        if ch == '<' && i + 1 < hi && chars[i + 1].is_ascii_uppercase() {
            if !lit.is_empty() {
                parts.push(TplPart::Lit(std::mem::take(&mut lit)));
            }
            let (toks, ni) = lex_jsx_component(src, chars, i, hi);
            i = ni;
            parts.push(TplPart::Expr(toks));
            continue;
        }
        lit.push(ch);
        i += 1;
    }
    if !lit.is_empty() {
        parts.push(TplPart::Lit(lit));
    }
    (parts, i)
}

/// Lê um componente JSX dentro de um template e devolve os tokens equivalentes
/// à chamada `Nome({ attr: val, ..., children: `...` })`, mais o índice logo
/// após o `/>` (self-closing) ou o `</Nome>` (com filhos). `start` aponta para
/// o `<`. Os filhos viram um template literal no atributo `children`.
#[allow(unused_assignments)] // `first` é setado no último atributo e não relido
fn lex_jsx_component(src: &Source, chars: &[char], start: usize, hi: usize) -> (Vec<Token>, usize) {
    let mut i = start + 1; // pula '<'
    let s = i;
    while i < hi && (chars[i].is_alphanumeric() || chars[i] == '_') {
        i += 1;
    }
    let name: String = chars[s..i].iter().collect();
    let head = (start, i); // span de `<Nome`, para erros do componente

    let mut toks = vec![Token::Ident(name.clone()), Token::LParen, Token::LBrace];
    let mut first = true;

    // junta os tokens de um atributo, com a vírgula separadora quando preciso
    macro_rules! push_attr {
        ($attr:expr, $val:expr) => {{
            if !first {
                toks.push(Token::Comma);
            }
            first = false;
            toks.push(Token::Ident($attr));
            toks.push(Token::Colon);
            toks.extend($val);
        }};
    }

    loop {
        while i < hi && chars[i].is_whitespace() {
            i += 1;
        }
        if i >= hi {
            diag::fatal(
                src,
                head,
                &format!("component <{}> is missing its closing '/>' or '>'", name),
                Some("close the component with '/>' (or '>...children</Name>')"),
            );
        }
        // self-closing: />  (sem filhos)
        if chars[i] == '/' && i + 1 < hi && chars[i + 1] == '>' {
            i += 2;
            break;
        }
        // abertura com filhos: >   ...filhos...   </Nome>
        if chars[i] == '>' {
            i += 1; // consome '>'
            let (parts, ni) = lex_template_body(src, chars, i, hi, Stop::Close(&name));
            i = ni;
            // children vira um template literal (texto + ${} + JSX aninhado)
            push_attr!("children".to_string(), vec![Token::Template(parts)]);
            break;
        }

        // nome do atributo
        let a = i;
        while i < hi && (chars[i].is_alphanumeric() || chars[i] == '_') {
            i += 1;
        }
        if i == a {
            diag::fatal(
                src,
                (i, i + 1),
                &format!("invalid attribute in component <{}>", name),
                None,
            );
        }
        let attr: String = chars[a..i].iter().collect();
        let attr_span = (a, i);

        while i < hi && chars[i].is_whitespace() {
            i += 1;
        }
        if i >= hi || chars[i] != '=' {
            diag::fatal(
                src,
                attr_span,
                &format!("attribute of <{}> needs a value", name),
                Some("use name=\"text\" or name={expr}"),
            );
        }
        i += 1;
        while i < hi && chars[i].is_whitespace() {
            i += 1;
        }

        // valor: "string" ou {expr}
        if i < hi && chars[i] == '"' {
            let open = i;
            i += 1;
            let mut sv = String::new();
            while i < hi && chars[i] != '"' {
                if chars[i] == '\\' && i + 1 < hi {
                    i += 1;
                    sv.push(match chars[i] {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '"' => '"',
                        '\\' => '\\',
                        e => e,
                    });
                } else {
                    sv.push(chars[i]);
                }
                i += 1;
            }
            if i >= hi {
                diag::fatal(
                    src,
                    (open, hi),
                    &format!("unterminated string in attribute of <{}>", name),
                    Some("close the string with \""),
                );
            }
            i += 1; // consome "
            push_attr!(attr, vec![Token::Str(sv)]);
        } else if i < hi && chars[i] == '{' {
            let brace = i;
            i += 1;
            let s2 = i;
            let mut depth = 1;
            while i < hi && depth > 0 {
                match chars[i] {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    _ => {}
                }
                if depth > 0 {
                    i += 1;
                }
            }
            if depth != 0 {
                diag::fatal(
                    src,
                    (brace, brace + 1),
                    &format!("'{{' without '}}' in attribute of <{}>", name),
                    Some("close the expression with }"),
                );
            }
            let inner_end = i;
            i += 1; // consome }
            // lexa no lugar, mantendo os índices absolutos no fonte
            let mut vt: Vec<Token> = lex_range(src, chars, s2, inner_end)
                .into_iter()
                .map(|(t, _, _)| t)
                .collect();
            vt.pop(); // tira o Eof
            if vt.is_empty() {
                diag::fatal(
                    src,
                    (brace, inner_end + 1),
                    &format!("attribute of <{}> has an empty value", name),
                    Some("put an expression inside {...}"),
                );
            }
            push_attr!(attr, vt);
        } else {
            diag::fatal(
                src,
                (i.min(hi.saturating_sub(1)), i + 1),
                &format!("invalid attribute value in <{}>", name),
                Some("use \"text\" or {expr}"),
            );
        }
    }

    toks.push(Token::RBrace);
    toks.push(Token::RParen);
    (toks, i)
}

/// Lexa `chars[lo..hi]` com spans absolutos no fonte. Interpolações de
/// template e atributos JSX reusam isto para os erros apontarem certo.
fn lex_range(src: &Source, chars: &[char], lo: usize, hi: usize) -> Vec<Spanned> {
    let mut i = lo;
    let mut tokens: Vec<Spanned> = Vec::new();

    while i < hi {
        let c = chars[i];

        // quebra de linha vira token (terminador de statement); runs
        // consecutivos colapsam em um só
        if c == '\n' {
            if !matches!(tokens.last(), Some((Token::Newline, _, _))) {
                tokens.push((Token::Newline, i, i + 1));
            }
            i += 1;
            continue;
        }

        // demais espaços em branco
        if c.is_whitespace() {
            i += 1;
            continue;
        }

        // comentários de linha: // ...
        if c == '/' && i + 1 < hi && chars[i + 1] == '/' {
            while i < hi && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }

        // literal de string: "..." com escapes \n \r \t \\ \" \0
        if c == '"' {
            let open = i;
            i += 1;
            let mut s = String::new();
            while i < hi && chars[i] != '"' {
                if chars[i] == '\\' && i + 1 < hi {
                    i += 1;
                    s.push(match chars[i] {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        '\\' => '\\',
                        '"' => '"',
                        '0' => '\0',
                        e => diag::fatal(
                            src,
                            (i - 1, i + 1),
                            &format!("unknown escape in string: \\{}", e),
                            Some("valid escapes: \\n \\r \\t \\\\ \\\" \\0"),
                        ),
                    });
                } else {
                    s.push(chars[i]);
                }
                i += 1;
            }
            if i >= hi {
                diag::fatal(
                    src,
                    (open, hi),
                    "unterminated string (missing closing quote)",
                    Some("the string opens here and is never closed — add \" at the end"),
                );
            }
            i += 1; // consome o " final
            tokens.push((Token::Str(s), open, i));
            continue;
        }

        // template literal: `texto ${expr} texto` (com componentes JSX)
        if c == '`' {
            let open = i;
            i += 1; // pula a crase de abertura
            let (parts, ni) = lex_template_body(src, chars, i, hi, Stop::Backtick);
            i = ni;
            tokens.push((Token::Template(parts), open, i));
            continue;
        }

        match c {
            '(' => { tokens.push((Token::LParen, i, i + 1)); i += 1; }
            ')' => { tokens.push((Token::RParen, i, i + 1)); i += 1; }
            '{' => { tokens.push((Token::LBrace, i, i + 1)); i += 1; }
            '}' => { tokens.push((Token::RBrace, i, i + 1)); i += 1; }
            '[' => { tokens.push((Token::LBracket, i, i + 1)); i += 1; }
            ']' => { tokens.push((Token::RBracket, i, i + 1)); i += 1; }
            ':' => { tokens.push((Token::Colon, i, i + 1)); i += 1; }
            ';' => { tokens.push((Token::Semicolon, i, i + 1)); i += 1; }
            ',' => { tokens.push((Token::Comma, i, i + 1)); i += 1; }
            '.' => {
                // '...' (variádico), '..' (faixa) ou '.'
                if i + 2 < hi && chars[i + 1] == '.' && chars[i + 2] == '.' {
                    tokens.push((Token::DotDotDot, i, i + 3));
                    i += 3;
                } else if chars.get(i + 1) == Some(&'.') {
                    tokens.push((Token::DotDot, i, i + 2));
                    i += 2;
                } else {
                    tokens.push((Token::Dot, i, i + 1));
                    i += 1;
                }
            }
            '+' => {
                // '++', '+=' ou '+'
                if chars.get(i + 1) == Some(&'+') {
                    tokens.push((Token::PlusPlus, i, i + 2)); i += 2;
                } else if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::PlusEq, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Plus, i, i + 1)); i += 1;
                }
            }
            '*' => {
                if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::StarEq, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Star, i, i + 1)); i += 1;
                }
            }
            '/' => {
                if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::SlashEq, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Slash, i, i + 1)); i += 1;
                }
            }
            '%' => {
                if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::PercentEq, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Percent, i, i + 1)); i += 1;
                }
            }
            '<' => {
                // '<<', '<=' ou '<'
                if chars.get(i + 1) == Some(&'<') {
                    tokens.push((Token::Shl, i, i + 2)); i += 2;
                } else if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::Le, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Lt, i, i + 1)); i += 1;
                }
            }
            '>' => {
                // '>>', '>=' ou '>'
                if chars.get(i + 1) == Some(&'>') {
                    tokens.push((Token::Shr, i, i + 2)); i += 2;
                } else if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::Ge, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Gt, i, i + 1)); i += 1;
                }
            }
            '&' => {
                if chars.get(i + 1) == Some(&'&') {
                    tokens.push((Token::AmpAmp, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Amp, i, i + 1)); i += 1;
                }
            }
            '|' => {
                if chars.get(i + 1) == Some(&'|') {
                    tokens.push((Token::PipePipe, i, i + 2)); i += 2;
                } else {
                    tokens.push((Token::Pipe, i, i + 1)); i += 1;
                }
            }
            '^' => { tokens.push((Token::Caret, i, i + 1)); i += 1; }
            '~' => { tokens.push((Token::Tilde, i, i + 1)); i += 1; }
            '=' => {
                // '==', '=>' ou '='
                if i + 1 < hi && chars[i + 1] == '=' {
                    tokens.push((Token::EqEq, i, i + 2));
                    i += 2;
                } else if i + 1 < hi && chars[i + 1] == '>' {
                    tokens.push((Token::FatArrow, i, i + 2));
                    i += 2;
                } else {
                    tokens.push((Token::Eq, i, i + 1));
                    i += 1;
                }
            }
            '!' => {
                // '!=' ou '!'
                if i + 1 < hi && chars[i + 1] == '=' {
                    tokens.push((Token::Neq, i, i + 2));
                    i += 2;
                } else {
                    tokens.push((Token::Bang, i, i + 1));
                    i += 1;
                }
            }
            '-' => {
                // '->', '--', '-=' ou '-'
                if i + 1 < hi && chars[i + 1] == '>' {
                    tokens.push((Token::Arrow, i, i + 2));
                    i += 2;
                } else if chars.get(i + 1) == Some(&'-') {
                    tokens.push((Token::MinusMinus, i, i + 2));
                    i += 2;
                } else if chars.get(i + 1) == Some(&'=') {
                    tokens.push((Token::MinusEq, i, i + 2));
                    i += 2;
                } else {
                    tokens.push((Token::Minus, i, i + 1));
                    i += 1;
                }
            }
            _ if c.is_ascii_digit() => {
                let start = i;
                while i < hi && chars[i].is_ascii_digit() {
                    i += 1;
                }
                let mut is_float = false;
                // parte fracionária: '.' seguido de dígito (senão '.' é acesso/variádico)
                if chars.get(i) == Some(&'.')
                    && chars.get(i + 1).is_some_and(|c| c.is_ascii_digit())
                {
                    is_float = true;
                    i += 1;
                    while i < hi && chars[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                // expoente: e/E [+/-]? dígitos
                if matches!(chars.get(i), Some('e') | Some('E')) {
                    let mut k = i + 1;
                    if matches!(chars.get(k), Some('+') | Some('-')) {
                        k += 1;
                    }
                    if chars.get(k).is_some_and(|c| c.is_ascii_digit()) {
                        is_float = true;
                        i = k + 1;
                        while i < hi && chars[i].is_ascii_digit() {
                            i += 1;
                        }
                    }
                }
                let s: String = chars[start..i].iter().collect();
                if is_float {
                    let f: f64 = s.parse().unwrap_or_else(|_| {
                        diag::fatal(src, (start, i), "invalid float literal", None)
                    });
                    tokens.push((Token::Float(f), start, i));
                } else {
                    let n = s.parse().unwrap_or_else(|_| {
                        diag::fatal(
                            src,
                            (start, i),
                            "invalid integer literal (too large for i64)",
                            None,
                        )
                    });
                    tokens.push((Token::Int(n), start, i));
                }
            }
            _ if c.is_alphabetic() || c == '_' => {
                let start = i;
                while i < hi && (chars[i].is_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
                let s: String = chars[start..i].iter().collect();
                let tok = match s.as_str() {
                    // `function` e `fn` são equivalentes (escolha de estilo)
                    "function" | "fn" => Token::Function,
                    "declare" => Token::Declare,
                    "import" => Token::Import,
                    "from" => Token::From,
                    "const" => Token::Const,
                    "let" => Token::Let,
                    "return" => Token::Return,
                    "while" => Token::While,
                    "for" => Token::For,
                    "break" => Token::Break,
                    "continue" => Token::Continue,
                    "match" => Token::Match,
                    "type" => Token::Type,
                    // reservada: orienta quem vem de outra sintaxe
                    "extern" => diag::fatal(
                        src,
                        (start, i),
                        "'extern' does not exist in lex",
                        Some(
                            "use 'declare function name(...): type' \
                             and import with import { ... } from \"module\"",
                        ),
                    ),
                    "if" => Token::If,
                    "else" => Token::Else,
                    "try" => Token::Try,
                    "catch" => Token::Catch,
                    "fail" => Token::Fail,
                    "spawn" => Token::Spawn,
                    "class" => Token::Class,
                    "extends" => Token::Extends,
                    "interface" => Token::Interface,
                    "implements" => Token::Implements,
                    "enum" => Token::Enum,
                    "new" => Token::New,
                    "static" => Token::Static,
                    "private" => Token::Private,
                    "super" => Token::Super,
                    "async" => Token::Async,
                    "await" => Token::Await,
                    "true" => Token::True,
                    "false" => Token::False,
                    "defer" => Token::Defer,
                    // reservada: orienta quem vem do TS/Java
                    "public" => diag::fatal(
                        src,
                        (start, i),
                        "'public' does not exist in lex",
                        Some("everything is public by default — use 'private' to hide a member"),
                    ),
                    _ => Token::Ident(s),
                };
                tokens.push((tok, start, i));
            }
            _ => diag::fatal(
                src,
                (i, i + 1),
                &format!("unexpected character: {:?}", c),
                None,
            ),
        }
    }

    tokens.push((Token::Eof, hi, hi));
    tokens
}
