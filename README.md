# lex

[![CI](https://github.com/lex-language/lex/actions/workflows/ci.yml/badge.svg)](https://github.com/lex-language/lex/actions/workflows/ci.yml)

Uma linguagem de baixo nível com **sintaxe TypeScript-like** — e melhorias onde
o TypeScript é fraco: tipos inteiros de verdade (`i32`/`i64`), erros checados
em tempo de compilação e threads reais — compilada **direto para LLVM IR**,
sem GC e sem runtime.

O compilador **é escrito na própria linguagem** (`src/`). Ele compila a si
mesmo até o **ponto-fixo** — recompilar o compilador com ele mesmo reproduz o
mesmo LLVM IR, byte a byte. Não há Rust no repositório: o único requisito é o
clang/LLVM.

```
fonte .lex → lexer → tokens → parser → AST → sema/typecheck → codegen → LLVM IR (texto) → clang → binário
```

## Pré-requisitos

- **clang / LLVM 18** (`brew install llvm@18` no macOS)
  O `wasm-ld` e o `llvm-lib` (para `--target wasm` e `--target windows-*`) vêm
  junto; o compilador os procura em `/opt/homebrew/opt/llvm@18/bin`.

## Bootstrap (como o compilador nasce sem um compilador)

O repositório traz uma **semente**: [`src/lex-seed.ll.gz`](src/lex-seed.ll.gz),
que é o LLVM IR do próprio compilador-em-lex, no ponto-fixo. O clang a transforma
num `bin/lex`, e a partir daí o `lex` recompila a si mesmo **a partir do fonte**:

```sh
./scripts/build-seed.sh     # -> bin/lex  (só precisa de clang)
```

O script termina validando o ponto-fixo. Se você mudar `src/*.lex`, regere a
semente antes de commitar:

```sh
./scripts/regen-seed.sh
```

> A IR da semente é **agnóstica de alvo** (usa `ptr` opaco e células i64), então o
> mesmo arquivo serve em qualquer plataforma que o clang suporte.

## Uso

```sh
./scripts/build-seed.sh         # constrói bin/lex a partir da semente

./bin/lex version

# compila para um binário nativo
./bin/lex examples/exemplo.lex -o exemplo
./exemplo; echo $?      # roda o tour e sai com 0

# mostra o LLVM IR gerado (ótimo para aprender)
./bin/lex examples/exemplo.lex --emit-ir

# compila e executa em um comando só
./bin/lex examples/exemplo.lex --run

# compila para WebAssembly (.wasm) e roda no runtime embutido (sem Node)
./bin/lex examples/exemplo.lex --target wasm -o exemplo.wasm --run
./bin/lex exemplo.wasm          # ou roda um .wasm já compilado
#   no browser, abra web/index.html e escolha o .wasm (veja web/README.md)

# cross-compile para outro SO/arquitetura — toolchain 100% LLVM 18, SEM zig:
#   macOS:   clang + SDK do sistema
#   Linux:   runtime FREESTANDING (syscalls cruas) + ld.lld → binário estático
#   Windows: runtime FREESTANDING (Win32 API) + lld-link (import libs via llvm-lib)
./bin/lex examples/exemplo.lex --target linux-x64   -o exemplo-linux
./bin/lex examples/exemplo.lex --target windows-x64 -o exemplo.exe
./bin/lex examples/exemplo.lex --target macos-x64   -o exemplo-x64
#   alvos: linux-x64, linux-arm64, windows-x64, windows-arm64, macos-x64, macos-arm64

# modo watcher: recompila a cada alteração nos fontes (.lex/.c);
# com --run, também re-executa o binário (mata o processo anterior —
# perfeito para os servidores HTTP)
./bin/lex examples/exemplo.lex --watch --run
```

**Multiplataforma.** O mesmo código lex roda em três frentes:
**nativo** (host ou cross-compile para Linux/Windows/macOS, x86/arm),
**web/browser** e **servidor** (ambos via `--target wasm`, executado pelo
runtime wasm embutido no próprio `lex` — sem Node).
Detalhes do alvo web em [web/README.md](web/README.md).

## Pacotes (`lex install`)

O próprio `lex` é o gerenciador de pacotes — sem ferramenta extra. O manifesto
e o lockfile são **TOML**; os pacotes baixados ficam em `lex_modules/` (por
projeto, estilo `node_modules`, já no `.gitignore`). A rede passa **só pelo
`git`** (sem cliente HTTP embutido), e o `lex.lock` fixa o commit de cada
dependência — instalação reprodutível.

```sh
lex init                       # cria um lex.toml no diretório atual
lex add cores                  # adiciona a dep (resolve a versão e instala)
lex add cores@^1.2.0           # com restrição semver
lex add github.com/joao/cores  # direto de uma URL git (sem registry)
lex add file:../cores          # de uma pasta local (ótimo p/ dev de pacote)
lex install                    # instala tudo do lex.toml (respeita o lex.lock)
lex update [cores]             # re-resolve p/ a maior versão compatível
lex remove cores               # remove a dep (e poda transitivas órfãs)
lex list                       # lista o que está instalado
```

Depois de instalar, um *bare import* resolve no pacote — a busca é `std/`
primeiro (os builtins ganham), depois `lex_modules/`:

```lex
import { greet } from "cores";   // -> lex_modules/cores/<entry>.lex
Terminal.log(greet("lex"));
```

O `lex.toml` declara o projeto e as deps; cada pacote publicado traz o seu,
inclusive o ponto de entrada (`main`) e suas próprias dependências (resolvidas
de forma transitiva e achatadas em `lex_modules/`):

```toml
[package]
name = "meu-app"
version = "0.1.0"
main = "src/app.lex"      # opcional; default tenta <nome>.lex, main.lex, lib.lex, src/…

[dependencies]
cores = "^1.2.0"                       # registry
http2 = "github.com/joao/http2@^0.3"   # URL git
local = "file:../local"                # pasta local
```

**Fontes.** Um nome nu (`cores`) é resolvido pelo **índice do registry** — um
repo git (sem servidor próprio) clonado em `~/.lex/registry`, que mapeia
`nome → URL`. A versão é escolhida entre as **tags** do repo (`git ls-remote`)
pela restrição semver (`^`, `~`, `>=`, `*`, …). Aponte o índice com a variável
`LEX_REGISTRY`. URLs git e `file:` dispensam o índice.

**Criando/hospedando um índice.** O índice é só uma pasta versionada com git,
com um `packages/<nome>.toml` por pacote (`repo = "<url>"`). Dá para criar e
manter o seu (público ou privado) com o próprio lex:

```sh
lex registry init ./meu-registry           # cria packages/ + README + git init
lex registry add cores github.com/joao/cores   # adiciona/atualiza uma entrada
# versione e publique o repo; quem consome aponta:  LEX_REGISTRY=<url-do-repo>

lex publish https://github.com/me/proj      # imprime a entrada deste pacote
```

## A linguagem hoje (v0)

```lex
function add(a: i32, b: i32): i32 {
    return a + b;
}

function main(): i32 {
    const x: i32 = 10;
    const y: i32 = add(x, 32);
    return y;          // vira o exit code do processo
}
```

Suportado: funções (`function` ou `fn`; `void`, `return;` e **return
implícito**; `main` **opcional** — statements no topo viram o `main`), parâmetros, `const` (imutável) e `let` (mutável) com tipos
(`i8`/`i32`/`i64`/`f64`/`f32`/`bool`/`ptr`), `true`/`false`, atribuição (e compostas
`+= -= *= /= %=`, `++`/`--`), aritmética `+ - * / %`, comparações
`== != < > <= >=`, lógicos com curto-circuito `&& ||` e unários `! - ~`,
bitwise `& | ^ << >>`, **ponto flutuante** (`f64`, literais `3.14`, `sqrt`/`floor`/…),
`if`/`else`, `while`, **`for`** (estilo C) e **`for...of`** com `break`/`continue`,
**`match`** (pattern matching), **genéricos** (`fn id<T>`, `class Box<T>`),
strings (com helpers: `substring`, `split`, `toUpper`, …), **arrays tipados** (`T[]`), **maps**
(`Map<T>`) e **JSON** (`jsonParse`/`jsonStringify`), `Terminal.log(x)`, erros falíveis
(`!`, `fail`, `try`, `catch valor` ou `catch e { ... }`, `main` falível),
threads (`spawn`, `join`), **`async`/`await`** (`Future<T>`, sobre threads) e **canais** (`Channel<T>`, `send`/`recv`), `defer`
(LIFO) e **memória dinâmica** (`alloc`/`free`, `poke`/`peek`), **filesystem**
(`readFile`/`writeFile`/`readDir`/… + a lib `fs`), funções como valor e arrow
functions, structs (`type`), classes (`class`/OOP), componentes **JSX com
filhos e listas**, `import { } from` e `declare function` (FFI), e um backend
**WebAssembly** (`--target wasm`).

O `return` é explícito, mas o valor padrão é **0**: `return;` sem valor (ou
simplesmente cair no fim da função) equivale a `return 0`. Útil para `main`
e funções que retornam 0 no caminho de sucesso:

```lex
fn salvar(x: i64): i64 {
    if (x < 0) { return; }   // return; == return 0
    return x;
}

fn main(): i32 {
    Terminal.log(salvar(42));
    // sem 'return' aqui: o exit code é 0
}
```

```lex
function main(): i32 {
    let soma: i64 = 0;
    let i: i64 = 1;
    while (i < 11) {
        soma = soma + i;   // let permite reatribuir; const não (erro de compilação)
        i = i + 1;
    }
    Terminal.log(soma);           // 55
    return 0;
}
```

### `main` é opcional: arquivos como script

No arquivo de entrada, `function main` não é obrigatória: statements escritos
no **topo** (fora de qualquer função) viram o corpo de um `main` sintetizado, e
o arquivo roda de cima pra baixo como um script. Funções, classes e `type`
podem aparecer ao lado — a ordem não importa, o topo enxerga tudo.

```lex
function dobro(x: i64): i64 { return x * 2; }

const nome: string = "mundo";
Terminal.log(`ola, ${nome}`);   // ola, mundo
Terminal.log(dobro(21));        // 42
// sem 'return' no fim: o exit code é 0
```

- ou você escreve `function main`, ou usa statements no topo — **não os dois**
  (o compilador recusa o arquivo se encontrar os dois).
- se o topo usa `try`/`fail`, o `main` sintetizado vira **falível**: um erro que
  escapar imprime `error: N` no stderr e vira exit code 1.
- vale só no arquivo de **entrada**. Um módulo importado só exporta declarações
  (não há ordem de inicialização para rodar código de topo).

Veja [`examples/exemplo.lex`](examples/exemplo.lex).

### Erros: interpretação forçada pelo compilador

Inspirado em Zig: `!` no retorno marca a função como falível, e o **sema**
(análise semântica, [`src/sema.rs`](src/sema.rs)) recusa qualquer chamada
falível que não decida o que fazer com o erro — não é warning, é erro de
compilação:

```lex
// 1 = divisão por zero
function dividir(a: i64, b: i64): i64! {
    if (b == 0) {
        fail 1;            // sai com o código de erro 1
    }
    return a / b;
}

function media(soma: i64, n: i64): i64! {
    const m: i64 = try dividir(soma, n);   // try: propaga o erro ao chamador
    return m;
}

function main(): i32 {
    const m: i64 = media(100, 0) catch 999; // catch: trata aqui (usa 999)
    Terminal.log(m);
    // const x: i64 = media(10, 2);         // <- NÃO COMPILA: erro ignorado
    return 0;
}
```

Por baixo, uma função falível retorna a struct LLVM `{ i64 erro, T valor }`
(erro `0` = sucesso); `try`/`catch` viram `extractvalue` + branch — custo de
runtime: um registrador e um desvio. Veja com `--emit-ir`.

Duas regras extras de honestidade:

- **`main` pode ser falível** (`function main(): i32!`): um erro que escapar
  imprime `erro: N` no stderr e o processo sai com código 1 — padrão
  Rust/Zig ([`examples/exemplo.lex`](examples/exemplo.lex)).
- **`f() catch v;` solto não compila**: o valor seria descartado, ou seja, o
  erro seria silenciado fingindo tratamento. Guarde o resultado ou use `try`.

Além do `catch valor`, há a forma em **bloco**, que dá acesso ao código do
erro e pode rodar lógica antes de decidir o valor (a última expressão do bloco
vira o resultado):

```lex
const m: i64 = media(100, 0) catch e {
    Terminal.log(e);              // 'e' é o código do erro (o 1 do `fail 1`)
    if (e == 1) { return; }   // pode até sair da função
    0                    // ou: a última expressão é o valor do catch
};
```

A forma em bloco trata o erro de verdade, então pode aparecer solta como
statement (`arquivo() catch e { Terminal.log(e) }`); só a forma de valor solta é recusada.

### Threads: spawn / join (sem runtime)

`spawn f(args)` roda `f` em outra thread do SO (via `pthread_create`, chamado
direto do IR — o binário não carrega runtime nenhuma). Os argumentos são
**copiados** para a thread, e como variáveis são imutáveis, não existe data
race por construção. `join(handle)` espera e devolve o valor retornado:

```lex
function fib(n: i64): i64 {
    if (n < 2) { return n; }
    return fib(n - 1) + fib(n - 2);
}

function main(): i32 {
    const t1: i64 = spawn fib(34);   // roda em paralelo
    const t2: i64 = spawn fib(33);   // roda em paralelo
    Terminal.log(join(t1));
    Terminal.log(join(t2));
    return 0;
}
```

Funções falíveis não podem ser spawnadas (um erro em outra thread não teria
quem o tratasse) — o sema recusa.

`spawn f(x);` como statement (sem guardar o handle) é fire-and-forget: o
codegen emite `pthread_detach` e a thread libera seus recursos sozinha ao
terminar — essencial para o futuro servidor (uma thread por conexão).

### Canais: threads conversando (estilo Go)

`join` espera *uma* thread devolver *um* valor; um **canal** (`Channel<T>`) é
uma fila bloqueante para mandar quantos valores quiser entre threads:

```lex
fn worker(id: i64, out: Channel<i64>) {
    send(out, id * id);              // enfileira
}

fn main(): i32 {
    const results: Channel<i64> = channel();
    spawn worker(2, results);        // 3 workers em paralelo
    spawn worker(3, results);
    spawn worker(4, results);
    let total: i64 = 0;
    let i: i64 = 0;
    while (i < 3) {
        total = total + recv(results);   // recv bloqueia até chegar um valor
        i = i + 1;
    }
    Terminal.log(total);                      // 29 (4 + 9 + 16, em qualquer ordem)
    return 0;
}
```

`channel()` cria; `send(c, v)` enfileira; `recv(c)` bloqueia até haver valor;
`chanClose(c)` fecha (recv num canal vazio fechado devolve 0). Por baixo é uma
fila FIFO com `pthread_mutex`+`cond`, alocada no **heap** (não na arena): o canal
é compartilhado e sobrevive ao fim da thread que o criou. Ele carrega valores
`i64` (números/handles) — strings montadas na arena de uma thread não atravessam
com segurança, porque aquela arena some quando a thread termina. Exemplo:
[`examples/exemplo.lex`](examples/exemplo.lex).

### `async` / `await`: a mesma sintaxe do JS, mas com threads reais

`async`/`await` no lex é **açúcar sobre as threads** — não há runtime de async,
event-loop nem _function coloring_. Chamar uma `async fn` lança uma thread (o
mesmo `spawn`) e devolve um **`Future<T>`**; `await` espera o resultado (o
`join`). Como as tarefas rodam em paralelo de verdade, dá pra disparar várias e
só então aguardar:

```lex
async fn baixar(id: i64): i64 {
    return id * id;          // (trabalho pesado de verdade aqui)
}

fn main(): i32 {
    const a: Future<i64> = baixar(6);   // dispara — roda numa thread
    const b: Future<i64> = baixar(7);   // dispara outra, em paralelo
    Terminal.log(await a + await b);     // espera as duas: 36 + 49 = 85
    return 0;
}
```

Regras (herdadas do `spawn`): uma `async fn` **não pode ser falível** (um erro em
outra thread não teria quem o tratasse) nem variádica; os argumentos são copiados
para a thread. No `--target wasm` (single-thread) o `await` roda **síncrono** e o
resultado trafega em 32 bits (use o alvo nativo para `f64`/`i64` grande entre
threads). Exemplo: [`examples/exemplo.lex`](examples/exemplo.lex).

### `defer` e memória dinâmica (estilo Zig)

A arena cobre o caso comum (uma por thread/requisição), mas às vezes você quer
memória sob demanda, com tempo de vida próprio: `alloc(n)` devolve `n` bytes
zerados no heap e `free(p)` os libera. Para não esquecer o `free` (nem repeti-lo
em cada `return`), `defer` agenda um statement para a **saída da função**:

```lex
fn checksum(): i64 {
    const buf: ptr = alloc(16);
    defer free(buf);             // roda na saída, qualquer que seja o caminho

    poke32(buf, 0, 1000);        // escreve 4 bytes no offset 0
    poke8(buf, 8, 37);           // 1 byte no offset 8
    return peek32(buf, 0) + peek8(buf, 8);
}
```

Os `defer`s rodam em ordem **LIFO** e só se o fluxo passou por eles (cada um tem
uma flag) — valem em todo caminho de saída: `return`, `fail`, `try` que propaga,
ou cair no fim. `poke8/16/32/64` e `peek8/16/32/64` leem/escrevem em offsets de
bytes; as variantes `poke16be`/`poke32be` gravam em ordem de rede — é exatamente
o que [`std/socket.lex`](std/socket.lex) usa para montar a `sockaddr_in` em lex
puro. Exemplo: [`examples/exemplo.lex`](examples/exemplo.lex).

### Filesystem

Operações de arquivo são **builtins** (não precisam de import): `readFile`,
`writeFile`, `appendFile`, `exists`, `isFile`, `isDir`, `fileSize`, `remove`,
`rename`, `mkdir`, `rmdir`, `readDir` (→ `string[]`) e `openFile` (fd para
streaming). Por baixo, são primitivos portáveis na runtime em C — usam os
headers reais da plataforma, o que resolve `struct stat`, `dirent` e as flags
`O_*` sem precisar de bitwise no lex:

```lex
mkdir("/tmp/demo");
writeFile("/tmp/demo/a.txt", "ola\n");
appendFile("/tmp/demo/a.txt", "mundo\n");
Terminal.log(fileSize("/tmp/demo/a.txt"));     // 10
Terminal.log(readFile("/tmp/demo/a.txt"));     // ola\nmundo\n
const nomes: string[] = readDir("/tmp/demo");
Terminal.log(len(nomes));                      // 1
```

A lib [`std/fs.lex`](std/fs.lex) acrescenta a camada idiomática: wrappers
**falíveis** (`readText`/`writeText` que dão `fail` em vez de sentinela) e a
classe **`File`** para leitura/escrita por streaming via fd (`readInto`,
`writeBytes`, `seek`, `done`) — ideal para arquivos grandes:

```lex
import { readText, File } from "fs";

const txt: string = try readText("/tmp/demo/a.txt");   // falha se não existir

const f: File = new File("/tmp/demo/a.txt", 0);        // 0 = leitura
const buf: ptr = alloc(64);
const n: i64 = f.readInto(buf, 63);
f.done();
```

Exemplo completo: [`examples/exemplo.lex`](examples/exemplo.lex).

### Funções como valor e arrow functions

Tipo de função no estilo TS, podendo guardar, passar e chamar:

```lex
function dobro(x: i64): i64 { return x * 2; }

function aplicar(f: (i64) => i64, x: i64): i64 {
    return f(x);
}

function main(): i32 {
    const d: (i64) => i64 = dobro;             // função nomeada como valor
    Terminal.log(aplicar((x: i64) => x + 1, 41));     // arrow function inline -> 42
    Terminal.log(d(21));                              // 42
    return 0;
}
```

Arrow functions **capturam** variáveis de fora **por valor** (uma cópia no
momento em que a closure é criada — mutações posteriores na variável de fora
não afetam a closure, e vice-versa; sem GC, sem ownership):

```lex
function makeAdder(a: i64): (i64) => i64 {
    return (b: i64) => a + b;          // captura 'a'
}
const add10 = makeAdder(10);
add10(7);                              // 17
```

Por baixo: a arrow é içada para uma função de topo (`__lambda_N`) que recebe um
"closure box" como env; o valor de uma função é um ponteiro para esse box
(`[fn_ptr, capturas...]`). Uma função nomeada usada como valor é embrulhada num
thunk com env vazio. A chamada via variável vira `indirect call` no IR.
`this` também pode ser capturado dentro de um método. Exemplo completo:
[`examples/exemplo.lex`](examples/exemplo.lex).

### Imports, FFI, strings e o servidor HTTP

Módulos no estilo TypeScript: `import { ... } from "..."` traz funções de
outro arquivo `.lex`, e `declare function` (como num `.d.ts`) declara
símbolos de C sem corpo. Especificador relativo (`"./x"`) resolve ao lado
do arquivo; nu (`"libc"`, `"socket"`) resolve em [`std/`](std/). Se existir um
`.c` com o mesmo nome ao lado do módulo, **o lex linka ele automaticamente**.

```lex
import { lexListen, lexAccept } from "socket";  // std/socket.lex + socket.c (auto-link)
import { write, strlen } from "libc";             // std/libc.lex

const resp: ptr = "HTTP/1.1 200 OK\r\n\r\nola!";
write(conn, resp, strlen(resp));
```

Literais de string viram constantes globais no binário (zero alocação) e o
tipo `ptr` carrega endereços. Funções sem tipo de retorno (ou `: void`) não
retornam valor; nas demais, o valor padrão é 0 (`return;` ou cair no fim).

Com isso, o lex roda um **servidor HTTP multithread de verdade** — uma thread
por conexão, porta ocupada tratada à força pelo compilador:

```sh
./bin/lex examples/exemplo.lex -o servidor
./servidor &
curl localhost:8080        # -> ola do lex!
```

O [`std/socket.lex`](std/socket.lex) é **lex puro**: a `sockaddr_in` é montada
byte a byte com `alloc`/`poke` (sem `socket.c`), e todo o resto — accept loop,
threads, erros — também é [lex](examples/exemplo.lex). As syscalls
(`socket`/`bind`/`listen`/`accept`) entram via `declare function` da libc.

### Template literals e componentes server-side

Template literals como no TS, com conversão automática de número:

```lex
const nome: ptr = "lex";
Terminal.log(`ola, ${nome}! soma = ${2 + 40}`);   // ola, lex! soma = 42
```

Por baixo, a concatenação acontece numa **arena por thread** (runtime mínima
embutida no lex): nada de GC — numa thread de `spawn`, a arena inteira é
liberada quando a função termina, ou seja, **uma arena por requisição** no
servidor, estilo Apache.

### Componentes estilo React, com structs e JSX

`type` define um struct (as props); um componente é uma função que recebe
props e devolve `Component` (HTML). `<Card .../>` é **JSX**: açúcar para a
chamada `Card({...})` com os atributos virando os campos do struct. Cada
requisição renderiza numa thread própria, com arena própria (sem GC):

A [`std/http.lex`](std/http.lex) é uma **classe**: você instancia
`new Server(porta)` e chama `start(handler)`. O `handler` recebe um `Conn`
(a conexão, com os métodos `recv`/`send`/`respond` compartilhando `this.conn`)
e devolve o HTML. Cada conexão roda numa thread própria com um `Conn` próprio.

```lex
import { Server, Conn } from "http";

type Props = {
    titulo: string
    pontos: i64
}

function Card(props: Props): Component {
    return `<div class="card">
        <h2>${props.titulo}</h2>
        <p>pontos: ${props.pontos}</p>
    </div>`;
}

function App(c: Conn): Component {
    return `<html><body>
        <h1>ola do lex!</h1>
        <Card titulo="primeiro card" pontos={42} />
        <Card titulo="segundo card" pontos={7} />
    </body></html>`;
}

function main(): i32! {
    const app: Server = new Server(8080);
    try app.start(App);
    return 0;
}
```

```sh
./bin/lex examples/exemplo.lex -o site
./site &
curl localhost:8080      # HTML composto pelos componentes, props interpoladas
```

`type` é um struct alocado na arena (ponteiro para um bloco de campos);
`string` e `Component` são aliases de `ptr`. Atributos JSX aceitam string
(`titulo="..."`) ou expressão (`pontos={42}`). Tags minúsculas (`<div>`) são
HTML literal; só as maiúsculas (`<Card>`) são componentes. Exemplo completo:
[`examples/exemplo.lex`](examples/exemplo.lex).

**Filhos e listas.** Um componente pode receber **filhos** se declarar um campo
`children: string` (como no React): tudo entre `<Card>` e `</Card>` — texto,
`${...}` e JSX aninhado — chega nesse campo. E interpolar um **array** num
template renderiza a **lista** (os elementos são concatenados, sem separador),
o que dá loops de componentes:

```lex
type Card = { title: string, children: string }
fn Card(p: Card): Component {
    return `<div class="card"><h2>${p.title}</h2>${p.children}</div>`;
}

let tags: Component[] = [];
tags.push(`<Tag name="lex" />`);
tags.push(`<Tag name="wasm" />`);

const page: Component = `<Card title="features">
    <p>com filhos e listas</p>
    ${tags}
</Card>`;
```

`children` é opcional (um `<Card/>` self-closing simplesmente não o passa).
Exemplo completo: [`examples/exemplo.lex`](examples/exemplo.lex).

### Etapa 2 do "React para lex": WebAssembly

`--target wasm` emite um módulo `.wasm` usando o mesmo codegen LLVM (só muda o
alvo, para `wasm32`). A runtime em C é compilada **freestanding** junto — um bump
allocator sobre a memória linear, com `mem*`/`str*`/`printf` próprios — então
**strings, JSON, arrays, Map, classes (com herança/dispatch), filesystem e até
`spawn`/canais rodam no browser, no servidor e embutidos no próprio `lex`**, com
saída idêntica à do nativo:

```sh
./bin/lex examples/exemplo.lex --target wasm -o dados.wasm --run
./bin/lex dados.wasm            # roda um .wasm já compilado
```

`--run` (e `lex arquivo.wasm`) executam o módulo num **runtime wasm embutido no
próprio compilador** ([wasmi](https://github.com/wasmi-labs/wasmi), 100% Rust):
nada de Node nem ferramenta externa. A única dependência do módulo é **um import
de host** — `lex.write(fd, ptr, len)` para a saída; programas com filesystem
também importam `lex.fs_*`/`lex.fd_*`. Esses imports são atendidos nativamente
por [`src/wasm_host.rs`](src/wasm_host.rs); os hosts de referência para o browser
(e um host Node opcional) estão em [`web/`](web/). No wasm base
(single-thread) o `spawn` roda **síncrono** (resultado correto, sem paralelismo);
paralelismo real e sockets são os próximos passos. Veja [web/README.md](web/README.md).

### Dados: arrays, strings, maps e JSON

lex tem três tipos dinâmicos — todos ponteiros para um bloco na **arena da
thread** (a mesma dos template literals): sem GC, liberados de uma vez no fim
da thread/requisição. Os helpers são _builtins_ (entram em [`src/builtins.rs`](src/builtins.rs),
com a runtime em C em [`src/runtime.c`](src/runtime.c)).

> **Sintaxe de método.** Todo helper de string/array/map/json também pode ser
> chamado como método sobre o primeiro argumento — `xs.push(40)` é açúcar para
> `push(xs, 40)`, `csv.split(",")` para `split(csv, ",")`. As duas formas
> convivem e podem ser encadeadas (`titulo.trim().toLower()`). Métodos de
> classe/struct têm precedência, então um `obj.metodo()` continua chamando o
> método do objeto, não o builtin.

**Arrays tipados** `T[]` — literal `[...]`, índice `a[i]` (leitura e escrita),
e os helpers `push`/`pop`/`slice`/`len`/`join`. Encadeáveis: `i64[][]`.

```ts
let xs: i64[] = [10, 20, 30];
xs.push(40);
Terminal.log(xs[0]);           // 10
Terminal.log(xs.len());        // 4
xs[0] = 99;
const nomes: string[] = ["ana", "bia"];
Terminal.log(nomes.join(", "));   // ana, bia
```

**Helpers de string** (o `==` compara endereços; para texto use `strEq`):
`len`, `substring`, `indexOf`, `contains`, `startsWith`, `endsWith`,
`toUpper`, `toLower`, `trim`, `strEq`, `charAt`, `charCode`, `parseInt`,
`parseFloat` (texto → `f64`), `str` (int → texto), `repeat`, `replace`,
`concat` e `split` (→ `string[]`).

```ts
const cols: string[] = "id,nome,idade".split(",");
Terminal.log(cols[1]);                     // nome
Terminal.log("lex".substring(0, 2).toUpper());   // LE
```

**Map** `Map<T>` — dicionário de chave string. Literal `{ "k": v }` (chave
**string**, o que o diferencia do struct literal `{ k: v }`) e os helpers
`mapGet`/`mapSet`/`mapHas`/`keys`/`len`.

```ts
let estoque: Map<i64> = { "maçã": 12, "pera": 7 };
estoque.mapSet("uva", 30);
Terminal.log(estoque.mapGet("maçã"));     // 12
Terminal.log(estoque.len());               // 3
```

**JSON** `json` — valor dinâmico (null/bool/número/string/array/objeto) com
parser e serializador de verdade:

```ts
const req: json = jsonParse("{\"user\": \"lex\", \"roles\": [\"dev\", \"ops\"]}");
Terminal.log(jsonAsStr(jsonGet(req, "user")));            // lex
Terminal.log(jsonAsStr(jsonAt(jsonGet(req, "roles"), 0))); // dev

const resp: json = jsonObject();
jsonSet(resp, "ok", jsonBool(1));
jsonSet(resp, "total", jsonNum(2));
Terminal.log(jsonStringify(resp));         // {"ok":true,"total":2}
```

Acesso: `jsonGet(j, chave)` (objeto), `jsonAt(j, i)` (array), `len(j)`,
`jsonTypeof(j)`, `jsonIsNull(j)`. Escalares: `jsonAsInt`/`jsonAsStr`/
`jsonAsBool`. Construtores: `jsonNum`/`jsonStr`/`jsonBool`/`jsonNull`/
`jsonObject`/`jsonArray` + `jsonSet`/`jsonPush`. Exemplo completo:
[`examples/exemplo.lex`](examples/exemplo.lex).

### Classes: OOP com herança e polimorfismo

`class` traz programação orientada a objeto completa, na sintaxe do
TypeScript: campos, `constructor`, métodos, `private`, `static`, `extends`,
`super` e `this`.

```ts
class Animal {
    nome: string
    private energia: i64        // visível só dentro de Animal

    constructor(nome: string, energia: i64) {
        this.nome = nome
        this.energia = energia
    }

    falar(): string { return "..." }

    status(): string {
        return `${this.nome} diz: ${this.falar()}`
    }
}

class Cachorro extends Animal {
    constructor(nome: string) {
        super(nome, 100)        // construtor do pai (obrigatório se ele existir)
    }
    falar(): string { return "au au!" }   // override

    static especie(): string { return "Canis familiaris" }
}

function apresenta(a: Animal) {
    Terminal.log(a.status())             // polimorfismo: o falar() da classe concreta
}

function main(): i32 {
    const rex = new Cachorro("Rex")
    apresenta(rex)              // "Rex diz: au au!"
    Terminal.log(Cachorro.especie())     // método estático: chama na classe
    return 0
}
```

Por baixo, um objeto é um bloco na arena da thread: o slot 0 guarda a
**vtable** da classe concreta (um array global com os endereços dos métodos)
e os slots seguintes guardam os campos (8 bytes cada, como nos structs).
Toda chamada de método é indireta pela vtable — é isso que faz `a.falar()`
executar a implementação de `Cachorro` mesmo quando `a` é tipado como
`Animal`. `super(...)` e `super.metodo(...)` são chamadas diretas (sem
vtable), e o `new` instala a vtable e zera os campos antes do construtor.

Regras que o compilador força:

- override exige assinatura idêntica (parâmetros, retorno e `!`);
- `private` (campo ou método) só é acessível dentro da classe que o declarou;
- construtor de subclasse precisa chamar `super(...)` se o pai tem construtor;
- métodos podem ser falíveis (`sacar(v: i64): i64!`) e integram com
  `try`/`catch` normalmente: `const x = conta.sacar(50) catch 0`;
- herança cíclica, override com assinatura diferente e campo sombreando
  campo herdado são erros de compilação.

#### `interface` / `implements`

Uma `interface` declara só **assinaturas** (sem corpo). `implements` faz o
compilador EXIGIR que a classe cumpra o contrato — cada método tem de existir,
**público**, de instância e com assinatura idêntica (parâmetros, retorno e
`!`). Um método **herdado** conta. É só checagem em tempo de compilação: a
interface não gera código nem layout.

```ts
interface Identificavel {
    papel(): string
    cartao(): string
}

// a classe pode combinar extends + implements (e várias interfaces):
class Pessoa implements Identificavel {
    nome: string
    papel(): string  { return "pessoa" }
    cartao(): string { return this.nome }
}
```

O nome de uma interface **não é um tipo de valor** (não vale em parâmetro,
campo ou variável — só com `implements`). Faltar um método, divergir a
assinatura, ou marcá-lo `private` é erro de compilação, com a assinatura
esperada na mensagem.

Exemplo completo: [`examples/exemplo.lex`](examples/exemplo.lex).

Um tour por (quase) toda a linguagem num arquivo só — OOP, arrays/strings/maps/
JSON, erros, funções como valor, threads + canais e memória crua — está em
[`examples/exemplo.lex`](examples/exemplo.lex).

### Operadores, controle de fluxo, floats e genéricos

O conjunto de operadores é o que você espera de uma linguagem estilo C/TS:

```ts
// comparações, lógicos (curto-circuito) e módulo
if (idade >= 18 && idade <= 65) { /* ... */ }
const par: bool = n % 2 == 0;
// bitwise e atribuição composta
let flags: i64 = 0;
flags = flags | 4;
flags <<= 1;
contador++;            // ++ -- += -= *= /= %=
// unários: -x, !flag, ~bits
```

`for` (estilo C) e `for...of` (sobre arrays), com `break`/`continue`:

```ts
for (let i: i64 = 0; i < 10; i++) {
    if (i % 2 == 1) { continue; }
    if (i > 6) { break; }
}
for (const nome of ["ana", "bia"]) { Terminal.log(nome); }
```

`match` — pattern matching com literais, `_` (curinga), binding, **faixas**
(`lo..hi`, intervalo `[lo, hi)`) e **guardas** (`padrão if cond`). É uma
**expressão**: o valor é o do braço que casar.

```ts
// como statement
match (cmd) {
    "start" => Terminal.log("iniciando"),
    "stop"  => Terminal.log("parando"),
    outro   => Terminal.log("desconhecido:", outro),   // binding
}

// como expressão, com faixa e guarda
const faixa: string = match (n) {
    x if x < 0 => "negativo",   // guarda
    0..10      => "dígito",     // faixa [0, 10)
    _          => "grande",
};
```

**Ponto flutuante** (`f64` e `f32`): literais `3.14`, aritmética, comparações e
uma biblioteca de math freestanding (sem libm): `sqrt`/`floor`/`ceil`/`round`/
`fabs`/`sin`/`cos`/`tan`/`exp`/`ln`/`log10`/`pow`, além de `min`/`max`
(polimórficos int/float). Inteiro vira float automaticamente no contexto certo,
e `f32`↔`f64` convertem sozinhos; o cast para inteiro trunca. Internamente o
float viaja na mesma célula de 8 bytes do lex (o padrão de bits — `f64` inteiro,
`f32` nos 32 bits baixos):

```ts
const area: f64 = 3.14159 * r * r;
const media: f64 = soma / n;       // se um lado é f64, divide como float
const x: f32 = 1.5;                 // f32 distinto; promove p/ f64 nos cálculos
Terminal.log(`raiz: ${sqrt(2.0)}`); // raiz: 1.414214
```

**Genéricos** (`T`) em funções e classes. O runtime é uniforme (toda célula é
i64, então `T` não duplica código — sem inchar o binário), mas os **argumentos
de tipo são reificados**: `Box<string>`, `id<f64>(x)` ou a inferência pelo
argumento (`primeiro(xs)`) carregam o tipo concreto, então `${}`, o boxing de
`any` e até floats através de um `T` saem certos — sem precisar anotar na leitura.

```ts
fn primeiro<T>(xs: T[]): T { return xs[0]; }

class Pilha<T> {
    items: T[]
    constructor() { this.items = [] }
    push(x: T) { this.items.push(x) }
    pop(): T { return this.items.pop() }
}

const p: Pilha<i64> = new Pilha<i64>();
p.push(10); p.push(20);
Terminal.log(p.pop());                  // 20

const nomes: string[] = ["ana", "bia"];
Terminal.log(`primeiro: ${primeiro(nomes)}`);   // ana — tipo concreto preservado
```

Veja tudo junto em [`examples/exemplo.lex`](examples/exemplo.lex).

## Testes

Os testes do seu programa são escritos **em lex**, em arquivos `*.test.lex`, no
estilo Jest/Mocha. Esses arquivos **não têm `function main`** — só `describe` /
`test` / `it` / `expect` no topo. O comando `lex test` descobre todos eles,
roda cada um e agrega o resultado (saída colorida, exit code pra CI):

```lex
// examples/tests/math.test.lex  —  sem function main!
fn dobro(x: i64): i64 { return x * 2; }

describe("aritmética", () => {
    test("dobro", () => {
        expect(dobro(21)).toBe(42);          // int
        expect(10).toBeGreaterThan(5);
    });
    it("strings, floats e arrays — o MESMO expect", () => {
        expect("le".toUpper()).toBe("LE");           // string (por conteúdo)
        expect(7.0 / 2.0).toBeCloseTo(3.5, 0.0001);  // float com tolerância
        expect([1, 2, 3]).toBe([1, 2, 3]);           // igualdade profunda
    });
});
```

```sh
lex test                 # roda todos os *.test.lex (recursivo); exit 0 = tudo passou
lex test examples/tests  # ou aponte uma pasta
```

Num arquivo `.test.lex`, o compilador injeta a biblioteca de testes e encerra
com `return testReport()` automaticamente — por isso nada de `main` nem de
`import`. Os corpos de `describe`/`test` são arrow functions (que podem
capturar variáveis de fora por valor, se precisar).

## Formatador (`lex fmt`)

```sh
lex fmt arquivo.lex          # reescreve formatado (in-place)
lex fmt --check src/*.lex    # CI: só confere, exit 1 se algo seria reformatado
```

O `lex fmt` é deliberadamente conservador e **seguro por construção**: só
normaliza a indentação (pela profundidade de `{}`/`[]`/`()`), tira espaço no
fim das linhas e colapsa linhas em branco repetidas. Ele **não** reescreve
código, não junta/quebra linhas e **nunca toca o interior de strings ou de
template literals** (onde o espaço faz parte do texto). Como o lex usa chaves e
quebras de linha para a sintaxe, mexer só na indentação não muda a tokenização
— ou seja, formatar nunca altera a semântica do programa. É idempotente.

## Diagnósticos e editor (`lex check`, `lex lsp`)

```sh
lex check arquivo.lex          # roda parser+sema (sem codegen); exit 0/1 (CI)
lex check --json arquivo.lex   # diagnósticos em JSON (consumido pelo LSP)
lex lsp                        # Language Server por stdio (diagnostics ao vivo)
```

O `lex lsp` é um Language Server mínimo que dá **diagnósticos ao vivo**: a cada
edição ele roda a análise (`lex check`) num subprocesso e republica os erros.
Qualquer cliente LSP serve — configure-o para iniciar `lex lsp` na linguagem
`lex`. Hoje os erros de semântica aparecem no painel de Problemas sem posição
precisa (caem na linha 0); posições por span no sema são um próximo passo.

Há **um único `expect`** para qualquer tipo (int, bool, float, string, array,
json): o valor é embrulhado em `any` e os matchers comparam por **valor**.
Matchers: `toBe`/`toEqual`/`notToBe` (igualdade profunda — números, strings por
conteúdo, floats, coleções), `toBeTruthy`/`toBeFalsy`, `toBeGreaterThan`/
`toBeLessThan` (numéricos), `toContain` (substring) e `toBeCloseTo(want, eps)`
(floats). Exemplos: [`examples/tests/`](examples/tests/).

> **Embutir testes num programa normal** (com `main`): importe de `"test"` e
> chame `testReport()` você mesmo (estilo BDD), ou use a classe `Test`
> (`new Test()` + `eq`/`ok`/`eqStr`/`near` + `done()`) quando quiser o placar à
> mão. Veja [`examples/teste.lex`](examples/teste.lex).

**Testes do próprio compilador.** O compilador é testado *em lex*:

- [`tests/`](tests/) — a suíte por módulo (lexer, parser, sema, codegen, fmt, json,
  toml, semver, pkg, diag, interp, math, strings, e2e). Rode `./bin/lex test tests/*.test.lex`.
- [`tests/parity.test.lex`](tests/parity.test.lex) — o **portão de paridade**:
  21 programas de linguagem completa (OOP/vtable, genéricos, `try`/`catch`, `async`/
  `await`, closures com captura, `enum`, `match` com guarda/faixa/destructuring,
  campos `static`, indexação de Map/JSON…) que são compilados, linkados e
  **executados**, conferindo o exit code.
- [`scripts/bootstrap.sh`](scripts/bootstrap.sh) — o **ponto-fixo**: o compilador
  recompila a si mesmo duas vezes e a IR tem de sair byte a byte igual.

## Editor (VS Code)

Há uma extensão em [`editors/vscode-lex`](editors/vscode-lex) que faz **syntax
highlighting** e embute um **cliente LSP** (diagnósticos ao vivo via `lex lsp`).
O highlighting realça keywords, tipos (`i32`/`i64`/`ptr`/`void`/`string`/
`Component`/`json`/`Map`/`T[]`), `type`/structs, classes (`class`/`extends`/
`new`/`private`/`static`/`this`/`super`), funções (`function`/`fn`), strings e
**template literals com HTML embutido** (as tags dentro de `` `...` `` viram
HTML de verdade e o `${...}` continua código lex), `import`/`declare`, os
builtins (`len`, `push`, `split`, `jsonParse`, …), parâmetros e operadores —
além de auto-fechar aspas/crase e indentar por blocos.

Para instalar, gere o bundle (precisa de Node) e copie a pasta:

```sh
cd editors/vscode-lex && npm install && npm run compile && cd -
cp -R editors/vscode-lex ~/.vscode/extensions/lex.lex-lang-0.1.0
# no VS Code: Cmd+Shift+P -> "Developer: Reload Window"
```

O cliente acha o servidor procurando `bin/lex` na raiz do workspace — então rode `./scripts/build-seed.sh`
antes. Para apontar um binário específico, use a setting `lex.server.path`. O
cliente **não** usa o `lex` do PATH por padrão (em Unix `/usr/bin/lex` costuma
ser o flex). Comando `lex: Reiniciar o Language Server` reinicia o `lex lsp`.

### Neovim (sem plugins, 0.8+)

[`editors/nvim/lex.lua`](editors/nvim/lex.lua) é um módulo drop-in que registra
o filetype `lex` e sobe o `lex lsp`. Copie para o runtimepath e chame no
`init.lua`:

```lua
require("lex").setup()                          -- acha o binário no projeto
-- require("lex").setup({ cmd = "/caminho/lex" })  -- binário explícito
```

## Roadmap

- [x] `if`/`else` e operadores de comparação (`== != < >`)
- [x] Saída de terminal (`Terminal.log`/`info`/`warn`/… via libc `write`)
- [x] Análise semântica antes do codegen (`sema.rs`)
- [x] Erros como valores forçados (`!`, `fail`, `try`, `catch`)
- [x] Threads (`spawn`/`join` via pthreads, sem runtime)
- [x] `async`/`await` (açúcar sobre threads reais: `async fn` → `Future<T>` via spawn, `await` → join; **sem runtime de async**, sem function coloring/event-loop) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Suíte de testes EM LEX: por módulo (`tests/`) + portão de paridade ponta-a-ponta (`tests/parity.test.lex`) + ponto-fixo do bootstrap
- [x] Biblioteca de testes **nativa** ([`std/test.lex`](std/test.lex)) + runner `lex test`: arquivos `*.test.lex` SEM `main`, só `describe`/`test`/`it`/`expect(x).toBe(y)` (um `expect` p/ qualquer tipo, com matchers); saída colorida e exit code pra CI ([`examples/tests/`](examples/tests/))
- [x] Sintaxe TypeScript-like (`function`/`fn`, `const`, `: tipo`)
- [x] Loops (`while`)
- [x] Retorno padrão 0 (`return;` vazio ou nenhum `return` = `return 0`)
- [x] Mutabilidade (`let`) com `alloca`/`store`/`load`
- [x] `main` opcional: statements no topo viram um `main` sintetizado ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] `main` falível (erro não tratado → stderr + exit code)
- [x] `spawn` fire-and-forget (`pthread_detach`)
- [x] Funções como valor (`(i64) => i64`) e arrow functions sem captura
- [x] FFI estilo TS: `declare function` + `import { } from` (com auto-link de `.c`)
- [x] Strings (literais → constantes globais) e tipo `ptr`
- [x] `void` e retorno padrão 0 (`return;` / sem return)
- [x] Servidor HTTP multithread ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Template literals com arena por thread (runtime embutida)
- [x] `std/http.lex`: servidor como classe (`new Server(porta).start(handler)`, com `Conn`)
- [x] Structs (`type Nome = {...}`), acesso a campo, `string`/`Component`
- [x] Componentes estilo React com **JSX** (`<Card .../>`) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] OOP completa: `class`, `new`, `extends`, vtable (polimorfismo), `super`, `private`, `static` ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] `interface` + `implements`: contrato de assinaturas checado em compilação (método herdado conta) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Arrays tipados (`T[]`, `[...]`, `a[i]`, `push`/`pop`/`slice`/`len`/`join`) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Helpers de string (`substring`, `split`, `indexOf`, `toUpper`, `strEq`, …)
- [x] Map tipado (`Map<T>`, `{ "k": v }`, `mapGet`/`mapSet`/`keys`)
- [x] JSON dinâmico (`jsonParse`/`jsonStringify` + acessores e construtores)
- [x] JSX com filhos (`<Card>...</Card>`) e listas (array interpolado no template) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Backend WebAssembly (`--target wasm`) — programas puros rodam, libc vira import
- [x] `sockaddr_in` nativo em lex (aposentou o `std/socket.c`) — via `alloc`/`poke`
- [x] Mais tipos: `bool` (`true`/`false`) e `i8`
- [x] Checagem de tipos no struct literal (campo faltando/desconhecido/duplicado)
- [x] Captura do código de erro no `catch` (`f() catch e { ... }`)
- [x] `defer` (LIFO, por caminho de saída) e memória dinâmica (`alloc`/`free`, `poke`/`peek`) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Canais entre threads (`Channel<T>`, `channel`/`send`/`recv`, estilo Go) ([`examples/exemplo.lex`](examples/exemplo.lex))
- [x] Runtime wasm **embutido** no compilador ([`src/wasm_host.rs`](src/wasm_host.rs), via wasmi): `lex app.lex --target wasm --run` e `lex app.wasm` rodam **sem Node**
- [x] Toolchain de cross-compile **100% LLVM 18, sem zig**: runtime FREESTANDING por SO — Linux via syscalls cruas + `ld.lld`, Windows via Win32 API + `lld-link` (import libs geradas com `llvm-lib`), macOS via `clang -arch`. Verificado em Docker: Linux x64 (qemu)/arm64 (nativo) e Windows x64 (wine) rodam hello/dados/arquivos/threads/canais/servidor idênticos ao nativo

- [x] Operadores de comparação `<=`/`>=` e módulo `%`
- [x] Operadores lógicos com curto-circuito (`&&`, `||`) e unários (`!`, `-`, `~`)
- [x] Bitwise (`&`, `|`, `^`, `<<`, `>>`) e atribuição composta (`+=`, `-=`, …, `++`, `--`)
- [x] `for` (estilo C) e `for...of` (itera arrays), com `break`/`continue`
- [x] Pattern matching: `match (x) { padrão [if guarda] => ..., _ => ... }` — como **expressão** (`const y = match (...)`), com **guardas** (`x if x > 0`), **faixas** (`1..10`), literais, `_`, binding, **padrões de tipo** (`Circle c => ...`, casa pela vtable o tipo de runtime do objeto e liga já tipado) e **destructuring** (`{x, y} => x + y`, liga campos de struct/objeto)
- [x] Ponto flutuante: `f64` **e `f32`** (literais `3.14`, aritmética, comparações, conversões int↔f32↔f64, JSON)
- [x] Biblioteca de math: `sqrt`/`floor`/`ceil`/`round`/`fabs`/`sin`/`cos`/`tan`/`exp`/`ln`/`log10`/`pow` e `min`/`max` (polimórficos int/float) — freestanding, sem libm
- [x] Tipos genéricos (`T`) em funções e classes (`fn id<T>`, `class Box<T>`): args de tipo **reificados** — `Box<string>`, `id<f64>(x)` e inferência por argumento (`first(xs)`) carregam o tipo concreto (runtime uniforme i64, sem inchar o binário). `${}` e boxing de `any` de valores genéricos saem certos.
- [x] Gerenciador de pacotes embutido (`lex init`/`add`/`install`/`update`/`remove`/`list`): manifesto+lockfile em TOML (`lex.toml`/`lex.lock`), `lex_modules/` por projeto, deps transitivas, semver via tags git; fontes registry (índice git em `~/.lex/registry`), URL git e `file:` — rede só pelo `git`, sem cliente HTTP
- [x] Checagem de tipos nos argumentos de chamadas: além do struct literal, o tipo de cada argumento é conferido contra o parâmetro (escalares coagem entre si, polimorfismo aceita subclasse, genéricos/`any`/`json` passam) — pega `f("x")` num `f(n: i64)` em compilação
- [x] Indexação por `[]` em **Map** e **JSON** (além de arrays): `m["k"]`, `m["k"] = v`, `j["campo"]`, `j[i]` e encadeado `j["nums"][2]`
- [x] `spawn obj.metodo(args)`: roda o método de instância em outra thread (`obj` vira o `this`, despacho estático pelo tipo declarado)
- [x] Campos `static` em classes: `static n: i64 = 0` (estado de classe compartilhado), acessado por `Classe.n`, com leitura/escrita, `private`, herança (storage compartilhado) e inicializador qualquer (rodado uma vez na entrada do programa)
- [x] `enum Cor { Red, Green, Blue }`: constantes inteiras nomeadas (`Cor.Red` = 0, 1, 2…), tipo `Cor`, comparação (`c == Cor.Red`) e padrão de variante no `match` (`Cor.Red => ...`)
- [x] Formatador `lex fmt` (e `lex fmt --check` para CI): normaliza indentação/espaços de forma conservadora, preservando comentários e o interior de templates — seguro por construção (não altera a semântica) e idempotente
- [x] **Closures com captura** (por valor): arrow functions capturam variáveis do escopo de fora (e `this`) — representadas como "closure box" (`[fn_ptr, capturas]`) com env passado na chamada; função nomeada como valor vira um thunk. ABI uniforme de valor-função
- [x] Tipo de retorno de arrow inferido do contexto: `const h: () => f64 = () => 2.5` não precisa mais de `(): f64 =>` — o `Fn` esperado define o tipo de retorno (a assinatura no IR é a mesma, célula i64)
- [x] `lex check` (validação parser+sema sem codegen, p/ CI) e `lex lsp` (Language Server por stdio com diagnostics ao vivo)
- [x] Tooling de registry: `lex registry init`/`add` e `lex publish` para criar/manter o índice de pacotes (o índice é um repo git com `packages/<nome>.toml`)
- [x] **Registry como SITE, escrito em lex** ([`registry-site/`](registry-site/)): um servidor HTTP em lex (dogfooding do próprio `std/http.lex` + fs + JSON) com lista/busca, página de detalhe e API JSON. Com `LEX_REGISTRY_API=<url>`, o `lex add` resolve por `GET /api/pkg/<nome>` e o `lex publish` faz `POST /api/publish` (rede via `curl`, como o `git`; auth opcional por token). Deploy via [`Dockerfile`](registry-site/Dockerfile) — cross-compila o site para um binário estático e roda num `scratch`

- [x] Posições por **span** nos erros de sema: cada diagnóstico carrega o trecho do fonte (statement/definição) etiquetado por módulo; o `lex check --json` devolve linha/coluna exatas (e o CLI desenha o trecho sublinhado), então o `lex lsp` aponta o ponto certo no editor em vez do painel de Problemas
- [x] Cliente LSP empacotado na extensão do VS Code (`vscode-languageclient` que sobe o `lex lsp`) + config drop-in para Neovim ([`editors/nvim/lex.lua`](editors/nvim/lex.lua))
- [x] **Inferência de tipo de retorno** (estilo Hindley-Milner): funções sem `: T` têm o retorno inferido do corpo por unificação num ponto-fixo (cobre recursão mútua) — `function double(x: i64) { return x * 2 }` é `i64`, `function pi() { return 3.14 }` é `f64`. Soma-se à inferência já existente (variáveis, argumentos, genéricos, valor-função e retorno de arrow). Tipos de parâmetro continuam anotados de propósito (ABI de valor-função, floats, FFI, módulos separados)
- [x] **Threads reais no `--target wasm`** (`--wasm-threads`): memória linear compartilhada + atomics; cada `spawn`/`async` vira um **Web Worker** (thread do SO de verdade) e `join`/`await` espera por um slot atômico. Verificado em Node: 4 workers de 120M iterações cada terminam no tempo de 1 (paralelismo real, não a execução síncrona do `wasmi`). Ver [web/README.md](web/README.md). O módulo com threads roda num host de workers (Node/browser com COOP/COEP), não no runtime embutido

### Limitações conhecidas (não são roadmap — são decisões/restrições)

- **HM total com inferência de parâmetros** não é objetivo: o lex abraça anotações; inferir tipos de parâmetro entre funções/módulos seria reescrever o type-checker por ganho marginal e quebraria a ABI de valor-função, floats e a FFI.
- **wasm + threads**: o resultado de `spawn`/`join`/`await` trafega por um `void*` de 32 bits, então valores > 32 bits truncam no wasm (no nativo são 64 bits). `Channel<T>` no wasm ainda é uma FIFO single-thread — para paralelismo use `spawn`+`join`. Sockets no browser dependem da camada de rede do host.
