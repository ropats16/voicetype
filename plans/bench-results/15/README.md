# #15 — benchmark run + default-engine decision

Short runs on one Mac, plus inference for the rest. **Measured:** everything
in the tables marked M3 Max. **Extrapolated (not measured):** every M1 8 GB
figure and every 60-minute battery/heat figure. No M1 8 GB was available and
the 60-minute battery/heat run was deferred; both are #40
("Re-run benchmark on M1 8 GB + 60-min battery/heat").

## Setup

- Apple M3 Max (Mac15,9, 12P + 4E CPU, 40-core GPU, 48 GB), macOS 26.7.2
  (25G332), plugged in. Release build of `35980a9` (this branch: `main` +
  the Automatic policy; nothing under `Bench/` or the adapters differs from
  `main`). Thermal `nominal` at the start and end of every run.
- Before each run: waited for no `swift-build`/`swift-frontend`/`xctest`
  process (none ran: no other agent was building), no thermal warning
  (`pmset -g therm`), then 45 s idle. Single runs, not the #7 two-round
  method; they match #7/#12/#13/#14's numbers within a few ms, so treat them as
  indicative to ±5%. Background apps (a browser, a VM) were open, as on a real
  Mac; the idle whole-Mac baseline moved between 10 and 23 W because of them.
- Standard fixtures (`.bench/fixtures/manifest.tsv`: 8 short clips, 127 words;
  623 s long clip, 1754 words), `--language en`. Short: `--runs 3 --only
  short` (24 jobs). Long: `--only long` (one pass). Raw JSON: `<engine>-short.json`,
  `<engine>-long.json`, `<engine>-pressure.json` here; `power/` for the
  energy runs.

| id | engine | model |
|---|---|---|
| parakeet | Turbo, FluidAudio 0.17.7 | `parakeet-tdt-0.6b-v3` (470 MB folder) |
| apple-speech | SpeechAnalyzer + SpeechTranscriber | OS-managed `en` model |
| whisper-small.en-q5_1 | whisper.cpp (Metal) | `ggml-small.en-q5_1.bin` (192 MB) — the 8–15 GB tier default |
| whisper-medium.en | whisper.cpp (Metal) | `ggml-medium.en.bin` (1.43 GiB) — stand-in for the ≥ 16 GB tier (`medium.en-q5_0`/`q8_0` are smaller, similar speed) |
| whisper-tiny.en | whisper.cpp (Metal) | `ggml-tiny.en.bin` |
| whisperkit-small.en_217MB | WhisperKit 1.1.1 (ANE) | `small.en_217MB` |

## Results (M3 Max, measured)

| engine | load (warm / first) | short p50 | short p90 | short WER | long WER | long RTF | engine RAM (peak − baseline) | Δ whole-Mac power, long clip | energy per audio-hour (whole-Mac Δ) | `top` energy impact (mean / peak) | thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **parakeet** | 0.18 s / 15.1 s ¹ | **55 ms** | **59 ms** | **0.8%** (1/127) | 2.39% (42/1754) | **0.0028** (357×) | 72 MiB + ANE ² | +34.7 W | **0.10 Wh** | 336 / 457 | nominal → nominal |
| **apple-speech** | 0.15 s / 0.26 s | 119 ms | 147 ms | 2.4% (3/127) | **2.17%** (38/1754) | 0.0182 (55×) | 59 MiB in-process + ~166 MiB `localspeechrecognition` ³ | +16.7 W | 0.31 Wh | 113 / 122 (≈ 98 of it the XPC service) | nominal → nominal |
| **whisper small.en-q5_1** | 0.19 s / 8.0 s ⁴ | 114 ms | 128 ms | 3.1% (4/127) | 2.74% (48/1754) | 0.0129 (78×) | 564 MiB | +51.0 W | 0.67 Wh | 36 / 90 | nominal → nominal |
| whisper medium.en | 0.70 s / 0.95 s | 283 ms | 316 ms | 3.1% (4/127) | 3.19% (56/1754) | 0.0302 (33×) | 1,998 MiB | +62.2 W | 1.95 Wh | 25 / 88 | nominal → nominal |
| whisper tiny.en | 0.10 s / 0.15 s | 35 ms | 43 ms | 3.1% (4/127) | 6.21% (109/1754) | 0.0048 | 402 MiB | — | — | 36 / 46 | nominal → nominal |
| whisperkit small.en_217MB | 0.83 s / 17.7 s ¹ | 383 ms | 453 ms | 3.1% (4/127) | 7.35% (129/1754) ⁵ | 0.0432 (23×) | 648 MiB + ANE ² | — | — | 76 / 96 | nominal → nominal |

