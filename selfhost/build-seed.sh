#!/usr/bin/env bash
# build-seed.sh — constrói o `lex` A PARTIR DA SEMENTE, sem nenhum compilador lex
# prévio e sem Rust. Só precisa de clang.
#
# A semente (lex-seed.ll.gz) é o LLVM IR do próprio compilador-em-lex (lexcli.lex),
# gerado por ele mesmo no ponto-fixo. A IR é AGNÓSTICA de alvo (usa `ptr` opaco e
# células i64), então o mesmo arquivo serve em qualquer plataforma que o clang
# suporte. Depois de ter o `bin/lex`, ele recompila a si mesmo a partir do FONTE —
# a semente só existe para o primeiro passo.
#
#   ./selfhost/build-seed.sh          # -> bin/lex
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p bin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 1. descomprime a semente (IR do compilador-em-lex)"
gunzip -c selfhost/lex-seed.ll.gz > "$TMP/seed.ll"
printf "    %s linhas de LLVM IR\n" "$(wc -l < "$TMP/seed.ll" | tr -d ' ')"

echo "==> 2. clang: semente + runtime.c -> bin/lex"
clang -Wno-override-module -O2 -o bin/lex "$TMP/seed.ll" src/runtime.c -lpthread

echo "==> 3. o lex da semente recompila a SI MESMO a partir do fonte"
./bin/lex build selfhost/lexcli.lex -o "$TMP/lex1" | tail -1
"$TMP/lex1" build selfhost/lexcli.lex -o "$TMP/lex2" | tail -1
if diff -q "$TMP/lex1.ll" "$TMP/lex2.ll" >/dev/null; then
    echo "    ✓ ponto-fixo: o compilador reproduz a si mesmo byte a byte"
else
    echo "    ✗ ponto-fixo QUEBRADO — a semente está fora de sincronia com o fonte"
    echo "      rode ./selfhost/regen-seed.sh para regerá-la"
    exit 1
fi

echo
echo "✅ bin/lex pronto — construído sem Rust, só com clang."
./bin/lex version
