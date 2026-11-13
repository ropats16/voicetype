#!/usr/bin/env bash
# Download a Parakeet (Core ML) model folder for the Parakeet engine and check
# every file against the SHA-256 the app pins (the app refuses a folder that
# doesn't match).
#
# Usage: scripts/download_parakeet_model.sh [model]
#   model: an id in scripts/parakeet_catalog.sh (default: parakeet-tdt-0.6b-v3,
#          ~460 MiB, 25 European languages).
#
# Files come from the model's Hugging Face repo at a pinned revision (never
# `main`) into ~/Library/Application Support/VoiceType/models/parakeet/<model>
# (or $VOICETYPE_APP_SUPPORT/models/parakeet/<model> — the app's rule). They are
# staged in <model>.part/ and the folder is renamed into place only once every
# file is complete and verified, so the app never sees a partial model. Re-runs
# resume, and repair a folder whose files were changed or deleted.
#
# Progress goes to stderr; the model folder's path is printed on stdout, e.g.
#   .build/release/VoiceType --bench --engine parakeet --model "$(bash scripts/download_parakeet_model.sh)"
#
# Parakeet TDT 0.6B v3 is © NVIDIA, licensed CC-BY-4.0
# (https://creativecommons.org/licenses/by/4.0/); converted to Core ML by
# FluidInference.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=parakeet_catalog.sh
source "$HERE/parakeet_catalog.sh"

MODEL="${1:-$PARAKEET_DEFAULT_MODEL}"
if ! REPO="$(parakeet_model_field "$MODEL" 2)"; then
  echo "error: unsupported Parakeet model '$MODEL'. Known models: $(parakeet_model_ids)" >&2
  exit 1
fi
REVISION="$(parakeet_model_field "$MODEL" 3)"
BASE_URL="${PARAKEET_MODEL_BASE_URL:-https://huggingface.co}"
DEST="$VOICETYPE_PARAKEET_DIR/$MODEL"
STAGE="$DEST.part"

say() { echo "$@" >&2; }
file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# folder_ok <dir> — every pinned file is present with its size and SHA-256.
folder_ok() {
  local path sha bytes
  while read -r path sha bytes; do
    [[ "$(file_size "$1/$path")" == "$bytes" ]] || return 1
    [[ "$(sha_of "$1/$path")" == "$sha" ]] || return 1
  done < <(parakeet_files "$MODEL")
}

if [[ -d "$DEST" ]]; then
  say "Checking $MODEL..."
  if folder_ok "$DEST"; then
    say "✓ $MODEL already present ($(du -sh "$DEST" | cut -f1)) at $DEST"
    echo "$DEST"
    exit 0
  fi
  say "$MODEL is incomplete or changed; repairing it."
  if [[ -d "$STAGE" ]]; then
    cp -Rn "$DEST/" "$STAGE/" 2>/dev/null || true
    rm -rf "$DEST"
  else
    mv "$DEST" "$STAGE"
  fi
fi

mkdir -p "$STAGE"
say "Downloading $MODEL from $REPO@${REVISION:0:7} → $DEST"
while read -r path sha bytes; do
  file="$STAGE/$path"
  mkdir -p "$(dirname "$file")"
  if [[ "$(file_size "$file")" == "$bytes" ]] && [[ "$(sha_of "$file")" == "$sha" ]]; then
    continue
  fi
  # A finished-size or oversized file that failed the check can't be resumed.
  if (( $(file_size "$file") >= bytes )); then rm -f "$file"; fi
  say "  $path ($bytes bytes)"
  # -L follow redirects, -C - resume, --fail surface HTTP errors.
  curl -L --fail -sS -C - -o "$file" "$BASE_URL/$REPO/resolve/$REVISION/$path"
  if [[ "$(file_size "$file")" != "$bytes" ]]; then
    say "error: $path incomplete ($(file_size "$file") of $bytes bytes). Check your connection and retry."
    exit 1
  fi
  if [[ "$(sha_of "$file")" != "$sha" ]]; then
    rm -f "$file"
    say "error: $path doesn't match its published checksum (discarded). Retry."
    exit 1
  fi
done < <(parakeet_files "$MODEL")

mv "$STAGE" "$DEST"
say "✓ Downloaded $MODEL ($(du -sh "$DEST" | cut -f1))"
echo "$DEST"
