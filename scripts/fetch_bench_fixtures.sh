#!/usr/bin/env bash
# Fetch the benchmark fixtures for `VoiceType --bench` into a git-ignored dir.
#
# Usage: scripts/fetch_bench_fixtures.sh [--dir DIR] [--tarball PATH] [--keep-download]
#   --dir DIR        where to write fixtures (default: .bench/fixtures in the repo)
#   --tarball PATH   use an already-downloaded LibriSpeech test-clean.tar.gz
#   --keep-download  keep the 331 MiB tarball after extracting (default: delete)
#
# Fixtures (real read speech with reference transcripts):
#   short/  7 LibriSpeech test-clean utterances (3–8 s, 4 male + 3 female
#           speakers) + whisper.cpp's jfk.wav (11 s) — dictation latency + WER.
#   long/   librispeech-long.wav: two whole test-clean chapters (speaker 5639
#           ch. 40744, male, then 1284 ch. 134647, female), utterances joined in
#           order with 0.25 s of silence, ~10.5 min — real-time factor + WER.
#   manifest.tsv  kind<TAB>path<TAB>reference, read by `--bench`.
#
# Licenses: LibriSpeech (Panayotov et al., 2015) is CC BY 4.0 — its LICENSE.TXT
# is copied next to the fixtures. jfk.wav ships with whisper.cpp (MIT); the 1961
# inaugural address is a US-government work in the public domain.
#
# The tarball comes from openslr.org (one-time, ~331 MiB) and is checked against
# a pinned SHA-256; every generated WAV is checked too, so every Mac benches
# byte-identical audio. Needs only stock macOS tools: curl, shasum, tar,
# afconvert (FLAC decode) and python3 (WAV assembly, from the Xcode CLT).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.bench/fixtures"
TARBALL=""
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|--tarball)
      if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == --* ]]; then
        echo "error: $1 needs a path (see --help)" >&2; exit 2
      fi
      if [[ "$1" == --dir ]]; then DIR="$2"; else TARBALL="$2"; fi
      shift 2 ;;
    --keep-download) KEEP=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

URL="${LIBRISPEECH_URL:-https://www.openslr.org/resources/12/test-clean.tar.gz}"
TARBALL_SHA256="39fde525e59672dc6d1551919b1478f724438a95aa55f874b576be21967e6c23"
JFK="$ROOT/Sources/CWhisper/whisper.cpp/samples/jfk.wav"
JFK_REFERENCE="And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country."

# Short dictation clips: LibriSpeech utterance ids.
SHORT_IDS=(
  2830-3980-0000
  4446-2271-0000
  61-70968-0000
  3570-5694-0001
  260-123286-0000
  7176-92135-0001
  2961-960-0007
)
# Chapters (speaker/chapter) concatenated, in order, into the long clip.
LONG_CHAPTERS=(5639/40744 1284/134647)
LONG_GAP_SECONDS=0.25

# SHA-256 of the manifest and every file it points at (16 kHz mono 16-bit WAV).
# Changing the fixture set changes these: re-pin from `shasum -a 256`.
EXPECTED_SHA256="\
2849c7cb4d3fff55b14d3a52a82eab7f3a702f72b1f2062c5e934474579d3eb2  manifest.tsv
59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e  short/jfk.wav
3c0d6c94ce6b60db4f062fbe74ea645847bef8ce13b91db6895489891c950d1e  short/2830-3980-0000.wav
49aaa700017a0d06640bff0461b38d4c7e90933b3ce47c25fd11aff085d4b88b  short/4446-2271-0000.wav
3f53c11bcec66e60659c3e53015f4f914d79b04eba0770347e644a4776fbe633  short/61-70968-0000.wav
7de6d535e2a7fab20fe7d8d29283ebfddafd3bc9bc05a4f79f67ce48df15719a  short/3570-5694-0001.wav
be2a972d7d4a6b5c0e5805b2f5cab8182cff9a0878b172b38c684830775b36e5  short/260-123286-0000.wav
4d15e8623d8638477be969fb385e7392b394325f5ce8ca2f4756ba2703c22517  short/7176-92135-0001.wav
852fcb3df9db2ae2d7adc25528fb6c2cf9033380ef73b31707b6d405ef5cf4f3  short/2961-960-0007.wav
d8ec77050286ed7730fba879b9bfd9ebb36a31c4cb28cb1276b4fa3203605144  long/librispeech-long.wav
"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
# Checks the fixtures in the current dir against the pins above (extra args go
# to shasum, e.g. -s for silent).
verify_pins() { printf '%s' "$EXPECTED_SHA256" | shasum -a 256 "$@" -c -; }

if [[ ! -f "$JFK" ]]; then
  echo "error: $JFK not found — run: git submodule update --init --recursive" >&2
  exit 1
fi
# Absolute paths: everything below runs from inside $DIR.
if [[ -n "$TARBALL" ]]; then TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"; fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
cd "$DIR"

# Already fetched and intact? Nothing to do.
if [[ -f manifest.tsv ]] && verify_pins -s 2>/dev/null; then
  echo "✓ Bench fixtures already present and verified in $DIR"
  exit 0
fi

