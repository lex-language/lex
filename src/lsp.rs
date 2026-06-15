//! `lex lsp` — um Language Server mínimo (diagnostics ao vivo) por stdio.
//!
//! Fala o subconjunto do LSP necessário para diagnósticos: `initialize`,
//! `textDocument/didOpen`/`didChange`, `shutdown`/`exit`. A cada edição,
//! grava o texto num arquivo temporário e roda `lex check --json` num
//! SUBPROCESSO (o parser aborta no 1º erro de sintaxe — rodar fora do processo
//! evita derrubar o servidor) e republica os diagnósticos.
//!
//! Os erros de semântica carregam o span do statement/definição (via
//! `sema::Diagnostic`), então o `lex check --json` já devolve linha/coluna
//! exatas e o editor sublinha o ponto certo. Erros de sintaxe ainda vêm do
//! parser (texto) como um diagnóstico de arquivo na linha 0.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::Command;

use crate::json::{self, Json};

pub fn run() -> ! {
    let mut stdin = std::io::stdin().lock();
    let mut counter: u64 = 0;
    while let Some(body) = read_message(&mut stdin) {
        let Some(msg) = json::parse(&body) else {
            continue;
        };
        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        match method {
            "initialize" => {
                let id = msg.get("id");
                // textDocumentSync: 1 = Full (o cliente manda o texto inteiro)
                respond(
                    id,
                    "{\"capabilities\":{\"textDocumentSync\":1},\"serverInfo\":{\"name\":\"lex-lsp\"}}",
                );
            }
            "shutdown" => respond(msg.get("id"), "null"),
            "exit" => std::process::exit(0),
            "textDocument/didOpen" => {
                if let Some(td) = msg.path(&["params", "textDocument"]) {
                    if let (Some(uri), Some(text)) = (
                        td.get("uri").and_then(|u| u.as_str()),
                        td.get("text").and_then(|t| t.as_str()),
                    ) {
                        counter += 1;
                        analyze_and_publish(uri, text, counter);
                    }
                }
            }
            "textDocument/didChange" => {
                let uri = msg
                    .path(&["params", "textDocument", "uri"])
                    .and_then(|u| u.as_str());
                // sincronização Full: o último change traz o texto inteiro
                let text = msg
                    .path(&["params", "contentChanges"])
                    .and_then(|c| c.as_array())
                    .and_then(|a| a.last())
                    .and_then(|c| c.get("text"))
                    .and_then(|t| t.as_str());
                if let (Some(uri), Some(text)) = (uri, text) {
                    counter += 1;
                    analyze_and_publish(uri, text, counter);
                }
            }
            _ => {} // initialized, didSave, etc. — ignorados
        }
    }
    std::process::exit(0);
}

/// Lê uma mensagem LSP: cabeçalhos `Content-Length` + corpo. `None` no EOF.
fn read_message(stdin: &mut impl Read) -> Option<String> {
    // lê cabeçalhos byte a byte até a linha em branco (\r\n\r\n)
    let mut headers = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if stdin.read(&mut byte).ok()? == 0 {
            return None;
        }
        headers.push(byte[0]);
        if headers.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    let header_text = String::from_utf8_lossy(&headers);
    let len: usize = header_text
        .lines()
        .find_map(|l| l.strip_prefix("Content-Length:"))
        .and_then(|n| n.trim().parse().ok())?;
    let mut buf = vec![0u8; len];
    stdin.read_exact(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Roda `lex check --json` no texto e publica os diagnósticos sob `uri`.
fn analyze_and_publish(uri: &str, text: &str, counter: u64) {
    let ext = if uri.ends_with(".test.lex") { ".test.lex" } else { ".lex" };
    let tmp: PathBuf = std::env::temp_dir().join(format!("lex_lsp_{}{}", counter, ext));
    if std::fs::write(&tmp, text).is_err() {
        return;
    }
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("lex"));
    let out = Command::new(exe)
        .arg("check")
        .arg("--json")
        .arg(&tmp)
        .output();
    let _ = std::fs::remove_file(&tmp);

    let diags = match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            match json::parse(stdout.trim()) {
                // diagnósticos estruturados do `lex check --json`
                Some(Json::Arr(items)) => items
                    .iter()
                    .map(diag_to_lsp)
                    .collect::<Vec<_>>(),
                // sem JSON (ex.: erro de sintaxe fatal no parser): usa o stderr
                _ => {
                    let err = String::from_utf8_lossy(&o.stderr);
                    let msg = err.trim();
                    if o.status.success() || msg.is_empty() {
                        Vec::new()
                    } else {
                        vec![file_diag(msg)]
                    }
                }
            }
        }
        Err(_) => Vec::new(),
    };

    let payload = format!(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\
         \"params\":{{\"uri\":\"{}\",\"diagnostics\":[{}]}}}}",
        json::escape(uri),
        diags.join(",")
    );
    send(&payload);
}

/// Converte um diagnóstico do `lex check --json` para o formato do LSP.
fn diag_to_lsp(d: &Json) -> String {
    let line = d.get("line").and_then(num).unwrap_or(0.0) as i64;
    let col = d.get("col").and_then(num).unwrap_or(0.0) as i64;
    let end_line = d.get("endLine").and_then(num).unwrap_or(line as f64) as i64;
    let end_col = d.get("endCol").and_then(num).unwrap_or((col + 1) as f64) as i64;
    let msg = d.get("message").and_then(|m| m.as_str()).unwrap_or("error");
    lsp_diag(line, col, end_line, end_col, msg)
}

fn file_diag(msg: &str) -> String {
    lsp_diag(0, 0, 0, 1, msg)
}

fn lsp_diag(line: i64, col: i64, end_line: i64, end_col: i64, msg: &str) -> String {
    format!(
        "{{\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\
         \"end\":{{\"line\":{},\"character\":{}}}}},\"severity\":1,\"message\":\"{}\"}}",
        line,
        col,
        end_line,
        end_col,
        json::escape(msg)
    )
}

fn num(j: &Json) -> Option<f64> {
    match j {
        Json::Num(n) => Some(*n),
        _ => None,
    }
}

/// Envia uma resposta a uma requisição (com `id`).
fn respond(id: Option<&Json>, result_json: &str) {
    let id_str = match id {
        Some(Json::Num(n)) => format!("{}", *n as i64),
        Some(Json::Str(s)) => format!("\"{}\"", json::escape(s)),
        _ => "null".to_string(),
    };
    send(&format!(
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{}}}",
        id_str, result_json
    ));
}

/// Escreve uma mensagem LSP (com o cabeçalho Content-Length) no stdout.
fn send(payload: &str) {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "Content-Length: {}\r\n\r\n{}", payload.len(), payload);
    let _ = out.flush();
}
