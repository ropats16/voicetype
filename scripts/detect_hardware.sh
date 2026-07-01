#!/usr/bin/env bash
# Detect this Mac's architecture, chip, and RAM, then recommend a default
# Whisper model and whether the Metal (GPU) build path applies. Consumed by
# scripts/setup.sh; also runnable standalone for diagnostics.
#
# Usage:
#   scripts/detect_hardware.sh            eval-safe KEY=value report on stdout
#                                         (ARCH, CHIP, MEM_GB, MODEL, METAL);
#                                         human narration goes to stderr.
#   scripts/detect_hardware.sh --model    print only the model (e.g. medium.en)
#   scripts/detect_hardware.sh --metal    print only 1 (Metal) or 0 (CPU-only)
#   scripts/detect_hardware.sh --arch     print only the arch (arm64 / x86_64)
#
# Model auto-pick (arch x whole-GiB RAM):
#   arm64  & >=16      -> medium.en     x86_64 & >=16          -> small.en
#   arm64  &  <16      -> small.en      x86_64 & >=8 and <16   -> base.en
#                                       x86_64 &  <8           -> tiny.en
#   Metal: arm64 -> 1, x86_64 -> 0
#
# Testability overrides (used instead of the live read when set), so the truth
# table can be verified on any machine and setup.sh/CI can be deterministic:
#   DETECT_ARCH        overrides `uname -m`
#   DETECT_MEM_BYTES   overrides `sysctl -n hw.memsize` (raw bytes)
#   DETECT_CHIP        overrides `sysctl -n machdep.cpu.brand_string`
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: detect_hardware.sh [--model | --metal | --arch]
  (no args)  eval-safe KEY=value report (ARCH CHIP MEM_GB MODEL METAL) on stdout
  --model    print the recommended Whisper model (e.g. medium.en)
  --metal    print 1 (Metal / Apple Silicon) or 0 (CPU-only / Intel)
  --arch     print the CPU architecture (arm64 or x86_64)
EOF
}

# Emit the argument single-quoted so it is safe to `eval`, escaping any embedded
# single quotes (' -> '\'').
squote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

detect_arch() {
  local a
  if [[ -n "${DETECT_ARCH:-}" ]]; then
    a="$DETECT_ARCH"
  elif ! a="$(uname -m 2>/dev/null)"; then
    echo "error: could not determine architecture (uname -m failed); set DETECT_ARCH to override." >&2
    return 1
  fi
  if [[ -z "$a" ]]; then
    echo "error: architecture came back empty; set DETECT_ARCH to override." >&2
    return 1
  fi
  printf '%s' "$a"
}

detect_chip() {
  local c
  if [[ -n "${DETECT_CHIP:-}" ]]; then
    c="$DETECT_CHIP"
  elif ! c="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"; then
    echo "error: could not read machdep.cpu.brand_string (need macOS/sysctl); set DETECT_CHIP to override." >&2
    return 1
  fi
  if [[ -z "$c" ]]; then
    echo "error: chip brand string came back empty; set DETECT_CHIP to override." >&2
    return 1
  fi
  printf '%s' "$c"
}

detect_mem_bytes() {
  local b
  if [[ -n "${DETECT_MEM_BYTES:-}" ]]; then
    b="$DETECT_MEM_BYTES"
  elif ! b="$(sysctl -n hw.memsize 2>/dev/null)"; then
    echo "error: could not read hw.memsize (need macOS/sysctl); set DETECT_MEM_BYTES to override." >&2
    return 1
  fi
  if [[ ! "$b" =~ ^[0-9]+$ ]]; then
    echo "error: memory size '$b' is not a positive integer number of bytes." >&2
    return 1
  fi
  printf '%s' "$b"
}

# whole-GiB from raw bytes (integer division by 1024^3)
gib_from_bytes() {
  printf '%s' "$(( $1 / (1024 * 1024 * 1024) ))"
}

metal_for_arch() {
  case "$1" in
    arm64)  printf '1' ;;
    x86_64) printf '0' ;;
    *) echo "error: unsupported architecture '$1' (expected arm64 or x86_64)." >&2; return 1 ;;
  esac
}

model_for() {
  local arch=$1 gib=$2
  case "$arch" in
    arm64)
      if (( gib >= 16 )); then printf 'medium.en'; else printf 'small.en'; fi
      ;;
    x86_64)
      if   (( gib >= 16 )); then printf 'small.en'
      elif (( gib >= 8 ));  then printf 'base.en'
      else                       printf 'tiny.en'
      fi
      ;;
    *)
      echo "error: unsupported architecture '$arch' (expected arm64 or x86_64)." >&2
      return 1
      ;;
  esac
}

report() {
  local arch chip bytes gib model metal
  arch="$(detect_arch)"
  chip="$(detect_chip)"
  bytes="$(detect_mem_bytes)"
  gib="$(gib_from_bytes "$bytes")"
  model="$(model_for "$arch" "$gib")"
  metal="$(metal_for_arch "$arch")"

  # Human narration on stderr; machine-parseable KEY=value on stdout.
  printf 'Detected %s, %s GB (%s) -> %s, Metal=%s\n' "$chip" "$gib" "$arch" "$model" "$metal" >&2

  printf 'ARCH=%s\n'   "$(squote "$arch")"
  printf 'CHIP=%s\n'   "$(squote "$chip")"
  printf 'MEM_GB=%s\n' "$(squote "$gib")"
  printf 'MODEL=%s\n'  "$(squote "$model")"
  printf 'METAL=%s\n'  "$(squote "$metal")"
}

main() {
  case "${1:-}" in
    --arch)
      local arch
      arch="$(detect_arch)"
      printf '%s\n' "$arch"
      ;;
    --metal)
      local arch metal
      arch="$(detect_arch)"
      metal="$(metal_for_arch "$arch")"
      printf '%s\n' "$metal"
      ;;
    --model)
      local arch bytes gib model
      arch="$(detect_arch)"
      bytes="$(detect_mem_bytes)"
      gib="$(gib_from_bytes "$bytes")"
      model="$(model_for "$arch" "$gib")"
      printf '%s\n' "$model"
      ;;
    "")
      report
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