# --- Download + verify the LibriSpeech tarball ---------------------------------
if [[ -z "$TARBALL" ]]; then
  mkdir -p .download
  TARBALL="$DIR/.download/test-clean.tar.gz"
  if [[ ! -f "$TARBALL" ]] || [[ "$(sha256 "$TARBALL")" != "$TARBALL_SHA256" ]]; then
    echo "Downloading LibriSpeech test-clean (~331 MiB) from $URL"
    # Resume a partial download; if that fails (e.g. HTTP 416 on a full-size
    # but corrupt file), start over once.
    if ! curl -L --fail -C - -o "$TARBALL" "$URL"; then
      echo "Resume failed; downloading from scratch" >&2
      rm -f "$TARBALL"
      curl -L --fail -o "$TARBALL" "$URL"
    fi
  fi
fi
echo "Verifying $TARBALL"
actual="$(sha256 "$TARBALL")"
if [[ "$actual" != "$TARBALL_SHA256" ]]; then
  echo "error: test-clean.tar.gz SHA-256 is $actual, expected $TARBALL_SHA256" >&2
  echo "       (delete it and re-run to download again)" >&2
  exit 1
fi

# --- Extract only what we use --------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/voicetype-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
members=(LibriSpeech/LICENSE.TXT)
for id in "${SHORT_IDS[@]}"; do
  IFS=- read -r spk ch _ <<< "$id"
  members+=("LibriSpeech/test-clean/$spk/$ch/$id.flac" "LibriSpeech/test-clean/$spk/$ch/$spk-$ch.trans.txt")
done
for c in "${LONG_CHAPTERS[@]}"; do members+=("LibriSpeech/test-clean/$c"); done
echo "Extracting ${#SHORT_IDS[@]} utterances + ${#LONG_CHAPTERS[@]} chapters"
tar -xzf "$TARBALL" -C "$WORK" "${members[@]}"
LS="$WORK/LibriSpeech/test-clean"

# --- Decode FLAC → WAV and write the manifest -----------------------------------
rm -rf short long SHA256SUMS
mkdir -p short long
cp "$WORK/LibriSpeech/LICENSE.TXT" LICENSE-LibriSpeech.txt

transcript() {  # utterance id → reference text
  local spk ch
  IFS=- read -r spk ch _ <<< "$1"
  grep "^$1 " "$LS/$spk/$ch/$spk-$ch.trans.txt" | cut -d' ' -f2-
}

# FLAC → 16-bit WAV via CoreAudio, then rewritten by python's wave module so
# the header is canonical (afconvert adds padding chunks that vary by OS).
decode() {  # in.flac out.wav
  afconvert -f WAVE -d LEI16 "$1" "$WORK/decoded.wav"
  python3 -I - "$WORK/decoded.wav" "$2" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "rb") as r:
    params, frames = r.getparams(), r.readframes(r.getnframes())
with wave.open(sys.argv[2], "wb") as w:
    w.setparams(params)
    w.writeframes(frames)
PY
}

{
  echo "# VoiceType bench fixtures — written by scripts/fetch_bench_fixtures.sh"
  echo "# kind<TAB>path<TAB>reference"
} > manifest.tsv

cp "$JFK" short/jfk.wav
printf 'short\tshort/jfk.wav\t%s\n' "$JFK_REFERENCE" >> manifest.tsv

for id in "${SHORT_IDS[@]}"; do
  IFS=- read -r spk ch _ <<< "$id"
  decode "$LS/$spk/$ch/$id.flac" "short/$id.wav"
  printf 'short\tshort/%s.wav\t%s\n' "$id" "$(transcript "$id")" >> manifest.tsv
done

echo "Building the long clip"
long_ids=()
for c in "${LONG_CHAPTERS[@]}"; do
  spk="${c%/*}"; ch="${c#*/}"
  while read -r id _; do long_ids+=("$id"); done < "$LS/$c/$spk-$ch.trans.txt"
done
mkdir -p "$WORK/long"
for id in "${long_ids[@]}"; do
  IFS=- read -r spk ch _ <<< "$id"
  decode "$LS/$spk/$ch/$id.flac" "$WORK/long/$id.wav"
done
python3 -I - "$LONG_GAP_SECONDS" long/librispeech-long.wav "${long_ids[@]/#/$WORK/long/}" <<'PY'
import sys, wave
gap, out, parts = float(sys.argv[1]), sys.argv[2], [p + ".wav" for p in sys.argv[3:]]
with wave.open(parts[0], "rb") as first:
    params = first.getparams()
silence = b"\0" * (int(gap * params.framerate) * params.sampwidth * params.nchannels)
with wave.open(out, "wb") as w:
    w.setparams(params)
    for i, p in enumerate(parts):
        with wave.open(p, "rb") as r:
            assert r.getparams()[:3] == params[:3], p
            if i:
                w.writeframes(silence)
            w.writeframes(r.readframes(r.getnframes()))
PY
long_reference=""
for id in "${long_ids[@]}"; do long_reference+="$(transcript "$id") "; done
printf 'long\tlong/librispeech-long.wav\t%s\n' "${long_reference% }" >> manifest.tsv

# --- Verify every fixture against the pins ---------------------------------------
if ! verify_pins; then
  echo "error: a generated fixture doesn't match its pinned SHA-256 (see above)" >&2
  exit 1
fi

if [[ "$KEEP" -eq 0 ]] && [[ "$TARBALL" == "$DIR/.download/test-clean.tar.gz" ]]; then rm -rf .download; fi
echo "✓ Bench fixtures ready in $DIR ($(grep -c '^short' manifest.tsv) short, $(grep -c '^long' manifest.tsv) long)"
