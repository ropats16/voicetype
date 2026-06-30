#pragma once
// Exposes whisper.cpp's plain-C API to Swift as `import CWhisper`.
// whisper.h pulls in ggml.h / ggml-cpu.h, resolved via the target's
// headerSearchPath settings in Package.swift.
#include "whisper.h"
