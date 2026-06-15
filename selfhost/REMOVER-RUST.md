# Roadmap: eliminar o `src/` (Rust) — o que falta e como

Estado atual (ver `selfhost/README.md` para detalhes): o **compilador-core está
auto-hospedado** (ponto-fixo provado por `bootstrap.sh`) e **8 ferramentas** estão
portadas e testadas/smoke — fmt, TOML, semver, pkg(manifesto), JSON, diag, LSP,
e o `lex` unificado (`lexcli.lex`). ~4.500 linhas de lex, 300 asserções verdes.

**Teste de aceitação da meta** ("Rust eliminado"): buildar um `lex` **stage0** em
lex (via Rust, uma última vez), e então **deletar `src/`** com:
1. `./stage0 test selfhost` passando (suíte verde sem o Rust), e
2. `./stage0` recompilando a si mesmo (`bootstrap` sob o stage0, ponto-fixo).

> Nota: o `runtime.c` continua **C** (compilado pelo clang) — "remover Rust" ≠
> "remover C". Até o `lex` de produção embute `runtime.c` e usa clang como linker.

As fases abaixo estão em **ordem de dependência**. Esforço é relativo (S/M/L/XL).
"Espelha" aponta o arquivo Rust de referência.

---

## Fase A — Arrow functions / closures  ·  esforço: L  ·  ✅ FEITO (não-capturante)
**Por quê:** bloqueia o `lex test` (o harness `std/test.lex` usa `test("…", () => {…})`)
e é a maior lacuna de linguagem do compilador self-hosted.

> **FEITO**: arrow não-capturante. Parser iça p/ `__lambda_N` (`Lambda` node, campos
> `lambdas`/`lambdaN` no Parser, anexados a `funcs` em `parseModule`); `parseTypeStr`
> lê `(T,…)=>R`. Sema: `typeOf(Lambda)="()=>?"` + `isFunctionType`. Codegen: `Lambda`→
> `ptrtoint (ptr @__lambda_N to i64)`; chamada de var de tipo função → call indireto
> (`inttoptr`+`call i64 %fp(...)`). e2e: `apply(() => 42)`→42, `applyTo((n)=>n*2,21)`→42.
> Bootstrap segue em ponto-fixo. FALTA (se algum alvo exigir): **captura** de locais.

- **Parser** (`parser.lex`): em `parsePrimary`, no caso `LParen`, fazer lookahead
  (`()` ou `(ident:` ou `(ident,`) → é arrow. Parsear params + `: ret` opcional +
  `=>` + corpo (bloco ou expr única → `return expr`). **Hoistar** para uma função
  de topo `__lambda_N` (acumular num `lambdas: Func[]` no Parser; `parseModule`
  anexa a `funcs`). A expressão vira um nó `Lambda { fnName }`.
- **Tipos de função** (`parseTypeStr`): aceitar `(T, …) => R` (hoje engasga no `(`).
- **Sema** (`sema.lex`): tipo de um `Lambda` = o tipo de função; `typeOf` de uma
  var com tipo `() => R` é "função".
- **Codegen** (`codegen.lex`): `Lambda` → `ptrtoint (ptr @__lambda_N to i64)`.
  Chamada de valor função (`body()` onde `body` é param/var de tipo função) →
  **call indireto**: carrega o i64, `inttoptr`, `call i64 %fp(...)`. Em `genCall`,
  distinguir nome-de-var-em-escopo (indireto) de função de topo (`@nome` direto).
- **Captura:** começar SEM captura (o harness não captura locais — só chama
  funções globais). Closures com captura (caixa fn+ambiente) ficam para depois,
  se algum alvo exigir.
- **Espelha:** `parse_lambda`/`Expr::Closure` em `src/parser.rs` (içamento p/
  `__lambda_N`), e o lowering de closure em `src/codegen.rs`.
- **Validar:** e2e — `fn apply(f: () => i64): i64 { return f() }` +
  `apply(() => 42)` → 42; passar arrow a uma função e chamar.

## Fase B — Tipo `any` + boxing  ·  esforço: L  ·  ✅ FEITO (escalares + string)
**Por quê:** `expect(actual: any)` embrulha qualquer valor com a **tag de tipo**
pra comparar int/string/float/array corretamente. Necessário p/ o `lex test`.

