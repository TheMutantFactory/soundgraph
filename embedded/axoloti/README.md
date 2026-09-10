# axoloti

Hardware-in-the-loop tests for the Axoloti Core (STM32F427, stock firmware
1.0.12-2). First station of the "Axoloti/Ksoloti experiments" roadmap item:
prove we can program the board over USB, then find its realtime limits.

No Java patcher anywhere: the host speaks the board's vendor bulk USB protocol
directly (`driver/axoproto.py`), and test patches are hand-written C++ against
a self-declared ABI (`patches/axo_abi.h`), linked against the stock firmware's
symbols. Protocol and ABI reference: `firmware/pconnection.c` and
`firmware/patch.h` at tag `1.0.12-2` of https://github.com/axoloti/axoloti.

## Wiring and rig shopping list

USB to the board's device port. Audio out -> audio in with a patch cable
(mono is fine — the tests use the left channel and report what the right one
carries). The loopback lets the on-board analyzer verify real audio without
any host audio interface.

The full rig, in order of usefulness per dollar:

- **Nothing** — the USB device port already carries the test protocol *and*
  class-compliant USB MIDI, so `test_midi.py`'s USB tier runs today.
- **6.35 mm TRS male-male patch cable** — upgrades the mono loop to stereo,
  so the right channel gets the same analyzer treatment as the left.
- **5-pin DIN MIDI cable, male-male** — MIDI OUT looped to MIDI IN. The DIN
  tests self-detect it and light up: burst integrity, wire-speed throughput,
  behavior under DSP load.
- **3.5 mm TRS male → 6.35 mm TRS male cable** — headphone out looped into
  line in, to exercise the codec's headphone driver path. Swap with the main
  loop between runs; the analyzer's level/channel signature says what's
  connected.
- **microSD card, 32 GB or smaller, any name brand** — must be FAT32 (the
  1.0.12 FatFs has no exFAT, so SDXC needs reformatting). Speed class is
  irrelevant here: host-side writes are USB-bound at ~62 KB/s and the F427's
  SDIO tops out far below modern card ratings — a plain Class 10/UHS-I is
  already overkill. Two cards beat one big one (A/B swaps, one sacrificial).
- **USB MIDI device for the host (A) port** — anything class-compliant:
  Korg nanoKEY2 / Akai LPK25 (USB mini-B), Arturia MiniLab 3 or Novation
  Launchpad Mini MK3 (USB-C). For *automated* testing the best device is a
  Raspberry Pi Pico (~$5) or a spare ESP32-S3 devkit running as a TinyUSB
  MIDI gadget — programmable to send deterministic bursts and echo, which
  turns the skipped USB-host test into a real closed loop.

## Setup

```sh
brew install libusb arm-none-eabi-gcc arm-none-eabi-binutils
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
tools/fetch-sdk.sh          # official 1.0.12-2 release, pinned sha256 -> sdk/
make -C patches             # -> patches/build/*.bin
```

`sdk/` holds GPL-3.0 upstream artifacts (firmware elf/bin, linker script) and
is fetched, not committed.

### Windows

The same, with three substitutions. The board's bulk interface is already
bound to WinUSB by the Axoloti installer, so no Zadig step:

```sh
python -m venv .venv && .venv/Scripts/pip install -r requirements.txt libusb-package
tools/fetch-sdk.sh          # opens the pinned dmg with 7-Zip instead of hdiutil
winget install Arm.GnuArmEmbeddedToolchain   # arm-none-eabi-g++; codegen finds it
```

## What the board heard

Every sgaxo patch keeps a tally of the MIDI it is handed, in its shared block:
a count, a CC count, and the last eight messages. `tools/hw.py scan` reads it
back (the editor's hardware panel shows it in the board's sentence), and
`tools/hw.py midi --seconds 10` prints new messages as they arrive - turn a
knob, hit a pad, and see the number it sends and the channel it sends on.
A controller plugged into the board's host port never reaches the computer,
so this is the only place to read it; a controller plugged into the computer
shows in the editor's right-hand panel under "MIDI in".

## From the editor

