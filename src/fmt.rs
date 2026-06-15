//! `lex fmt` — formatador conservador da linguagem.
//!
//! Estratégia deliberadamente simples e SEGURA: o formatador só normaliza a
//! indentação (por profundidade de chaves/colchetes/parênteses), remove espaço
//! em branco no fim das linhas e colapsa linhas em branco consecutivas. Ele
//! NUNCA reescreve código, junta/quebra linhas, nem mexe no interior de
//! strings ou template literals.
//!
//! Isso o torna seguro por construção: como o lex usa chaves e quebras de
//! linha (não indentação) para a sintaxe, mudar só o espaço de indentação não
//! altera a tokenização — logo não muda a semântica. O único cuidado é o
//! interior de template literals (`` `...` ``), onde o espaço FAZ parte do
//! texto: essas linhas saem inalteradas.

use std::path::Path;
use std::process::exit;

const INDENT: &str = "    "; // 4 espaços

/// Estado ao varrer uma linha de código (fora de template).
struct LineScan {
    opens: i32,
    closes: i32,
    /// Quantos fechadores aparecem ANTES de qualquer outro conteúdo — usados
    /// para "puxar" a própria linha um nível para a esquerda (`}` alinha com o
    /// abridor).
    leading_closes: i32,
    /// A linha terminou dentro de um template literal aberto (`` ` `` sem fechar)?
    opens_template: bool,
}

/// Varre uma linha de código (que NÃO começa dentro de um template) contando
/// os delimitadores que afetam a indentação, pulando strings, chars,
/// comentários e o interior de templates de uma linha só.
fn scan_code_line(line: &str) -> LineScan {
    let bytes: Vec<char> = line.chars().collect();
    let mut i = 0;
    let mut opens = 0;
    let mut closes = 0;
    let mut leading_closes = 0;
    let mut seen_content = false; // já vimos algo que não é fechador/espaço?
    while i < bytes.len() {
        let c = bytes[i];
        match c {
            ' ' | '\t' => {}
            '/' if i + 1 < bytes.len() && bytes[i + 1] == '/' => break, // comentário
            '"' | '\'' => {
                seen_content = true;
                let quote = c;
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == '\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == quote {
                        break;
                    }
                    i += 1;
                }
            }
            '`' => {
                seen_content = true;
                // template: procura a crase de fecho na mesma linha
                i += 1;
                let mut closed = false;
                while i < bytes.len() {
                    if bytes[i] == '`' {
                        closed = true;
                        break;
                    }
                    i += 1;
                }
                if !closed {
                    // template multi-linha: o resto pertence a ele
                    return LineScan { opens, closes, leading_closes, opens_template: true };
                }
            }
            '{' | '[' | '(' => {
                opens += 1;
                seen_content = true;
            }
            '}' | ']' | ')' => {
                closes += 1;
                if !seen_content {
                    leading_closes += 1;
                }
            }
            _ => seen_content = true,
        }
        i += 1;
    }
    LineScan { opens, closes, leading_closes, opens_template: false }
}

/// Acha o fim de um template multi-linha: devolve `true` se a crase de fecho
/// aparece nesta linha (o restante volta a ser código — mas, para simplificar
/// e manter a segurança, ignoramos código após o fecho na mesma linha: linhas
/// assim são raras e ficam intactas de qualquer forma).
fn template_closes_on(line: &str) -> bool {
    let bytes: Vec<char> = line.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == '`' {
            return true;
        }
        i += 1;
    }
    false
}

/// Formata o conteúdo de um arquivo. Idempotente.
pub fn format_source(src: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut depth: i32 = 0;
    let mut in_template = false;
    let mut blank_run = 0;

    for raw in src.lines() {
        if in_template {
            // interior de template: sai inalterado (o espaço é parte do texto)
            out.push(raw.to_string());
            if template_closes_on(raw) {
                in_template = false;
            }
            continue;
        }

        let trimmed = raw.trim_end();
        let content = trimmed.trim_start();

        if content.is_empty() {
            // colapsa linhas em branco consecutivas em no máximo uma
            blank_run += 1;
            if blank_run == 1 {
                out.push(String::new());
            }
            continue;
        }
        blank_run = 0;

        let scan = scan_code_line(content);
        let this_depth = (depth - scan.leading_closes).max(0);
        let indent = INDENT.repeat(this_depth as usize);
        out.push(format!("{}{}", indent, content));

        depth = (depth + scan.opens - scan.closes).max(0);
        if scan.opens_template {
            in_template = true;
        }
    }

    // garante exatamente uma quebra de linha no fim e sem linhas em branco finais
    while out.last().map(|l| l.is_empty()).unwrap_or(false) {
        out.pop();
    }
    let mut result = out.join("\n");
    result.push('\n');
    result
}

/// Ponto de entrada do subcomando `lex fmt`.
///
/// Uso:
///   lex fmt <arquivo.lex>...     reescreve cada arquivo formatado (in-place)
///   lex fmt --check <arquivo>... só confere; sai com código 1 se algo mudaria
pub fn run(args: &[String]) -> ! {
    let mut check = false;
    let mut files: Vec<String> = Vec::new();
    for a in args {
        match a.as_str() {
            "--check" => check = true,
            s => files.push(s.to_string()),
        }
    }
    if files.is_empty() {
        eprintln!("usage: lex fmt [--check] <file.lex>...");
        exit(1);
    }

    let mut changed = 0;
    let mut errors = 0;
    for f in &files {
        if !f.ends_with(".lex") {
            eprintln!("lex fmt: skipping '{}' (not a .lex file)", f);
            continue;
        }
        let src = match std::fs::read_to_string(Path::new(f)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("lex fmt: cannot read '{}': {}", f, e);
                errors += 1;
                continue;
            }
        };
        let formatted = format_source(&src);
        if formatted == src {
            continue;
        }
        changed += 1;
        if check {
            println!("would reformat {}", f);
        } else if let Err(e) = std::fs::write(Path::new(f), &formatted) {
            eprintln!("lex fmt: cannot write '{}': {}", f, e);
            errors += 1;
        } else {
            println!("formatted {}", f);
        }
    }

    if errors > 0 {
        exit(2);
    }
    // --check: exit 1 se algo seria reformatado (útil em CI)
    if check && changed > 0 {
        exit(1);
    }
    exit(0);
}