> **FEITO**: reusa o `LexJson` do runtime. No ponto onde um valor concreto encontra
> um parâmetro/campo `any`, o codegen BOXA: i64→`__lex_json_num`, f64→`__lex_json_float`,
> string→`__lex_json_str`, bool→`__lex_json_bool` (`any`→`any` não re-boxa). Sema:
> `funcParamTypes`/`methodParamTypes` + `any` é primitivo. Builtins json no codegen:
> `jsonEq`/`jsonAsInt`/`jsonAsFloat`/`jsonNum`/… → `__lex_json_*`. e2e: `jsonEq` por
> valor (int/string) e o padrão campo-`any`+método-`any` (espelho do `expect`/`toBe`).
> FALTA p/ arrays/maps em `any` (gotcha conhecido: só literais estruturam).

- **Codegen** (`codegen.lex`): ao passar um valor para um parâmetro `any`, **box**:
  alocar `{tag, payload}` (ou usar o `LexJson` do runtime, que já é tag+payload —
  `__lex_json_num/str/float/...`). `any` → reusar `LexJson` é o caminho mais curto
  (o runtime já compara com `__lex_json_eq`).
- **Sema**: tipo `any`; coerção valor→any no ponto de chamada conforme o tipo do arg.
- **Espelha:** `gen_box_value`/`gen_box_any` em `src/codegen.rs` (a tag por tipo).
- **Validar:** `expect(1).toBe(1)`, `expect("a").toBe("a")`, `expect(1.5).toBe(1.5)`
  compilando e comparando certo (depende de B + parte de C).
- **Gotcha conhecido** (memória do projeto): `expect` só estrutura arrays LITERAIS;
  array vindo de var é encaixotado como ponteiro-número. Decidir se replica ou corrige.

## Fase C — `lex test` (driver + harness)  ·  esforço: M  ·  ✅ FEITO (não-capturante)
- O harness JÁ existe (`std/test.lex`: `describe/test/it/expect/testReport`,
  placar em slots globais `gget/gset`).

> **FEITO**: (a) `Terminal.<método>(…)` virou **builtin de prelúdio** no codegen
> (`genTerminalPrint`: concatena os args por tipo — string/any/f64/i64/bool — e
> imprime + `\n`), evitando compilar `std/terminal.lex` (que usa static/variádico/
> libc). + builtins `gget`/`gset`/`fabs`/`contains`. (b) Driver **`lextest.lex`**:
> mescla `std/test.lex` + o arquivo de teste (e seus imports) num Program, anexa
> `return testReport()` ao main, compila e roda. *VALIDADO*: `lextest semver.test.lex`
> → "todas as 23 asserções passaram" (igual ao `lex test` Rust); `pkg.test.lex` idem.
>
> **CAPTURA — FEITA** (via globais promovidos, sem closure/env): `const`/`let`
> DIRETOS do `main` (script) e de cada lambda viram **slots globais** (`gget`/`gset`,
> slots 2+; 0/1 são do harness), visíveis em qualquer função — inclusive captura
> ANINHADA (`const` num arrow `describe` usado em arrows `test` internos). Regra:
> main+lambdas excluem os globais dos allocas; funções normais mantêm (param/local
> sombreia global homônimo — ex.: param `src` de `lexSrc` vs global `src` do `lexc`).
> + métodos de string (`.contains`/`.startsWith`/`.endsWith`). *PARIDADE TOTAL*:
> as **12 suítes** `selfhost/*.test.lex` passam sob o `lextest` (= `lex test` Rust).
> O `lex test` agora roda **sem o Rust**. (Trade-off: nomes de const iguais entre
> arrows compartilham slot — ok porque os testes rodam em sequência.)
- **Driver** (`lextest.lex`, novo): `lex test <dir>` → `readDir`, filtra `*.test.lex`,
  e para cada arquivo: injeta `import { describe, test, expect, testReport } from
  "test"` + sintetiza um `main` que roda os `describe` de topo e retorna
  `testReport()`. (No Rust isso é feito em `src/main.rs:547` e `run_tests` em ~1293.)
