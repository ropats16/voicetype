# Benchmark harness (`VoiceType --bench`)

Runs a speech engine over fixed audio fixtures **through `TranscriptionEngine`**
(the same load → warm-up → serial job queue the app uses) and reports what
matters for dictation: short-clip latency, long-audio real-time factor, peak
memory, model load time and word error rate. Output: a table on stdout and a
versioned JSON report, so runs compare across engines, models, commits and Macs.

## Running it on a Mac

```sh
git submodule update --init --recursive    # jfk.wav fixture + whisper.cpp
bash scripts/fetch_bench_fixtures.sh       # one time; idempotent; → .bench/fixtures
make build                                 # release build — debug numbers aren't comparable
.build/release/VoiceType --bench --git-sha "$(git describe --always --dirty)" \
  --model "$HOME/Library/Application Support/VoiceType/models/ggml-medium.en.bin"
```

On an 8 GB Mac (or for a quick run) use a lighter model — medium.en peaks
around 2 GiB:

```sh
make model MODEL=base.en                   # ~142 MiB
.build/release/VoiceType --bench --git-sha "$(git describe --always --dirty)" \
  --model "$HOME/Library/Application Support/VoiceType/models/ggml-base.en.bin"
```

Options:

| flag | default | |
|---|---|---|
| `--model <file>` | (required) | model file, directory or id; the engine's descriptor turns it into a `ModelSpec` |
| `--engine <id>` | `whisper` | an engine in `EngineRegistry.shared` this Mac can run (`BenchEngine.all`) |
| `--manifest <tsv>` | `.bench/fixtures/manifest.tsv` | fixture list |
| `--runs <n>` | `3` | passes over the short clips (round-robin) |
| `--only short\|long` | both | skip one half (the long clip dominates run time) |
| `--language <code>` | `config.json`'s `language` | passed to the engine, as the app does |
| `--threads <n>` | `config.json`'s `threads` (0 = auto) | passed to the engine, as the app does |
| `--suppress-nst on\|off` | `off` | whisper `suppress_nst`: never decode non-speech tokens (♪, `[…]`, `(…)` — but also `"` `:` `/` `*` `+` `=` `@` `#` `_` …) |
| `--audio-ctx off\|clip` | `off` | whisper `audio_ctx`: `off` = full 1500-frame (30 s) encoder window; `clip` = sized to each clip (`WhisperTuning.audioContext(forSampleCount:)`: frames + 64 padding, rounded up to 64, min 256, full window from ~28.5 s) |
| `--temp-fallback on\|off` | `on` | whisper `temperature_inc`: `on` = 0.2 (re-decode hotter when a decode looks bad), `off` = 0 (one greedy decode) |
| `--vad off\|<file>` | `off` | whisper's built-in Silero VAD: transcribe only detected speech. `<file>` = a ggml Silero model (`bash scripts/download_vad_model.sh` / `make vad-model` → `~/Library/Application Support/VoiceType/models/ggml-silero-v6.2.0.bin`) |
| `--json <path>` | `.bench/results/<time>-<engine>-<model>.json` | report path |
| `--git-sha <sha>` | none (recorded as `null`) | commit to record; the binary never runs git |

