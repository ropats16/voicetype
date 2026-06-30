#!/usr/bin/env bash
# One-shot setup: fetch whisper.cpp, embed the Metal shader, download the model,
# build, and package dist/VoiceType.app.
#
# Usage: scripts/setup.sh [model]
#   model: tiny.en | base.en | small.en | medium.en   (default: medium.en)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODEL="${1:-medium.en}"

echo "==> [1/4] Fetching whisper.cpp submodule"
git -C "$ROOT" submodule update --init --recursive

echo ""
echo "==> [2/4] Embedding Metal shader"
bash "$ROOT/scripts/embed_metal_shader.sh"

echo ""
echo "==> [3/4] Downloading model ($MODEL)"
bash "$ROOT/scripts/download_model.sh" "$MODEL"

echo ""
echo "==> [4/4] Building and packaging the .app"
bash "$ROOT/scripts/package_app.sh"

echo ""
echo "✓ Setup complete."
echo ""
echo "Next steps:"
echo "  1. Install to /Applications:   make install"
echo "  2. Grant permissions on first run (you only do this once — the app is"
echo "     signed with a stable certificate, so grants survive rebuilds):"
echo "       • Microphone    — prompted on first launch"
echo "       • Accessibility — System Settings → Privacy & Security → Accessibility → enable VoiceType"
echo "  3. Hold Control + Shift to dictate; release to insert at your cursor."