- O `modloader` precisa resolver o módulo `"test"` → `std/test.lex` (resolução de
  `std/`, ver Fase F).
- **Espelha:** `run_tests` + injeção do import em `src/main.rs`.
- **Validar:** `lextest selfhost` reproduz o mesmo placar do `lex test` do Rust.

## Fase D — Span tracking (lexer + parser)  ·  esforço: M  ·  ✅ FEITO
**Por quê:** pré-requisito p/ diagnósticos com linha/coluna (Fase E).

> **FEITO**: `Token` ganhou `pos` (offset de byte de início); o lexer preenche em
> todas as fábricas (`tk`/`tkText`/`tkInt`/`tkFloat` recebem `pos`). O nó `Var`
> ganhou `pos` (posição do identificador). Bootstrap segue em ponto-fixo.
> (Outros nós podem ganhar span quando a Fase E precisar de mais precisão.)

- **Lexer** (`lexer.lex`): cada `Token` carrega o offset de início (byte). Já lê por
  byte; só adicionar o campo `pos` e preenchê-lo.
- **Parser** (`parser.lex`): nós de AST carregam `(start, end)`. Mínimo: statements
  e expressões-chave (o suficiente p/ apontar erros).
- **Espelha:** `Span` em `src/ast.rs`/`src/lexer.rs`.
- **Validar:** unit — o span de um nó bate com o trecho no fonte (usar `diag.lex`
  pra renderizar e conferir o caret).

## Fase E — `lex check` self-hosted (sema com diagnósticos)  ·  esforço: XL  ·  🟡 SLICE FEITO
**Por quê:** hoje o `lexlsp` chama o `lex check --json` **do Rust**. Pra cortar essa
dependência, a sema-em-lex precisa emitir diagnósticos.

> **SLICE FEITO — variável indefinida**: `checkProgram(prog): Diag[]` em `sema.lex`
> + driver `lexcheck.lex`. Conjunto de DEFINIDOS = funções/classes/enums + `this`/
> `Terminal` + params+locais (let/for-of/match-bind) de TODAS as funções; um `Var`
> fora dele → `undefined variable: 'X'` com posição. Resolve imports (`loadProgram`)
> → SEM falso-positivo em código real (`lexcheck selfhost/parser.lex` → `[]`). Saída
> JSON `[{line,col,endLine,endCol,message}]` (0-based) compatível c/ o `lexlsp`.
> *VALIDADO*: `return zzz`→undefined; ok→`[]`; parser.lex→`[]`. **FALTA p/ paridade**:
> erros de sintaxe (parser é silencioso), tipo/aridade/campo inexistente, escopo
> (slice é grosseiro: "definido em qq lugar = ok"), + rewire do `lexlsp` p/ usar o
> `lexcheck` em vez do Rust.

- **Sema** (`sema.lex`): além das tabelas (F6.2), detectar erros e acumular
  `Diagnostic { line, col, endLine, endCol, message }`: variável indefinida,
  campo/método inexistente, aridade, tipo incompatível (no nível grosseiro), etc.
- **Driver** `lex check --json`: roda lexer→parser→sema, imprime o array JSON de
  diagnósticos (usar `json.lex` p/ montar). O `lexlsp` então chama o check
  self-hosted em vez do Rust.
- **Espelha:** `src/sema.rs` (~103KB) — é a maior peça; portar incrementalmente
  (começar por resolução de nomes, que cobre o caso do smoke do LSP).
- **Validar:** `lex check --json` em arquivos com erro conhecido bate (linha/col/
  msg) com o do Rust, caso a caso.

## Fase F — CLI completo (`lex` de produção em lex)  ·  esforço: L  ·  🟡 NÚCLEO FEITO
> **NÚCLEO FEITO**: o `lexcli.lex` agora despacha **build/run/fmt/test/check/version**
> num único binário (importando `runTestFile` de `testrunner.lex` e `runCheck` de
> `checker.lex` — módulos só-declaração; os drivers `lextest`/`lexcheck` ficaram
> finos). *Smoke*: `lex test <suíte>` ✓, `lex check --json` ✓, `lex run/build/fmt`.
> O **`lexlsp` agora chama o `lexcheck`** (não mais o `lex check` do Rust) → o LSP
> roda sem Rust (smoke: didOpen→publishDiagnostics da variável indefinida).
> **FALTA**: `lsp`/`pkg`/wasm no despacho unificado; flags do `main.rs`; resolução
> de `std/` subindo diretórios (hoje caminhos relativos à raiz do repo); `--watch`.

