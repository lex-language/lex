#!/usr/bin/env bash
# regen-seed.sh — REGERA a semente a partir do fonte atual do compilador.
# Rode sempre que mudar src/*.lex, senão o build-seed.sh acusa ponto-fixo
# quebrado (a semente ficaria desatualizada em relação ao fonte).
#
# Usa o `bin/lex` que já existe (ou constrói um da semente antiga primeiro).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LEX="${LEX:-./bin/lex}"
[ -x "$LEX" ] || { echo "erro: $LEX não existe — rode ./src/scripts/build-seed.sh antes"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> compila o compilador com ele mesmo, até o ponto-fixo"
"$LEX" build src/lexcli.lex -o "$TMP/l1" | tail -1
"$TMP/l1" build src/lexcli.lex -o "$TMP/l2" | tail -1
diff -q "$TMP/l1.ll" "$TMP/l2.ll" >/dev/null || { echo "✗ o compilador não chega no ponto-fixo — não vou gravar a semente"; exit 1; }

gzip -9 -c "$TMP/l2.ll" > src/lex-seed.ll.gz
printf "✅ semente regerada: src/lex-seed.ll.gz (%s)\n" "$(du -h src/lex-seed.ll.gz | cut -f1)"
