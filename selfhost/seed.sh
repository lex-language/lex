#!/usr/bin/env bash
# seed.sh — demonstra que o compilador-em-lex (lexcli) faz o fluxo de dev e
# RECONSTRÓI A SI MESMO sem o Rust no caminho. Prova o self-hosting do SUBSET.
#
# IMPORTANTE: o compilador-em-lex cobre o SUBSET da linguagem em que ele próprio
# é escrito — compila a si mesmo + a suíte tests/, mas NÃO programas de linguagem
# completa (ex.: examples/exemplo.lex usa float-arith/try/spawn/struct-literal,
# fora do subset). O src/ (Rust) segue sendo o compilador de linguagem-completa
# (e o único com wasm/cross-compile/float). Ver selfhost/REMOVER-RUST.md.
#
# Rode da raiz do repo:  ./selfhost/seed.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUSTLEX=./target/release/lex
STAGE0=/tmp/lex-stage0
STAGE1=/tmp/lex-stage1

echo "==> 1. Rust compila o lex unificado -> stage0"
$RUSTLEX selfhost/lexcli.lex -o "$STAGE0" | tail -1

echo
echo "==> 2. o stage0 (em lex) faz o fluxo, SEM Rust:"
cat > /tmp/seed_demo.lex <<'EOF'
fn fib(n: i64): i64 { if (n < 2) { return n } return fib(n - 1) + fib(n - 2) }
fn main(): i32 { Terminal.log(`fib(10) = ${fib(10)}`) return fib(10) }
EOF
echo -n "   - run:   "; "$STAGE0" run /tmp/seed_demo.lex; echo "           (exit=$? — fib(10)=55)"
echo -n "   - test:  "; "$STAGE0" test tests/semver.test.lex | tail -1
echo -n "   - check: "; printf 'fn main(): i32 { return zzz }' > /tmp/seed_bad.lex; "$STAGE0" check /tmp/seed_bad.lex
echo -n "   - fmt:   "; "$STAGE0" fmt --check selfhost/fmt.lex >/dev/null 2>&1 && echo "fmt.lex já formatado (ok)"

echo
echo "==> 3. o stage0 reconstrói a SI MESMO -> stage1 (auto-suficiência do subset)"
"$STAGE0" build selfhost/lexcli.lex -o "$STAGE1" | tail -1
echo -n "   - stage1: "; "$STAGE1" version

echo
echo "✅ o compilador-em-lex (subset) compila, roda, testa, checa, formata e SE"
echo "   RECONSTRÓI sem o Rust. (O src/ Rust segue p/ linguagem-completa/wasm/cross.)"
rm -f /tmp/seed_demo.lex /tmp/seed_bad.lex
