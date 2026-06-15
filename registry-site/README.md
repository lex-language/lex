# lex registry — o site (escrito em lex)

O registry de pacotes do lex como um **site HTTP escrito na própria linguagem**
([`server.lex`](server.lex)) — dogfooding do servidor HTTP, do filesystem e do
JSON do lex. Substitui (ou complementa) o índice git: os clientes publicam e
resolvem pacotes pela API HTTP.

## Rotas

| Método | Rota | O que faz |
|---|---|---|
| `GET`  | `/`               | lista + busca de pacotes (HTML) — `?q=<termo>` |
| `GET`  | `/pkg/<nome>`     | página de detalhe do pacote (HTML) |
| `GET`  | `/api/packages`   | índice inteiro em JSON |
| `GET`  | `/api/pkg/<nome>` | um pacote em JSON — **é o que o `lex add` consome** |
| `POST` | `/api/publish`    | publica/atualiza um pacote (usado por `lex publish`) |

Cada pacote é um arquivo `data/<nome>.json` = `{ name, repo, version, description }`.

## Rodar local

```sh
lex registry-site/server.lex -o registry   # compila (rode da raiz do repo: usa std/)
./registry                                  # escuta em http://localhost:8080
```

## Conectar o `lex` ao site

O compilador fala com o site por HTTP quando `LEX_REGISTRY_API` está definido
(a rede é via `curl`, como o `git`):

```sh
export LEX_REGISTRY_API=http://localhost:8080

# publicar o pacote do diretório atual (lê lex.toml + o remote 'origin')
lex publish

# resolver/instalar pela API (GET /api/pkg/<nome> → repo git → clona por tag)
lex add greet
```

Sem `LEX_REGISTRY_API`, o `lex` cai no índice git (`LEX_REGISTRY` /
`github.com/lex-language/registry`). Para tornar o site o padrão de todos,
preencha `DEFAULT_REGISTRY_API` em `src/pkg.rs` com a URL hospedada.

## Autenticação (opcional)

Se existir um arquivo `data/.token`, o `POST /api/publish` exige um campo
`token` igual no corpo. O `lex publish` envia o valor de `LEX_REGISTRY_TOKEN`:

```sh
echo "um-segredo" > data/.token            # no servidor
LEX_REGISTRY_TOKEN=um-segredo lex publish  # no cliente
```

Sem `data/.token`, o publish é aberto (bom para uso local/privado).

## Deploy (Docker)

A imagem é multi-stage: compila o `lex` (Rust + LLVM 18) e **cross-compila o
site para um binário estático linux-x64**, que roda numa imagem `scratch`
(sem SO/libc).

```sh
docker build -f registry-site/Dockerfile -t lex-registry .
docker run -p 8080:8080 -v lexdata:/srv/data lex-registry
```

O volume em `/srv/data` persiste os pacotes publicados. O servidor escuta em
`0.0.0.0:8080`. Atrás de um proxy (Caddy/nginx) para TLS, aponte os clientes
com `LEX_REGISTRY_API=https://seu-dominio`.

## Limitações (v1)

- A requisição é lida num único `read` (até 8 KiB) — basta para GETs e publishes
  pequenos; payloads grandes seriam truncados.
- A página de detalhe mostra a versão publicada; listar todas as tags exigiria o
  site falar git (fora do escopo).
- A busca é por substring no nome (sem URL-decode de `%xx`).