`config.json` is only read (defaults if it's missing), never written.

The four whisper flags (#7) default to what the app ships (`WhisperTuning.default`);
any combination can be swept without rebuilding, e.g.:

```sh
VAD="$(bash scripts/download_vad_model.sh)"
.build/release/VoiceType --bench --git-sha "$(git describe --always --dirty)" \
  --model "$HOME/Library/Application Support/VoiceType/models/ggml-base.en.bin" \
  --threads 4 --audio-ctx clip --temp-fallback off --vad "$VAD"
```

The chosen tuning is printed in the table header (`language en · threads auto ·
suppress-nst off · audio-ctx off · temp-fallback on · vad off`) and recorded in
the report's `settings.whisper`. Whatever the flags, the adapter always drops
non-speech tags from the text (`NonSpeechFilter`), so WER never counts them.

Progress goes to stderr; only the table goes to stdout. whisper.cpp/ggml's own
logs are silenced (`WhisperLogging`; warnings/errors go to `Log.debug` only).

For numbers worth comparing: plug in the Mac, close heavy apps, let it idle a
minute, and check the header's `thermal` reads `nominal` (it shows `start → end`
if the Mac heated up during the run). Run each config twice
and keep the second if the first ran on a cold disk cache (load time).

## What each number means

- **Load** — `adapter`: the adapter factory (`makeAdapter`: reading weights,
  building the GPU context, compiling Metal kernels). `warm-up`: the engine's
  1 s silent job before it reports ready. `total`: `load()` → ready, i.e. what
  the user waits for at launch. Measured by wrapping the factory and adapter the
  bench hands to `TranscriptionEngine`; the engine itself is unchanged.
- **Short dictation** — wall time of `engine.transcribe(samples)` per clip (the
  queue hop included: what the user waits for after releasing the key), each
  clip `--runs` times round-robin. Per-clip median/min/max; `p50`/`p90`/mean/max
  over every run of every clip. Audio decode isn't timed (it's done up front).
