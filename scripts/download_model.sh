#!/usr/bin/env bash
# Download a GGML Whisper model into the app's models directory and check it
# against the SHA-256 the app pins (the app refuses a file that doesn't match).
#
# Usage: scripts/download_model.sh [model]
#   model: any id in scripts/model_catalog.sh, e.g. small.en-q5_1, medium.en,
#          small (multilingual), large-v3-turbo-q5_0. Omit to fetch the model the
#          app auto-picks for this Mac.
#
# Models are fetched from the official ggml model repo on Hugging Face and
# stored in ~/Library/Application Support/VoiceType/models (or
# $VOICETYPE_APP_SUPPORT/models — the same rule the app uses) so both the .app
# and `swift run` find them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=model_catalog.sh
source "$HERE/model_catalog.sh"

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
  MODEL="$(bash "$HERE/detect_hardware.sh" --model)"
  echo "==> Auto-selected model for this Mac: $MODEL"
fi
BASE_URL="${WHISPER_MODEL_BASE_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main}"
FILE="ggml-${MODEL}.bin"
DEST="$VOICETYPE_MODELS_DIR/$FILE"

if ! SHA="$(model_field "$MODEL" 2)"; then
  echo "error: unsupported model '$MODEL'. Known models: $(model_ids)" >&2
  exit 1
fi
BYTES="$(model_field "$MODEL" 3)"

file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }

verify() {
  echo "Checking SHA-256 of ${FILE}..."
  local actual
  actual="$(shasum -a 256 "$DEST" | awk '{print $1}')"
  if [[ "$actual" != "$SHA" ]]; then
    echo "error: $FILE checksum mismatch (got $actual, expected $SHA)." >&2
    echo "       Delete $DEST and run this again." >&2
    return 1
  fi
}

mkdir -p "$VOICETYPE_MODELS_DIR"

if [[ -f "$DEST" ]]; then
  if [[ "$(file_size "$DEST")" == "$BYTES" ]]; then
    verify
    echo "✓ $FILE already present ($(du -h "$DEST" | cut -f1)) at $DEST"
    exit 0
  fi
  echo "Existing $FILE is incomplete ($(file_size "$DEST") of $BYTES bytes); resuming."
fi

echo "Downloading $FILE from $BASE_URL"
echo "  → $DEST"
# -L follow redirects, -C - resume, --fail surface HTTP errors.
curl -L --fail -C - -o "$DEST" "$BASE_URL/$FILE"

if [[ "$(file_size "$DEST")" != "$BYTES" ]]; then
  echo "error: download incomplete ($(file_size "$DEST") of $BYTES bytes). Check your connection and retry." >&2
  exit 1
fi
verify
echo "✓ Downloaded $FILE ($(du -h "$DEST" | cut -f1))"
