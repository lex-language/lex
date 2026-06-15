//! lex — o compilador da linguagem lex.
//!
//! Pipeline:  fonte .lex  ->  tokens  ->  AST  ->  sema  ->  LLVM IR  ->  .o  ->  binário

mod ast;
mod builtins;
mod codegen;
mod diag;
mod fmt;
mod json;
mod lexer;
mod lsp;
mod oop;
mod parser;
mod pkg;
mod sema;
#[cfg(test)]
mod tests;
mod token;
mod wasm_host;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::ast::{ImportDecl, Program};
use crate::diag::Source;

/// Runtime mínima (arena de strings dos template literals), embutida no
/// compilador e linkada em todo binário.
const RUNTIME_C: &str = include_str!("runtime.c");

/// Resolve "spec" para um arquivo .lex: relativo ao arquivo que importa
/// (`./shim`) ou, para especificadores nus (`libc`), na pasta `std/`, depois nos
/// pacotes instalados em `lex_modules/`.
fn resolve_module(spec: &str, base: &Path) -> Option<PathBuf> {
    let file = format!("{}.lex", spec);
    if spec.starts_with("./") || spec.starts_with("../") {
        let p = base.join(&file);
        return if p.exists() { Some(p) } else { None };
    }
    // especificador nu: std/ primeiro (builtins ganham), depois pacotes
    // instalados (lex_modules/), depois um .lex local ao lado do importador.
    if let Some(p) = find_std_file(&file, base) {
        return Some(p);
    }
    if let Some(p) = resolve_package_entry(spec) {
        return Some(p);
    }
    let local = base.join(&file);
    if local.exists() { Some(local) } else { None }
}

