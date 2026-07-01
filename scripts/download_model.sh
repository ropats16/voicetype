#!/usr/bin/env bash
# Download a GGML Whisper English model into the app's models directory.
#
# Usage: scripts/download_model.sh [model]
#   model: tiny.en | base.en | small.en | medium.en   (default: medium.en)
#
# Models are fetched from the official ggml model repo on Hugging Face and
# stored in ~/Library/Application Support/VoiceType/models so both the .app and
# `swift run` find them.
set -euo pipefail

MODEL="${1:-medium.en}"
BASE_URL="${WHISPER_MODEL_BASE_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main}"
MODELS_DIR="${VOICETYPE_APP_SUPPORT:-$HOME/Library/Application Support/VoiceType}/models"
FILE="ggml-${MODEL}.bin"
DEST="$MODELS_DIR/$FILE"

case "$MODEL" in
  tiny.en|base.en|small.en|medium.en) ;;
  *) echo "error: unsupported model '$MODEL' (use tiny.en|base.en|small.en|medium.en)" >&2; exit 1 ;;
esac

mkdir -p "$MODELS_DIR"

if [[ -f "$DEST" ]]; then
  size=$(stat -f%z "$DEST" 2>/dev/null || echo 0)
  if [[ "$size" -gt 1000000 ]]; then
    echo "✓ $FILE already present ($(du -h "$DEST" | cut -f1)) at $DEST"
    exit 0
  fi
  echo "Existing $FILE looks incomplete; re-downloading."
fi

echo "Downloading $FILE from $BASE_URL"
echo "  → $DEST"
# -L follow redirects, -C - resume, --fail surface HTTP errors.
curl -L --fail -C - -o "$DEST" "$BASE_URL/$FILE"

size=$(stat -f%z "$DEST" 2>/dev/null || echo 0)
if [[ "$size" -lt 1000000 ]]; then
  echo "error: download appears incomplete ($size bytes). Check your connection and retry." >&2
  exit 1
fi
echo "✓ Downloaded $FILE ($(du -h "$DEST" | cut -f1))"
