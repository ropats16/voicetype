# VoiceType — local Whisper speech-to-text for macOS
#
# Single entry point for building and installing the app.
#   make setup     one-shot: fetch whisper.cpp, embed shader, download model, build, package
#   make run       build and run from the source tree (dev)
#   make build     just compile (release)
#   make package   assemble dist/VoiceType.app
#   make install   build, package, and copy to /Applications
#   make model     download the model the app auto-picks for this Mac
#                  (or a specific one: make model MODEL=small.en-q5_1)
#   make vad-model download the Silero VAD model (bench --vad, #7)
#   make parakeet-model  download the Parakeet engine's model folder (#13)
#                  (or a specific one: make parakeet-model PARAKEET=<id>)
#   make whisperkit-model  download a WhisperKit (Core ML) model folder (#12)
#                  (or a specific one: make whisperkit-model WHISPERKIT=tiny.en)
#   make clean     remove build artifacts

APP   := VoiceType
# Empty = the model the app auto-picks for this Mac (scripts/model_catalog.sh).
MODEL ?=
# Empty = scripts/parakeet_catalog.sh's default (parakeet-tdt-0.6b-v3).
PARAKEET ?=
# Empty = scripts/download_whisperkit_model.sh's default (small.en_217MB).
WHISPERKIT ?=

.PHONY: setup embed model vad-model parakeet-model whisperkit-model build run package install clean

# `make setup` auto-detects the model from this Mac's arch + RAM. Pass MODEL= to
# override, e.g. `make setup MODEL=small.en-q5_1` — only a command-line MODEL is
# forwarded, so the plain `make setup` reaches setup.sh with no arg (auto-pick).
setup:
ifeq ($(origin MODEL),command line)
	bash scripts/setup.sh $(MODEL)
else
	bash scripts/setup.sh
endif

# Generate the embedded Metal-shader artifacts (idempotent). Required before any
# swift build, so build/run depend on it. No-op on Intel (CPU-only build).
embed:
	bash scripts/embed_metal_shader.sh

model:
	bash scripts/download_model.sh $(MODEL)

vad-model:
	bash scripts/download_vad_model.sh

parakeet-model:
	bash scripts/download_parakeet_model.sh $(PARAKEET)

whisperkit-model:
	bash scripts/download_whisperkit_model.sh $(WHISPERKIT)

build: embed
	swift build -c release

run: embed
	swift run -c release

# package_app.sh embeds + builds + assembles, so no extra build dependency here.
package:
	bash scripts/package_app.sh

install:
	bash scripts/package_app.sh --install

clean:
	swift package clean || true
	rm -rf dist