/// Procura `std/<file>` da forma mais tolerante possível, para que o `lex`
/// funcione de qualquer subdiretório do projeto (não só da raiz): tenta `std/`
/// relativo ao CWD e depois SUBINDO pelos diretórios pais do CWD e do diretório
/// do arquivo importador. O primeiro `std/<file>` encontrado vence (o mais
/// próximo). Mantém o comportamento antigo (rodar da raiz) como caso rápido.
fn find_std_file(file: &str, base: &Path) -> Option<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        roots.extend(cwd.ancestors().map(Path::to_path_buf));
    }
    let base_abs = base.canonicalize().unwrap_or_else(|_| base.to_path_buf());
    roots.extend(base_abs.ancestors().map(Path::to_path_buf));
    for root in roots {
        let p = root.join("std").join(file);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// Resolve um pacote instalado (`import { } from "cores"`) para seu ponto de
/// entrada em `lex_modules/cores/`: o `main` do lex.toml do pacote ou, na sua
/// ausência, convenções (`cores.lex`, `main.lex`, `lib.lex`, `src/…`).
fn resolve_package_entry(name: &str) -> Option<PathBuf> {
    let dir = Path::new(pkg::MODULES_DIR).join(name);
    if !dir.is_dir() {
        return None;
    }
    if let Some(main) = pkg::package_main(&dir) {
        let p = dir.join(&main);
        if p.exists() {
            return Some(p);
        }
    }
    let candidates = [
        format!("{}.lex", name),
        "main.lex".to_string(),
        "lib.lex".to_string(),
        format!("src/{}.lex", name),
        "src/main.lex".to_string(),
    ];
    for cand in candidates {
        let p = dir.join(cand);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// Módulos da "prelude": ficam globalmente disponíveis em todo arquivo .lex,
/// sem precisar de `import`. O `Terminal` (logger) é injetado por aqui — a
/// fonte continua em std/terminal.lex, editável sem recompilar o compilador.
/// Cada par é (especificador do módulo, símbolo que ele exporta).
const PRELUDE: &[(&str, &str)] = &[("terminal", "Terminal")];

/// Carrega os módulos importados (recursivamente), mescla as funções no
/// programa e anota arquivos .c vizinhos para o link.
fn load_imports(program: Program, input_dir: &Path, link_extras: &mut Vec<String>) -> Program {
    let mut functions = program.functions;
    let mut structs = program.structs;
    let mut interfaces = program.interfaces;
    let mut classes = program.classes;
    let mut enums = program.enums;

    // imports explícitos do programa + a prelude implícita (Terminal etc.).
    let mut imports = program.imports;
    for (module, export) in PRELUDE {
        // não injeta se o programa já traz esse módulo ou símbolo por conta
        // própria — o import explícito do usuário tem precedência.
        let already = imports
            .iter()
            .any(|i| i.module == *module || i.names.iter().any(|n| n == export));
        // best-effort: só injeta se o arquivo da prelude existe de fato, para
        // não derrubar a compilação de quem roda o lex sem a std por perto.
        if !already && resolve_module(module, input_dir).is_some() {
            imports.push(ImportDecl {
                names: vec![export.to_string()],
                module: module.to_string(),
            });
        }
    }

    let mut pending: Vec<(ImportDecl, PathBuf)> = imports
        .into_iter()
        .map(|i| (i, input_dir.to_path_buf()))
        .collect();
    let mut loaded: HashSet<PathBuf> = HashSet::new();
    let mut module_id = 1;

    while let Some((imp, base)) = pending.pop() {
        let path = resolve_module(&imp.module, &base).unwrap_or_else(|| {
            diag::fatal_plain(&format!(
                "module '{}' not found (looked for {}.lex in {} and in std/)",
                imp.module,
                imp.module,
                base.display()
            ))
        });
        let canon = path.canonicalize().unwrap_or_else(|_| path.clone());

        if loaded.insert(canon) {
            let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
                diag::fatal_plain(&format!("could not read module {}: {}", path.display(), e))
            });
            let msrc = Source::new(path.display().to_string(), text);
            let mprog = parser::parse(lexer::lex(&msrc), module_id, &msrc);
            module_id += 1;

            let mdir = path.parent().unwrap_or(Path::new(".")).to_path_buf();
            for mi in mprog.imports {
                pending.push((mi, mdir.clone()));
            }

            // um .c com o mesmo nome ao lado do .lex entra no link sozinho
            let c = path.with_extension("c");
            if c.exists() {
                let s = c.to_string_lossy().to_string();
                if !link_extras.contains(&s) {
                    link_extras.push(s);
                }
            }

            for f in mprog.functions {
                // declares repetidos entre módulos são inofensivos
                if f.external
                    && functions.iter().any(|e| e.name == f.name && e.external)
                {
                    continue;
                }
                functions.push(f);
            }
            for s in mprog.structs {
                if !structs.iter().any(|e| e.name == s.name) {
                    structs.push(s);
                }
            }
            for it in mprog.interfaces {
                if !interfaces.iter().any(|e| e.name == it.name) {
                    interfaces.push(it);
                }
            }
            for c in mprog.classes {
                if !classes.iter().any(|e| e.name == c.name) {
                    classes.push(c);
                }
            }
            for en in mprog.enums {
                if !enums.iter().any(|e| e.name == en.name) {
                    enums.push(en);
                }
            }
        }

        for n in &imp.names {
            let achou = functions.iter().any(|f| f.name == *n)
                || structs.iter().any(|s| s.name == *n)
                || interfaces.iter().any(|it| it.name == *n)
                || classes.iter().any(|c| c.name == *n)
                || enums.iter().any(|e| e.name == *n);
            if !achou {
                diag::fatal_plain(&format!("module '{}' does not export '{}'", imp.module, n));
            }
        }
    }

    Program { imports: Vec::new(), structs, interfaces, classes, enums, functions }
}

/// Imprime a ajuda da linha de comando (`lex help` / `-h` / sem argumentos).
fn print_help() {
    println!(
        "lex {} — the lex language compiler and toolchain\n",
        env!("CARGO_PKG_VERSION")
    );
    print!("{}", HELP_BODY);
}

const HELP_BODY: &str = "\
USAGE:
    lex <file.lex> [extras.c ...] [options]   compile and link a program
    lex <file.wasm>                           run a pre-compiled wasm module
    lex <command> [args ...]                  run a subcommand

OPTIONS:
    -o <path>           output path (default: input name without extension)
    --run               run the program right after compiling
    --watch             recompile automatically whenever a source changes
    --emit-ir           print the generated LLVM IR instead of linking
    --target <target>   native (default), wasm, or a cross-compile alias
                        (linux-x64, linux-arm64, windows-x64, macos-arm64, ...)
    --wasm-threads      with --target wasm: shared memory + atomics so spawn/
                        async become real Web Workers (run via web/threads-host.mjs)

COMMANDS:
    test [dir]          discover and run every *.test.lex file
    fmt [--check] <f>   format source files (--check fails if not formatted)
    check [--json] <f>  analyze (parse + sema) without generating code
    lsp                 start the language server (live diagnostics) over stdio

PACKAGES:
    init                create a lex.toml in the current project
    add <pkg>           add a dependency and install it
    install, i          install the dependencies listed in lex.toml
    update, upgrade     update dependencies to the latest allowed versions
    remove, rm <pkg>    remove a dependency
    list, ls            list the installed dependencies
    registry <cmd>      manage a package index (init / add)
    publish             print this package's registry entry

OTHER:
    help, -h, --help        show this help
    version, -v, --version  show the version

Run `lex help <command>` (or `lex <command> --help`) for details on a command.
";

/// Imprime a ajuda detalhada de um comando específico (`lex <cmd> --help`).
/// Comando desconhecido cai na ajuda de compilação (o uso padrão de `lex`).
fn print_command_help(cmd: &str) {
    let text = match cmd {
        "test" => "\
lex test [dir] — discover and run every *.test.lex file

Scans [dir] recursively (default: current directory), skipping target,
lex_modules, .git and node_modules. Test files need no `main` or imports —
just describe/test/it/expect(...). Exits 1 if any test fails (good for CI).

EXAMPLE:
    lex test examples/tests
",
        "fmt" => "\
lex fmt [--check] <file.lex> ... — format lex source files

Normalizes indentation and spacing conservatively (preserves comments and the
inside of templates); safe by construction and idempotent.

OPTIONS:
    --check   do not write; exit 1 if any file is not formatted (CI)

EXAMPLES:
    lex fmt src/app.lex
    lex fmt --check examples/exemplo.lex
",
        "check" => "\
lex check [--json] <file.lex> — analyze (parse + sema) without generating code

Fast validation for editors and CI. Reports errors and exits non-zero on failure.

OPTIONS:
    --json    emit the diagnostics as JSON

EXAMPLE:
    lex check src/app.lex
",
        "lsp" => "\
lex lsp — start the language server over stdio

Speaks the Language Server Protocol with live diagnostics. Meant to be launched
by an editor / LSP client, not run by hand.
",
        "init" => "\
lex init — create a lex.toml manifest in the current project
",
        "add" => "\
lex add <pkg>[@version] ... — add one or more dependencies and install them

A package spec is one of:
    <name>[@req]                 a registry package (e.g. mylib@^1.2)
    github.com/user/repo[@req]   a git URL
    file:../path                 a local path

EXAMPLES:
    lex add mylib
    lex add github.com/user/lib@^1.0
    lex add file:../mylib
",
        "install" | "i" => "\
lex install  (alias: i) — install the dependencies listed in lex.toml

Resolves and downloads into lex_modules/, writing lex.lock for a reproducible build.
",
        "update" | "upgrade" => "\
lex update [pkg ...]  (alias: upgrade) — update dependencies to the latest allowed versions

With no arguments updates every dependency; otherwise only the named ones.
",
        "remove" | "rm" | "uninstall" => "\
lex remove <pkg> ...  (aliases: rm, uninstall) — remove dependencies and prune them
",
        "list" | "ls" => "\
lex list  (alias: ls) — list the installed dependencies
",
        "registry" => "\
lex registry <init|add> — manage a package index (a git repo of packages/<name>.toml)

SUBCOMMANDS:
    init [dir]                create the index (packages/ + README + git init)
    add <name> <url> [dir]    register a package: writes packages/<name>.toml

EXAMPLES:
    lex registry init
    lex registry add mylib github.com/user/mylib
",
        "publish" => "\
lex publish — print this package's registry entry (paste it into an index)
",
        "version" | "-v" | "-V" | "--version" => "\
lex version  (aliases: -v, --version) — show the compiler version
",
        "help" | "-h" | "--help" => "\
lex help [command] — show general help, or detailed help for a command

EXAMPLE:
    lex help add
",
        // o \"comando\" padrão é compilar um arquivo .lex
        _ => "\
lex <file.lex> [extras.c ...] [options] — compile and link a lex program

ARGS:
    <file.lex>      the program to compile
    extras.c/.o     extra C/object files to link (e.g. a socket shim)

OPTIONS:
    -o <path>           output path (default: input name without extension)
    --run               run the program right after compiling
    --watch             recompile automatically whenever a source changes
    --emit-ir           print the generated LLVM IR instead of linking
    --target <target>   native (default), wasm, or a cross-compile alias
                        (linux-x64, linux-arm64, windows-x64, macos-arm64, ...)
    --wasm-threads      with --target wasm: shared memory + atomics so spawn/
                        async become real Web Workers (run via web/threads-host.mjs)

EXAMPLES:
    lex app.lex -o app
    lex app.lex --run
    lex app.lex --target wasm -o app.wasm --run
",
    };
    print!("{}", text);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // ajuda e versão — antes de qualquer outro despacho.
    // `lex` sem argumentos → ajuda geral.
    if args.len() < 2 {
        print_help();
        std::process::exit(0);
    }
    // ajuda por comando: `lex help [comando]` ou `lex <comando> -h|--help`.
    let asks_help = matches!(args[1].as_str(), "help" | "-h" | "--help")
        || args[2..].iter().any(|a| a == "-h" || a == "--help");
    if asks_help {
        // em `lex help <cmd>` o comando é args[2]; em `lex <cmd> --help` é args[1].
        let cmd = if matches!(args[1].as_str(), "help" | "-h" | "--help") {
            args.get(2).map(|s| s.as_str())
        } else {
            Some(args[1].as_str())
        };
        match cmd {
            Some(c) => print_command_help(c),
            None => print_help(),
        }
        std::process::exit(0);
    }
    if matches!(args[1].as_str(), "version" | "-v" | "-V" | "--version") {
        println!("lex {}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }

    // subcomandos do gerenciador de pacotes (lex install/add/remove/update/…).
    // `lex arquivo.lex` continua caindo no compilador normalmente — os comandos
    // são palavras reservadas que não terminam em .lex.
    if args.len() >= 2 && pkg::is_subcommand(&args[1]) {
        pkg::run(&args);
    }

    // `lex test [dir]` — descobre e roda todos os arquivos *.test.lex.
    if args.len() >= 2 && args[1] == "test" {
        run_tests(&args[2..]);
    }

    // `lex fmt [--check] <arquivo.lex>...` — formatador (indentação/espaços).
    if args.len() >= 2 && args[1] == "fmt" {
        fmt::run(&args[2..]);
    }

    // `lex check [--json] <arquivo.lex>` — análise (parse+sema) sem codegen.
    if args.len() >= 2 && args[1] == "check" {
        run_check(&args[2..]);
    }

    // `lex lsp` — servidor de linguagem (diagnostics ao vivo) por stdio.
    if args.len() >= 2 && args[1] == "lsp" {
        lsp::run();
    }

    let mut input: Option<String> = None;
    let mut output: Option<String> = None;
    let mut link_extras: Vec<String> = Vec::new();
    let mut emit_ir = false;
    let mut watch = false;
    let mut run = false;
    // `--wasm-threads`: com `--target wasm`, emite um módulo com memória
    // COMPARTILHADA + atomics, em que `spawn`/`async` viram Web Workers reais
    // (paralelismo de verdade). Sem a flag, o wasm é single-thread (síncrono) e
    // roda no runtime embutido (wasmi). O módulo com threads NÃO roda no wasmi;
    // é para um host com workers (Node/browser, ver web/threads-host.mjs).
    let mut wasm_threads = false;
    // alvo de compilação: "native" (padrão), "wasm", ou um alias de cross-
    // compile (linux-x64, windows-x64, macos-arm64, …) — resolvido mais abaixo.
    let mut target = String::from("native");

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-o" => {
                i += 1;
                output = Some(
                    args.get(i)
                        .unwrap_or_else(|| diag::fatal_plain("the -o flag requires a path"))
                        .clone(),
                );
            }
            "--emit-ir" => emit_ir = true,
            "--watch" => watch = true,
            "--run" => run = true,
            "--wasm-threads" => wasm_threads = true,
            // --target <alvo>: native (padrão), wasm, ou um alias de cross-
            // compile (linux-x64, linux-arm64, windows-x64, macos-arm64, …).
            "--target" => {
                i += 1;
                target = args
                    .get(i)
                    .unwrap_or_else(|| diag::fatal_plain("the --target flag requires a value"))
                    .clone();
            }
            s if s.starts_with("--target=") => {
                target = s["--target=".len()..].to_string();
            }
            // arquivos .c/.o extras vão direto para o link (ex.: shim de sockets)
            s if s.ends_with(".c") || s.ends_with(".o") => link_extras.push(s.to_string()),
            // qualquer outra flag (começa com '-') é desconhecida — erro claro
            // em vez de ser tratada como nome de arquivo de entrada.
            s if s.starts_with('-') => diag::fatal_plain(&format!(
                "unknown option '{}' — run `lex help` to see the available options",
                s
            )),
            s => input = Some(s.to_string()),
        }
        i += 1;
    }

    let input = input.unwrap_or_else(|| {
        diag::fatal_plain("no input file given — run `lex help` to see the usage")
    });

    // Atalho: `lex programa.wasm` roda um módulo já compilado no runtime
    // embutido (wasmi), sem Node nem qualquer host externo.
    if input.ends_with(".wasm") {
        match wasm_host::run_wasm(Path::new(&input)) {
            Ok(code) => std::process::exit(code),
            Err(e) => diag::fatal_plain(&format!("wasm run failed: {}", e)),
        }
    }

    // Modo watcher: observa os fontes e recompila a cada alteração.
    if watch {
        watch_mode(&input, output.as_deref(), run);
    }

    let source = std::fs::read_to_string(&input).unwrap_or_else(|e| {
        // erro comum: o usuário digitou um subcomando inexistente (ex.: `lex buld`).
        // se não parece um fonte e o arquivo não existe, aponte para a ajuda.
        if !input.ends_with(".lex") && !Path::new(&input).exists() {
            diag::fatal_plain(&format!(
                "'{}' is not a known command or file — run `lex help` to see the commands",
                input
            ));
        }
        diag::fatal_plain(&format!("could not read {}: {}", input, e))
    });

    // fonte -> tokens -> AST
    let src = Source::new(input.clone(), source);
    let mut program = parser::parse(lexer::lex(&src), 0, &src);

    // Arquivos *.test.lex rodam em "modo teste": a biblioteca de testes (`test`)
    // é injetada e o `main` sintetizado encerra com `return testReport()`. Assim
    // um arquivo de teste tem só `describe`/`test`/`expect` no topo — sem `main`.
    let is_test = input.ends_with(".test.lex");
    if is_test {
        program.imports.push(ImportDecl {
            names: ["describe", "it", "test", "expect", "testReport"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            module: "test".to_string(),
        });
    }

    // resolve `import { ... } from "..."` (e auto-linka .c vizinhos)
    let input_dir = Path::new(&input).parent().unwrap_or(Path::new(".")).to_path_buf();
    let mut program = load_imports(program, &input_dir, &mut link_extras);

    // fecha o modo teste: o `main` sintetizado (que roda os describe/test do
    // topo) termina chamando testReport(), cujo retorno vira o exit code.
    if is_test {
        if let Some(m) = program.functions.iter_mut().find(|f| f.name == "main") {
            m.body.push(crate::ast::Stmt::synthetic(crate::ast::StmtKind::Return(Some(
                crate::ast::Expr::Call {
                    name: "testReport".to_string(),
                    type_args: Vec::new(),
                    args: Vec::new(),
                },
            ))));
        }
    }

    // análise semântica: erros falíveis não tratados param a compilação aqui
    if let Err(errors) = sema::check(&mut program) {
        for e in &errors {
            eprintln!("{}", render_sema_diag(&src, e));
        }
        eprintln!();
        eprintln!(
            "{}",
            diag::fail_line(&format!(
                "{}: build failed with {} error{}",
                input,
                errors.len(),
                if errors.len() == 1 { "" } else { "s" }
            ))
        );
        std::process::exit(1);
    }

    // AST -> LLVM IR
    let context = inkwell::context::Context::create();
    let mut cg = codegen::Codegen::new(&context, "lex");
    cg.compile(&program);

    // Modo "mostre o IR": imprime o LLVM IR e sai.
    if emit_ir {
        print!("{}", cg.ir_string());
        return;
    }

    let stem = || {
        Path::new(&input)
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .to_string()
    };

    // --target wasm: emite um módulo WebAssembly e linka com o wasm-ld.
    // A runtime.c é compilada FREESTANDING para wasm32 (bump allocator sobre a
    // memória linear, mem*/str*/printf próprios) e linkada junto: strings, JSON,
    // arrays, Map e Terminal.log rodam no browser e no Node/WASI. A única dependência
    // externa é o import `lex.write(fd, ptr, len)`, fornecido pelo host JS.
    if target == "wasm" || target == "wasm32" {
        let out_path = output.unwrap_or_else(|| format!("{}.wasm", stem()));
        let obj_path = format!("{}.o", out_path);
        cg.emit_object(Path::new(&obj_path), &codegen::TargetKind::Wasm)
            .unwrap_or_else(|e| diag::fatal_plain(&format!("codegen error: {}", e)));

        // runtime.c -> objeto wasm32 (clang do LLVM 18; o do sistema pode não
        // ter o backend wasm). Freestanding: sem libc, sem sysroot.
        let rt_src = std::env::temp_dir().join("lex_runtime.c");
        std::fs::write(&rt_src, RUNTIME_C).expect("failed to write the runtime");
        let rt_obj = std::env::temp_dir().join("lex_runtime.wasm.o");
        let clang = clang_wasm_path();
        // modo threads: memória COMPARTILHADA + atomics, e a runtime compila com
        // -matomics/-mbulk-memory e o caminho LEX_WASM_THREADS (pthread via host).
        let mut clang_args: Vec<String> = vec![
            "--target=wasm32".into(),
            "-O2".into(),
            "-ffreestanding".into(),
            "-fno-builtin".into(),
            "-nostdlib".into(),
        ];
        if wasm_threads {
            clang_args.push("-matomics".into());
            clang_args.push("-mbulk-memory".into());
            clang_args.push("-DLEX_WASM_THREADS".into());
        }
        clang_args.push("-c".into());
        clang_args.push(rt_src.to_string_lossy().into_owned());
        clang_args.push("-o".into());
        clang_args.push(rt_obj.to_string_lossy().into_owned());
        let rt_status = Command::new(&clang)
            .args(&clang_args)
            .status()
            .unwrap_or_else(|e| {
                diag::fatal_plain(&format!("failed to invoke clang ({}): {}", clang, e))
            });
        if !rt_status.success() {
            diag::fatal_plain("failed to compile the runtime for wasm32");
        }

        let wasm_ld = wasm_ld_path();
        let mut ld_args: Vec<String> = vec![
            obj_path.clone(),
            rt_obj.to_string_lossy().into_owned(),
            "--no-entry".into(),
            "--export-all".into(),
            // qualquer símbolo de SO ainda não portado vira import.
            "--allow-undefined".into(),
        ];
        if wasm_threads {
            // memória compartilhada entre os Workers: IMPORTADA (o host cria UMA
            // WebAssembly.Memory shared e passa a todas as instâncias), com
            // atomics e a tabela/stack-pointer exportados (o worker chama o
            // thunk pelo índice e ajusta sua própria pilha).
            ld_args.push("--shared-memory".into());
            ld_args.push("--import-memory".into());
            ld_args.push("--max-memory=268435456".into()); // 256 MiB
            // o conjunto precisa cobrir TODOS os recursos usados pelos objetos
            // (o backend LLVM emite sign-ext/mutable-globals por padrão).
            ld_args.push("--features=atomics,bulk-memory,mutable-globals,sign-ext".into());
            ld_args.push("--export-table".into());
            ld_args.push("--export=__stack_pointer".into());
        } else {
            ld_args.push("--export-memory".into());
        }
        ld_args.push("-o".into());
        ld_args.push(out_path.clone());
        let status = Command::new(&wasm_ld)
            .args(&ld_args)
            .status()
            .unwrap_or_else(|e| {
                diag::fatal_plain(&format!(
                    "failed to invoke wasm-ld ({}): {}",
                    wasm_ld, e
                ))
            });
        let _ = std::fs::remove_file(&obj_path);
        let _ = std::fs::remove_file(&rt_obj);
        if !status.success() {
            diag::fatal_plain("wasm linking failed");
        }
        let label = if wasm_threads { "wasm+threads" } else { "wasm" };
        println!("{}", diag::ok_line(&format!("compiled ({}): {}", label, out_path)));
        // --run: roda o .wasm no runtime embutido (wasmi), sem Node. O módulo com
        // threads usa memória compartilhada/atomics, que o wasmi não suporta —
        // rode-o no host de workers (node web/threads-host.mjs <arquivo.wasm>).
        if run {
            if wasm_threads {
                diag::fatal_plain(
                    "the embedded runner (wasmi) doesn't support shared memory/atomics — \
                     run the threaded module with: node web/threads-host.mjs <file.wasm>",
                );
            }
            match wasm_host::run_wasm(Path::new(&out_path)) {
                Ok(code) => std::process::exit(code),
                Err(e) => diag::fatal_plain(&format!("wasm run failed: {}", e)),
            }
        }
        return;
    }

    // --target <alias>: cross-compile para outro SO/arquitetura. O LLVM emite o
    // objeto no triple do alvo; o link traz o que o alvo precisa:
    //   - macOS (host macOS): `clang -arch` usa o SDK do sistema — sem zig.
    //   - Linux: runtime FREESTANDING (syscalls cruas, sem libc nem CRT) linkada
    //     com `ld.lld` via clang do LLVM 18 → binário estático. Ver o bloco
    //     LEX_NATIVE_FREESTANDING em runtime.c.
    //   - Windows: runtime FREESTANDING pela Win32 API (kernel32/ws2_32) +
    //     lld-link; import libs geradas com llvm-lib. Ver LEX_WIN_FREESTANDING.
    // Nenhum alvo usa zig: todo o toolchain é o LLVM 18 (já exigido pelo inkwell).
    if target != "native" {
        let xt = resolve_cross(&target).unwrap_or_else(|| {
            diag::fatal_plain(&format!(
                "unknown --target '{}'\nuse: native, wasm, or a cross alias: {}",
                target,
                CROSS_ALIASES.join(", ")
            ))
        });

        let out_path = output.unwrap_or_else(|| format!("{}{}", stem(), xt.ext));
        let obj_path = format!("{}.o", out_path);
        cg.emit_object(Path::new(&obj_path), &codegen::TargetKind::Cross(xt.llvm.to_string()))
            .unwrap_or_else(|e| diag::fatal_plain(&format!("codegen error: {}", e)));

        // a runtime vai como fonte: o linker a compila para o alvo junto do link
        let rt_path = std::env::temp_dir().join("lex_runtime.c");
        std::fs::write(&rt_path, RUNTIME_C).expect("failed to write the runtime");
        let rt_str = rt_path.to_string_lossy().to_string();

        let status = if xt.os == "macos" && cfg!(target_os = "macos") {
            // macOS: clang do sistema cross-linka com `-arch` usando o SDK.
            let mut a: Vec<String> = vec![
                "-arch".into(),
                xt.arch.into(),
                // informa a plataforma ao linker (o objeto do LLVM não carrega
                // o load command), silenciando o aviso "no platform load command"
                "-mmacosx-version-min=11.0".into(),
                obj_path.clone(),
                rt_str.clone(),
            ];
            for extra in &link_extras {
                a.push(extra.clone());
            }
            a.push("-o".into());
            a.push(out_path.clone());
            a.push("-lpthread".into()); // no macOS faz parte da libSystem (no-op)
            Command::new("clang").args(&a).status().unwrap_or_else(|e| {
                diag::fatal_plain(&format!("failed to invoke clang: {}", e))
            })
        } else if xt.os == "linux" {
            // Linux: runtime freestanding (sem libc) + ld.lld via clang do LLVM
            // 18. Binário 100% estático, zero zig. -DLEX_NATIVE_FREESTANDING liga
            // a camada de syscalls + _start próprio em runtime.c.
            let clang = clang_wasm_path();
            let mut a: Vec<String> = vec![
                format!("--target={}", xt.llvm),
                "-DLEX_NATIVE_FREESTANDING".into(),
                "-ffreestanding".into(),
                "-fno-builtin".into(),
                "-nostdlib".into(),
                "-fno-stack-protector".into(),
                "-fno-pie".into(),
                "-static".into(),
                "-fuse-ld=lld".into(),
                "-Wl,--entry,_start".into(),
                obj_path.clone(),
                rt_str.clone(),
            ];
            for extra in &link_extras {
                a.push(extra.clone());
            }
            a.push("-o".into());
            a.push(out_path.clone());
            Command::new(&clang).args(&a).status().unwrap_or_else(|e| {
                diag::fatal_plain(&format!("failed to invoke clang ({}): {}", clang, e))
            })
        } else {
            // Windows: runtime freestanding pela Win32 API (kernel32/ws2_32) +
            // lld-link via clang do LLVM 18. As import libs são geradas na hora
            // com llvm-lib a partir de .def embutidos — sem Windows SDK, sem
            // mingw, sem zig. -DLEX_WIN_FREESTANDING liga a camada Win32.
            let tmp = std::env::temp_dir();
            let k32_def = tmp.join("lex_kernel32.def");
            let ws2_def = tmp.join("lex_ws2_32.def");
            let k32_lib = tmp.join("lex_kernel32.lib");
            let ws2_lib = tmp.join("lex_ws2_32.lib");
            std::fs::write(&k32_def, WIN_KERNEL32_DEF).expect("failed to write kernel32.def");
            std::fs::write(&ws2_def, WIN_WS2_32_DEF).expect("failed to write ws2_32.def");
            let llvm_lib = llvm_tool_path("llvm-lib");
            for (def, lib) in [(&k32_def, &k32_lib), (&ws2_def, &ws2_lib)] {
                let st = Command::new(&llvm_lib)
                    .args([
                        format!("/def:{}", def.to_string_lossy()),
                        format!("/out:{}", lib.to_string_lossy()),
                        format!("/machine:{}", xt.arch),
                    ])
                    .status()
                    .unwrap_or_else(|e| {
                        diag::fatal_plain(&format!("failed to invoke llvm-lib ({}): {}", llvm_lib, e))
                    });
                if !st.success() {
                    diag::fatal_plain("failed to generate the Windows import libs");
                }
            }
            let clang = clang_wasm_path();
            let mut a: Vec<String> = vec![
                format!("--target={}", xt.llvm),
                "-DLEX_WIN_FREESTANDING".into(),
                "-ffreestanding".into(),
                "-fno-builtin".into(),
                "-fno-stack-protector".into(),
                "-nostdlib".into(),
                "-fuse-ld=lld".into(),
                "-Wl,/entry:lexWinStart".into(),
                "-Wl,/subsystem:console".into(),
                obj_path.clone(),
                rt_str.clone(),
                k32_lib.to_string_lossy().to_string(),
                ws2_lib.to_string_lossy().to_string(),
            ];
            for extra in &link_extras {
                a.push(extra.clone());
            }
            a.push("-o".into());
            a.push(out_path.clone());
            Command::new(&clang).args(&a).status().unwrap_or_else(|e| {
                diag::fatal_plain(&format!("failed to invoke clang ({}): {}", clang, e))
            })
        };
        let _ = std::fs::remove_file(&obj_path);
        if !status.success() {
            diag::fatal_plain(&format!("cross link failed for {}", target));
        }
        println!(
            "{}",
            diag::ok_line(&format!("compiled ({}): {}", target, out_path))
        );
        if run {
            eprintln!(
                "{}",
                diag::dim_line("note: --run does not apply to a cross-compiled binary")
            );
        }
        return;
    }

    // Nome do binário de saída: padrão = nome do arquivo sem extensão.
    let out_path = output.unwrap_or_else(stem);

    // LLVM IR -> arquivo objeto
    let obj_path = format!("{}.o", out_path);
    cg.emit_object(Path::new(&obj_path), &codegen::TargetKind::Native).unwrap_or_else(|e| {
        diag::fatal_plain(&format!("codegen error: {}", e))
    });

    // a runtime embutida vai junto no link
    let rt_path = std::env::temp_dir().join("lex_runtime.c");
    std::fs::write(&rt_path, RUNTIME_C).expect("failed to write the runtime");
    let rt_str = rt_path.to_string_lossy().to_string();

    // arquivo objeto -> binário (usa o clang como linker)
    // -lpthread: threads do spawn/join (no macOS já vem na libSystem)
    let mut clang_args: Vec<&str> = vec![obj_path.as_str(), rt_str.as_str()];
    for extra in &link_extras {
        clang_args.push(extra);
    }
    clang_args.extend(["-o", &out_path, "-lpthread"]);
    let status = Command::new("clang")
        .args(&clang_args)
        .status()
        .expect("failed to invoke clang");

    let _ = std::fs::remove_file(&obj_path);

    if !status.success() {
        diag::fatal_plain("linking failed");
    }

    println!(
        "{}",
        diag::ok_line(&format!("compiled: {}", local_bin(&out_path).display()))
    );

    // --run sem --watch: executa o binário e propaga o código de saída
    if run {
        let bin = local_bin(&out_path);
        let status = Command::new(&bin).status().unwrap_or_else(|e| {
            eprintln!("failed to run {}: {}", bin.display(), e);
            std::process::exit(1);
        });
        std::process::exit(status.code().unwrap_or(0));
    }
}

/// Modo watcher: observa o diretório do fonte (e std/) e recompila a cada
/// alteração em arquivos .lex/.c. Com --run, também (re)executa o binário.
fn watch_mode(input: &str, output: Option<&str>, run: bool) -> ! {
    use notify::{RecursiveMode, Watcher};
    use std::time::Duration;

    let exe = std::env::current_exe().expect("could not locate the lex executable itself");

    // cada rebuild re-invoca o lex com os mesmos argumentos, menos os flags
    // do watcher — assim erro de compilação não derruba o watcher
    let fwd: Vec<String> = std::env::args()
        .skip(1)
        .filter(|a| a != "--watch" && a != "--run")
        .collect();

    let out_path = output.map(str::to_string).unwrap_or_else(|| {
        Path::new(input)
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .to_string()
    });

    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = notify::recommended_watcher(tx).unwrap_or_else(|e| {
        eprintln!("failed to create the watcher: {}", e);
        std::process::exit(1);
    });

    let input_dir = Path::new(input)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
        .to_path_buf();
    watcher
        .watch(&input_dir, RecursiveMode::Recursive)
        .unwrap_or_else(|e| {
            eprintln!("failed to watch {}: {}", input_dir.display(), e);
            std::process::exit(1);
        });

    // módulos da std também disparam rebuild (ex.: std/socket.lex, std/socket.c)
    let std_dir = Path::new("std");
    if std_dir.is_dir() {
        let _ = watcher.watch(std_dir, RecursiveMode::Recursive);
    }

    let header = format!("watching {} — ctrl+c to quit", input_dir.display());

    let mut running: Option<std::process::Child> = None;
    recompile(&exe, &fwd, &out_path, run, &header, &mut running);

    loop {
        match rx.recv() {
            Ok(Ok(event)) if is_source_change(&event) => {
                // junta a rajada de eventos que o editor emite num save só
                while rx.recv_timeout(Duration::from_millis(150)).is_ok() {}
                recompile(&exe, &fwd, &out_path, run, &header, &mut running);
            }
            Ok(_) => {}
            Err(_) => {
                eprintln!("watcher terminated unexpectedly");
                std::process::exit(1);
            }
        }
    }
}

/// Só alterações em fontes (.lex/.c) disparam rebuild — escrever o binário
/// de saída ou o .o no diretório observado não conta.
fn is_source_change(event: &notify::Event) -> bool {
    use notify::EventKind;
    if !matches!(
        event.kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    ) {
        return false;
    }
    event
        .paths
        .iter()
        .any(|p| matches!(p.extension().and_then(|e| e.to_str()), Some("lex") | Some("c")))
}

fn recompile(
    exe: &Path,
    args: &[String],
    out_path: &str,
    run: bool,
    header: &str,
    running: &mut Option<std::process::Child>,
) {
    // limpa o terminal a cada reload, mantendo só o cabeçalho do watcher
    use std::io::Write as _;
    print!("\x1b[2J\x1b[H");
    println!("{}", diag::dim_line(header));
    println!();
    let _ = std::io::stdout().flush();

    // o processo anterior (ex.: servidor segurando a porta) sai antes do link
    if let Some(mut old) = running.take() {
        let _ = old.kill();
        let _ = old.wait();
    }

    match Command::new(exe).args(args).status() {
        Ok(s) if s.success() => {
            if run {
                let bin = local_bin(out_path);
                match Command::new(&bin).spawn() {
                    Ok(child) => *running = Some(child),
                    Err(e) => eprintln!("failed to run {}: {}", bin.display(), e),
                }
            }
        }
        Ok(_) => {
            eprintln!();
            eprintln!(
                "{}",
                diag::fail_line("build failed — fix the error above and save to rebuild")
            );
        }
        Err(e) => eprintln!("{}", diag::error_line(&format!("failed to invoke the compiler: {}", e))),
    }
}

/// Um alvo de cross-compile: triple do LLVM (p/ emitir o objeto), arquitetura
/// (`-arch` do clang no macOS; `/machine` do llvm-lib no Windows), extensão do
/// binário e família do SO. O link é todo LLVM 18 (clang/lld), sem zig.
struct CrossTarget {
    llvm: &'static str,
    arch: &'static str,
    ext: &'static str,
    os: &'static str,
}

/// Aliases de cross-compile aceitos em --target (mostrados no erro de alvo
/// desconhecido).
const CROSS_ALIASES: &[&str] = &[
    "linux-x64",
    "linux-arm64",
    "windows-x64",
    "windows-arm64",
    "macos-x64",
    "macos-arm64",
];

/// Resolve um alias amigável de --target para o triple de LLVM e a arquitetura. `None`
/// se não for um alias conhecido.
fn resolve_cross(spec: &str) -> Option<CrossTarget> {
    let t = match spec {
        "linux-x64" | "linux-x86_64" => CrossTarget {
            llvm: "x86_64-unknown-linux-gnu",
            arch: "x86_64",
            ext: "",
            os: "linux",
        },
        "linux-arm64" | "linux-aarch64" => CrossTarget {
            llvm: "aarch64-unknown-linux-gnu",
            arch: "aarch64",
            ext: "",
            os: "linux",
        },
        "windows-x64" | "windows-x86_64" => CrossTarget {
            // MSVC triple: objeto COFF + ABI MS x64, linkado com lld-link
            llvm: "x86_64-pc-windows-msvc",
            arch: "x64", // /machine do llvm-lib
            ext: ".exe",
            os: "windows",
        },
        "windows-arm64" => CrossTarget {
            llvm: "aarch64-pc-windows-msvc",
            arch: "arm64",
            ext: ".exe",
            os: "windows",
        },
        "macos-x64" | "macos-x86_64" => CrossTarget {
            // o triple carrega a versão do OS p/ o objeto trazer o platform load
            // command (sem ele o linker do macOS emite um aviso)
            llvm: "x86_64-apple-macosx11.0.0",
            arch: "x86_64",
            ext: "",
            os: "macos",
        },
        "macos-arm64" | "macos-aarch64" => CrossTarget {
            llvm: "arm64-apple-macosx11.0.0",
            arch: "arm64",
            ext: "",
            os: "macos",
        },
        _ => return None,
    };
    Some(t)
}

/// Caminho do wasm-ld: usa o LLVM 18 do build (LLVM_SYS_180_PREFIX, gravado
/// em tempo de compilação pelo .cargo/config.toml), com fallback para o PATH.
fn wasm_ld_path() -> String {
    match option_env!("LLVM_SYS_180_PREFIX") {
        Some(prefix) => format!("{}/bin/wasm-ld", prefix),
        None => "wasm-ld".to_string(),
    }
}

/// Caminho do clang do LLVM 18 (mesmo prefixo do wasm-ld). Preferimos este ao
/// `clang` do PATH porque o do sistema (Apple clang) pode não trazer o backend
/// wasm. Fallback para o PATH se o prefixo não estiver gravado.
fn clang_wasm_path() -> String {
    match option_env!("LLVM_SYS_180_PREFIX") {
        Some(prefix) => format!("{}/bin/clang", prefix),
        None => "clang".to_string(),
    }
}

/// Caminho de uma ferramenta do LLVM 18 pelo prefixo do build (ex.: llvm-lib).
fn llvm_tool_path(name: &str) -> String {
    match option_env!("LLVM_SYS_180_PREFIX") {
        Some(prefix) => format!("{}/bin/{}", prefix, name),
        None => name.to_string(),
    }
}

/// .def das funções do kernel32 que a runtime freestanding do Windows usa. O
/// llvm-lib gera a import lib MS (sem precisar do Windows SDK nem do mingw).
const WIN_KERNEL32_DEF: &str = "LIBRARY kernel32.dll\nEXPORTS\n\
GetStdHandle\nWriteFile\nReadFile\nCloseHandle\nGetProcessHeap\nHeapAlloc\n\
HeapFree\nHeapReAlloc\nCreateFileW\nSetFilePointerEx\nGetFileAttributesW\n\
GetFileAttributesExW\nDeleteFileW\nMoveFileExW\nCreateDirectoryW\n\
RemoveDirectoryW\nFindFirstFileW\nFindNextFileW\nFindClose\n\
MultiByteToWideChar\nWideCharToMultiByte\nGetCurrentThreadId\nCreateThread\n\
WaitForSingleObject\nSleep\nInitializeCriticalSection\nEnterCriticalSection\n\
LeaveCriticalSection\nDeleteCriticalSection\nInitializeConditionVariable\n\
SleepConditionVariableCS\nWakeConditionVariable\nWakeAllConditionVariable\n\
ExitProcess\n";

/// .def do ws2_32 (sockets). socket/bind/listen/accept/setsockopt são resolvidos
/// direto destes exports; read/write/close usam HANDLEs (kernel32).
const WIN_WS2_32_DEF: &str = "LIBRARY ws2_32.dll\nEXPORTS\n\
WSAStartup\nsocket\nbind\nlisten\naccept\nsetsockopt\nrecv\nsend\nclosesocket\n";

/// "contador" -> "./contador"; caminhos com diretório ficam como estão.
fn local_bin(out_path: &str) -> PathBuf {
    let p = Path::new(out_path);
    if p.is_absolute() || p.components().count() > 1 {
        p.to_path_buf()
    } else {
        Path::new(".").join(p)
    }
}

/// `lex test [dir]` — descobre todos os arquivos *.test.lex (recursivamente,
/// Escapa uma string para um literal JSON (entre aspas, sem as aspas).
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Renderiza um diagnóstico do sema para o terminal: com o trecho do fonte
/// (cabeçalho, sublinhado) quando o erro é do arquivo analisado (module 0) e
/// tem posição; senão, só a mensagem. Spans de módulos importados ou
/// sintéticos (`module != 0`) não têm fonte aqui, então caem na forma simples.
fn render_sema_diag(src: &Source, d: &sema::Diagnostic) -> String {
    if d.span.module == 0 {
        diag::render(src, (d.span.lo, d.span.hi), &d.message, None)
    } else {
        diag::error_line(&d.message)
    }
}

/// Converte o span (offset de char) em linha/coluna 1-based + fim, para o JSON
/// do `lex check --json`. Só os spans do arquivo analisado (module 0) viram
/// posição; o resto cai na linha 0 (aparece no painel de Problemas do editor).
fn span_line_col(src: &Source, span: ast::Span) -> (usize, usize, usize, usize) {
    if span.module != 0 {
        return (0, 0, 0, 1);
    }
    let chars: Vec<char> = src.text.chars().collect();
    let to_lc = |idx: usize| -> (usize, usize) {
        let idx = idx.min(chars.len());
        let mut line = 0usize; // 0-based para o LSP
        let mut col = 0usize;
        for &ch in chars.iter().take(idx) {
            if ch == '\n' {
                line += 1;
                col = 0;
            } else {
                col += 1;
            }
        }
        (line, col)
    };
    let (sl, sc) = to_lc(span.lo);
    let (el, ec) = to_lc(span.hi.max(span.lo + 1));
    (sl, sc, el, ec)
}

/// `lex check [--json] <arquivo.lex>` — roda o front-end (parser + sema) sem
/// gerar código. Sem `--json`, imprime os erros e sai 0/1 (útil em CI). Com
/// `--json`, emite os diagnósticos como um array JSON (consumido pelo `lex lsp`).
/// Um erro de sintaxe ainda é fatal no parser (o processo encerra com a
/// mensagem); por isso os erros de sema (que o sema agrega) é que viram JSON.
fn run_check(args: &[String]) -> ! {
    let mut json = false;
    let mut file: Option<String> = None;
    for a in args {
        match a.as_str() {
            "--json" => json = true,
            s => file = Some(s.to_string()),
        }
    }
    let input = file.unwrap_or_else(|| {
        eprintln!("usage: lex check [--json] <file.lex>");
        std::process::exit(2);
    });
    let source = std::fs::read_to_string(&input)
        .unwrap_or_else(|e| diag::fatal_plain(&format!("could not read {}: {}", input, e)));
    let src = Source::new(input.clone(), source);
    let mut program = parser::parse(lexer::lex(&src), 0, &src);

    let is_test = input.ends_with(".test.lex");
    if is_test {
        program.imports.push(ImportDecl {
            names: ["describe", "it", "test", "expect", "testReport"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            module: "test".to_string(),
        });
    }
    let input_dir = Path::new(&input).parent().unwrap_or(Path::new(".")).to_path_buf();
    let mut link_extras = Vec::new();
    let mut program = load_imports(program, &input_dir, &mut link_extras);

    match sema::check(&mut program) {
        Ok(()) => {
            if json {
                println!("[]");
            } else {
                println!("{}", diag::ok_line(&format!("{}: ok", input)));
            }
            std::process::exit(0);
        }
        Err(errors) => {
            if json {
                // cada diagnóstico vira linha/coluna (do arquivo analisado) —
                // é o que faz o `lex lsp` sublinhar o ponto exato no editor.
                let items: Vec<String> = errors
                    .iter()
                    .map(|e| {
                        let (l, c, el, ec) = span_line_col(&src, e.span);
                        format!(
                            "{{\"line\":{},\"col\":{},\"endLine\":{},\"endCol\":{},\"message\":\"{}\"}}",
                            l, c, el, ec, json_escape(&e.message)
                        )
                    })
                    .collect();
                println!("[{}]", items.join(","));
            } else {
                for e in &errors {
                    eprintln!("{}", render_sema_diag(&src, e));
                }
            }
            std::process::exit(1);
        }
    }
}

/// pulando target/lex_modules/.git/node_modules), compila e roda cada um, e
/// agrega o resultado. Sai com código != 0 se algum arquivo falhar.
fn run_tests(args: &[String]) -> ! {
    let dir = args
        .iter()
        .find(|a| !a.starts_with('-'))
        .map(String::as_str)
        .unwrap_or(".");

    let mut files: Vec<PathBuf> = Vec::new();
    find_test_files(Path::new(dir), &mut files);
    files.sort();

    if files.is_empty() {
        eprintln!("{}", diag::dim_line(&format!("no *.test.lex files found in '{}'", dir)));
        std::process::exit(0);
    }

    let exe = std::env::current_exe().expect("could not locate the lex executable");
    let tmp = std::env::temp_dir();
    let mut failed = 0usize;

    for (i, f) in files.iter().enumerate() {
        println!("{}", diag::dim_line(&format!("── {}", f.display())));
        let bin = tmp.join(format!("lex_test_run_{}", i));
        // compila (o modo teste é detectado pela extensão .test.lex); captura o
        // stdout do compilador para silenciar o "✓ compiled".
        let compiled = Command::new(&exe).arg(f).arg("-o").arg(&bin).output();
        match compiled {
            Ok(out) if out.status.success() => {
                // roda o binário com stdout herdado (mostra o relatório colorido)
                let ran = Command::new(&bin).status();
                let _ = std::fs::remove_file(&bin);
                if !matches!(ran, Ok(s) if s.success()) {
                    failed += 1;
                }
            }
            Ok(out) => {
                failed += 1;
                eprint!("{}", String::from_utf8_lossy(&out.stderr));
                eprintln!("{}", diag::fail_line("  build failed"));
            }
            Err(e) => {
                failed += 1;
                eprintln!("{}", diag::error_line(&format!("could not run the compiler: {}", e)));
            }
        }
    }

    println!();
    let total = files.len();
    let passed = total - failed;
    if failed == 0 {
        println!(
            "{}",
            diag::ok_line(&format!("{} de {} arquivos de teste passaram", passed, total))
        );
        std::process::exit(0);
    }
    eprintln!(
        "{}",
        diag::fail_line(&format!("{} de {} arquivos de teste falharam", failed, total))
    );
    std::process::exit(1);
}

/// Coleta recursivamente os arquivos `*.test.lex` sob `dir`.
fn find_test_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if p.is_dir() {
            if matches!(name.as_str(), "target" | "lex_modules" | ".git" | "node_modules") {
                continue;
            }
            find_test_files(&p, out);
        } else if name.ends_with(".test.lex") {
            out.push(p);
        }
    }
}