Scan and Flash sit beside Add node in the Godot editor. Scan runs
`tools/hw.py scan`; Flash runs `tools/hw.py flash BANK.json`, which bakes
the bank (below) with `bake-bank.py` and writes it to the mounted card.
Both report through `run/axoloti-status.json`, which the editor's hardware
panel follows. A bank is `schema/bank.schema.json`: a name and an ordered
list of `{"name", "patch"}` entries, patch paths relative to the bank file.

## Run

```sh
.venv/bin/pytest tests -v -s
```

Everything skips cleanly when no board is on USB, so this suite is safe to
point CI at; it is deliberately not wired into the repo's default ctest run.

Tiers, in dependency order:

| file | proves | needs |
|------|--------|-------|
| `tests/test_link.py` | enumeration, ping/ack, firmware identity | board |
| `tests/test_programming.py` | memory write/read-back = the patch upload path, throughput floors | board |
| `tests/test_patch_run.py` | compiled patches execute: heartbeat at 3000 cycles/s, clean restart | board + built patches |
| `tests/test_limits.py` | analog loopback integrity, DSP load ramp -> max clean oscillator count (`tests/reports/dsp_limits.json`) | board + loopback cable |

## sgaxo: soundgraph patches, compiled for the board

`sgaxo/codegen.py` compiles a soundgraph patch (JSON) into an Axoloti patch
binary — and its front-end is patch-io itself, via `sg-validate --resolve`:
any schema version loads, modules expand, Input/Output seams become
terminals, validation runs natively, and the engine's own schedule (execution
order + feedback edges) comes along, so scheduling stays defined in exactly
one place. sgaxo then generates C++ over the kernel library
(`sgaxo/kernels.h`, line-for-line restatements of dsp-core inner loops) —
including summing-input premixes and block-end feedback snapshots exactly as
graph.cpp performs them — compiles with arm-none-eabi-g++ against the stock
firmware, and uploads over the driver. Editor patches compile: modules,
feedback loops through Delay, and AudioInput (the effects-box configuration —
`build_patch(..., zero_input=False)` wires the codec's real input). The board renders the shared golden vectors and the
host reads the raw float32 samples back over USB:

- six of seven golden cases **bit-exact** (max abs error 0): sine, noise,
  noise-pink, square, delay-feedback (through the SDRAM delay line), and
  ahd-envelope
- `first-synth` (note events, saw, LFO-modulated SVF, ADSR, limiter):
  **max abs error 2e-6** — 50x inside the 1e-4 cross-target tolerance; the
  residual is the SVF's on-board polynomial tan/exp2

Fidelity comes from three rules: the graph runs at dsp-core's 64-frame block
size behind a FIFO (per-block semantics are part of the golden recordings);
every parameter-derived coefficient (ADSR exp curves, glide) is precomputed
on the host in double precision and baked as a literal; and only per-block
modulation math (SVF tan/exp2) runs on the board, as short polynomials.
`-ffp-contract=off` keeps rounding identical to native.

Compiled patches are playable instruments: live MIDI (any transport) drives
the same note handler the golden events replay through.

Supported today: Input(note)/Output seams, Sine/Saw/Square/Noise
oscillators — with their fm, pm and (the sine's) feedback inputs, the sine's
four shapes — Noise (white and pink), LFO (all shapes), StateVariableFilter,
OnePoleFilter, Delay/Comb/Allpass (SDRAM-backed lines, 4 MB budget), Phaser,
Drive, Crush, Slide, Arpeggio, ADSR, AhdEnvelope, Retrigger, Gain, Constant,
Add, Multiply, Mixer, MidiCC (the board's CC and pitch-bend table, read once
a block), NoteTriggers and TriggerBus (pads) — twenty-seven node types,
every one hardware-verified:
eleven manifest goldens bit-exact, slide 9e-6, first-synth 2e-6, and three
fixtures against the native render at or under 1e-5. Editor patches at any
schema version compile through the patch-io resolver, including Sampler
patches: buffers ship to a 3.5 MB SDRAM pool over USB before start
(verified by readback), and the read head runs in libgcc soft-double —
IEEE-exact against native, ~10-15% CPU per sampler, hit-verified bit-exact
on hardware. The Speech node speaks too: the TMS5220 phrase bank
rides the same SDRAM pool, and the demo verifies at 2.4e-7 over a second of
voice. Polyphony works: the resolver emits the voiced graph
through graph.cpp's own replicate_voices, and the generated runtime carries
the engine's exact voice allocator (same-note retrigger, oldest-released,
steal-with-release). Verified: a 3-voice pad with overlapping notes at 5e-4,
and the 85-node 4-voice warehouse patch — far past realtime, rendered slower
than the audio it describes and still faithful at 2.5e-5. The one refusal
left is hosted plugins, which is physics, not a gap. Kernels
without golden-manifest cases are verified against a native sg-render of the
same patch (golden-on-demand, tests/fixtures/). Everything else is
refused by name
at compile time — the subset is a tested claim, not a vibe.

```sh
python3 sgaxo/codegen.py path/to/patch.json   # -> sgaxo/build/patch.bin
```

Toolchain output is captured: a failure comes back as the compiler's own
words, and warnings are counted and kept quiet unless `SGAXO_VERBOSE=1`.

Baked patches run at 16-frame blocks; captures for the golden tests at 64.
The codec calls the patch every 16 frames, and a 64-frame block rendered
inside one of those calls has a peak load four times its mean: Poly Five at
a 74% mean overran every call and sounded chunky. At 16 the peak is the
mean; per-block modulation (an SVF's sweep) then updates four times as
often, finer than the desktop rather than coarser. Every patch keeps a cycle
counter on its render (`block_cycles_*` in the shared block): `hw.py scan`
reports the mean as a share of the codec call, the editor's hardware panel
says "load n% of a codec call", and over 100 is the chunkiness of an
overrun. Measured per node at 16-frame blocks: a saw about 1%, a square
1.4%, an SVF 0.6% (2.5% with its cutoff moving), an ADSR 1.2%, an
oscillator with a *moving* fm input 5.5% - so Poly Five's five voices are
about 51%, and each drum of the kit about 6%.

Patches compile at -O2. The board's code window is 44 KB, and at -O3 the
inliner's choices made a smaller graph *larger* (Poly Five with four drums
overflowed by 4 KB while the same patch with eight fit); -O2 is a fifth
smaller for about six percent more DSP load (Poly Five with the whole kit:
58.6% at -O3, 62.5% at -O2, five notes and a pad held). `SGAXO_OPT=-O3`
overrides it for a measurement.

Block buffers are pooled by lifetime: an output's block is free once its last
consumer has run, so a patch's close memory scales with how many signals are
alive at once rather than how many nodes it has (eight game sounds on one
card: 73 outputs in 21 blocks). A source of a feedback binding lives to the
block end, and no block is handed to a node that still reads it.

## A controller on the board: the MPK mini set

`tools/make-mpk-examples.py` (repository root) writes
`examples/banks/axoloti-akai-mpk-mini/` and its bank: Poly Five with the
kit on the pads, eight game sounds on the pads, the kit alone, and one
patch per DX7 and FM preset with a filter, an echo and four drums — 199
entries, knobs K1–K8 on MidiCC nodes (CC 1–8, what this MPK sends; a mk3
factory program says 70–77), pads on a NoteTriggers row at note 36, and
the joystick: its CC axis bends the pitch up two semitones, its bend axis
is the volume, left quieter and right louder. Poly Five carries no echo
(the engine copies everything after the keyboard once per voice, and an
echo there is five delay lines) and two drums, kick and snare: the five
voices are 51% of a codec call and each drum about 6%. The game pads carry
six sounds; eight were 96%. The bank asks for
`"program_change": "prev-next"`: on the board program 0 is the previous
entry, 1 the next, 2 the first, and every other number the entry it names,
so the MPK's PROG CHANGE pads walk a bank of two hundred. A mk2 or a
re-programmed mini sends other numbers: change `CONTROLLER` in the script
and run it again.

## Shipping standalone: the SD bank

`tools/bake-bank.py OUT_DIR patch1.json patch2.json ...` turns editor patches
into a card a customer can use with no computer:

- `/start.bin` — entry 0, booted at power-on
- `/index.axb` + `/<name>/patch.bin` — the bank; MIDI Program Change on any
  transport switches entries through the firmware's own loader (program 0 =
  first entry, bad loads fall back to start.bin)
