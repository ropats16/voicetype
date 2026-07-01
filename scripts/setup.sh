#!/usr/bin/env bash
# One-shot setup: detect hardware, fetch whisper.cpp, embed the Metal shader
# (auto-skipped on Intel), download the auto-picked model, write a starter
# config if none exists, then build and package dist/VoiceType.app.
#
# Usage: scripts/setup.sh [model]
#   model: tiny.en | base.en | small.en | medium.en
#          (omit to auto-pick based on this Mac's arch + RAM)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Detect first. An explicit model argument overrides the auto-pick.
if [[ -n "${1:-}" ]]; then
  MODEL="$1"
  echo "==> Using model from argument: $MODEL"
else
  # Narration (chip/RAM/selection) goes to stderr; --model prints just the name.
  bash "$ROOT/scripts/detect_hardware.sh" >/dev/null
  MODEL="$(bash "$ROOT/scripts/detect_hardware.sh" --model)"
  echo "==> Auto-selected model: $MODEL"
fi

echo ""
echo "==> [1/5] Fetching whisper.cpp submodule"
git -C "$ROOT" submodule update --init --recursive

echo ""
echo "==> [2/5] Embedding Metal shader (skipped automatically on Intel/CPU builds)"
bash "$ROOT/scripts/embed_metal_shader.sh"

echo ""
echo "==> [3/5] Downloading model ($MODEL)"
bash "$ROOT/scripts/download_model.sh" "$MODEL"

echo ""
echo "==> [4/5] Configuring model path"
# Write a minimal starter config ONLY IF none exists — never clobber a config the
# user already has. The app tolerates a partial config: every other key falls
# back to its default via Config.init(from:). VOICETYPE_APP_SUPPORT overrides the
# base dir so this step is testable without touching the real config.
APP_SUPPORT="${VOICETYPE_APP_SUPPORT:-$HOME/Library/Application Support/VoiceType}"
CONFIG="$APP_SUPPORT/config.json"
MODEL_FILE="$APP_SUPPORT/models/ggml-$MODEL.bin"
if [[ -f "$CONFIG" ]]; then
  echo "✓ existing config preserved: $CONFIG"
else
  mkdir -p "$APP_SUPPORT"
  printf '{\n  "modelPath": "%s"\n}\n' "$MODEL_FILE" > "$CONFIG"
  echo "✓ wrote starter config: $CONFIG (modelPath -> $MODEL_FILE)"
fi

echo ""
echo "==> [5/5] Building and packaging the .app"
bash "$ROOT/scripts/package_app.sh"

echo ""
echo "✓ Setup complete (model: $MODEL)."
echo ""
echo "Next steps:"
echo "  1. Install to /Applications:   make install"
echo "  2. Grant permissions on first run (you only do this once — the app is"
echo "     signed with a stable certificate, so grants survive rebuilds):"
echo "       • Microphone    — prompted on first launch"
echo "       • Accessibility — System Settings → Privacy & Security → Accessibility → enable VoiceType"
echo "  3. Hold Control + Shift to dictate; release to insert at your cursor."