- Espelhar `src/main.rs`: flags, `--target`, `-o`, resolução de `std/` (subir
  diretórios achando `std/` — já existe no Rust, portar a `resolve_module`/
  `find_std_file`), modos (`run`/`build`/`check`/`test`/`fmt`/`lsp`/`pkg`),
  `--watch`. Unificar `lexcli`/`lexpkg`/`lexlsp`/`lextest` num só despacho.
- **Espelha:** `src/main.rs` (dispatch + resolução de módulos).
- **Validar:** rodar os mesmos comandos do dia a dia e comparar com o `lex` Rust.

## Fase G — pkg: fetch/publish (rede)  ·  esforço: M  (depende de F6.8-A/B já prontos)
- `install`/`update`/`add`(com fetch)/`publish`/`registry`. Usa `system()` com
  redirecionamento p/ capturar saída de `git`/`curl` (`git ls-remote --tags`,
  `clone --depth 1`, `rev-parse HEAD`, `checkout`; `curl -fsSL`/`-X POST`).
  Lockfile `lex.lock` end-to-end (commit via `rev-parse`), resolução transitiva
  (loop até estabilizar) + prune de órfãos (BFS).
- **Espelha:** `src/pkg.rs` (resta ~o grosso da lógica de rede/resolução).
- **Validar:** smoke clonando um repo público pequeno; lock reprodutível.

## Fase H — wasm + cross-compile  ·  esforço: L
- Emissão por triple, flags de `wasm-ld`/`clang --target`, runtime por alvo
  (freestanding/wasm), import libs do Windows. O codegen textual já existe; é
  orquestração de toolchain + os flags certos por alvo.
- **Espelha:** `src/wasm_host.rs` + a lógica de target em `src/main.rs`/`src/codegen.rs`.
- **Validar:** compilar p/ wasm32 e rodar via wasmi/Node; cross p/ linux-x64 e rodar.

## Fase I — Semente (stage0) + deletar `src/`  ·  esforço: S  (depende de tudo acima)
1. Buildar o `lex` unificado em lex com o Rust, uma última vez:
   `lex build selfhost/lexcli.lex -o lex-stage0` (quando `lexcli` cobrir
   build/run/check/test/fmt/lsp/pkg).
2. Commitar `lex-stage0` (binário) **e** o `runtime.c`.
3. Rodar o teste de aceitação (topo deste doc) sob o stage0.
4. Arquivar/deletar `src/` (e o `Cargo.toml`/inkwell). A partir daí, o stage0
   reconstrói o compilador a partir de `selfhost/*.lex`.

---

## Ordem sugerida e tamanho

```
A (arrow) → B (any) → C (lex test)        ← destrava rodar a suíte sem Rust
D (spans) → E (lex check)                 ← corta a dependência do LSP no Rust
F (CLI completo)                          ← um único `lex` em lex
G (pkg rede) · H (wasm/cross)             ← paralelas, independentes
I (semente + deletar src/)                ← fim
```

Soma honesta: **A+B+C+D+E+F** são o caminho crítico e somam algo da ordem de
**+4–6k linhas de lex**, comparável a tudo que já foi feito — e **E** (sema com
diagnósticos, espelhando ~103KB de Rust) é a peça mais pesada e a menos
verificável de forma hermética. G/H agregam, mas não bloqueiam o `lex test`/`build`.

Marcos verificáveis pelo caminho (não precisam esperar o fim):
- depois de **C**: `lextest selfhost` roda a suíte SEM o Rust;
- depois de **E**: `lexlsp` não chama mais o `lex check` do Rust;
- depois de **F**: existe um único `lex` em lex pro dia a dia;
- depois de **I**: `src/` deletado, stage0 se reconstrói (meta atingida).
