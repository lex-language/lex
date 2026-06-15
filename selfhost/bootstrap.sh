#!/bin/sh
# bootstrap.sh — prova o self-hosting do lex (F6.6).
#
# O compilador-em-lex (selfhost/lexc.lex + imports) compila O PRÓPRIO FONTE e o
# resultado é ESTÁVEL: ponto-fixo de 3 estágios. Rode da raiz do repo:
#
#   ./selfhost/bootstrap.sh
#
# stage0: o lex de produção (Rust) compila lexc.lex            -> lexc0
# stage1: lexc0 (self-hosted) compila lexc.lex                 -> lexc1 (+ lexc1.ll)
# stage2: lexc1 (self-hosted) compila lexc.lex                 -> lexc2 (+ lexc2.ll)
# prova : lexc1.ll == lexc2.ll  (o compilador-em-lex é estável compilando a si mesmo)
set -e
LEX=${LEX:-./target/release/lex}
ENTRY=selfhost/lexc.lex
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "stage0: $LEX $ENTRY -> lexc0"
"$LEX" "$ENTRY" -o "$TMP/lexc0"

echo "stage1: lexc0 $ENTRY -> lexc1"
"$TMP/lexc0" "$ENTRY" "$TMP/lexc1"

echo "stage2: lexc1 $ENTRY -> lexc2"
"$TMP/lexc1" "$ENTRY" "$TMP/lexc2"

echo "ponto-fixo: lexc1.ll == lexc2.ll ?"
if diff -q "$TMP/lexc1.ll" "$TMP/lexc2.ll" >/dev/null; then
    echo "✅ self-hosting provado — IR idêntico ($(wc -l < "$TMP/lexc1.ll") linhas), ponto-fixo alcançado"
else
    echo "✗ FALHOU: o IR diferiu entre os estágios"
    diff "$TMP/lexc1.ll" "$TMP/lexc2.ll" | head -20
    exit 1
fi
