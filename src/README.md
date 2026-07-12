# O compilador do lex

O compilador é escrito **na própria linguagem**. Ele compila o próprio fonte até o
**ponto-fixo**: recompilá-lo com ele mesmo produz o mesmo LLVM IR, byte a byte.

```
fonte .lex ──▶ lexer ──▶ parser ──▶ sema ──▶ typecheck ──▶ codegen ──▶ LLVM IR (texto)
                                                                            │
                                                          clang ◀───────────┘
                                                            │
                                              runtime.c ────┴──▶ binário
```

Não há passe de otimização: a IR sai direta e o LLVM (via clang) faz o resto.

## O núcleo

| arquivo | o que faz |
|---|---|
| `compiler/lexer.lex` | fonte → tokens. Quebras de linha viram `Tok.Newline` (o parser as ignora). Um template `` `…${}…` `` sai como **um** token com o corpo cru — quem o divide é o parser. |
| `compiler/parser.lex` | tokens → AST, por *precedence climbing*. A AST é uma **hierarquia de classes** (`Expr`/`Stmt` + uma subclasse por construção), percorrida com `match` por tipo. Arrows são **içadas** para funções `__lambda_N` de topo. |
| `compiler/sema.lex` | o modelo de objeto e a inferência de tipos. `ClassTable`: por classe, os campos com seu **slot** (herança põe os do pai primeiro, mesmos slots), a vtable (override mantém o índice) e uma **tag** única para o `match` por tipo. `typeOf(expr, scope)` devolve o tipo como *string*. |
| `compiler/typecheck.lex` | as checagens de verdade: aridade, tipo de argumento, campo/método inexistente, `const` reatribuído. **Leniente por princípio** — tipo desconhecido (`"?"`) nunca acusa, porque um falso-positivo quebraria o build do próprio compilador. |
| `compiler/codegen.lex` | AST → LLVM IR **textual**. Sem `phi`: os valores moram em `alloca`/`load`/`store` e o LLVM promove. |
| `compiler/modloader.lex` | segue os `import` (recursivo, dedup), resolve caminhos relativos e módulos `std/`, e funde tudo num `Program` só — é aí que tipos cross-módulo passam a resolver. |

## O modelo de execução

**Tudo é uma célula i64.** Um ponteiro trafega como inteiro; um `f64` trafega como
os **bits** do double dentro de um i64. Por isso as bordas (um `let` anotado, um
argumento, um `return`) precisam de `coerce` — `let x: i64 = round(…)` sem `fptosi`
guardaria o padrão de bits.

**Objeto** = bloco de slots: slot 0 = a *tag* da classe, slots 1..n = os campos.
O dispatch é estático (`@Dono.metodo(this, …)`), exceto quando o método é
**sobrescrito** — aí o codegen compara a tag e escolhe a implementação (`genDynDispatch`).

**Closure** = bloco no heap: slot 0 = o ponteiro da função, slots 1.. = uma **cópia**
de cada variável livre (captura por valor). A chamada indireta lê o ponteiro do slot 0
e passa o próprio env como 1º argumento.

**Erro** (`fail`/`try`/`catch`) é fora-de-banda: um flag no runtime. `fail` seta e sai;
`try` propaga; `catch` limpa e usa o fallback.

## A fronteira com o C

`runtime.c` é a **biblioteca padrão**, não parte do compilador. O codegen nunca
implementa string/array/JSON — ele emite uma chamada:

```llvm
declare ptr @__lex_concat(ptr, ptr)
  %t2 = call ptr @__lex_concat(ptr %t0, ptr %t1)
```

São **81 símbolos `__lex_*`**. A tabela `rtAbi` (em `compiler/codegen.lex`) guarda a assinatura
C real de cada um — `"<args>|<ret>"`, com `'p'` = ponteiro, `'.'` = i64, `'v'` = void.
Isso importa porque no nativo `ptr == i64` (e declarar tudo i64 passaria), mas no
**wasm32 `ptr == i32`**: sem a ABI certa o `wasm-ld` recusa o link. A conversão
acontece só na borda da chamada (`rtCall`), então os valores seguem sendo células i64.

O `runtime.c` traz também três camadas de SO *freestanding* (wasm, Linux por syscall
crua, Windows por Win32) — é o que faz `--target linux-x64` gerar um ELF estático sem
libc, e `--target wasm` um módulo que só importa `lex.write` do host.

## As ferramentas

Tudo mora num binário só (`lexcli.lex`), que despacha os subcomandos:

| | |
|---|---|
| `tools/fmt.lex` | `lex fmt` — indentação por profundidade de delimitadores |
| `tools/checker.lex` | `lex check` — sintaxe + indefinidos + tipos, em JSON |
| `tools/lspserver.lex` | `lex lsp` — Language Server por stdio (chama o checker direto) |
| `tools/testrunner.lex` | `lex test` — funde `std/test.lex` + a suíte, compila e roda |
| `tools/pkg*.lex`, `tools/toml.lex`, `tools/semver.lex` | `lex pkg` — manifesto e resolução |
| `tools/json.lex`, `tools/diag.lex` | JSON (usado pelo LSP) e diagnósticos estilo rustc |

## Bootstrap

`lex-seed.ll.gz` é o LLVM IR **deste compilador**, no ponto-fixo. O clang o transforma
num `bin/lex` sem precisar de compilador lex algum:

```sh
./scripts/build-seed.sh    # -> bin/lex, e valida o ponto-fixo
./scripts/regen-seed.sh    # regere a semente após mudar src/*.lex
```

A IR da semente é **agnóstica de alvo** (usa `ptr` opaco), então o mesmo arquivo serve
em qualquer plataforma que o clang suporte.
