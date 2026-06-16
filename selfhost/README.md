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
- [x] **F2 — Parser** (`parser.lex`) = **F6.1**: tokens → AST. AST = hierarquia de
      `class` (nó base `Expr`/`Stmt` + subclasses), percorrida com `match` por
      padrão de tipo. Testado em `parser.test.lex` (62 asserções) comparando a AST
      renderizada como S-expression. **Cobre todo o subset que o próprio
      `selfhost/*.lex` usa** (verificado: `parseModule` consome lexer/parser/codegen/
      interp/lexc/lexi até o `Eof`, sem dessincronizar):
      - Expressões: escada de precedência (precedence climbing), unários, chamadas,
        array literal, pós-fixos (`.campo`/`.metodo()`/`[i]`), `new C(args)`,
        `match` por tipo, template literals `...${}...`, map `{}`/struct literal.
      - Statements: let/const (c/ tipo), atribuição (var/campo/índice), return,
        if/else/else-if, while, **for-of**, **for C-style**, break, continue,
        expr-statement — newlines invisíveis (multilinha funciona).
      - Topo: `fn`, `class` (extends/constructor/campos/métodos), `enum`, `import`;
        statements de topo viram `main` (script-mode). `parseModule(): Program`.
      Falta (não usado pelo compilador): defer/fail, compound assign, try/catch/
      spawn/await/arrow, e type/interface/declare no topo.
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
- [~] **F6 — Remoção completa do Rust**: **compilador-core BOOTSTRAPADO** ✅ — o
      compilador-em-lex compila o seu próprio fonte e é estável (ponto-fixo, ver
      `selfhost/bootstrap.sh`). F6.1–F6.6 feitas: parser, sema (classes+tipos),
      codegen (dados+host+classes+match), módulos e bootstrap. **Falta** portar o
      resto do CLI (F6.7–F6.11: fmt, pkg, LSP, wasm/cross-compile, JSON/watch) pra
      aposentar o `src/` inteiro. **Plano completo na seção
      [F6 — Remoção completa do Rust](#f6--remoção-completa-do-rust) no fim.**

## Como rodar

```sh
lex test selfhost                       # toda a suíte (lexer, parser, sema, codegen, interp, e2e)
./selfhost/bootstrap.sh                 # prova o self-hosting (ponto-fixo de 3 estágios)

cat > /tmp/p.lex <<'EOF'
fn fib(n: i64): i64 { if (n < 2) { return n } return fib(n-1) + fib(n-2) }
fn main(): i64 { print(fib(10)) return fib(10) }
EOF

# (A) COMPILAR para binário nativo (usa clang como linker):
lex selfhost/lexc.lex -o /tmp/lexc
/tmp/lexc /tmp/p.lex /tmp/p && /tmp/p; echo $?      # imprime 55, exit 55

# o lexc self-hosted compila o PRÓPRIO compilador (e o resultado roda):
/tmp/lexc selfhost/lexc.lex /tmp/lexc1 && /tmp/lexc1 /tmp/p.lex /tmp/p && /tmp/p; echo $?

# (B) INTERPRETAR, sem clang nem LLVM (lex puro):
lex selfhost/lexi.lex -o /tmp/lexi
/tmp/lexi /tmp/p.lex; echo $?                       # imprime 55, exit 55
```

## Estado

Compilador-core **BOOTSTRAPADO** ✅ — front-end + sema estrutural + codegen
completo + loader de módulos + fmt + TOML/semver + pkg(manifesto) + JSON + diag
+ **`lex` unificado** (`lexcli`: build/run/fmt/test/check/lsp/pkg/version +
`--target`/`--watch`, num binário só) em lex: ~5500 linhas, **306 asserções** +
ponto-fixo (`bootstrap.sh`) + **semente stage0** (`seed.sh`: o lex em lex faz o
fluxo e se reconstrói SEM Rust). Caminhos:
- **Self-hosting** — `lexc` (em lex) compila `selfhost/lexc.lex` (a si mesmo) e o
  IR é estável entre estágios (`lexc1.ll == lexc2.ll`). O Rust não é mais
  necessário pra buildar o compilador-core.
- **Nativo** — `fonte → tokens → AST → sema → LLVM IR → clang+runtime.c → binário`.
- **Interpretado** — `fonte → tokens → AST → executa direto`, **sem clang/LLVM**.

Falta portar o resto do CLI (F6.7–F6.11) pra aposentar o `src/` inteiro — ver **F6**.

## F6 — Remoção completa do Rust

Meta final: o `src/` em Rust deixa de ser necessário pra construir e evoluir o
lex. Dois insights cortam o esforço:

1. **O runtime C (`src/runtime.c`, ~107KB) é REÚSO, não reescrita.** Ele já
   exporta tudo que o compilador-em-lex precisa — o backend só tem que **emitir
   chamadas** e **linkar o `runtime.c` via clang** (igual o compilador Rust faz
   hoje: `clang out.ll runtime.c -lpthread`). Funções-chave: `__lex_concat`,
   `__lex_strlen`, `__lex_str_eq`, `__lex_substring`, `__lex_i64_to_str`,
   `__lex_f64_to_str`, `__lex_parse_float`; `__lex_arr_new/push/get/set/len/pop`;
   `__lex_map_new/set/get`; `__lex_alloc` (objeto = slot 0 vtable + campos i64);
   `__lex_args`, `__lex_system`, `__lex_fs_read/write`. "Remover Rust" ≠ "remover
   C": o runtime continua C, compilado pelo clang, exatamente como na produção.

2. **O alvo do bootstrap é só o que `selfhost/*.lex` USA pra compilar a si
   mesmo** — não a linguagem inteira. O fonte do compilador **NÃO usa** (e
   portanto fica fora do escopo): `try/catch/defer/fail`, `type` aliases,
   `interface`, struct literals, arrow functions, ternário, optional chaining,
   compound assignment (`+=`), `super`, generics aninhados. **USA**: classes
   (`extends`/`constructor`/campos/métodos/`this`), `match` por tipo, strings,
   arrays `T[]`, `Map<i64>`, template literals, `for-of`, `enum`, `import`,
   `new`, e os builtins de host.

### O que "bootstrap" significa aqui

O binário `lexc` (compilador-em-lex) já existe — o `lex` (Rust) compila
`lexc.lex` hoje. O problema é que `lexc` só gera o subset, então `lexc lexc.lex`
falha. O bootstrap fecha quando `lexc` compila o próprio fonte, validado por
**ponto-fixo de 3 estágios**:

```
lex   lexc.lex  ->  lexc0        # seed, compilado pelo Rust
lexc0 lexc.lex  ->  lexc1        # 1º self-compile
lexc1 lexc.lex  ->  lexc2        # 2º self-compile
assert lexc1 == lexc2            # byte a byte: ponto-fixo alcançado
```

### Etapas (ordem por dependência + cobertura/esforço)

Cada etapa tem um **portão de validação** que precisa passar antes da próxima.

- [x] **F6.1 — Parser completo** (`parser.lex`) — `class`/`extends`/
      `constructor`/métodos/campos, `enum`, `import`, `match` expr, template
      literals, `for-of`, `for` C-style, `Map<>`, `new`, map/array literal,
      script-mode (`main` sintetizado). Puro `texto→dados`, sem runtime.
      *Portão OK*: 62 asserções verdes + `parseModule` consome todos os
      `selfhost/*.lex` até o `Eof` sem dessincronizar.
- [~] **F6.2 — Sema estrutural** (`sema.lex`, novo) — NÃO é checador de tipos
      completo; só o esqueleto que o codegen exige. Destrava F6.3 e F6.4.
      - [x] **Tabela de classes** (`ClassTable`): por classe, campos com slot
        (slot 0 = vtable, herança põe campos do pai primeiro), vtable método→índice
        com override no lugar, classe-pai, e **tag única p/ `match` por tipo**.
        `enum`→i64 (`EnumTable`). *Portão OK*: 13 asserções + dump conferido nas
        classes reais (Token, hierarquia Expr/Stmt, Parser/Codegen/Interp).
      - [x] **Inferência de tipo grosseira** por expressão `{i64,f64,string,bool,
        array `T[]`, `Map<V>`, Classe, `?`}` — `Sema.typeOf(expr, scope)` com `Scope`
        (var/param/campo/`this`), assinaturas de função/método e builtins. *Portão
        OK*: 24 asserções + smoke em código real (`toks[m-1].kind`→`Tok`,
        `toks.len()`→`i64`, `peek8(src,i)`→`i64` sobre `lexer.lex`).
      - [x] **Resolução de imports** (tipos/classes cross-módulo) — resolvida pelo
        merge de módulos da F6.5 (a `Sema` vê o `Program` combinado).
- [x] **F6.3 — Codegen de dados + host** (`codegen.lex`, `lexc.lex`) — codegen
      agora é **dirigido pela Sema** (`typeOf` escolhe a chamada de runtime):
      strings (literais como globais de bytes, `concat`/`strEq`/`substring`/`charAt`/
      `str`/`parseInt`/`parseFloat`/`peek8`/`len`), arrays `T[]` (literal/`.push`/
      `.pop`/`.len`/`xs[i]`/`xs[i]=v`), `Map` (`{}`, `m[k]`/`m[k]=v`, mapGet/Set),
      template→cadeia de `__lex_concat`+`i64_to_str`/`f64_to_str`, `f64` literal
      (bitcast), host `Terminal.log`/`readFile`/`writeFile`/`system`/`args`. `lexc.lex`
      **linka `src/runtime.c`**. *Portão OK*: 16 asserções e2e que COMPILAM+RODAM
      binário nativo (concat imprime "hello world", soma de array=10, map=20,
      template="lex tem 3 letras", …) + driver `lexc` compilou/rodou um programa
      com array/string de ponta a ponta. TODO: aritmética `f64`, curto-circuito, `for`.
- [ ] **F6.4 — Codegen de classes/métodos/`match`** (`codegen.lex`) — alocação
      de objeto (`__lex_alloc`, slot 0 = vtable, campos via GEP), `new`,
      load/store de campo, dispatch por vtable, `match`-por-tipo (compara tag/
      vtable). É o **keystone**: aqui as estruturas do próprio compilador
      (`Token`/`Expr`/AST) passam a compilar. *Portão*: compilar um mini-AST
      com herança + `match` e rodar.
- [x] **F6.5 — Módulos + driver** (`modloader.lex`, `lexc.lex`) — `ModuleLoader`
      segue os `import` (recursivo, dedup por caminho), resolve caminhos relativos
      e faz o merge num único `Program`; `compileFileToIR(entrada)`. `lexc.lex` usa
      o loader e linka `src/runtime.c`. *Portão OK*: import de classe entre arquivos
      compila+roda (e2e) + o próprio compilador (5 módulos) compila como uma unidade.
- [x] **F6.6 — Bootstrap completo** — o compilador-em-lex compila o SEU PRÓPRIO
      fonte e o resultado é estável. *Portão OK* (`selfhost/bootstrap.sh`): stage0
      (Rust) → lexc0; lexc1 = lexc0 compilando lexc.lex; lexc2 = lexc1 compilando
      lexc.lex; **`lexc1.ll == lexc2.ll` byte a byte** (ponto-fixo, ~15,7k linhas de
      IR). **O Rust não é mais necessário pra buildar o compilador-core** — basta
      guardar um `lexc` stage0. (Bugs achados/corrigidos no caminho: alloca de
      locais hoistada pro entry — nomes SSA únicos; sem rótulo `entry:` — colidia
      com o param `entry`; `args()`→`__lex_args`.)

### Depois do compilador: o resto do CLI

F6.1–F6.6 entregam o **compilador-core**. Mas o binário `lex` Rust faz mais — pra
deletar o `src/` *de verdade*, falta portar (cada um é uma frente própria, bem
maior que o core, mas todas já em cima de um lex self-hosted). Atividades:

**F6.7 — `fmt`** ✅ FEITO (`fmt.lex` + `lexfmt.lex`, espelha `src/fmt.rs`):

- [x] Driver `lexfmt [--check] <arquivos>` (in-place ou `--check`); só `.lex`.
- [x] Indentação por contagem de delimitadores (`{[(`→+1, `}])`→−1), 4 espaços;
      fechadores iniciais "puxam pra esquerda".
- [x] Pula interior de strings `"…"`/`'…'` (com escapes) e do `//` em diante.
- [x] Preserva template literals multilinha (espaço é texto) intactos.
- [x] Remove trailing whitespace; colapsa linhas em branco em ≤1; um `\n` no EOF.
- [x] *Portão OK*: 10 asserções (`fmt.test.lex`) + **saída byte-idêntica ao
      `lex fmt` do Rust** num arquivo desformatado + idempotência.

**F6.8 — Gerenciador de pacotes** (`src/pkg.rs`, ~38KB; toda rede via `git`/`curl`)
— **fundações prontas** (`toml.lex`, `semver.lex`); falta o wiring dos comandos:

- [x] **TOML** em lex (`toml.lex`): parse/serialize de tabelas `[t]`, array-de-tabelas
      `[[t]]`, `chave = "string"` e listas `["a","b"]` — cobre `lex.toml`/`lex.lock`.
      16 asserções (`toml.test.lex`) incl. round-trip.
- [x] **Semver** em lex (`semver.lex`): `parseSemVer`/`cmpSemVer` + `VersionReq`
      (`^ ~ >= > <= < = *`, bare=caret) + `semverPickBest` (maior que casa).
      23 asserções (`semver.test.lex`).
- [x] **Parse de spec** (`pkg.lex`): registry (`nome@^1.2.0`), git direto
      (`github.com/u/r@ref`, `git@host:...`), local (`file:../path`) + normalização
      de URL. 25 asserções (`pkg.test.lex`).
- [x] **Comandos de manifesto** (`lexpkg.lex`): `init`/`add`/`remove`/`list` —
      criam/editam/leem `lex.toml` de verdade (TOML round-trip). *Smoke OK*:
      `init demo` + `add cores@^1.2.0` + `add github.com/u/http` + `list` + `remove`.
- [ ] `install`/`update`/`registry`/`publish` (driver + lógica de rede).
- [ ] Lockfile `lex.lock` end-to-end: `commit` via `git rev-parse HEAD`.
- [ ] Fetch git: `git ls-remote --tags`, `clone --depth 1 --branch <tag>`,
      `rev-parse HEAD`, `checkout <commit>`; remover `.git` depois.
- [ ] Resolução transitiva (loop até estabilizar) + `prune_orphans` (BFS de
      alcançabilidade a partir das deps diretas). Sem backtracking (first-win).
- [ ] Fontes: índice git em `~/.lex/registry` (lê `packages/<nome>.toml`) **ou**
      API HTTP (`GET {api}/api/pkg/<nome>`); armazenar em `lex_modules/` (flat).
- [ ] `publish`: infere repo (arg/`git remote get-url origin`), `POST {api}/api/
      publish` JSON (token via `LEX_REGISTRY_TOKEN`) **ou** imprime entrada TOML.
- [ ] Wrappers de processo externo: `git` e `curl` (GET `-fsSL`, POST `-X POST`).

**F6.9 — LSP** ✅ FEITO (`lexlsp.lex`, espelha `src/lsp.rs`):

- [x] Habilitou o host: builtin **`readStdin(n): string`** (runtime `__lex_read_stdin`,
      com `fflush(stdout)` antes de bloquear) — nativo-libc, como `args`/`system`.
- [x] Transporte JSON-RPC 2.0 sobre stdio (framing `Content-Length:\r\n\r\n`),
      reusando o parser de `json.lex`.
- [x] `initialize` → `textDocumentSync:1` + `serverInfo{name:"lex-lsp"}`;
      `didOpen`/`didChange` (full sync); `shutdown`/`exit`.
- [x] Análise via subprocesso `lex check --json` → `publishDiagnostics`
      (range + `severity:1`). *Smoke OK*: handshake + `didOpen` num arquivo com
      erro publica o diagnóstico real (`undefined variable`, range certo).

**F6.10 — Alvos extra: wasm32 + cross-compile** (`src/wasm_host.rs` + target em
`src/main.rs`/`src/codegen.rs`):

- [ ] Emissão de objeto por triple (`Target::initialize_all`, `set_triple`,
      `set_data_layout`).
- [ ] **wasm32**: IR→objeto `wasm32-unknown-unknown`; runtime `clang
      --target=wasm32 -ffreestanding -fno-builtin -nostdlib`; link `wasm-ld
      --no-entry --export-all --allow-undefined --export-memory`.
- [ ] **wasm host imports** (espelha `web/lex-host.js`): `lex.write`, `lex.fs_*`
      (read/write/append/exists/.../open), `lex.fd_*` (read/write/close/seek),
      `__lex_wasm_alloc`; ponteiros i32 (memória linear de 32 bits).
- [ ] **`--wasm-threads`**: runtime `-matomics -mbulk-memory -DLEX_WASM_THREADS`;
      link `--shared-memory --import-memory --features=atomics,bulk-memory,...`;
      spinlock atômico (`lex_brk_lock`); exporta `__stack_pointer`+tabela.
- [ ] **Cross-compile** — aliases→triples: `linux-x64/arm64`,
      `windows-x64/arm64` (`.exe`), `macos-x64/arm64`.
- [ ] Link Linux: estático, `-DLEX_NATIVE_FREESTANDING -ffreestanding -nostdlib
      -static -fuse-ld=lld -Wl,--entry,_start` (syscalls no runtime, zero libc).
- [ ] Link macOS: `clang -arch <a> -mmacosx-version-min=11.0 ... -lpthread`
      (precisa rodar em macOS).
- [ ] Link Windows: `-DLEX_WIN_FREESTANDING`, gerar import libs com `llvm-lib`
      (kernel32.def/ws2_32.def), `lld-link /entry:lexWinStart /subsystem:console`.
- [ ] Localizar toolchain LLVM 18 (`clang`, `wasm-ld`, `llvm-lib`) via
      `LLVM_SYS_180_PREFIX`/PATH.

**F6.11 — Resto: JSON, watch, diagnósticos**:

- [x] **JSON** (`json.lex`): parser recursivo (`{}`/`[]`/string com escapes/
      número/`true`/`false`/`null`), acessores `jGet`/`jStr`/`jNum`/`jArr`/`jPath`,
      e `jEscape` pra saída. 14 asserções (`json.test.lex`) incl. mensagem estilo
      LSP. (`\uXXXX` vira `?` — lossy; LSP é ~ASCII. Números são i64.)
- [x] **Diagnósticos** (`diag.lex`): `renderDiag` estilo rustc (cabeçalho,
      `--> arquivo:linha:col`, gutter `|`, trecho da fonte, `^^^` com cálculo de
      linha/coluna e expansão de tab), `help:` opcional. 3 asserções
      (`diag.test.lex`). (Caminho sem-cor; ANSI/TTY e `✓`/`✖` ficam de fora.)
- [ ] **Watch mode**: recompilar ao salvar (hoje via crate `notify`); em lex,
      poll de mtime ou `__lex_fs_*` sobre os arquivos do projeto.

### `lex` unificado (`lexcli.lex`)

Um único binário-em-lex que despacha subcomandos delegando aos módulos:
`lex build/run/fmt/version`. Compila a si mesmo (`lex build selfhost/lexcli.lex`
→ binário que roda). É o embrião do `lex` de produção escrito em lex.

### O que AINDA falta pra deletar o `src/` de verdade (honesto)

> **Roadmap fase-a-fase detalhado: [`selfhost/REMOVER-RUST.md`](REMOVER-RUST.md)**
> (arquivos, features, dependências, validação e esforço de cada etapa, A→I).

O compilador-core está auto-hospedado e várias ferramentas portadas, mas o `lex`
de produção (`src/`, ~14k linhas) faz mais. Pra aposentar o `src/` inteiro falta —
e cada item é GRANDE e pouco testável de forma hermética aqui:

- **`lex test` (test runner)**: o harness já é lex (`std/test.lex`), MAS usa dois
  recursos que o compilador self-hosted ainda NÃO tem — **arrow functions/closures**
  (`test("...", () => {...})`) e o tipo **`any`** com boxing+tag (`expect(actual:
  any)`). Logo, antes do `lex test` faltam: (a) arrow/closures no parser+codegen,
  (b) `any`/boxing no codegen, (c) o driver que acha os `.test.lex` e injeta o
  import do harness. É a maior pendência isolada.
- **`lex check` self-hosted**: a sema-em-lex (F6.2) monta tabelas/tipos mas NÃO
  emite diagnósticos com span. Exige rastrear posições no lexer/parser (hoje não
  rastreiam) + um checador que espelhe `src/sema.rs` (~103KB). O `lexlsp` hoje
  ainda chama o `lex check --json` do Rust por subprocesso.
- **CLI completo** (`src/main.rs`): todas as flags, resolução de `std/`, modos.
- **wasm/cross-compile** (F6.10) e **pkg fetch/publish** (rede).
- **Semente**: build do `lexcli` (via Rust) → commitar o binário **stage0** →
  então deletar `src/`. A partir daí o stage0 reconstrói tudo. (O `runtime.c`
  continua C — "remover Rust" ≠ "remover C"; até a produção o compila com clang.)

### Tamanho do esforço

O core do compilador Rust (lexer+parser+ast+sema+codegen) é ~10k linhas; o
self-host do core ficou em ~2k. F6.1–F6.6 + fmt/TOML/semver/JSON/diag/LSP/CLI já
são ~4.4k linhas de lex. O que falta (test runner + check com diagnósticos + CLI
completo) é da mesma ordem de grandeza outra vez, e é a parte menos verificável
sem rodar contra editores/CI reais.
