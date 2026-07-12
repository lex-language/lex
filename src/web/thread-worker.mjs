// Worker de uma thread do lex (criado por `lex.spawn` em threads-host.mjs).
//
// Instancia o MESMO módulo wasm sobre a MESMA memória compartilhada, ajusta a
// sua pilha, chama o thunk pelo índice na tabela indireta e publica o resultado
// na memória compartilhada (slots `res`/`status`) com um notify atômico para o
// `join` (busy-wait) da thread que o criou.
import { workerData } from "node:worker_threads";

const { module, memory, fnIdx, arg, statusPtr, resPtr, stackTop } = workerData;

const text = (ptr, len) => Buffer.from(memory.buffer, ptr, len).toString("utf8");
const stub0 = () => 0;
const stubNeg = () => -1;

const imports = {
  env: { memory },
  lex: {
    write: (fd, ptr, len) => {
      const s = text(ptr, len);
      if (fd === 2) process.stderr.write(s);
      else process.stdout.write(s);
    },
    // uma thread pode criar outras (spawn aninhado) — mas isto exigiria importar
    // o Worker aqui; para o caso comum (1 nível) deixamos como no-op seguro.
    spawn: () => {},
    fs_read: stub0, fs_write: stubNeg, fs_append: stubNeg, fs_exists: stub0,
    fs_is_file: stub0, fs_is_dir: stub0, fs_size: stubNeg, fs_remove: stubNeg,
    fs_rename: stubNeg, fs_mkdir: stubNeg, fs_rmdir: stubNeg, fs_open: stubNeg,
    fs_list: stub0, fd_read: stub0, fd_write: stubNeg, fd_close: stub0,
    fd_seek: stubNeg,
  },
};

const instance = new WebAssembly.Instance(module, imports);
const ex = instance.exports;

// espera o data-init da thread principal terminar (flag atômico do wasm-ld) e
// dá à thread a sua própria pilha (wasm cresce para baixo: topo = base+tam).
ex.__wasm_init_memory?.();
ex.__stack_pointer.value = stackTop;

// chama o thunk: índice -> função na tabela exportada, recebe o `arg` (ponteiro).
const fn = ex.__indirect_function_table.get(fnIdx);
const res = fn(arg) | 0;

// publica o resultado e sinaliza o `join` (release via Atomics.store + notify).
const dv = new DataView(memory.buffer);
dv.setInt32(resPtr, res, true);
dv.setInt32(resPtr + 4, 0, true);
const i32 = new Int32Array(memory.buffer);
Atomics.store(i32, statusPtr >> 2, 1);
Atomics.notify(i32, statusPtr >> 2);
