#!/usr/bin/env bash
# Download a Parakeet (Core ML) model folder for the Parakeet engine and check
# every file against the SHA-256 pinned in scripts/parakeet_files.tsv.
#
# Usage: scripts/download_parakeet_model.sh [model]
#   model: an id in scripts/parakeet_files.tsv (= ParakeetCatalog.models).
#          Omit for the app's default, parakeet-tdt-0.6b-v3 (~460 MiB, 25
#          European languages; ParakeetCatalogTests keeps the two in step).
#
# Files come from the model's Hugging Face repo at a pinned revision (never
# `main`) into ~/Library/Application Support/VoiceType/models/parakeet/<model>/
# (or under $VOICETYPE_APP_SUPPORT — the app's rule). Staging, resume, repair
# and the manifest the app verifies: scripts/lib/folder_model.sh. A folder
# downloaded before the manifest existed gets one on the next run.
#
# Progress goes to stderr; the model folder's path is printed on stdout, e.g.
#   .build/release/VoiceType --bench --engine parakeet --model "$(bash scripts/download_parakeet_model.sh)"
#
# Parakeet TDT 0.6B v3 is © NVIDIA, licensed CC-BY-4.0
# (https://creativecommons.org/licenses/by/4.0/); converted to Core ML by
# FluidInference.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/folder_model.sh
source "$HERE/lib/folder_model.sh"

MODEL="${1:-parakeet-tdt-0.6b-v3}"
download_folder_model "$HERE/parakeet_files.tsv" parakeet "$MODEL" "${PARAKEET_MODEL_BASE_URL:-https://huggingface.co}"
