# Folder-model downloads (sourced, not run), shared by
# download_whisperkit_model.sh and download_parakeet_model.sh.
#
# A folder model is pinned file by file in a table, scripts/<engine>_files.tsv:
#   id <TAB> source (repo/resolve/<commit>/path) <TAB> local path <TAB> bytes <TAB> sha256
# The folder is assembled in <model>.part/, each file resumed (curl -C -) and
# checked against its pin. Then the manifest (voicetype-manifest.sha256: one
# `<sha256>  <path>` line per file, sorted by path, `shasum -a 256` format) is
# written last and the folder renamed into place. The app treats a catalog
# folder as installed once its manifest is there, and verifies the folder
# against the manifest digest its catalog pins (ModelVerifier.verifyFolder),
# so it never sees a partial model.
#
# Re-runs resume a .part, and repair a finished folder whose files changed or
# went missing (or that predates its manifest) keeping every good file: only
# what's missing or wrong is fetched again.

# shellcheck source=../model_catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/../model_catalog.sh"

FOLDER_MODEL_MANIFEST="voicetype-manifest.sha256"

fm_say() { echo "$@" >&2; }
fm_file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }
fm_sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# fm_known_ids <table> — the table's model ids, in order, space-separated.
fm_known_ids() { awk -F'\t' '!/^#/ && NF && !seen[$1]++ { printf "%s%s", sep, $1; sep = " " }' "$1"; }

# fm_manifest <rows> — the manifest for a model's table rows.
fm_manifest() { awk -F'\t' '{ print $5 "  " $3 }' <<<"$1" | LC_ALL=C sort -k2; }

# fm_folder_ok <dir> <rows> — the manifest is the pinned one and every file matches it.
fm_folder_ok() {
  [[ -f "$1/$FOLDER_MODEL_MANIFEST" ]] && [[ "$(cat "$1/$FOLDER_MODEL_MANIFEST")" == "$(fm_manifest "$2")" ]] \
    && (cd "$1" && shasum -a 256 --quiet -c "$FOLDER_MODEL_MANIFEST" >/dev/null 2>&1)
}

# download_folder_model <table> <subdir> <model> <base url>
# Fetches <model> into $VOICETYPE_MODELS_DIR/<subdir>/<model>/ (a no-op when
# it's already complete). Progress goes to stderr; the folder's path is
# printed on stdout.
download_folder_model() {
  local table="$1" subdir="$2" model="$3" base_url="$4"
  local rows dest part
  rows="$(awk -F'\t' -v id="$model" '$1 == id' "$table")"
  if [[ -z "$rows" ]]; then
    fm_say "error: unknown $subdir model '$model'. Known models: $(fm_known_ids "$table")"
    return 1
  fi
  dest="$VOICETYPE_MODELS_DIR/$subdir/$model"
  part="$dest.part"
  mkdir -p "$(dirname "$dest")"

  if [[ -d "$dest" ]]; then
    fm_say "Checking $model..."
    if fm_folder_ok "$dest" "$rows"; then
      fm_say "✓ $model already present ($(du -sh "$dest" | cut -f1)) at $dest"
      echo "$dest"
      return 0
    fi
    fm_say "$model is incomplete, modified or has no manifest; repairing it (good files are kept)."
    if [[ -d "$part" ]]; then
      # Move the finished folder's files over the partial one's (they were
      # complete once); every file is re-checked below either way.
      local f
      while IFS= read -r -d '' f; do
        mkdir -p "$(dirname "$part/$f")"
        mv -f "$dest/$f" "$part/$f"
      done < <(cd "$dest" && find . -type f -print0)
      rm -rf "$dest"
    else
      mv "$dest" "$part"
    fi
  fi
  mkdir -p "$part"
  rm -f "$part/$FOLDER_MODEL_MANIFEST"   # written last, once every file checks out

  fm_say "Downloading $model → $dest"
  local src path bytes sha out
  while IFS=$'\t' read -r _ src path bytes sha; do
    out="$part/$path"
    mkdir -p "$(dirname "$out")"
    if [[ "$(fm_file_size "$out")" == "$bytes" ]] && [[ "$(fm_sha_of "$out")" == "$sha" ]]; then
      continue
    fi
    # A file at or past its size that failed the check can't be a resumable prefix.
    if (( $(fm_file_size "$out") >= bytes )); then rm -f "$out"; fi
    fm_say "  $path ($bytes bytes)"
    # -L follow redirects, -C - resume, --fail surface HTTP errors.
    curl -sS -L --fail -C - -o "$out" "$base_url/$src"
    if [[ "$(fm_file_size "$out")" != "$bytes" ]]; then
      fm_say "error: $path incomplete ($(fm_file_size "$out") of $bytes bytes). Check your connection and re-run to resume."
      return 1
    fi
    if [[ "$(fm_sha_of "$out")" != "$sha" ]]; then
      rm -f "$out"
      fm_say "error: $path doesn't match its pinned checksum (discarded). Re-run."
      return 1
    fi
  done <<<"$rows"

  fm_manifest "$rows" >"$part/$FOLDER_MODEL_MANIFEST"
  mv "$part" "$dest"
  fm_say "✓ $model ready ($(du -sh "$dest" | cut -f1)) at $dest"
  echo "$dest"
}