1. First load after the binary/model changed: Core ML compiles the model for
   the Neural Engine, then caches it until a model change or OS update.
2. `phys_footprint` doesn't count Neural Engine memory.
3. The model runs in a per-client XPC process; its RSS is #14's measurement
   (~166 MiB peak on the long clip), not re-measured here.
4. First use of a newly downloaded file: the checksum hash (cached afterwards).
5. #12 measured 3.5% on the same clip: WhisperKit's unseeded temperature
   fallback makes long-form WER vary run to run (see `plans/benchmark.md`).

### Energy proxy (no sudo)

Two proxies, neither is `powermetrics`:

- **Whole-Mac power** (`power/`): the battery controller's
  `PowerTelemetryData` accumulators (`AccumulatedSystemLoad /
  SystemLoadAccumulatorCount` deltas, `ioreg -c AppleSmartBattery`; published
  about once a minute, so each run was ~150 s idle, then the long clip repeated
  to ~150 s of transcription: parakeet ×86, apple-speech ×14, small.en-q5_1 ×19,
  medium.en ×8). Power = mean over the publication spans fully inside each
  phase; Δ = transcribing − idle. **Energy per audio-hour = Δ W × RTF** (Wh of
  extra energy to transcribe one hour of audio). It counts CPU + GPU + ANE +
  memory (plus whatever else changed on the Mac), not just this process.
- **`top` energy impact** (`top -l 0 -s 1 -stats pid,command,cpu,power`,
  VoiceType + `localspeechrecognition`, during the same runs): it tracks CPU
  time only (≈ %CPU here) and misses the GPU and ANE, so it ranks whisper.cpp
  (GPU) as cheap and Turbo (≈ 3.4 cores of CPU around its ANE work) as costly
  per second. Use it for "how much CPU does it take from other apps", not for
  energy.

Per audio-hour the whole-Mac figure ranks the engines Turbo (0.10 Wh) < Apple
Speech (0.31) < whisper small.en-q5_1 (0.67) < medium.en (1.95): Turbo draws
the most power while it runs but finishes ~5–10× sooner.

### 8 GB proxy: simulated memory pressure

`memory_pressure -l warn` (it allocates until the kernel reports the warn
level — reached in ~25 s, ~40 GB of pages compressed, 0.8 GB swapped) held for
one short-clip run per main engine, then killed (checked: no
`memory_pressure` left; pressure level back to normal). Raw:
`*-pressure.json`.

| engine | short p50 / p90 idle | under warn pressure | load | peak footprint idle → pressure |
|---|---|---|---|---|
| parakeet | 55 / 59 ms | 55 / 67 ms | 0.28 s | 71 → 50 MiB |
| apple-speech | 119 / 147 ms | 121 / 144 ms | 0.23 s | 14 → 12 MiB (+ XPC service) |
| whisper small.en-q5_1 | 114 / 128 ms | 116 / 129 ms | 0.29 s | 698 → 510 MiB |

No latency change: the kernel compressed other memory and the warm models'
working sets stayed resident. On a real 8 GB Mac the ceiling is far lower (the
48 GB Mac still had 45% free at "warn"), so this shows the engines degrade
gracefully at the warn level, not what a full 8 GB machine with a browser
open does — that's #40. The footprints are what matters for 8 GB: Turbo and
Apple Speech cost ~0.1–0.25 GiB, small.en-q5_1 ~0.6 GiB, medium.en ~2 GiB.

## M1 8 GB (extrapolated, not measured)

Scaling from Apple's published figures, per engine by where its work runs
(measured: whisper.cpp uses 0.2–0.4 CPU cores, i.e. it's GPU-bound; Turbo ~3.4
cores around its ANE work; Apple Speech ~1.1 cores in its XPC service;
WhisperKit ~0.8 cores, ANE-bound):

