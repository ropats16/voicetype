# VoiceType — local Whisper speech-to-text for macOS
#
# Single entry point for building and installing the app.
#   make setup     one-shot: fetch whisper.cpp, embed shader, download model, build, package
#   make run       build and run from the source tree (dev)
#   make build     just compile (release)
#   make package   assemble dist/VoiceType.app
#   make install   build, package, and copy to /Applications
#   make model     download the default model (override: make model MODEL=small.en)
#   make clean     remove build artifacts

APP   := VoiceType
MODEL ?= medium.en

.PHONY: setup embed model build run package install clean

setup:
	bash scripts/setup.sh $(MODEL)

# Generate the embedded Metal-shader artifacts (idempotent). Required before any
# swift build, so build/run depend on it.
embed:
	bash scripts/embed_metal_shader.sh

model:
	bash scripts/download_model.sh $(MODEL)

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
