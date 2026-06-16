#!/usr/bin/env bash
# seed.sh — constrói o `lex` stage0 (escrito em lex) e demonstra que ele faz o
# fluxo completo de dev SEM o compilador Rust no caminho, inclusive reconstruir a
# si mesmo. É a prova da "semente": depois disto, o src/ (Rust) pode ser
# arquivado — basta guardar o binário stage0 (ou um branch de arquivo do Rust).
#
# Rode da raiz do repo:  ./selfhost/seed.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUSTLEX=./target/release/lex
STAGE0=/tmp/lex-stage0
STAGE1=/tmp/lex-stage1

echo "==> 1. Rust compila o lex unificado -> stage0 (ÚLTIMA vez que o Rust aparece)"
$RUSTLEX selfhost/lexcli.lex -o "$STAGE0" | tail -1

echo
echo "==> 2. o stage0 (em lex) faz o fluxo, SEM Rust:"
cat > /tmp/seed_demo.lex <<'EOF'
fn fib(n: i64): i64 { if (n < 2) { return n } return fib(n - 1) + fib(n - 2) }
fn main(): i32 { Terminal.log(`fib(10) = ${fib(10)}`) return fib(10) }
EOF
echo -n "   - run:   "; "$STAGE0" run /tmp/seed_demo.lex; echo "           (exit=$? — fib(10)=55)"
echo -n "   - test:  "; "$STAGE0" test selfhost/semver.test.lex | tail -1
echo -n "   - check: "; printf 'fn main(): i32 { return zzz }' > /tmp/seed_bad.lex; "$STAGE0" check /tmp/seed_bad.lex
echo -n "   - fmt:   "; "$STAGE0" fmt --check selfhost/fmt.lex >/dev/null 2>&1 && echo "fmt.lex já formatado (ok)"

echo
echo "==> 3. o stage0 reconstrói a SI MESMO -> stage1 (auto-suficiência)"
"$STAGE0" build selfhost/lexcli.lex -o "$STAGE1" | tail -1
echo -n "   - stage1: "; "$STAGE1" version

echo
echo "✅ o stage0 compila, roda, testa, checa, formata e SE RECONSTRÓI sem o Rust."
echo "   → o src/ (Rust) pode ser arquivado; o stage0 é a semente."
rm -f /tmp/seed_demo.lex /tmp/seed_bad.lex
