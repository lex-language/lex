#!/bin/sh
set -e

# Lex installer
# Usage: curl -fsSL https://lex-lang.doxacode.com.br/install.sh | sh

REPO="lex-language/lex"
INSTALL_DIR="${LEX_INSTALL_DIR:-$HOME/.lex}"
BIN_DIR="$INSTALL_DIR/bin"

echo ""
echo "  Installing Lex..."
echo ""

# Detect OS and architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)
        echo "  Error: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

case "$OS" in
    darwin) OS="macos" ;;
    linux) OS="linux" ;;
    mingw*|msys*|cygwin*)
        echo "  Error: Windows detected. Please use the Windows installer:"
        echo "  https://github.com/$REPO/releases/latest"
        exit 1
        ;;
    *)
        echo "  Error: Unsupported OS: $OS"
        exit 1
        ;;
esac

TARGET="$OS-$ARCH"
echo "  Detected: $TARGET"

# Create directories
mkdir -p "$INSTALL_DIR"

# Download latest release
RELEASE_URL="https://github.com/$REPO/releases/latest/download/lex-$TARGET.tar.gz"
echo "  Downloading..."

if command -v curl > /dev/null 2>&1; then
    curl -fsSL "$RELEASE_URL" | tar -xz -C "$INSTALL_DIR"
elif command -v wget > /dev/null 2>&1; then
    wget -qO- "$RELEASE_URL" | tar -xz -C "$INSTALL_DIR"
else
    echo "  Error: curl or wget required"
    exit 1
fi

chmod +x "$BIN_DIR/lex"

# Sanity: every build links the C runtime, so a lex without it can only report
# its version. findRuntime() looks here (see src/compiler/modloader.lex).
if [ ! -f "$INSTALL_DIR/lib/runtime.c" ]; then
    echo "  Error: lib/runtime.c missing from the release tarball"
    exit 1
fi

# Verify installation
if [ -x "$BIN_DIR/lex" ]; then
    VERSION=$("$BIN_DIR/lex" version 2>/dev/null || echo "unknown")
    echo ""
    echo "  Lex $VERSION installed successfully!"
    echo ""
    echo "  Location: $BIN_DIR/lex"
    echo "  Runtime:  $INSTALL_DIR/lib/runtime.c"
    echo ""

    # Check if already in PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            echo "  Ready to use! Try: lex version"
            ;;
        *)
            echo "  Add to your PATH:"
            echo ""
            echo "    export PATH=\"$BIN_DIR:\$PATH\""
            echo ""
            echo "  Or add to your shell config (~/.bashrc, ~/.zshrc, etc.)"
            ;;
    esac
else
    echo "  Error: Installation failed"
    exit 1
fi

echo ""
