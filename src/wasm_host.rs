// wasm_host.rs — host nativo para módulos wasm do lex, sem Node.
//
// A runtime wasm do lex é freestanding: tudo o que toca o "mundo" passa por
// imports no namespace `lex.*` (ver runtime.c e web/lex-host.js). Este módulo
// embute um interpretador wasm (wasmi, 100% Rust) e atende esses imports
// diretamente contra o filesystem real, para que
//
//     lex programa.lex --target wasm --run
//
// rode o .wasm sem nenhuma ferramenta externa. É a contraparte Rust do
// web/lex-host.js: mesma superfície de imports, mesma semântica.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use wasmi::{Caller, Engine, Extern, Linker, Memory, Module, Store, Val, ValType};

/// Valor zero do tipo dado (para preencher params/results na chamada dinâmica).
fn zero_val(t: &ValType) -> Val {
    match t {
        ValType::I32 => Val::I32(0),
        ValType::I64 => Val::I64(0),
        ValType::F32 => Val::F32(0.0f32.into()),
        ValType::F64 => Val::F64(0.0f64.into()),
        _ => Val::I32(0),
    }
}

/// Estado do host: tabela de file descriptors abertos por `fs_open`. Os fds
/// 0/1/2 (stdin/stdout/stderr) não passam por aqui — `lex.write` cuida da
/// saída. `next_fd` começa em 3 para não colidir com eles.
struct Host {
    files: HashMap<i64, std::fs::File>,
    next_fd: i64,
}

impl Host {
    fn new() -> Self {
        Host { files: HashMap::new(), next_fd: 3 }
    }
}

/// Pega a memória linear exportada pelo módulo (`memory`).
fn memory(caller: &mut Caller<'_, Host>) -> Memory {
    match caller.get_export("memory") {
        Some(Extern::Memory(m)) => m,
        _ => panic!("wasm module does not export 'memory'"),
    }
}

/// Lê uma string C (UTF-8, terminada em NUL) a partir de `ptr`.
fn read_cstr(caller: &mut Caller<'_, Host>, ptr: i32) -> String {
    let mem = memory(caller);
    let data = mem.data(&*caller);
    let start = ptr as usize;
    let mut end = start;
    while end < data.len() && data[end] != 0 {
        end += 1;
    }
    String::from_utf8_lossy(&data[start..end]).into_owned()
}

/// Lê `len` bytes brutos a partir de `ptr`.
fn read_bytes(caller: &mut Caller<'_, Host>, ptr: i32, len: usize) -> Vec<u8> {
    let mem = memory(caller);
    let data = mem.data(&*caller);
    let start = ptr as usize;
    let end = (start + len).min(data.len());
    data[start..end].to_vec()
}

/// Reserva `n` bytes na arena do wasm chamando `__lex_wasm_alloc` e devolve o
/// ponteiro (offset na memória linear). 0 em falha.
fn wasm_alloc(caller: &mut Caller<'_, Host>, n: usize) -> i32 {
    let alloc = match caller.get_export("__lex_wasm_alloc") {
        Some(Extern::Func(f)) => f,
        _ => return 0,
    };
    let typed = match alloc.typed::<i64, i32>(&*caller) {
        Ok(t) => t,
        Err(_) => return 0,
    };
    typed.call(&mut *caller, n.max(1) as i64).unwrap_or(0)
}

/// Grava `bytes` na memória a partir de `ptr` (assume espaço já reservado).
fn write_mem(caller: &mut Caller<'_, Host>, ptr: i32, bytes: &[u8]) {
    let mem = memory(caller);
    let _ = mem.write(&mut *caller, ptr as usize, bytes);
}

/// Aloca `bytes` na arena, copia e termina com NUL; devolve o ptr (0 se vazio).
fn alloc_with_nul(caller: &mut Caller<'_, Host>, bytes: &[u8]) -> i32 {
    let p = wasm_alloc(caller, bytes.len() + 1);
    if p == 0 {
        return 0;
    }
    write_mem(caller, p, bytes);
    write_mem(caller, p + bytes.len() as i32, &[0]);
    p
}

