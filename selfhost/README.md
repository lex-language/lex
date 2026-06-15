# lex em lex — o caminho até o self-hosting

Meta: levar o lex até o ponto em que **o próprio lex escreve e evolui o
compilador do lex** (bootstrap / self-hosting). O compilador de hoje é escrito
em Rust (`src/`, ~13.5k linhas) e gera LLVM IR via `inkwell`. Aqui reescrevemos
o compilador **em lex**, etapa por etapa, cada uma com testes que rodam no
próprio `lex`.

Ordem de bootstrap: o front-end primeiro (puro `texto → dados`, não precisa de
nada novo no compilador), depois as primitivas de host, depois o backend.

## Fases

- [x] **F1 — Lexer** (`lexer.lex`): fonte → tokens. Cobre espaços/quebras,
      comentários de linha, strings com escapes, números (int/float com valor
      via `parseFloat`), identificadores + todas as palavras-chave, e toda a
      pontuação/operadores. Testado em `lexer.test.lex` (`lex test selfhost`).
      Pendência marcada no arquivo: template literals e JSX (scan ingênuo por ora).
- [x] **Correções de linguagem** (no compilador Rust) que o front-end exigiu:
      - `else if` (antes o `else` exigia bloco) — `src/parser.rs`.
      - `parseFloat(s): f64` builtin — `src/builtins.rs` + `src/runtime.c`
        (parser de double próprio, vale em todos os alvos) + `src/codegen.rs`.
      - PENDENTE: `expect`/`any` estruturar arrays NÃO-literais (hoje viram
        ponteiro-número; comparamos elemento a elemento) — `gen_box_value`.
- [~] **F2 — Parser** (`parser.lex`): tokens → AST. AST = hierarquia de `class`
      (nó base `Expr`/`Stmt` + subclasses), percorrida com `match` por padrão de
      tipo. Testado em `parser.test.lex` (42 asserções) comparando a AST renderizada
      como S-expression. FEITO:
      - Expressões: escada de precedência completa (precedence climbing), unários,
        parênteses, chamadas, array literal, pós-fixos (`.campo`/`.metodo()`/`[i]`).
      - Statements: let/const (c/ tipo), atribuição (var/campo/índice), return,
        if/else/else-if, while, break, continue, expr-statement — newlines invisíveis
        (multilinha funciona), igual a src/parser.rs.
      - Declaração de função: `fn nome(p: T, …): R[!] { corpo }`.
      Falta: for/for-of, defer/fail, compound assign; demais expressões
      (match/try/catch/spawn/await/new/struct/map/template/arrow); demais
      declarações de topo (class/type/enum/interface/import/declare) + parseProgram.
- [~] **F3 — Sema**: MÍNIMA por ora — o subset do backend não exige checagem de
      tipos (tudo é i64). Uma `sema.lex` completa (tipos, falibilidade forçada,
      resolução de nomes, espelhando `src/sema.rs`) é a próxima fase para cobrir
      a linguagem inteira.
- [x] **F4 — Primitivas de host** (no compilador Rust): builtins que o
      compilador-em-lex precisa pra ser uma ferramenta de CLI de verdade:
      - `args(): string[]` — argumentos de linha de comando (capturados via um
        construtor do `.init_array`, já que o `main` do lex não recebe argv) — `src/runtime.c`.
      - `system(cmd): i64` — dispara o clang/linker (libc no host).
      - `parseFloat(s): f64` — valor de literais float.
- [x] **F5 — Backend** (`codegen.lex`): emite **LLVM IR textual** (`.ll`) e chama
      o `clang` pra montar+linkar — sem `inkwell`, mantendo "compila direto pra
      LLVM IR". Estratégia alloca/load/store (sem phi à mão). Testado em
      `codegen.test.lex` (18 asserções, fragmentos do IR) e **`e2e.test.lex`**
      (7 asserções) que COMPILA E RODA o binário nativo conferindo o exit code.
      Subset: funções i64, let/const, atribuição a variável, return, if/else/else-if,
      while, break/continue, expr-stmt; expressões int/bool/var, `+ - * / %`,
      `== != < > <= >=`, **bitwise `& | ^ << >>`**, **lógicos `&& ||`** (sem
      curto-circuito), unários `- ! ~`, chamadas, **`print(x)`** (emite `printf`
      → saída de verdade); `main(): i32` vira exit code.
      TODO no backend: float/string/array/struct/class, curto-circuito em `&&`/`||`, for.
- [x] **Driver** (`lexc.lex`): o compilador self-hosted de ponta a ponta —
      `lexc <entrada.lex> [saida]` lê o fonte, gera o `.ll` e chama o clang.
      PROVADO: compilou `fib`/`while`/aritmética para binários nativos que rodam
      com o exit code correto, tudo dirigido pelo próprio lex.
- [x] **Interpretador** (`interp.lex` + driver `lexi.lex`): a alternativa que
      **pula o clang E o LLVM por completo** — em vez de gerar IR, anda na AST e
      executa direto, em lex puro. Mesmo subset do codegen. Roda sem nenhuma
      ferramenta externa (verificado até com `PATH=/usr/bin`). Testado em
      `interp.test.lex` (9 asserções: fib, soma 1..100, bitwise, lógicos,
      break/continue). Para gerar binário NATIVO ainda é preciso um
      assembler+linker (clang, ou `llc`+`ld.lld`) — isso é inerente; até o
      compilador lex de produção usa o clang como linker.
- [~] **F6 — Bootstrap completo**: o compilador-em-lex compilar o SEU PRÓPRIO
      fonte ainda não — exige o backend cobrir toda a linguagem que o compilador
      usa (classes/métodos, strings, arrays, Map, `match`, templates, genéricos,
      builtins, imports). A ARQUITETURA está provada de ponta a ponta sobre um
      subset; o que falta é ampliar a cobertura do front-end→backend até abraçar
      o próprio `selfhost/*.lex`.

## Como rodar

```sh
lex test selfhost                       # toda a suíte (lexer, parser, codegen, interp, e2e)

cat > /tmp/p.lex <<'EOF'
fn fib(n: i64): i64 { if (n < 2) { return n } return fib(n-1) + fib(n-2) }
fn main(): i64 { print(fib(10)) return fib(10) }
EOF

# (A) COMPILAR para binário nativo (usa clang como linker):
lex selfhost/lexc.lex -o /tmp/lexc
/tmp/lexc /tmp/p.lex /tmp/p && /tmp/p; echo $?      # imprime 55, exit 55

# (B) INTERPRETAR, sem clang nem LLVM (lex puro):
lex selfhost/lexi.lex -o /tmp/lexi
/tmp/lexi /tmp/p.lex; echo $?                       # imprime 55, exit 55
```

## Estado

Front-end + dois back-ends em lex: ~1900 linhas, **137 asserções verdes**.
Dois caminhos de execução, ambos sobre o próprio `lex`:
- **Nativo** — `fonte → tokens → AST → LLVM IR → clang → binário`. Programas
  compilados imprimem (`print` → `printf`).
- **Interpretado** — `fonte → tokens → AST → executa direto`, **sem clang/LLVM**.

Falta ampliar a cobertura da linguagem (float/string/array/class/…) rumo ao
bootstrap total (F6).
