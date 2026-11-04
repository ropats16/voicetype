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
| `--model <file>` | (required) | model file passed to the engine's adapter factory |
| `--engine <id>` | `whisper` | an id from `BenchEngine.all` |
| `--manifest <tsv>` | `.bench/fixtures/manifest.tsv` | fixture list |
| `--runs <n>` | `3` | passes over the short clips (round-robin) |
| `--only short\|long` | both | skip one half (the long clip dominates run time) |
| `--language <code>` | `config.json`'s `language` | passed to the engine, as the app does |
| `--threads <n>` | `config.json`'s `threads` (0 = auto) | passed to the engine, as the app does |
| `--json <path>` | `.bench/results/<time>-<engine>-<model>.json` | report path |
| `--git-sha <sha>` | none (recorded as `null`) | commit to record; the binary never runs git |

`config.json` is only read (defaults if it's missing), never written.

Progress and engine logs go to stderr; only the table goes to stdout.

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

## JSON report (schema version 1)

Keys are sorted; durations in seconds, sizes in bytes. Every key is always
present — a value that's unknown or doesn't apply is `null`, never omitted — so
the key set is fixed per `schemaVersion`.

```jsonc
{
  "schemaVersion": 1,
  "createdAt": "2026-11-04T02:21:25Z",
  "machine": { "chip": "Apple M3 Max", "model": "Mac15,9", "memoryBytes": 51539607552,
               "performanceCores": 12, "efficiencyCores": 4,      // null on Intel
               "osVersion": "26.3.0 (25D125)",
               "thermalStateAtStart": "nominal", "thermalStateAtEnd": "nominal" },
  "engine":  { "id": "whisper", "modelFile": "ggml-tiny.en.bin",
               "modelBytes": 77704715 },       // directories summed; null if no such path
  "build":   { "configuration": "release", "gitSHA": "e344a97-dirty" },  // null without --git-sha
  "settings": { "shortRuns": 3, "language": "en", "threads": 0 },
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

Bump `schemaVersion` (in `BenchReport`) on any breaking change.

## Adding an engine

Write a `TranscriptionAdapter` (see `WhisperAdapter`) and the factory the app
will use for it, then register it with one line in `BenchEngine.all(_:)`
(`Sources/VoiceType/Bench/BenchRunner.swift`); `options` carries the app's
`language`/`threads`:

```swift
BenchEngine(id: "parakeet", makeAdapter: TranscriptionEngine.parakeetAdapter(language: options.language)),
```

and run `--bench --engine parakeet --model <its model file or directory>`. The
engine's `load()` reports `.missing` if `--model` isn't an existing path, so an
engine without a model file still needs some path (e.g. its asset directory).

## Code map

- `Bench/BenchCommand.swift` — CLI parsing, fixture decoding, machine info, output.
- `Bench/BenchRunner.swift` — `BenchEngine` registry, the run loop, memory sampling.
- `Bench/BenchReport.swift` — JSON schema + table. `Bench/BenchStats.swift` —
  percentiles, RTF. `Bench/WordErrorRate.swift` — normalization + WER.
  `Bench/BenchManifest.swift` — manifest parsing.
- Tests: `BenchTests` (fake adapter on a fake clock — exact timings),
  `WordErrorRateTests`.
