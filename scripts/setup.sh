#!/usr/bin/env bash
# One-shot setup: detect hardware, fetch whisper.cpp, embed the Metal shader
# (auto-skipped on Intel), download the model, then build and package
# dist/VoiceType.app.
#
# Usage: scripts/setup.sh [model]
#   model: any id in scripts/model_catalog.sh (e.g. small.en-q5_1, medium.en)
#          Omit it to download the model the app auto-picks for this Mac's
#          chip + RAM; the app then selects it by itself (config "model": "auto").
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Detect first. An explicit model argument overrides the auto-pick.
EXPLICIT_MODEL=0
if [[ -n "${1:-}" ]]; then
  EXPLICIT_MODEL=1
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
echo "==> [4/5] Configuring the model"
# Write a minimal starter config ONLY IF none exists — never clobber a config the
# user already has. With no explicit model the app needs no config entry: it
# auto-picks by itself (the same table this script used). The app tolerates a
# partial config: every other key falls back to its default via
# Config.init(from:). VOICETYPE_APP_SUPPORT overrides the base dir (the same
# rule the app uses), so this step is testable without touching the real config.
# shellcheck source=model_catalog.sh
source "$ROOT/scripts/model_catalog.sh"
CONFIG="$VOICETYPE_SUPPORT_DIR/config.json"
if [[ -f "$CONFIG" ]]; then
  echo "✓ existing config preserved: $CONFIG"
  echo "  note: if it sets \"modelPath\" or \"model\", the app keeps using that model."
  echo "        To use $MODEL, pick it in Settings, or set \"model\": \"auto\" (or"
  echo "        \"$MODEL\") and remove \"modelPath\"."
elif [[ "$EXPLICIT_MODEL" == 1 ]]; then
  mkdir -p "$VOICETYPE_SUPPORT_DIR"
  printf '{\n  "model": "%s"\n}\n' "$MODEL" > "$CONFIG"
  echo "✓ wrote starter config: $CONFIG (model -> $MODEL)"
else
  echo "✓ no config needed: the app auto-picks $MODEL for this Mac"
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
