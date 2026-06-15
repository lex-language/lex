//! Diagnósticos: erros de compilação claros e visuais, estilo rustc.
//!
//! ```text
//! error: unterminated string (missing closing quote)
//!   --> examples/exemplo.lex:20:18
//!    |
//! 20 |     Terminal.log("ola)
//!    |                  ^^^^^
//!    |
//!    = help: the string opens here and is never closed — add " at the end
//! ```

use std::io::IsTerminal;

/// Um arquivo-fonte: o nome (exibido nos erros) e o conteúdo.
pub struct Source {
    pub name: String,
    pub text: String,
}

impl Source {
    pub fn new(name: impl Into<String>, text: impl Into<String>) -> Self {
        Source { name: name.into(), text: text.into() }
    }
}

const RED: &str = "1;31";
const GREEN: &str = "1;32";
const BLUE: &str = "1;34";
const CYAN: &str = "1;36";
const BOLD: &str = "1";
const DIM: &str = "2";

fn paint(on: bool, code: &str, s: &str) -> String {
    if on { format!("\x1b[{}m{}\x1b[0m", code, s) } else { s.to_string() }
}

fn stderr_tty() -> bool {
    std::io::stderr().is_terminal()
}

fn stdout_tty() -> bool {
    std::io::stdout().is_terminal()
}

/// "erro:" em vermelho + mensagem em negrito (erro sem posição no fonte).
pub fn error_line(msg: &str) -> String {
    let c = stderr_tty();
    format!("{} {}", paint(c, RED, "error:"), paint(c, BOLD, msg))
}

/// Erro fatal sem posição: imprime e encerra o processo.
pub fn fatal_plain(msg: &str) -> ! {
    eprintln!("{}", error_line(msg));
    std::process::exit(1);
}

/// Erro fatal apontando um trecho do fonte: imprime o diagnóstico completo
/// (cabeçalho, trecho com sublinhado e dica) e encerra o processo.
pub fn fatal(src: &Source, span: (usize, usize), msg: &str, hint: Option<&str>) -> ! {
    eprintln!("{}", render(src, span, msg, hint));
    std::process::exit(1);
}

/// "✓ msg" em verde — status de sucesso (stdout).
pub fn ok_line(msg: &str) -> String {
    let c = stdout_tty();
    format!("{} {}", paint(c, GREEN, "✓"), msg)
}

/// "✖ msg" em vermelho — falha que não encerra o processo (ex.: watcher).
pub fn fail_line(msg: &str) -> String {
    let c = stderr_tty();
    format!("{} {}", paint(c, RED, "✖"), paint(c, BOLD, msg))
}

/// Texto esmaecido — cabeçalhos discretos (ex.: header do watcher).
pub fn dim_line(msg: &str) -> String {
    let c = stdout_tty();
    paint(c, DIM, msg)
}

/// Monta o diagnóstico completo. O span é (início, fim) em índices de char
/// no fonte; linha e coluna são derivadas dele.
pub fn render(src: &Source, (start, end): (usize, usize), msg: &str, hint: Option<&str>) -> String {
    let c = stderr_tty();
    let chars: Vec<char> = src.text.chars().collect();
    let start = start.min(chars.len());

    // linha e coluna (1-based) + onde começa a linha do erro
    let mut line = 1usize;
    let mut col = 1usize;
    let mut line_start = 0usize;
    for (idx, &ch) in chars.iter().enumerate().take(start) {
        if ch == '\n' {
            line += 1;
            col = 1;
            line_start = idx + 1;
        } else {
            col += 1;
        }
    }
    let line_end = chars[line_start..]
        .iter()
        .position(|&ch| ch == '\n')
        .map(|p| line_start + p)
        .unwrap_or(chars.len());

    // o sublinhado fica contido na linha onde o erro começa
    let span_len = end
        .saturating_sub(start)
        .min(line_end.saturating_sub(start))
        .max(1);

    // expande tabs para o sublinhado alinhar com o texto impresso
    let mut rendered = String::new();
    let mut caret_pad = 0usize;
    let mut caret_len = 0usize;
    for (off, ch) in chars[line_start..line_end].iter().enumerate() {
        let w = if *ch == '\t' { 4 } else { 1 };
        if off < col - 1 {
            caret_pad += w;
        } else if off < col - 1 + span_len {
            caret_len += w;
        }
        if *ch == '\t' {
            rendered.push_str("    ");
        } else {
            rendered.push(*ch);
        }
    }
    let caret_len = caret_len.max(1);

    let ln = line.to_string();
    let pad = " ".repeat(ln.len());
    let bar = paint(c, BLUE, "|");

    let mut out = String::new();
    out.push_str(&format!("{} {}\n", paint(c, RED, "error:"), paint(c, BOLD, msg)));
    out.push_str(&format!(
        "{}{} {}:{}:{}\n",
        pad,
        paint(c, BLUE, "-->"),
        src.name,
        line,
        col
    ));
    out.push_str(&format!("{} {}\n", pad, bar));
    out.push_str(&format!("{} {} {}\n", paint(c, BLUE, &ln), bar, rendered));
    out.push_str(&format!(
        "{} {} {}{}\n",
        pad,
        bar,
        " ".repeat(caret_pad),
        paint(c, RED, &"^".repeat(caret_len))
    ));
    if let Some(h) = hint {
        out.push_str(&format!("{} {}\n", pad, bar));
        out.push_str(&format!(
            "{} {} {} {}\n",
            pad,
            paint(c, BLUE, "="),
            paint(c, CYAN, "help:"),
            h
        ));
    }
    out
}