- **Long audio** — one `transcribe` of the ~10.4 min clip. `RTF` = processing ÷
  audio duration (lower is better; `speed` = 1/RTF, × real time). This is a
  single pass over the whole clip (the engine chunks internally, whisper.cpp in
  30 s windows); it is not the app's chunked/streaming path for meetings
  (#7/#31), which adds per-chunk overhead and context handling.
- **Memory** — the bench process's `phys_footprint` (what Activity Monitor calls
  Memory; on Apple Silicon it includes Metal buffers), via
  `proc_pid_rusage(RUSAGE_INFO_V4)`. Only this process is counted: an engine
  that runs inference in an OS service (Apple SpeechAnalyzer, #14) will read
  far too low, so compare its RAM with Activity Monitor or `footprint` on the
  service as well. `baseline`: before the model loads (fixtures
  already decoded, ~40 MiB of them). `loaded`: after load + warm-up. `peak`:
  highest footprint *sampled* on a short timer (`BenchRunner.memorySampleInterval`)
  and between jobs (never inside a timed job), from load start to the end — the
  engine's peak; a spike shorter than the interval can be missed. `lifetime peak`: the kernel's exact
  `ri_lifetime_max_phys_footprint` at the end — an upper bound that also counts
  fixture decoding. Engine cost ≈ `peak − baseline`.
- **WER** — word-level Levenshtein (S + D + I) ÷ reference words, after the same
  normalization on both sides: lowercase; apostrophes dropped (`don't` =
  `dont`); other punctuation → space (so hyphens split words); whitespace
  collapsed; numbers spelled out as LibriSpeech references read them (`21` →
  `twenty one`; `1,905` → `one thousand nine hundred five`; four-digit years
  1100–2099 year-style: `1961` → `nineteen sixty one`, `1905` → `nineteen oh
  five`, `2005` → `two thousand five`, `2010` → `twenty ten`; `$5` → `five
  dollars`; `5%` → `five percent`).
  No other text normalization (e.g. `Mr.` vs `MISTER`, British spellings), so
  absolute WER runs a little high; comparisons between engines stay fair.
  Short-clip WER is pooled (total edits ÷ total words), not a mean of rates.

## Fixtures

`scripts/fetch_bench_fixtures.sh` builds `.bench/fixtures/` (git-ignored):

| clip | source | length | |
|---|---|---|---|
| `short/jfk.wav` | whisper.cpp `samples/jfk.wav` | 11 s | public domain (1961 inaugural address); repo MIT |
| `short/<utt>.wav` × 7 | LibriSpeech test-clean: 2830-3980-0000, 4446-2271-0000, 61-70968-0000, 3570-5694-0001, 260-123286-0000, 7176-92135-0001, 2961-960-0007 | 3.5–7.6 s, 4 M + 3 F speakers | CC BY 4.0 |
| `long/librispeech-long.wav` | LibriSpeech test-clean chapters 5639/40744 (M) then 1284/134647 (F), utterances in order, 0.25 s silence between | 623 s (10.4 min) | CC BY 4.0 |

The fixtures are read speech (audiobooks): fluent, well-recorded, with
literary vocabulary. Real dictation is spontaneous (fillers, restarts), terser,
heavier on names, numbers and jargon, and recorded on laptop or AirPods mics, so
absolute WER and latency will differ in the app. Use the bench to rank engines
and catch regressions, not to predict dictation accuracy exactly.

No single test-clean speaker or chapter reaches 10 min (the longest is 8.3), so
the long clip joins two whole chapters. References are LibriSpeech's own
transcripts (uppercase, no punctuation, numbers spelled out).

LibriSpeech ASR corpus © 2014 Vassil Panayotov, CC BY 4.0
(<https://www.openslr.org/12>; V. Panayotov, G. Chen, D. Povey, S. Khudanpur,
"LibriSpeech: an ASR corpus based on public domain audio books", ICASSP 2015).
Its `LICENSE.TXT` is copied to `.bench/fixtures/LICENSE-LibriSpeech.txt`.

The script downloads `test-clean.tar.gz` (~331 MiB) once from openslr.org
(override with `LIBRISPEECH_URL=` for a mirror, or `--tarball <path>` for a local
copy), checks its pinned SHA-256, extracts only the files used, decodes FLAC →
16 kHz mono 16-bit WAV with `afconvert`, rewrites headers canonically with
python's `wave`, and checks every output (and `manifest.tsv`) against pinned
SHA-256s — so every Mac benches byte-identical audio. The tarball is deleted
afterwards unless `--keep-download`.

Fixture files are decoded by the bench through `WavFileSource` + `AudioCapture`
(the same resampling path as the mic), so any format AVAudioFile reads works in
a hand-written manifest.

### Manifest format

`manifest.tsv`, one clip per line, tab-separated: `kind<TAB>path<TAB>reference`.
`kind` is `short` (latency) or `long` (RTF); `path` is relative to the manifest
(or absolute); `#` comments and blank lines are ignored. The clip id is the file
name without its extension.

## JSON report (schema version 2)

Keys are sorted; durations in seconds, sizes in bytes. Every key is always
present — a value that's unknown or doesn't apply is `null`, never omitted — so
the key set is fixed per `schemaVersion`.

```jsonc
{
  "schemaVersion": 2,
  "createdAt": "2026-11-04T02:21:25Z",
  "machine": { "chip": "Apple M3 Max", "model": "Mac15,9", "memoryBytes": 51539607552,
               "performanceCores": 12, "efficiencyCores": 4,      // null on Intel
               "osVersion": "26.3.0 (25D125)",
               "thermalStateAtStart": "nominal", "thermalStateAtEnd": "nominal" },
  "engine":  { "id": "whisper", "modelFile": "ggml-tiny.en.bin",
               "modelBytes": 77704715 },       // directories summed; null if no such path
  "build":   { "configuration": "release", "gitSHA": "e344a97-dirty" },  // null without --git-sha
  "settings": { "shortRuns": 3, "language": "en", "threads": 0,
                "whisper": { "suppressNonSpeech": false, "audioContext": "off",   // "off" | "clip"
                             "temperatureFallback": true,
                             "vad": null } },   // null = off, else the Silero model path
  "results": {
    "load":   { "adapterSeconds": 0.08, "warmUpSeconds": 0.04, "totalSeconds": 0.12 },
    "memory": { "baselineBytes": …, "loadedBytes": …, "peakBytes": …,
                "lifetimePeakBytes": … },      // null if unreadable
    "short": {
      "clips": [ { "id": "jfk", "audioSeconds": 11.0, "latenciesSeconds": [0.044, …],
                   "medianLatencySeconds": 0.044,
                   "transcript": { "reference": "…", "hypothesis": "…",
                                   "wer": { "substitutions": 0, "deletions": 0, "insertions": 0,
                                            "referenceWords": 22, "rate": 0.0 } } } ],
      "latency": { "count": 24, "p50Seconds": …, "p90Seconds": …, "meanSeconds": …,
                   "minSeconds": …, "maxSeconds": … },   // null with no short clips
      "wer": { … pooled … }
    },
    "long": {
      "clips": [ { "id": "librispeech-long", "audioSeconds": 623.5, "processingSeconds": 3.1,
                   "realTimeFactor": 0.005, "transcript": { … } } ],
      "realTimeFactor": 0.005,                           // null with no long clips
      "wer": { … }
    }
  }
}
```

Bump `schemaVersion` (in `BenchReport`) on any breaking change. v2 (#7) added
`settings.whisper`.

## Adding an engine

One registration plugs an engine into the app, Settings, config validation,
the model-missing notices, `--selftest --engine` and the bench at once:

1. Write the adapter: a `TranscriptionAdapter` (see `WhisperAdapter`). The
   engine calls it only on its own serial queue, so it needs no locking;
   segments carry seconds from the start of the submitted audio.
2. Describe the engine in one new file,
   `Sources/VoiceType/Transcription/Engines/<Name>Engine.swift`: a struct
   conforming to `EngineDescriptor` (see `EngineDescriptor.swift` for each
   requirement's contract, `WhisperEngine.swift` for a full example).
   Required: `kind` (its `EngineKind` case — ids `whisperkit`, `parakeet`,
   `apple-speech` already exist), `resolve(_:in:)` (the user's `ModelChoice`
   → `ModelSpec` with `engine: kind`), `makeAdapter(_:)` and
   `acknowledgement`. Override as needed: `availability(in:)` (e.g.
   `environment.isAtLeast(macOS: 26)`, `environment.hardware.isAppleSilicon`;
   return `.unavailable(reason: "Apple Speech needs macOS 26")`),
   `supportedLanguages` (nil = any; include `"auto"` only if it detects the
   language), `models` (Settings' picker rows), `isPresent(_:)` (default: a
   file or directory at `spec.path`; OS-managed models override),
   `installedModelIDs(in:)`, `downloadHint(for:)` (`.command(…)` or
   `.instructions(…)`), `spec(forModelArgument:language:)` (what `--model`
   means).
3. Register it with one line in `EngineRegistry.shared`
   (`Sources/VoiceType/Transcription/Engines/EngineRegistry.swift`):

   ```swift
   static let shared = EngineRegistry([
       WhisperEngine(),
       ParakeetEngine(),
   ])
   ```

4. Credit it: append a `## <EngineKind.displayName>` section to
   `ACKNOWLEDGEMENTS.md` (`AcknowledgementsTests` checks every registered
   engine has one).
5. Test it with the shared contract (`Tests/VoiceTypeTests/EngineContract.swift`):
   `try await EngineContract.assertTranscribesJFK(spec:, engines:)` and
   `assertSilenceYieldsNoTags`, skipping when its model isn't installed.

Then `--bench --engine parakeet --model <model file, directory or id>` runs
it: `BenchEngine.all` comes from the registry, and an id that's unknown, not
registered, or unavailable on this Mac fails with the reason. `--model` goes
through the descriptor's `spec(forModelArgument:language:)` (as an absolute
path) and `.missing` follows its `isPresent`, so an OS-managed engine can
take a locale or model id there.

## Code map

- `Bench/BenchCommand.swift` — CLI parsing (`tuning(from:)` for the whisper flags),
  fixture decoding, machine info, output.
- `Transcription/WhisperTuning.swift` — the whisper knobs and `audio_ctx` sizing;
  `WhisperAdapter.fullParams` maps them onto `whisper_full_params`.
- `Bench/BenchRunner.swift` — `BenchEngine` (built from `EngineRegistry`), the
  run loop, memory sampling.
- `Transcription/Engines/` — `EngineKind`, `EngineDescriptor`, `EngineRegistry`,
  one descriptor per engine.
- `Bench/BenchReport.swift` — JSON schema + table. `Bench/BenchStats.swift` —
  percentiles, RTF. `Bench/WordErrorRate.swift` — normalization + WER.
  `Bench/BenchManifest.swift` — manifest parsing.
- Tests: `BenchTests` (fake adapter on a fake clock — exact timings),
  `WordErrorRateTests`.

## Whisper tuning (#7) — results

Run 2026-11-10 on an Apple M3 Max (Mac15,9, 12P + 4E, 48 GiB), macOS 26.7.2
(25G332), release build, plugged in, every run thermal `nominal` unless noted.
Primary model **medium.en** (the app default; 1.43 GiB), with **tiny.en** as the
lighter-Mac reference. Fixtures: the standard manifest (8 short clips, 127
words; 623 s long clip, 1754 words), `--runs 3`.

- Sweep binary: `85891a8` (chunk 1: knobs + flags). "Before" = bc37815's
  decoding, reproduced by flags: `--suppress-nst off --audio-ctx off
  --temp-fallback on --vad off --threads 0` (auto = min(16, 8) = 8).
- "After" binary: `e2f7abb` (these defaults), no tuning flags, `--threads 0`
  (auto = min(12 P-cores, 8) = 8).
- Shas are the on-`main` commits. The runs used the same code before a rebase
  onto the DictationSession work (pre-rebase `c3663f7` / `94b6675`); nothing
  under `Transcription/` or `Bench/` differs. The later inline-caption filter
  tightening (review fix) doesn't touch these fixtures: LibriSpeech output has
  no tags.
- Method: one knob at a time vs the baseline. Each config ran twice, in
  opposite orders (round 1 A→Z, round 2 Z→A), ≥ 45 s idle between runs and
  only once the thermal state was back to `nominal` and no other build/test was
  running; the table averages the two rounds (they agreed within ~5 ms). An
  earlier sweep without cool-downs drifted by up to 2× as the Mac heated
  (`fair`), so ignore single uncooled runs.

### Before / after

| model | build | load | short p50 | short p90 | long RTF | peak mem | short WER | long WER |
|---|---|---|---|---|---|---|---|---|
| medium.en | before (bc37815 decoding) | 0.67 s | 296 ms | 325 ms | 0.0311 (32×) | 2,094 MiB | 3.1% (4/127) | 3.19% (56/1754) |
| medium.en | **after** (e2f7abb) | 0.67 s | 290 ms | 323 ms | 0.0311 (32×) | 2,096 MiB | 3.1% (4/127) | 3.19% (56/1754) |
| tiny.en | before | 0.11 s | 36 ms | 43 ms | 0.0051 | 499 MiB | 3.1% (4/127) | 6.21% (109/1754) |
| tiny.en | **after** | 0.13 s | 36 ms | 43 ms | 0.0049 | 498 MiB | 3.1% (4/127) | 6.21% (109/1754) |

Same speed and accuracy: on this Mac no knob bought latency without costing
accuracy, so the shipped decoding stays whisper.cpp's own. What #7 changes is
correctness: non-speech tags never reach the text (`NonSpeechFilter`), whisper/ggml
logs are silenced, and `suppress_nst` — which chunk 1 had turned on — is off
again, keeping `:` `/` quotes etc. in dictation.

### Per-knob sweep (vs baseline)

medium.en:

| config | load | short p50 | short p90 | long RTF | peak mem | short WER | long WER |
|---|---|---|---|---|---|---|---|
| baseline | 0.67 s | 296 ms | 325 ms | 0.0311 | 2,094 MiB | 3.1% (4/127) | 3.19% (56/1754) |
| suppress-nst on | 0.64 s | 292 ms | 324 ms | 0.0310 | 2,096 MiB | 3.1% (4/127) | 3.36% (59/1754) |
| audio-ctx clip | 0.60 s | 198 ms | 5,467 ms | — | 2,283 MiB | **16.5%** (21/127) | — |
| audio-ctx clip + temp-fallback off | 0.54 s | 177 ms | 981 ms | — | 1,986 MiB | **174.8%** (222/127) | — |
| temp-fallback off | 0.67 s | 291 ms | 324 ms | 0.0311 | 2,095 MiB | 3.1% (4/127) | 3.19% (56/1754) |
| VAD (Silero v6.2.0) | 0.45 s | 305 ms | 342 ms | 0.0325 | 2,129 MiB | 3.1% (4/127) | 3.65% (64/1754) |
| threads 1 | 0.68 s | 296 ms | 329 ms | 0.0319 | 2,096 MiB | 3.1% | 3.19% |
| threads 2 | 0.67 s | 294 ms | 327 ms | 0.0314 | 2,095 MiB | 3.1% | 3.19% |
| threads 4 | 0.67 s | 292 ms | 323 ms | 0.0313 | 2,095 MiB | 3.1% | 3.19% |
| threads 6 | 0.68 s | 290 ms | 323 ms | 0.0311 | 2,096 MiB | 3.1% | 3.19% |
| threads 8 (= baseline) | 0.67 s | 296 ms | 325 ms | 0.0311 | 2,094 MiB | 3.1% | 3.19% |
| threads 12 | 0.67 s | 288 ms | 323 ms | 0.0311 | 2,096 MiB | 3.1% | 3.19% |

tiny.en (direction check):

| config | load | short p50 | short p90 | long RTF | short WER | long WER |
|---|---|---|---|---|---|---|
| baseline | 0.11 s | 36 ms | 43 ms | 0.0051 | 3.1% (4/127) | 6.21% (109/1754) |
| suppress-nst on | 0.10 s | 36 ms | 44 ms | 0.0050 | 3.1% | 6.04% (106/1754) |
| audio-ctx clip | 0.12 s | 31 ms | 49 ms | — | **13.4%** (17/127) | — |
| temp-fallback off | 0.11 s | 35 ms | 43 ms | 0.0049 | 3.1% | 6.21% |
| VAD | 0.08 s | 51 ms | 66 ms | 0.0070 | 2.4% (3/127) | **7.24%** (127/1754) |
| threads 2 / 4 / 12 | 0.11–0.12 s | 37 / 35 / 35 ms | 46 / 44 / 42 ms | 0.0053 / 0.0050 / 0.0048 | 3.1% | 6.21% |

`audio-ctx clip` is short-clip only (it has no effect on the 623 s clip). Its
row on medium.en is one round from the uncooled sweep (nominal throughout); the
p90 is a clip (3570-5694-0001) re-decoding for ~8 s per run. With fallback off
too, a clip decodes into a repetition loop (WER 175%). VAD's load looks faster
only because its 1 s silent warm-up skips the encoder (see below).

### Silence and noise

A scratch manifest of 3/8 s digital silence, 5 s white noise at −45 and
−30 dBFS, 8 s brown noise at −30 dBFS, and the JFK clip with 1 s of noise before
and 6 s after (empty references, so any word is an insertion). Median of 3
runs; `∅` = empty output.

| model · config | silence 3 s | silence 8 s | white −45 | white −30 | brown −30 | JFK + 6 s tail |
|---|---|---|---|---|---|---|
| medium · baseline (nst off, fallback on) = **after** | 205 ms ∅ | 206 ms ∅ | 198 ms ∅ | 193 ms ∅ | 187 ms ∅ | 323 ms, 0% WER |
| medium · fallback off | 206 ms ∅ | 207 ms ∅ | 200 ms ∅ | 194 ms ∅ | 189 ms ∅ | 326 ms, 0% WER |
| medium · nst on | 175 ms **“you”** | 176 ms **“you”** | 169 ms ∅ | 175 ms ∅ | 188 ms ∅ | 325 ms, 0% WER |
| medium · nst on, fallback off | 175 ms **“you”** | 176 ms **“you”** | 170 ms ∅ | 176 ms ∅ | 189 ms ∅ | 326 ms, 0% WER |
| medium · nst on, VAD | 7 ms ∅ | 18 ms ∅ | 11 ms ∅ | 10 ms ∅ | 16 ms ∅ | 359 ms, 0% WER |
| tiny · baseline | 21 ms ∅ | 22 ms ∅ | 21 ms ∅ | 19 ms ∅ | 22 ms ∅ | 46 ms, 0% WER |
| tiny · fallback off | 21 ms ∅ | 22 ms ∅ | 21 ms ∅ | 20 ms ∅ | 22 ms ∅ | 46 ms, 0% WER |
| tiny · nst on | 16 ms ∅ | 17 ms ∅ | 26 ms ∅ | 26 ms ∅ | 19 ms ∅ | 46 ms, 0% WER |
| tiny · VAD | 6 ms ∅ | 18 ms ∅ | 11 ms ∅ | 11 ms ∅ | 17 ms ∅ | 86 ms, 0% WER |

- Temperature fallback costs nothing on silence or noise in release builds
  (the 8.5 s seen in a debug build didn't reproduce on either model).
- With `suppress_nst` off, medium.en decodes digital silence to
  `[BLANK_AUDIO]`, which `NonSpeechFilter` drops (empty output). With it on,
  that token is banned and the model says "you" instead — a hallucination that
  would be pasted.
- VAD makes empty clips 10–30× cheaper (no encoder run) and removes the "you",
  but adds 35–40 ms to a clip that has speech.

### Decisions

Tolerance (agreed for #7): adopt a knob only if short-clip WER regresses by
≤ 0.5 percentage points absolute vs baseline **and** latency improves
meaningfully; threads: the faster at equal WER. Note 1 word on the short set is
0.79 pp, so in practice "no extra short-clip errors".

| knob | decision | why |
|---|---|---|
| `suppress_nst` | **off** (chunk 1 had on) | No latency or short-WER change; long WER +0.17 pp on medium (−0.17 on tiny: noise). But its token list (`whisper.cpp`'s `non_speech_tokens`) bans `"` `#` `(` `)` `*` `+` `/` `:` `;` `<` `=` `>` `@` `[` `]` `_` `{` `|` `}` `~` `--` — "3:30", "and/or", quotes, emails — and turns silence into "you" on medium. Tags are kept out by `NonSpeechFilter` instead (now also `*sighs*`-style captions). |
| `audio_ctx` sized to clip | **rejected** | −98 ms p50 (−33%), but short WER +13.4 pp (medium) / +10.2 pp (tiny) and an 8 s tail: far outside 0.5 pp. |
| temperature fallback off | **rejected** (stays on) | No latency gain (−5 ms p50, within noise; RTF equal), equal WER; fallback is what rescues bad decodes (with `audio_ctx` clip, turning it off went 16.5% → 175% WER). |
| Silero VAD | **rejected** (flag kept for later) | Short WER equal but no latency gain: +9 ms p50 on medium, +15 ms on tiny; long WER +0.46 pp medium / +1.03 pp tiny (segments decoded without their neighbours' context; RTF +5% / +37%). Its win is only empty/silent clips, already handled (empty output) without it. Shipping it would also need the Silero model provisioned in-app. |
| threads | **auto = performance cores, ≤ 8** (`WhisperAdapter.autoThreadCount`) | 1–12 threads within noise on both models (Metal does the work; ≤ ±3% p50, long RTF 0.0311–0.0319 medium). 8 stays on this Mac (min(12 P, 8)), so this is the benched config; the old rule, min(all cores, 8), would put efficiency cores in the pool on 4P+4E Macs, where they'd only lag ggml's per-op barriers. Unmeasured on those Macs. |

If VAD is revisited (e.g. for long meeting audio with lots of silence): the
engine's warm-up feeds 1 s of silence, which VAD skips entirely, so the encoder
and decoder pipelines aren't compiled until the first real dictation (the 0.00 s
warm-up above). The warm-up would need a non-silent signal, or to bypass VAD.

### Commands

```sh
W=.bench/results/issue-7; mkdir -p "$W"
M="$HOME/Library/Application Support/VoiceType/models"
VAD="$(bash scripts/download_vad_model.sh)"
SHA="$(git describe --always --dirty)"
bench() { .build/release/VoiceType --bench --git-sha "$SHA" --runs 3 --threads "${T:-0}" "$@"; }

# before (on 85891a8): bc37815's decoding
bench --model "$M/ggml-medium.en.bin" --suppress-nst off --audio-ctx off --temp-fallback on --vad off --json "$W/before.json"
# one knob at a time (each flag once; the first occurrence wins)
bench --model "$M/ggml-medium.en.bin" --suppress-nst on  --audio-ctx off  --temp-fallback on  --vad off --json "$W/nst.json"
bench --model "$M/ggml-medium.en.bin" --suppress-nst off --audio-ctx clip --temp-fallback on  --vad off --only short --json "$W/ctx.json"
bench --model "$M/ggml-medium.en.bin" --suppress-nst off --audio-ctx off  --temp-fallback off --vad off --json "$W/tfoff.json"
bench --model "$M/ggml-medium.en.bin" --suppress-nst off --audio-ctx off  --temp-fallback on  --vad "$VAD" --json "$W/vad.json"
# threads: T=1 / 2 / 4 / 6 / 12 with the before flags, e.g.
T=4 bench --model "$M/ggml-medium.en.bin" --suppress-nst off --audio-ctx off --temp-fallback on --vad off --json "$W/thr4.json"
# after (on e2f7abb): the app's defaults
bench --model "$M/ggml-medium.en.bin" --json "$W/after.json"
# tiny.en: the same with ggml-tiny.en.bin; silence/noise: --manifest <scratch manifest> --only short
```

Between runs: wait ≥ 45 s, for thermal `nominal`, and for no other compile/test
to be running. The bench takes the **first** occurrence of a flag, so a sweep
script mustn't append overrides after a base set of flags.

## Parakeet (#13) — results

Run 2026-11-13, same Mac and fixtures as above (M3 Max, macOS 26.7.2, release,
nominal), `--engine parakeet --language en --runs 3`, model folder
`parakeet-tdt-0.6b-v3` (`make parakeet-model`; FluidAudio 0.17.7, default int8
encoder), single uncooled run — treat as indicative.

| engine / model | load | short p50 | short p90 | long RTF | peak mem | short WER | long WER |
|---|---|---|---|---|---|---|---|
| parakeet / tdt-0.6b-v3 | 0.19 s (first ever: 17 s) | 63 ms | 75 ms | 0.0035 (290×) | 169 MiB | 0.8% (1/127) | 2.39% (42/1754) |
| whisper / medium.en (above) | 0.67 s | 290 ms | 323 ms | 0.0311 (32×) | 2,096 MiB | 3.1% (4/127) | 3.19% (56/1754) |

**Parakeet notes.** The first load after a download compiles the models for the
Neural Engine (~17 s, 534 MiB lifetime peak); Core ML caches that, so later
loads take ~0.2 s, until an OS update or a model change. `phys_footprint` doesn't
count Neural Engine memory, so the 169 MiB peak understates the real cost.
Silence decodes to empty text. Follow-ups: (1) our manifest is tools 5.9, so
FluidAudio's traits can't be turned off — its TTS and diarizer code and the
NemoTextProcessing library (~8 MB) are compiled in; a tools-6.2 manifest with
`traits: []` would drop them. (2) The default int8 encoder can flip tokens on
some windows (FluidAudio #760); `Encoder_v2.mlmodelc` (int8-v2, +143 MB) fixes
that — bench it before switching. (3) `scripts/package_app.sh` doesn't copy the
`FluidAudio_FluidAudio.bundle` resource bundle; the ASR path never reads it, but
FluidAudio's TTS would crash without it.
