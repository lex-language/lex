O Lex resolve um problema bem específico: trazer a ergonomia do TypeScript para linguagens compiladas de baixo nível.

Baseado no projeto:

O problema
TypeScript é familiar (sintaxe elegante, tipagem clara) — mas compila pra JavaScript, que é interpretado, lento e roda em VM.
Rust/C compilam nativamente — mas a sintaxe é pesada (ownership, borrow checker, tipos complexos).
Você quer o melhor dos dois mundos: escrever com a fluidez do TypeScript mas rodar nativo, rápido, sem GC nem runtime.
A solução do Lex
"TypeScript que compila nativo: ints reais, erros checados em compile-time, threads reais, sem GC/runtime/async"

Sintaxe TypeScript-like (function nome(a: i64): i64 {}, const x: i64 = ...)
Compila via LLVM (não transpila — é compilação de verdade pra código de máquina)
Erros como valores (union types : T!, try/catch, fail) — não exceptions que crasham em runtime
Threads reais (via pthread, spawn f())
Inteiros de verdade (i32, i64 — não float disfarçado como em JS)
Zero GC, zero overhead de runtime
É basicamente a resposta ao pedido: "Quero escrever TypeScript nativo com performance de C/Rust" — um AssemblyScript, mas bem feito e com threads.
