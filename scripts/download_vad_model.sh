#!/usr/bin/env bash
# Download whisper.cpp's ggml Silero VAD model into the app's models directory
# and check it against a pinned SHA-256. Used by the bench (`--vad <file>`, #7);
# the app doesn't use VAD (yet), so it isn't in the model catalog.
#
# Usage: scripts/download_vad_model.sh        → prints the installed path
#
# Source: huggingface.co/ggml-org/whisper-vad (what whisper.cpp's own
# models/download-vad-model.sh fetches). Stored in
# ~/Library/Application Support/VoiceType/models (or $VOICETYPE_APP_SUPPORT/models).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=model_catalog.sh
source "$HERE/model_catalog.sh"   # VOICETYPE_MODELS_DIR

FILE="ggml-silero-v6.2.0.bin"
SHA="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
BYTES=885098
URL="${WHISPER_VAD_BASE_URL:-https://huggingface.co/ggml-org/whisper-vad/resolve/main}/$FILE"
DEST="$VOICETYPE_MODELS_DIR/$FILE"
PART="$DEST.part"

sha_ok() { [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$SHA" ]]; }

mkdir -p "$VOICETYPE_MODELS_DIR"
if [[ -f "$DEST" ]] && sha_ok "$DEST"; then
  echo "✓ $FILE already present" >&2
  echo "$DEST"
  exit 0
fi

echo "Downloading $FILE ($BYTES bytes) from $URL" >&2
curl -L --fail -sS -o "$PART" "$URL"
if [[ "$(stat -f%z "$PART")" != "$BYTES" ]] || ! sha_ok "$PART"; then
  rm -f "$PART"
  echo "error: downloaded $FILE doesn't match its pinned size/SHA-256 (discarded). Retry." >&2
  exit 1
fi
mv -f "$PART" "$DEST"
echo "✓ Downloaded $FILE" >&2
echo "$DEST"
