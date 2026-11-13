#!/usr/bin/env bash
# Download a WhisperKit (Core ML) model folder into the app's models directory
# and check every file against the SHA-256 pinned in scripts/whisperkit_files.tsv.
#
# Usage: scripts/download_whisperkit_model.sh [model]
#   model: an id in scripts/whisperkit_files.tsv (= WhisperKitCatalog.models),
#          e.g. tiny.en, base.en, small, small.en_217MB, large-v3-v20240930_626MB.
#          Omit for the English Automatic pick (WhisperKitCatalog.defaultModel;
#          WhisperKitCatalogTests keeps the two in step).
#
# Files come from huggingface.co/argmaxinc/whisperkit-coreml (Core ML models)
# and the matching openai/whisper-* repo (tokenizer), each at a pinned commit,
# into ~/Library/Application Support/VoiceType/models/whisperkit/<model>/ (or
# under $VOICETYPE_APP_SUPPORT — the same rule the app uses). Staging, resume,
# repair and the manifest the app verifies: scripts/lib/folder_model.sh.
#
# Progress goes to stderr; the model folder's path is printed on stdout, e.g.
#   .build/release/VoiceType --bench --engine whisperkit --model "$(bash scripts/download_whisperkit_model.sh tiny.en)"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/folder_model.sh
source "$HERE/lib/folder_model.sh"

MODEL="${1:-small.en_217MB}"
download_folder_model "$HERE/whisperkit_files.tsv" whisperkit "$MODEL" "${WHISPERKIT_BASE_URL:-https://huggingface.co}"
