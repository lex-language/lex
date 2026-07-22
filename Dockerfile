# Dockerfile — a landing page do lex, servida pelo próprio lex.
#
# Dois estágios porque o lex COMPILA para binário nativo: o clang só é
# necessário para construir, nunca para servir. O estágio final não tem
# compilador nenhum — só o binário do servidor e os arquivos estáticos.
#
#   1. bootstrap: a semente (LLVM IR do compilador-em-lex) vira `bin/lex`
#   2. `lex server --build`: as páginas .lsx viram um servidor nativo
#   3. runtime: debian slim + o binário
#
# Construir:  docker build -t lex-site .
# Rodar:      docker run -p 3000:3000 lex-site

# ── estágio 1: constrói o compilador e o servidor ────────────────────────────
FROM debian:bookworm-slim AS build

# clang é a ÚNICA dependência do bootstrap (o compilador é escrito em lex) —
# mas precisa ser >= 15: a semente é IR com PONTEIRO OPACO (`ptr`), e o clang 14
# que o bookworm instala como `clang` recusaria o arquivo inteiro.
# gzip descomprime a semente; diffutils faz a checagem de ponto-fixo.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends clang-16 gzip diffutils ca-certificates \
 && ln -sf /usr/bin/clang-16 /usr/local/bin/clang \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# a semente vira bin/lex e valida o ponto-fixo (o compilador reproduz a si
# mesmo byte a byte). Se a semente estiver dessincronizada do fonte, falha aqui.
RUN ./src/scripts/build-seed.sh

# as rotas são os .lsx de site/pages/; o servidor sai como binário nativo.
# O `mkdir` não é cerimônia: o build escreve o .ll ao lado do binário, e sem o
# diretório o clang falha com "no such file or directory: '/out/lex-site.ll'".
RUN mkdir -p /out && ./bin/lex server site/ --build /out/lex-site

# ── estágio 2: só o que serve ────────────────────────────────────────────────
FROM debian:bookworm-slim

# o binário é nativo e dinâmico contra a glibc; nada de toolchain aqui.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --uid 10001 lex

WORKDIR /site
# public/ é lido em RUNTIME, por caminho relativo ao diretório atual — daí o
# WORKDIR e a cópia. As páginas, ao contrário, já estão compiladas no binário.
COPY --from=build /src/site/public ./public
COPY --from=build /out/lex-site /usr/local/bin/lex-site

USER lex
EXPOSE 3000
# a porta é a do lex.toml no build; `--port` ainda vence em runtime.
CMD ["lex-site", "--port", "3000"]
