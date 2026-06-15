// Host de WORKERS para os módulos wasm do lex compilados com `--wasm-threads`.
//
// Roda um .wasm de memória COMPARTILHADA: cada `spawn` do lex chama o import
// `lex.spawn`, que aqui cria um Web Worker (node:worker_threads) instanciando o
// MESMO módulo sobre a MESMA WebAssembly.Memory compartilhada. O worker ajusta a
// sua própria pilha (`__stack_pointer`), chama o thunk pelo índice na tabela e
// escreve o resultado + o "done" na memória compartilhada; o `join` do lex faz
// busy-wait atômico nesse slot. É paralelismo de verdade (threads do SO).
//
//   lex prog.lex --target wasm --wasm-threads -o prog.wasm
//   node web/threads-host.mjs prog.wasm
//
// Em browser vale o mesmo desenho (Web Workers + SharedArrayBuffer), mas a
// página precisa dos headers COOP/COEP para liberar a memória compartilhada.
import { readFileSync } from "node:fs";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";

const file = process.argv[2];
if (!file) {
  console.error("uso: node web/threads-host.mjs <arquivo.wasm>");
  process.exit(2);
}

const bytes = readFileSync(file);
const module = new WebAssembly.Module(bytes);

// Memória compartilhada entre a thread principal e todos os workers. O máximo
// casa com o `--max-memory` do link (256 MiB = 4096 páginas de 64 KiB).
const memory = new WebAssembly.Memory({ initial: 512, maximum: 4096, shared: true });

const workerFile = fileURLToPath(new URL("./thread-worker.mjs", import.meta.url));

// imports `lex.*` para a thread principal. Os `fs_*`/`fd_*` são stubs (este host
// foca em threads); `write` imprime; `spawn` cria um worker por thread do lex.
function makeImports(memory) {
  const text = (ptr, len) =>
    Buffer.from(memory.buffer, ptr, len).toString("utf8");
  const stub0 = () => 0;
  const stubNeg = () => -1;
  return {
    env: { memory },
    lex: {
      write: (fd, ptr, len) => {
        const s = text(ptr, len);
        if (fd === 2) process.stderr.write(s);
        else process.stdout.write(s);
      },
      spawn: (fnIdx, arg, statusPtr, resPtr, stackTop) => {
        // cria a thread: o worker recebe tudo por workerData (clone estruturado
        // de Module + Memory compartilhada), então roda sem depender do event
        // loop da thread principal (que fica em busy-wait no `join`).
        new Worker(workerFile, {
          workerData: { module, memory, fnIdx, arg, statusPtr, resPtr, stackTop },
        }).unref();
      },
      // filesystem: não implementado neste host de threads (stubs seguros)
      fs_read: stub0, fs_write: stubNeg, fs_append: stubNeg, fs_exists: stub0,
      fs_is_file: stub0, fs_is_dir: stub0, fs_size: stubNeg, fs_remove: stubNeg,
      fs_rename: stubNeg, fs_mkdir: stubNeg, fs_rmdir: stubNeg, fs_open: stubNeg,
      fs_list: stub0, fd_read: stub0, fd_write: stubNeg, fd_close: stub0,
      fd_seek: stubNeg,
    },
  };
}

const instance = new WebAssembly.Instance(module, makeImports(memory));
const ex = instance.exports;

// inicializa os data segments passivos NA memória compartilhada (vtables, etc.).
// Guardado por um flag atômico do próprio wasm-ld → roda uma única vez.
ex.__wasm_init_memory?.();
ex.__wasm_call_ctors?.();

const code = ex.main();
// pequena folga para o stdout dos workers/print esvaziar antes de sair
process.exitCode = code | 0;
