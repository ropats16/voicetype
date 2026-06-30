#!/usr/bin/env bash
# Embed ggml's Metal shader into the binary so it JIT-compiles at runtime — no
# Metal toolchain (xcrun metal) needed at build time, and nothing to bundle into
# the .app. This mirrors whisper.cpp's own GGML_METAL_EMBED_LIBRARY build
# (ggml/src/ggml-metal/CMakeLists.txt): merge ggml-common.h + ggml-metal-impl.h
# into the shader, then emit an assembly file that `.incbin`s the merged source.
#
# Outputs (gitignored build artifacts) into Sources/CWhisper/:
#   ggml-metal-embed.metal   merged shader source
#   ggml-metal-embed.s       assembly exposing ggml_metallib_start/_end
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
G="$ROOT/Sources/CWhisper/whisper.cpp/ggml/src"
M="$G/ggml-metal"
COMMON="$G/ggml-common.h"
IMPL="$M/ggml-metal-impl.h"
SRC="$M/ggml-metal.metal"
OUTDIR="$ROOT/Sources/CWhisper"
MERGED="$OUTDIR/ggml-metal-embed.metal"
ASM="$OUTDIR/ggml-metal-embed.s"

if [[ ! -f "$SRC" ]]; then
  echo "error: $SRC not found. Run 'git submodule update --init' (or 'make setup')." >&2
  exit 1
fi

if [[ -f "$ASM" && -f "$MERGED" && "$MERGED" -nt "$SRC" && "$MERGED" -nt "$COMMON" && "$MERGED" -nt "$IMPL" ]]; then
  echo "✓ embedded Metal shader already up to date"
  exit 0
fi

echo "Embedding Metal shader (merge headers + .incbin; no toolchain)…"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# 1) inline ggml-common.h at the __embed_ggml-common.h__ placeholder
sed -e "/__embed_ggml-common.h__/r ${COMMON}" -e "/__embed_ggml-common.h__/d" < "$SRC" > "$TMP"
# 2) inline ggml-metal-impl.h at its #include line
sed -e "/#include \"ggml-metal-impl.h\"/r ${IMPL}" -e "/#include \"ggml-metal-impl.h\"/d" < "$TMP" > "$MERGED"

# 3) assembly that embeds the merged source as a data blob (absolute path, like
#    the upstream cmake build, so .incbin resolves regardless of compiler CWD)
{
  echo ".section __DATA,__ggml_metallib"
  echo ".globl _ggml_metallib_start"
  echo "_ggml_metallib_start:"
  echo ".incbin \"${MERGED}\""
  echo ".globl _ggml_metallib_end"
  echo "_ggml_metallib_end:"
} > "$ASM"

echo "✓ Wrote $MERGED"
echo "✓ Wrote $ASM"
