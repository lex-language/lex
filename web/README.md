# lex no wasm — threads reais (Web Workers + memória compartilhada)

Um módulo wasm compilado com `--wasm-threads` usa **memória linear
compartilhada** e atomics: cada `spawn`/`async` do lex vira um **Web Worker**
(uma thread do SO de verdade), e `join`/`await` espera o resultado por um slot
atômico na memória compartilhada. É paralelismo real — não a execução síncrona
do runtime embutido (`wasmi`).

## Rodar (Node)

```sh
# compila com threads (memória compartilhada + atomics)
lex web/demo-threads.lex --target wasm --wasm-threads -o web/demo-threads.wasm

# roda no host de workers (node:worker_threads + SharedArrayBuffer)
node web/threads-host.mjs web/demo-threads.wasm
# => ra=2000 rb=3000 rc=5000 total=10000
```

`threads-host.mjs` cria a `WebAssembly.Memory({ shared: true })`, instancia o
módulo e atende o import `lex.spawn` criando um `Worker` por thread do lex.
`thread-worker.mjs` instancia o MESMO módulo sobre a MESMA memória, ajusta a
pilha da thread (`__stack_pointer`), chama o thunk pelo índice na tabela e
publica o resultado com um `Atomics.notify`.

Comprovação de paralelismo real: 4 workers fazendo 120M iterações cada (480M no
total) terminam em ~0,39s — praticamente o mesmo tempo de 1 worker (~0,37s) numa
máquina de 8 núcleos. Serial levaria ~4×.

## Browser

O mesmo desenho funciona no browser (Web Workers + `SharedArrayBuffer`), mas a
página precisa ser servida com os headers de isolamento cross-origin para
liberar a memória compartilhada:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

O `join` faz busy-wait no slot de status, então no browser rode o `main` do lex
dentro de um Worker (a thread principal do browser não pode bloquear). Em Node a
thread principal pode bloquear, por isso o host roda `main` direto.

## Limitações (conhecidas)

- O ABI do thunk de `spawn`/`join` passa o resultado por um `void*` de 32 bits,
  então resultados > 32 bits truncam no wasm (no nativo são 64 bits). Use
  resultados pequenos (ints/handles) — a mesma limitação do `async`/`await`.
- `Channel<T>` no wasm ainda é uma FIFO single-thread (sem bloqueio entre
  threads). Para paralelismo, use `spawn` + `join` (ou `async`/`await`).
- O módulo com `--wasm-threads` NÃO roda no runtime embutido (`wasmi` não tem
  memória compartilhada/atomics) — use o host de workers (Node/browser).