- `/<name>/b<N>.raw` — sample and phrase buffers as raw float32; baked
  patches load them into SDRAM at init through FatFs, chunked and
  watchdog-fed, so Sampler and Speech patches ship standalone too

Fastest path is baking to a directory and copying with a card reader;
`--board` writes over USB (~60 KB/s) and size-verifies every file. Baked
patches keep live MIDI, real audio input (`zero_input=False`), and the whole
verified vocabulary.

Verified on hardware, card in slot: the Program Change walk loads every
entry (ids checked), out-of-range falls back to /start.bin with the
firmware's own log line, the Sampler's SDRAM buffer reads back byte-identical
to its card sidecar after an SD load — and a cold power-cycle boots the board
into entry 0 autonomously, no computer involved.

## How the pieces talk

- Host -> board: `AxoW` (memory write) uploads, `Axos`/`AxoS` start/stop,
  `Axor`/`Axoy` read memory, `Axop` ping. Acks (`AxoA`) carry `dspLoadPct`
  and the running patch id.
- Patch -> host: a fixed shared-memory block at `0x2001C000`
  (`patches/sg_shm.h` = `tests/shm.py`) with a heartbeat, an input analyzer
  (peak/mean-square/zero-crossings per 100 ms window) and controls the host
  pokes by memory write (tone on/off, load-bank size).
