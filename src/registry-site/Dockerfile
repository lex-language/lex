# Imagem do registry-site do lex.
#
# Estágio 1: compila o compilador `lex` (Rust + LLVM 18) e CROSS-COMPILA o site
# (src/registry-site/server.lex) para um binário ESTÁTICO linux-x64 (runtime
# freestanding do lex: syscalls cruas + ld.lld, sem libc).
# Estágio 2: imagem mínima `scratch` só com o binário — sem SO, sem libc.
#
#   docker build -f registry-site/Dockerfile -t lex-registry .
#   docker run -p 8080:8080 -v lexdata:/srv/data lex-registry
#
# Os clientes apontam o `lex` para cá com:
#   export LEX_REGISTRY_API=http://SEU_HOST:8080

# --- estágio 1: build -------------------------------------------------------
FROM ubuntu:24.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential curl ca-certificates \
        llvm-18 llvm-18-dev llvm-18-tools clang-18 lld-18 libpolly-18-dev \
        libzstd-dev zlib1g-dev libffi-dev libxml2-dev libedit-dev libncurses-dev \
    && rm -rf /var/lib/apt/lists/*
RUN ln -sf /usr/bin/clang-18 /usr/local/bin/clang \
    && ln -sf /usr/lib/llvm-18/bin/wasm-ld /usr/local/bin/wasm-ld || true
WORKDIR /src
COPY . .
# o compilador é escrito EM LEX: sai da semente (LLVM IR) via clang, sem Rust.
RUN ./src/scripts/build-seed.sh
# binário estático do servidor (roda em qualquer linux-x64, inclusive scratch)
RUN ./bin/lex build src/registry-site/server.lex --target linux-x64 -o /registry

# --- estágio 2: runtime mínimo ---------------------------------------------
FROM scratch
COPY --from=builder /registry /registry
# o servidor cria/usa ./data sob o WORKDIR; monte um volume aqui para persistir
WORKDIR /srv
VOLUME /srv/data
EXPOSE 8080
ENTRYPOINT ["/registry"]
