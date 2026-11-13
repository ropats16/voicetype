# Acknowledgements

VoiceType is MIT-licensed and builds on the work below. This file is the
source for the in-app Acknowledgements screen (#21).

Each speech engine has one section, headed by its name exactly as Settings
shows it (`EngineKind.displayName`); `AcknowledgementsTests` checks every
registered engine has one. Other components (libraries, models not tied to an
engine) get a section of their own. Use this format:

```markdown
## <Name>

- **<Component>** — <author>. <License> (<SPDX id>). <URL>
  <Optional note: what VoiceType uses it for, attribution the license asks for.>
```

Full license texts live with each component (e.g. the submodule's `LICENSE`)
or at the linked URL.

## Whisper (whisper.cpp)

- **whisper.cpp** — Georgi Gerganov and contributors. MIT License (MIT).
  https://github.com/ggml-org/whisper.cpp
  Vendored as a submodule at `Sources/CWhisper/whisper.cpp`; VoiceType's
  default speech engine.
- **ggml** — Georgi Gerganov and contributors. MIT License (MIT).
  https://github.com/ggml-org/ggml
  The tensor library under whisper.cpp (Metal on Apple Silicon), bundled with it.
- **Whisper models** — OpenAI. MIT License (MIT). https://github.com/openai/whisper
  Model weights, converted to ggml format and published at
  https://huggingface.co/ggerganov/whisper.cpp; downloaded on demand.

## WhisperKit (Core ML)

- **WhisperKit** (argmax-oss-swift) — Argmax, Inc. MIT License (MIT).
  https://github.com/argmaxinc/argmax-oss-swift
  Runs Whisper on Core ML (Neural Engine); its WhisperKit library is linked
  into the app.
- **swift-transformers** (portions, in WhisperKit's `ArgmaxCore/External`) —
  Hugging Face SAS. Apache License 2.0 (Apache-2.0).
  https://github.com/huggingface/swift-transformers
  Hub and tokenizer code, modified by Argmax; linked in through WhisperKit.
- **Whisper models (Core ML)** — OpenAI. MIT License (MIT).
  https://github.com/openai/whisper
  Converted to Core ML by Argmax and published (MIT) at
  https://huggingface.co/argmaxinc/whisperkit-coreml, with OpenAI's tokenizer
  files from https://huggingface.co/openai; downloaded on demand by
  `make whisperkit-model`.

## Turbo (English/EU)

- **Parakeet TDT 0.6B v3** — NVIDIA. Creative Commons Attribution 4.0
  International (CC-BY-4.0). https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  License: https://creativecommons.org/licenses/by/4.0/. Used unmodified, in
  the Core ML conversion by FluidInference
  (https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml);
  downloaded on demand by `make parakeet-model`.
- **FluidAudio** — FluidInference. Apache License 2.0 (Apache-2.0).
  https://github.com/FluidInference/FluidAudio
  Runs Parakeet on Core ML (Neural Engine); linked into the app.
- **NemoTextProcessing (text-processing-rs)** — FluidInference. Apache License
  2.0 (Apache-2.0). https://github.com/FluidInference/text-processing-rs
  Prebuilt library, linked in through FluidAudio.
- **fastcluster** — © 2011 Daniel Müllner; changes from 1.1.24 © Google Inc.
  BSD 2-Clause License (BSD-2-Clause). https://danifold.net/fastcluster.html
  Linked in through FluidAudio.

## Apple Speech

- **Speech framework and on-device speech models** — Apple Inc. Part of macOS,
  under the macOS Software License Agreement. https://developer.apple.com/documentation/speech
  SpeechAnalyzer / SpeechTranscriber (macOS 26); macOS downloads and manages
  the models. Nothing is bundled with VoiceType.