| resource | M1 (8 GB MacBook Air) | M3 Max (this Mac) | M3 Max ÷ M1 | source |
|---|---|---|---|---|
| Neural Engine | 16-core, 11 TOPS | "up to 60 percent faster than in the M1 family" (≈ 18 TOPS, the figure Apple gave at the M3 launch) | **~1.6×** | [M1][m1], [M3][m3] |
| GPU | 8-core, 2.6 TFLOPS | 40-core, "up to 50% faster than M1 Max"; M1 Max "up to 4x faster than M1" | **~6×** | [M1][m1], [M3][m3], [M1 Pro/Max][m1max] |
| Memory bandwidth | ~68 GB/s (M1 Max's 400 GB/s is "nearly 6x that of M1") | 400 GB/s | **~6×** | [M1 Pro/Max][m1max], [MBP 16" 2023 specs][mbp23] |
| CPU (multi-thread) | 4P + 4E | 12P + 4E, "up to 80% faster than M1 Max"; M1 Max "up to 70% faster than M1" | **~3×** | [M3][m3], [M1 Pro/Max][m1max] |
| Battery (MacBook Air M1) | 49.9 Wh | — | — | [MacBook Air M1 specs][mba] |

Assumptions: latency and RTF scale by the factor of the unit the engine is
bound on (ranges where it mixes units); fixed overheads scale the same; the
same model fits (8 GB) and isn't swapped; energy per unit of work is the same
as on the M3 Max (±50%: M1 is an older process node with a smaller GPU).

| engine | factor | short p50 (M1, est.) | long RTF (M1, est.) | 1 h of audio processed in | RAM (same as measured) |
|---|---|---|---|---|---|
| parakeet | 2–3× (ANE 1.6×, CPU 3×) | ~110–165 ms | ~0.006–0.008 | ~20–30 s | ~0.1 GiB + ANE |
| apple-speech | 1.6–2× | ~190–240 ms | ~0.03–0.036 | ~1.8–2.2 min | ~0.2 GiB (XPC) |
| whisper small.en-q5_1 | 4.5–6× (GPU, bandwidth) | ~510–680 ms | ~0.06–0.08 | ~3.5–4.6 min | ~0.6 GiB |
| whisper medium.en | 4.5–6× | ~1.3–1.7 s | ~0.14–0.18 | ~8–11 min | ~2 GiB (too much for 8 GB) |
| whisper tiny.en | 4.5–6× | ~160–210 ms | ~0.02–0.03 | ~1.3–1.7 min | ~0.4 GiB |
| whisperkit small.en | 1.6–2× (ANE) | ~610–770 ms | ~0.07–0.09 | ~4–5 min | ~0.65 GiB + ANE |

The ranking holds on an M1: Turbo stays well under the "short dictation in
well under a second" goal and Apple Speech stays under ~0.25 s; whisper
small.en-q5_1 (the fallback) is ~0.5–0.7 s — acceptable for a fallback, and
the reason Turbo/Apple Speech are worth defaulting to on 8 GB Macs. The one
close call: on an M1, WhisperKit small.en may be as fast as whisper.cpp
small.en-q5_1 (its ANE path gains relative to the GPU) — still never faster
than Turbo or Apple Speech, so it doesn't change the defaults; #40 checks it.

### 60-minute meeting (extrapolated, not measured)

A meeting transcribes two channels (Me + Them), so ~2 audio-hours per hour.
From the measured energy per audio-hour (whole-Mac Δ) and the M1 factors above:

| engine | extra energy per meeting hour | of a 49.9 Wh MacBook Air battery | M1 busy time per meeting hour | heat (est.) |
|---|---|---|---|---|
| parakeet | ~0.2 Wh (0.1–0.3) | ~0.4% | ~40–60 s (1–2% duty) | negligible |
| apple-speech | ~0.6 Wh (0.3–0.9) | ~1.2% | ~3.6–4.4 min (6–7%) | negligible |
| whisper small.en-q5_1 | ~1.3 Wh (0.7–2.0) | ~2.7% | ~7–9 min (12–15%) | warm bursts; fine on a fanless Air |
| whisper medium.en | ~3.9 Wh (1.9–5.8) | ~8% | ~16–22 min (27–36%) | likely throttles a fanless Air; not an 8 GB default anyway |

Not included: the app's own capture/VAD/idle cost during a meeting, the display
and the rest of the Mac (a 60-minute call's own power dwarfs all of these).
Measured fact behind it: every run here, including ~150 s of sustained
transcription at up to ~82 W whole-Mac, stayed thermal `nominal`.

## Default engine per tier (Automatic)

`config.json`'s `engine: "auto"` — the default for new configs **and** for
configs without an `engine` key (explicit values such as `"parakeet"` are kept)
— runs the engine `EnginePolicy.automatic` picks. Dictation and meetings use
the same policy: meetings aren't built yet; the meeting session will call the
same pure function.

| Mac / language | Default | Model |
|---|---|---|
| Apple Silicon, language explicitly one of Turbo's (English + 24 EU), Turbo model downloaded | **Turbo** (Parakeet TDT 0.6B v3) | `parakeet-tdt-0.6b-v3` (Turbo's own pick) |
| Apple Silicon, no Turbo for it (other explicit language, or Turbo not downloaded / failed), macOS 26, Apple Speech takes the language and its model is installed | **Apple Speech** | OS-managed, per language |
| Auto-detect language | **whisper.cpp** | whisper's own Automatic |
| Intel | **whisper.cpp** (CPU) | whisper's own Automatic |
| Otherwise (nothing above installed; the picked engine's model fails to load) | **whisper.cpp** | whisper's own Automatic |

whisper's own Automatic (`ModelCatalog.recommended`) is unchanged: Apple Silicon
< 8 GB `base.en-q5_1`, 8–15 GB `small.en-q5_1`, 16–31 GB `medium.en-q5_0`, ≥ 32
GB `medium.en-q8_0`; Intel `tiny.en-q5_1` / `base.en-q5_1` / `small.en-q5_1`;
non-English → the multilingual twin.

- **First match wins.** With Turbo not downloaded (or failed) on macOS 26 and
  Apple Speech's model installed for the language, Automatic runs Apple Speech,
  not whisper: Apple Speech is the second choice and beats whisper.cpp on every
  axis measured.
- **Never downloads.** Only models already installed count. whisper.cpp's
  Automatic keeps its rule (the recommended model if present, else the largest
  downloaded one no bigger, else the smallest; it names the recommended one —
  `.missing` + download hint — only when nothing is downloaded).
- **Failure.** A picked model that fails to load (corrupt, tampered, Core ML
  error) is skipped for the session: the app logs it, shows the usual
  failed-load notice, and loads the next engine (`AppDelegate.engineStatusChanged`).
  A Settings change retries it.
- **WhisperKit is never a default** (still selectable).
- Settings' engine picker shows **Automatic (<engine>)** first, with why it
  isn't Turbo when it isn't: "Automatic (Whisper — Turbo isn't downloaded)",
  "… — Turbo doesn't support Japanese", "… — Turbo doesn't detect the
  language", "… — Turbo needs Apple Silicon", "… — Turbo failed to load".

API (`Sources/VoiceType/Transcription/Engines/EnginePolicy.swift`), for the
app now and the meeting session later:

```swift
EnginePolicy.automatic(language: String, environment: EngineEnvironment,
                       installed: Set<EngineKind>, failed: Set<EngineKind> = [],
                       engines: EngineRegistry = .shared) -> EnginePolicy.Pick   // kind + reason?
```

`ModelSelection.select(config, …, facts: EngineFacts)` wraps it for the app:
`facts` says which models are installed without blocking main (Apple Speech's
state comes from `SpeechModelPresence`, asked asynchronously at launch and on
settings changes; launch waits for that answer before loading, so it loads one
model) and which engines failed to load.

## Why

**Turbo first.** It leads or ties on every axis measured: the fastest short
dictation (55 ms p50: 2× Apple Speech and whisper small.en-q5_1, 5× medium.en),
the best short WER (1/127 words), long WER within 0.2 pp of the best, the
lowest RTF (an hour of audio in ~10 s here, ~20–30 s on an M1, est.), the
lowest energy per audio-hour (0.10 Wh, a third of Apple Speech's), and ~0.1 GiB
of RAM. It's also the least exposed to an M1's weak GPU. Gates: Apple Silicon
only, English + 24 EU languages only, and no language detection (v3 detects
only among its own languages, so another language's speaker would get confident
garbage) — hence "language explicitly one of Turbo's". Its 470 MB model is a
download the app never starts by itself; the first load compiles it for the
ANE (~15 s, once per model/OS update). Its CPU share while transcribing
(~3.4 cores, briefly) is the cost — fine for dictation-length jobs.

**Apple Speech second.** Accuracy at Turbo's level (the best long WER here,
2.17%), ~120 ms short latency, no model files (macOS downloads and updates
it, and often already has it), the model in its own process (~0.2 GiB), and
the second-lowest energy per audio-hour. It covers languages Turbo doesn't
(Japanese, Chinese, Korean, Cantonese), so it's their default, and it beats
whisper when Turbo isn't downloaded. Limits: macOS 26 only, ~11 languages, no
language detection, ~2× Turbo's latency.

**WhisperKit never default.** Here it's ~3× slower than whisper.cpp
small.en-q5_1 for short clips (383 vs 114 ms) and in RTF, its long-form WER
swings run to run (3.5% in #12, 7.35% now), its first load compiles for
17–66 s, and it adds no language coverage whisper.cpp lacks. Even if an M1's
ANE closes the gap to whisper.cpp (est.), it stays behind Turbo and Apple
Speech, which cover its use. Still selectable; #40 re-checks it.

**whisper.cpp: fallback, auto-detect, Intel.** The only engine that runs on
every Mac (Metal on Apple Silicon, CPU on Intel), takes every language and
detects the language, with the checksum-pinned RAM-tier catalog. Its 8 GB
default, small.en-q5_1, is a sound fallback: 114 ms here (~0.5–0.7 s on an M1,
est.), 3.1% / 2.74% WER, ~0.6 GiB. medium.en (the ≥ 16 GB tier, as q5_0/q8_0)
was no more accurate on these fixtures (3.19% long WER vs 2.74%) for ~2.5× the
latency, ~3× the energy and ~2 GiB — worth a look when the whisper tier table is
next revisited (not changed here: on ≥ 16 GB Apple Silicon Macs Automatic picks
Turbo or Apple Speech first anyway).

## Measured vs extrapolated

| | measured (M3 Max, this run) | extrapolated |
|---|---|---|
| load, short p50/p90, WER, long RTF, in-process RAM | ✓ all six engines | M1 8 GB latency/RTF (scaling above) |
| energy | whole-Mac Δ W and Wh per audio-hour (4 engines, ~150 s each), `top` energy impact (all) | 60-min meeting energy, battery % on a 49.9 Wh Air |
| heat | thermal state start → end per run (all nominal, incl. ~150 s sustained) | 60-min heat / throttling on a fanless Air |
| 8 GB | footprints; `memory_pressure -l warn` on a 48 GB Mac | a real 8 GB Mac under load, swap |
| `localspeechrecognition` RAM | — (from #14) | — |

Follow-up: **#40** — re-run on an M1 8 GB + the 60-minute battery/heat run.

## Commands

```sh
SHA="$(git describe --always --dirty)"; M="$HOME/Library/Application Support/VoiceType/models"
MAN=.bench/fixtures/manifest.tsv; OUT=plans/bench-results/15
bench() { .build/release/VoiceType --bench --git-sha "$SHA" --language en --manifest "$MAN" "$@"; }
# per engine (--engine/--model): parakeet "$M/parakeet/parakeet-tdt-0.6b-v3"; apple-speech en;
# whisper "$M/ggml-small.en-q5_1.bin" / ggml-medium.en.bin / ggml-tiny.en.bin; whisperkit "$M/whisperkit/small.en_217MB"
bench --engine parakeet --model "$M/parakeet/parakeet-tdt-0.6b-v3" --runs 3 --only short --json "$OUT/parakeet-short.json"
bench --engine parakeet --model "$M/parakeet/parakeet-tdt-0.6b-v3" --only long --json "$OUT/parakeet-long.json"
#   …while: top -l 0 -s 1 -stats pid,command,cpu,power  (VoiceType + localspeechrecognition rows)
# pressure: memory_pressure -l warn &  (wait for sysctl kern.memorystatus_vm_pressure_level == 2)
bench --engine parakeet --model "$M/parakeet/parakeet-tdt-0.6b-v3" --runs 3 --only short --json "$OUT/parakeet-pressure.json"
#   …then kill memory_pressure
# power: a manifest listing the long clip N times (symlinks long-1.wav…), --only long, while sampling
#   ioreg -rw0 -c AppleSmartBattery  → PowerTelemetryData AccumulatedSystemLoad / SystemLoadAccumulatorCount
#   each second for ~150 s idle then the run (power/<engine>.tsv; JSON without transcript text: power/<engine>.json)
```

[m1]: https://www.apple.com/newsroom/2020/11/apple-unleashes-m1/
[m3]: https://www.apple.com/newsroom/2023/10/apple-unveils-m3-m3-pro-and-m3-max-the-most-advanced-chips-for-a-personal-computer/
[m1max]: https://www.apple.com/newsroom/2021/10/introducing-m1-pro-and-m1-max-the-most-powerful-chips-apple-has-ever-built/
[mbp23]: https://support.apple.com/en-us/117737
[mba]: https://support.apple.com/en-us/111883
