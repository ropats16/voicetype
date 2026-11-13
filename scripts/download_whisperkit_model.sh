#!/usr/bin/env bash
# Download a WhisperKit (Core ML) model folder into the app's models directory
# and check every file against the SHA-256 pinned in scripts/whisperkit_files.tsv.
#
# Usage: scripts/download_whisperkit_model.sh [model]
#   model: an id in scripts/whisperkit_files.tsv (= WhisperKitCatalog.models),
#          e.g. tiny.en, base.en, small.en_217MB, large-v3-v20240930_626MB.
#          Omit for the English default (WhisperKitCatalog.defaultEnglish).
#
# Files come from huggingface.co/argmaxinc/whisperkit-coreml (Core ML models)
# and the matching openai/whisper-* repo (tokenizer), each at a pinned commit,
# into ~/Library/Application Support/VoiceType/models/whisperkit/<model>/ (or
# under $VOICETYPE_APP_SUPPORT — the same rule the app uses). The folder is
# assembled in <model>.part/ and renamed only once complete and verified; its
# manifest (voicetype-manifest.sha256, `shasum -a 256` format) is what the app
# checks against WhisperKitCatalog's pinned digest.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=model_catalog.sh
source "$HERE/model_catalog.sh"

TABLE="$HERE/whisperkit_files.tsv"
MANIFEST="voicetype-manifest.sha256"
BASE_URL="${WHISPERKIT_BASE_URL:-https://huggingface.co}"

known_ids() { awk -F'\t' '!/^#/ && !seen[$1]++ { printf "%s%s", sep, $1; sep = " " }' "$TABLE"; }

MODEL="${1:-small.en_217MB}"
ROWS="$(awk -F'\t' -v id="$MODEL" '$1 == id' "$TABLE")"
if [[ -z "$ROWS" ]]; then
  echo "error: unsupported WhisperKit model '$MODEL'. Known models: $(known_ids)" >&2
  exit 1
fi

DIR="$VOICETYPE_MODELS_DIR/whisperkit"
DEST="$DIR/$MODEL"
PART="$DEST.part"
mkdir -p "$DIR"

file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
# The manifest: one `<sha256>  <path>` line per file, sorted by path (bytewise).
manifest() { awk -F'\t' '{ print $5 "  " $3 }' <<<"$ROWS" | LC_ALL=C sort -k2; }
folder_ok() { [[ -f "$1/$MANIFEST" ]] && [[ "$(cat "$1/$MANIFEST")" == "$(manifest)" ]] \
                && (cd "$1" && shasum -a 256 --quiet -c "$MANIFEST" >/dev/null 2>&1); }

if [[ -d "$DEST" ]]; then
  echo "Checking existing $MODEL..."
  if folder_ok "$DEST"; then
    echo "✓ $MODEL already present ($(du -sh "$DEST" | cut -f1)) at $DEST"
    exit 0
  fi
  echo "Existing $MODEL is incomplete or modified; repairing it."
  rm -rf "$PART"
  mv "$DEST" "$PART"   # keep the good files; each is re-checked below
fi
mkdir -p "$PART"

echo "Downloading WhisperKit $MODEL → $DEST"
while IFS=$'\t' read -r _ src path bytes sha; do
  out="$PART/$path"
  mkdir -p "$(dirname "$out")"
  if [[ "$(file_size "$out")" == "$bytes" ]] && [[ "$(sha_of "$out")" == "$sha" ]]; then
    continue
  fi
  # A file of the wrong size that can't be a resumable prefix starts over.
  if (( $(file_size "$out") >= bytes )); then rm -f "$out"; fi
  echo "  $path ($bytes bytes)"
  # -L follow redirects, -C - resume, --fail surface HTTP errors.
  curl -sS -L --fail -C - -o "$out" "$BASE_URL/$src"
  if [[ "$(file_size "$out")" != "$bytes" ]] || [[ "$(sha_of "$out")" != "$sha" ]]; then
    rm -f "$out"
    echo "error: $path doesn't match its pinned size/checksum (discarded). Retry." >&2
    exit 1
  fi
done <<<"$ROWS"

manifest >"$PART/$MANIFEST"
if ! folder_ok "$PART"; then
  echo "error: $MODEL failed its final check. Retry." >&2
  exit 1
fi
mv "$PART" "$DEST"
echo "✓ Downloaded $MODEL ($(du -sh "$DEST" | cut -f1))"