- The load bank in `patches/looplab.cpp` burns DSP cycles in 0..1024
  oscillator steps without touching the audio path, so overload shows up
  as missed cycles and loopback dropouts — which is the point.

## Known limits (device-reported, see tests/reports/)

Patch code+rodata window is 44 KB (`ramlink.ld`), upload runs ~60 KB/s
(the firmware parses uploads byte-by-byte), readback ~700 KB/s.

Realtime ceilings measured on a stock Core (clean = all three overload
signals green, loopback verified):

| workload | clean limit | ~load/unit |
|----------|-------------|------------|
| raw q32 phase-acc oscillators (`looplab`) | 176 | 0.52% |
| soundgraph Sine nodes, faithful float port (`nodelab`) | 48 | 1.9% |
| Sine→SVF→Gain voices (`nodelab`) | 28 (84 nodes) | 3.3% |

The Sine node costs ~3.7x a raw oscillator: float table-lerp is cheap on the
M4F, but the per-sample nullptr checks, nyquist clamp and the
`frequency / sample_rate` divide (14-cycle FPU op, per sample) add up. A full
voice is ~1.7 Sine-equivalents — the SVF's five-multiply core plus Gain are
cheaper than the oscillator that feeds them.

The stress tier (`tests/test_stress.py`, `patches/stresslab.cpp`) characterizes
the engine rather than just finding its ceiling. Measured on this rig:

- noise floor −66 dBFS RMS; loopback gain −7.6 dB
- amplitude linearity exact (6.0 dB steps) from −36 to −1 dBFS
- frequency response flat within ±0.1 dB, 50 Hz – 20 kHz
- SINAD ~47 dB at −6 dBFS, unchanged from idle to 85% DSP load
  (measurement is loopback path + float32 estimator; ceiling 60 dB)
- zero clicks/dropouts across 5 s at 84% load, 44 idle↔84% load flips,
  USB hammering (129 KB/s readback while at 84%), and a 60 s
  everything-at-once soak (63% load + SDRAM traffic)
- SDRAM: 24.6 MB/s write+verify traffic clean at 68% load; pushing 49 MB/s
  overloads the CPU (audible dropouts) but never corrupts a word
- 20 upload/start/stop churn cycles without degradation

`tools/soak.py --minutes 30` runs the everything-at-once soak for as long as
you like, with per-10 s defect reporting.

One trap for posterity: a marginally seated USB cable brownout-crashes the
board under load and looks exactly like a patch bug (crashes within seconds
whenever the DSP load rises, stable at idle). It cost an afternoon and an
instruction-level binary diff to prove the code innocent. Every ramp
measurement now records the 5 V rail (`v50_raw`, ~3100 healthy); the readings
are noisy, so judge by crashes, not by single samples.
