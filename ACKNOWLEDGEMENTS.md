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
