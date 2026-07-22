#!/bin/bash
# release.sh — Compila binários para todas as plataformas e cria release no GitHub
#
# Uso:
#   ./scripts/release.sh <versão>
#   ./scripts/release.sh 0.2.0
#
# Requisitos:
#   - gh (GitHub CLI) autenticado
#   - lex funcional no PATH
#   - LLVM 18 para cross-compile (brew install llvm@18)

set -e

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "uso: $0 <versão>"
    echo "exemplo: $0 0.2.0"
    exit 1
fi

# Valida formato da versão
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "erro: versão deve ser no formato X.Y.Z (ex: 0.2.0)"
    exit 1
fi

TAG="v$VERSION"
RELEASE_DIR="dist/release-$VERSION"
REPO="doxacode/lex-lang"

echo "=== Lex Release $VERSION ==="
echo ""

# Verifica se gh está instalado e autenticado
if ! command -v gh &> /dev/null; then
    echo "erro: gh (GitHub CLI) não está instalado"
    echo "      instale com: brew install gh"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "erro: gh não está autenticado"
    echo "      execute: gh auth login"
    exit 1
fi

# Verifica se lex está disponível
if ! command -v lex &> /dev/null; then
    echo "erro: lex não está no PATH"
    exit 1
fi

# Atualiza a versão no código fonte
echo "1. Atualizando versão no código fonte..."
sed -i '' "s/const LEX_VERSION: string = \"[^\"]*\"/const LEX_VERSION: string = \"$VERSION\"/" src/lexcli.lex
echo "   LEX_VERSION = $VERSION"

# Cria diretório de release
echo ""
echo "2. Compilando binários..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Lista de targets
TARGETS=(
    "macos-arm64"
    "macos-x64"
    "linux-arm64"
    "linux-x64"
)

for target in "${TARGETS[@]}"; do
    echo "   Compilando lex-$target..."
    lex build src/lexcli.lex -o "$RELEASE_DIR/lex-$target" --target "$target"
done

echo ""
echo "3. Binários gerados:"
ls -lh "$RELEASE_DIR/"

# Cria a tag
echo ""
echo "4. Criando tag $TAG..."
git add src/lexcli.lex
git commit -m "release: $VERSION" || true
git tag -a "$TAG" -m "Release $VERSION"

# Push da tag
echo ""
echo "5. Enviando tag para o GitHub..."
git push origin main
git push origin "$TAG"

# Cria a release no GitHub
echo ""
echo "6. Criando release no GitHub..."
gh release create "$TAG" \
    --repo "$REPO" \
    --title "Lex $VERSION" \
    --generate-notes \
    "$RELEASE_DIR"/*

echo ""
echo "=== Release $VERSION concluída! ==="
echo ""
echo "Veja em: https://github.com/$REPO/releases/tag/$TAG"
