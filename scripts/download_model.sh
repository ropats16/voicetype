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

# sha_ok <file> — the file's SHA-256 is the pinned one.
sha_ok() {
  echo "Checking SHA-256 of ${FILE}..."
  [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$SHA" ]]
}

mkdir -p "$VOICETYPE_MODELS_DIR"

# The download lands in <file>.part and is renamed only once complete and
# verified, so the app never sees (or tries to load) a partial model.
PART="$DEST.part"

if [[ -f "$DEST" ]]; then
  size="$(file_size "$DEST")"
  if [[ "$size" == "$BYTES" ]]; then
    if sha_ok "$DEST"; then
      echo "✓ $FILE already present ($(du -h "$DEST" | cut -f1)) at $DEST"
      exit 0
    fi
    echo "error: $FILE doesn't match its published checksum. Delete $DEST and run this again." >&2
    exit 1
  elif (( size < BYTES )); then
    echo "Existing $FILE is incomplete ($size of $BYTES bytes); resuming."
    mv -f "$DEST" "$PART"   # older versions downloaded in place
  else
    echo "Existing $FILE is larger than expected ($size of $BYTES bytes); downloading again."
    rm -f "$DEST"
  fi
fi

# A .part bigger than the file can't be resumed (the server would answer 416).
if [[ -f "$PART" ]] && (( $(file_size "$PART") > BYTES )); then
  echo "Discarding an oversized partial download."
  rm -f "$PART"
fi

if [[ "$(file_size "$PART")" != "$BYTES" ]]; then
  echo "Downloading $FILE from $BASE_URL"
  echo "  → $DEST"
  # -L follow redirects, -C - resume, --fail surface HTTP errors.
  curl -L --fail -C - -o "$PART" "$BASE_URL/$FILE"
fi

if [[ "$(file_size "$PART")" != "$BYTES" ]]; then
  echo "error: download incomplete ($(file_size "$PART") of $BYTES bytes). Check your connection and retry." >&2
  exit 1
fi
if ! sha_ok "$PART"; then
  rm -f "$PART"
  echo "error: downloaded $FILE doesn't match its published checksum (discarded). Retry." >&2
  exit 1
fi
mv -f "$PART" "$DEST"
echo "✓ Downloaded $FILE ($(du -h "$DEST" | cut -f1))"
