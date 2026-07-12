#!/bin/sh
# bootstrap.sh — prova o SELF-HOSTING do lex: o compilador compila o próprio fonte
# e o resultado é ESTÁVEL (ponto-fixo de 3 estágios).
#
#   ./src/scripts/bootstrap.sh
#
# stage0: o `lex` que você já tem (bin/lex) compila src/lexcli.lex  -> lex0
# stage1: lex0 (gerado por ele mesmo) recompila src/lexcli.lex      -> lex1 (+ lex1.ll)
# stage2: lex1 recompila src/lexcli.lex                             -> lex2 (+ lex2.ll)
# prova : lex1.ll == lex2.ll — o compilador reproduz a si mesmo byte a byte.
#
# (Se você não tem bin/lex ainda, rode ./src/scripts/build-seed.sh — ele parte da
#  semente em LLVM IR e não precisa de nenhum compilador lex prévio.)
set -e
cd "$(dirname "$0")/../.."          # a raiz do repo
LEX=${LEX:-./bin/lex}
ENTRY=src/lexcli.lex
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "stage0: $LEX $ENTRY -> lex0"
"$LEX" build "$ENTRY" -o "$TMP/lex0" | tail -1

echo "stage1: lex0 $ENTRY -> lex1"
"$TMP/lex0" build "$ENTRY" -o "$TMP/lex1" | tail -1

echo "stage2: lex1 $ENTRY -> lex2"
"$TMP/lex1" build "$ENTRY" -o "$TMP/lex2" | tail -1

echo "ponto-fixo: lex1.ll == lex2.ll ?"
if diff -q "$TMP/lex1.ll" "$TMP/lex2.ll" >/dev/null; then
    echo "✅ self-hosting provado — IR idêntico ($(wc -l < "$TMP/lex1.ll") linhas), ponto-fixo alcançado"
else
    echo "✗ FALHOU: o IR diferiu entre os estágios"
    diff "$TMP/lex1.ll" "$TMP/lex2.ll" | head -20
    exit 1
fi
