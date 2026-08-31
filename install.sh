#!/bin/bash
# sezish installer — offline meeting transcription for macOS
# Usage: curl -fsSL sezi.sh/install | bash
set -euo pipefail

# Served from our own box (dl.sezi.sh, h1): the GitHub repo is private, so
# release-asset URLs are dead for anonymous users.
CLI_URL="https://dl.sezi.sh/sezish"
BIN_DIR="$HOME/.local/bin"

say() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "sezish supports macOS only."

# uv — Python runner (installs deps in an isolated env on first run)
if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    say "Installing uv (Python runner)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ffmpeg — audio decoding
if ! command -v ffmpeg >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        say "Installing ffmpeg via Homebrew..."
        brew install ffmpeg
    else
        die "ffmpeg not found and Homebrew is not installed. Install Homebrew (https://brew.sh) or ffmpeg manually, then re-run."
    fi
fi

say "Installing sezish to $BIN_DIR..."
mkdir -p "$BIN_DIR"
curl -fsSL "$CLI_URL" -o "$BIN_DIR/sezish"
chmod +x "$BIN_DIR/sezish"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "NOTE: add $BIN_DIR to your PATH (e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc)" ;;
esac

say "Done. Try it:"
echo
echo "    sezish your-meeting.mp4"
echo
echo "First run downloads the model (~225 MB) and Python deps — give it a minute."
echo "Better quality (and +592 MB): sezish --large your-meeting.mp4"