/// Registra todos os imports `lex.*` no linker. Espelha web/lex-host.js.
fn define_imports(linker: &mut Linker<Host>) -> Result<(), wasmi::Error> {
    // --- saída: lex.write(fd, ptr, len) -> void --------------------------
    linker.func_wrap("lex", "write", |mut caller: Caller<'_, Host>, fd: i32, ptr: i32, len: i32| {
        let bytes = read_bytes(&mut caller, ptr, len.max(0) as usize);
        if fd == 2 {
            let _ = std::io::stderr().write_all(&bytes);
            let _ = std::io::stderr().flush();
        } else {
            let _ = std::io::stdout().write_all(&bytes);
            let _ = std::io::stdout().flush();
        }
    })?;

    // --- filesystem por caminho ------------------------------------------
    linker.func_wrap("lex", "fs_read", |mut caller: Caller<'_, Host>, path_ptr: i32| -> i32 {
        let path = read_cstr(&mut caller, path_ptr);
        match std::fs::read(&path) {
            Ok(data) => alloc_with_nul(&mut caller, &data),
            Err(_) => 0,
        }
    })?;
    linker.func_wrap(
        "lex",
        "fs_write",
        |mut caller: Caller<'_, Host>, path_ptr: i32, data_ptr: i32, n: i64| -> i64 {
            let path = read_cstr(&mut caller, path_ptr);
            let data = read_bytes(&mut caller, data_ptr, n.max(0) as usize);
            match std::fs::write(&path, &data) {
                Ok(()) => data.len() as i64,
                Err(_) => -1,
            }
        },
    )?;
    linker.func_wrap(
        "lex",
        "fs_append",
        |mut caller: Caller<'_, Host>, path_ptr: i32, data_ptr: i32, n: i64| -> i64 {
            let path = read_cstr(&mut caller, path_ptr);
            let data = read_bytes(&mut caller, data_ptr, n.max(0) as usize);
            let res = std::fs::OpenOptions::new().create(true).append(true).open(&path);
            match res.and_then(|mut f| f.write_all(&data)) {
                Ok(()) => data.len() as i64,
                Err(_) => -1,
            }
        },
    )?;
    linker.func_wrap("lex", "fs_exists", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        i64::from(Path::new(&read_cstr(&mut caller, p)).exists())
    })?;
    linker.func_wrap("lex", "fs_is_file", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        i64::from(Path::new(&read_cstr(&mut caller, p)).is_file())
    })?;
    linker.func_wrap("lex", "fs_is_dir", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        i64::from(Path::new(&read_cstr(&mut caller, p)).is_dir())
    })?;
    linker.func_wrap("lex", "fs_size", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        let path = read_cstr(&mut caller, p);
        match std::fs::metadata(&path) {
            Ok(m) => m.len() as i64,
            Err(_) => -1,
        }
    })?;
    linker.func_wrap("lex", "fs_remove", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        -i64::from(std::fs::remove_file(read_cstr(&mut caller, p)).is_err())
    })?;
    linker.func_wrap("lex", "fs_rename", |mut caller: Caller<'_, Host>, a: i32, b: i32| -> i64 {
        let from = read_cstr(&mut caller, a);
        let to = read_cstr(&mut caller, b);
        -i64::from(std::fs::rename(from, to).is_err())
    })?;
    linker.func_wrap("lex", "fs_mkdir", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        -i64::from(std::fs::create_dir(read_cstr(&mut caller, p)).is_err())
    })?;
    linker.func_wrap("lex", "fs_rmdir", |mut caller: Caller<'_, Host>, p: i32| -> i64 {
        -i64::from(std::fs::remove_dir(read_cstr(&mut caller, p)).is_err())
    })?;
    linker.func_wrap("lex", "fs_list", |mut caller: Caller<'_, Host>, path_ptr: i32| -> i32 {
        let path = read_cstr(&mut caller, path_ptr);
        let names: Vec<String> = match std::fs::read_dir(&path) {
            Ok(rd) => rd.filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned())).collect(),
            Err(_) => Vec::new(),
        };
        alloc_with_nul(&mut caller, names.join("\n").as_bytes())
    })?;
    linker.func_wrap("lex", "fs_open", |mut caller: Caller<'_, Host>, path_ptr: i32, mode: i64| -> i64 {
        let path = read_cstr(&mut caller, path_ptr);
        // mode: 1 = write (trunc), 2 = append, outro = read
        let opened = match mode {
            1 => std::fs::OpenOptions::new().write(true).create(true).truncate(true).open(&path),
            2 => std::fs::OpenOptions::new().append(true).create(true).open(&path),
            _ => std::fs::OpenOptions::new().read(true).open(&path),
        };
        match opened {
            Ok(f) => {
                let st = caller.data_mut();
                let fd = st.next_fd;
                st.next_fd += 1;
                st.files.insert(fd, f);
                fd
            }
            Err(_) => -1,
        }
    })?;

    // --- filesystem por fd (streaming) -----------------------------------
    linker.func_wrap(
        "lex",
        "fd_read",
        |mut caller: Caller<'_, Host>, fd: i64, buf_ptr: i32, n: i64| -> i64 {
            let n = n.max(0) as usize;
            let mut buf = vec![0u8; n];
            let read = {
                let st = caller.data_mut();
                match st.files.get_mut(&fd) {
                    Some(f) => f.read(&mut buf).unwrap_or(0),
                    None => return 0,
                }
            };
            if read == 0 {
                return 0;
            }
            write_mem(&mut caller, buf_ptr, &buf[..read]);
            read as i64
        },
    )?;
    linker.func_wrap(
        "lex",
        "fd_write",
        |mut caller: Caller<'_, Host>, fd: i64, buf_ptr: i32, n: i64| -> i64 {
            let data = read_bytes(&mut caller, buf_ptr, n.max(0) as usize);
            // fds padrão caem na saída do processo, como no node-host
            if fd == 1 {
                return std::io::stdout().write(&data).map(|w| w as i64).unwrap_or(-1);
            }
            if fd == 2 {
                return std::io::stderr().write(&data).map(|w| w as i64).unwrap_or(-1);
            }
            let st = caller.data_mut();
            match st.files.get_mut(&fd) {
                Some(f) => f.write(&data).map(|w| w as i64).unwrap_or(-1),
                None => -1,
            }
        },
    )?;
    linker.func_wrap("lex", "fd_close", |mut caller: Caller<'_, Host>, fd: i64| -> i64 {
        -i64::from(caller.data_mut().files.remove(&fd).is_none())
    })?;
    linker.func_wrap(
        "lex",
        "fd_seek",
        |mut caller: Caller<'_, Host>, fd: i64, off: i64, whence: i64| -> i64 {
            // whence: 0 = início, 1 = atual, 2 = fim (estilo lseek)
            let pos = match whence {
                1 => SeekFrom::Current(off),
                2 => SeekFrom::End(off),
                _ => SeekFrom::Start(off.max(0) as u64),
            };
            let st = caller.data_mut();
            match st.files.get_mut(&fd) {
                Some(f) => f.seek(pos).map(|p| p as i64).unwrap_or(-1),
                None => -1,
            }
        },
    )?;

    Ok(())
}

/// Carrega e roda um `.wasm` do lex, devolvendo o exit code do `main()`.
pub fn run_wasm(path: &Path) -> Result<i32, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("could not read {}: {}", path.display(), e))?;

    let engine = Engine::default();
    let module = Module::new(&engine, &bytes[..]).map_err(|e| format!("invalid wasm module: {}", e))?;

    let mut store = Store::new(&engine, Host::new());
    let mut linker = <Linker<Host>>::new(&engine);
    define_imports(&mut linker).map_err(|e| format!("failed to define host imports: {}", e))?;

    let instance = linker
        .instantiate_and_start(&mut store, &module)
        .map_err(|e| format!("failed to instantiate wasm: {}", e))?;

    let main = instance
        .get_func(&store, "main")
        .ok_or_else(|| "wasm module does not export 'main'".to_string())?;

    // main pode ter assinaturas diferentes conforme o link: `() -> i32`, ou o
    // estilo C `(argc: i32, argv: i32) -> i32`. Montamos os inputs a partir dos
    // tipos declarados (zerados: 0 args, argv nulo) e tratamos retorno i32/void.
    let ty = main.ty(&store);
    let inputs: Vec<Val> = ty.params().iter().map(zero_val).collect();
    let mut results: Vec<Val> = ty.results().iter().map(zero_val).collect();
    main.call(&mut store, &inputs, &mut results)
        .map_err(|e| format!("wasm trapped: {}", e))?;

    let code = match results.first() {
        Some(Val::I32(c)) => *c,
        Some(Val::I64(c)) => *c as i32,
        _ => 0,
    };
    Ok(code)
}
