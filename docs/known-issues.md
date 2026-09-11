# Known Issues

Open problems, ordered by how much they threaten the Knobcon demo.

## Open

- **Two sfxr shelf patches ship overlapping.** `examples/patches/sfxr/explosion.json`
  opens with `vibrato` over `repeat_on` by 176x208 and `powerup.json` with `vibrato`
  over `repeat` by 376x176 (measured by editor_test's clear-layout check at 100%,
  2026-09-11). The layout is `sfxr-ref shelf`'s, in tools/sfxr-ref/to_shelf.cpp; Tidy
  clears it in the editor, and the other five shelf patches open clean.
- **Import MIDI quantises to sixteenths whatever the file holds.** Ornaments finer than
  a sixteenth land on one step. The `division` field could carry a finer grid when the
  file asks for it; nothing does yet.
- **The Web Serial deploy button has never been clicked.** The web editor can push a patch
  straight into the board's NVS, and everything around it is verified, but the serial port
  chooser is gesture-gated by design so a human has to try it. This is step 7–9 of the
  90-second demo, so it should be the next thing anyone tests.
- **The web editor has now been used, on macOS Chromium.** A full session against the
  Mac-built wasm: audio starts clean, the meter follows the envelope and LFO, patch
  switching regenerates the controls, validator messages arrive specific and actionable,
  and a rejected Apply leaves the last good graph running. Two paper cuts found and
  fixed: a freshly loaded patch kept the previous patch's scroll position, and the piano
  keys were divs — invisible to assistive tech. They are buttons with note names now.
  Still true: no human has *heard* it (the session was driven, not listened to), and no
  WebKit browser has run it.
- **Only Chrome has run the browser build.** Safari is the one to worry about — its
  AudioWorklet implementation has historically been the fussiest, and it matters for the
  "open a URL on a phone" story.
- **Linux has never been compiled.** CMake and miniaudio cover it; nothing has exercised
  it. macOS arm64 now has: the tree builds warning-free, `sg-play` opens CoreAudio through
  miniaudio, the CLI tools work, and the Godot editor loads the extension and passes all
  280 of its checks. Four defects found doing it are fixed; see docs/decisions.md for
  the one that needed a decision.
- **No `getUserMedia` in the browser.** `AudioInput` nodes schedule correctly but receive
  silence, so a patch built on one validates and runs in the browser without doing
  anything audible.
- **The Waveshare board's microphone array is not driven.** The ES7210 is recorded in the
  board profile; the firmware only opens the ES8311 output path.
- **`set_audio_input` assumes the host's frame count lines up with block boundaries.** If a
  host delivers input in a size that is not a multiple of 64, the tail of a period is read
  as silence. Generated audio is unaffected — an output FIFO handles that. Fixing it
  properly needs an input FIFO too.
- **Filter cutoff modulation is sampled once per block.** At 64 frames that is a 750 Hz
  update rate, smooth for any LFO but ruling out audio-rate filter FM. Deliberate: it
  keeps `tan()` out of the inner loop, which is what would hurt on ESP32.
- **A Godot project must be imported before its extension registers.** `--headless --quit`
  does not scan the filesystem, so `SoundGraphEngine` appears missing and the editor shows
  its "build the extension first" message even when the DLL is present. Run
  `godot --headless --path editor-godot --import` once. Noted because the symptom points
  at the wrong cause.

## Accepted limitations

- **Control-rate signals are computed per sample, not per block.** Correct but wasteful.
  Revisit only if ESP32-S3 profiling says so.
- **Polyphony replicates the whole note-driven cone.** `NoteInput` carries a `voices`
  parameter (1–16, default 1; engine cap `kMaxVoices`); the graph copies everything
  downstream of the input once per voice, sums the copies at the host sinks, and an
  allocator routes each note (steal longest-held, retrigger on repeat). At 1 voice the
  build is byte-identical to the old mono path — that identity is what keeps every
  golden stable. Two consequences to know: audio from *outside* the cone that joins the
  note path before the sink fans into every voice copy and is heard once per voice
  (route such mixes into a summing jack after the voices instead), and changing
  `voices` takes effect on rebuild, not live — the editor knows this: committing a
  voices knob gesture rebuilds the engine, and undo takes the rebuild path back.
- **No parameter smoothing on `set_parameter`.** Immediate sets can zipper on large jumps.
  `Gain` and filter cutoff are the ones likely to need it first.
- **No denormal protection.** Not observable on x64 with SSE flush-to-zero defaults, but
  the `Delay` feedback path is where it would bite on another target.
- **`esp_codec_dev` is fetched by the component manager at build time.** The one place the
  repository needs the network to build. Vendor it before demo prep if offline builds
  become critical.
- **Cable routing gives up gracefully in a dense patch.** When no clear route exists it
  picks the least-blocked one rather than searching exhaustively, because routing runs per
  cable per frame.
- **The socket grammar advertises four shapes for two realities.** Goal 3.0 enumerated all
  182 ports on all 51 runtime types: 78 audio, 104 control, and none at all declaring event
  or note. `SignalType::Event` and `SignalType::Note` are real in dsp-core — they are
  message types that do not interconvert with streams, and `signal_types_compatible`
  enforces it — and in `dsp-core/src` they appear only in the functions that turn them into
  strings and back. So the square and ring sockets, and the trigger colour, are unreachable.

  Not a bug in any one port: it is a policy applied without exception, and gates as float
  streams is what lets an LFO be a clock. Recorded as a taxonomy question for whenever the
  signal model is next opened, and as the reason the cables have two classes and not three.

- **A cable's signal type is hue-only between its endpoints.** Found by 15B's grayscale
  render of the dense QA graph: socket shape carries audio against control at both ends and
  survives a monochrome display, and the cable between them does not. Bounded — a reader
  can always recover a cable's type by looking at either end — but tracing one wire through
  a crossing region without looking at its ends needs colour.

  **Closed by the cable pass's goal 3**: a sparse transverse rib every 160 screen pixels on
  control cables, audio left unmarked. See docs/cables.md.

## Resolved

- White noise ranged `[-1, 3)` — wrong PRNG divisor, caught by inspecting golden vectors
  rather than trusting them.
- A truncated upload wedged the device console forever; `getchar()` under the
  interrupt-driven USB driver blocks with no timeout.
- Mouse controls stole keyboard focus, so the next note played after touching a slider was
  silently eaten.
- Godot saved patches through `JSON.stringify`, which sorted keys alphabetically and
  floated every number; saving now goes through the core's serialiser.
- Auto-place appeared non-deterministic; the algorithm was fine, the button silently
  switched to selection-only mode.

## 2026-08-27 — RESOLVED: the 3.49 panel needs a true cold boot, not a reset

The panel showed a lit white rectangle whatever was sent to it, with Waveshare's own
firmware as well as ours, and the vendor firmware logged 211 I2C NACKs in eight seconds
from the touch controller. Display and touch are the same silicon behind one flex
connector, so I concluded the ribbon had been disturbed when the case was opened and
recommended reseating it.

That was wrong, and wrong in an instructive way. Pulling the 18650 and reconnecting
brought the panel straight back — the vendor demo, then ours. The board has a battery, so
a USB reset, an RTS pulse, and the RST button are all *warm* resets that never drop the
panel's rails. Whatever state the AXS15231B had latched into survived every reset
available over the cable, which is why hours of driver work looked like it changed
nothing: the evidence was real, the inference from it was not. Two functions of one chip
failing together does imply one shared cause; it does not imply the cause is mechanical.

So: on this board, "have you power cycled it" and "have you reset it" are different
questions, and only the first requires the battery to come out. Anything that presents as
the panel being electrically absent should try that before anything is taken apart.

### The original entry, kept because the reasoning is worth seeing fail

The ESP32-S3-Touch-LCD-3.49 shows a uniform lit white rectangle whatever is sent to it.
Waveshare's own `10_LVGL_V9_Test`, built from their repository and flashed to the same
board, does exactly the same — so this is not our driver.

The evidence that it is physical rather than electrical-configuration: that same vendor
firmware logs 211 I2C NACKs in eight seconds. The AXS15231B is one part doing both jobs —
it drives the panel over QSPI and answers touch over I2C at 0x3b. QSPI is write-only, so
"send init commands success" means only that the ESP32 clocked bytes out of a pin, and it
would report that into a disconnected cable just as cheerfully. The NACK is a read, and a
read that is not answered means the part is not there.

Display and touch are the same silicon behind the same flex connector, and the case was
opened the same evening to look for a camera. First thing to try is reseating the display
FPC. Note also that this panel was never observed working: the factory firmware was
running when the board arrived, but nobody photographed its screen before the case came
apart, so "it worked before" is an assumption rather than an observation.

What is already known-good on this board and should not be re-derived: audio (ES8311 out,
ES7210 in, amp on the TCA9554 at 0x20 pin 7), and the whole display path down to the last
accepted byte — see the driver work on dd/ESP32-s3-touch-lcd-3.49.

## 2026-09-10 — legalize_test and geometry_contract_test are out of the gate, temporarily

`tools/pre-push.sh` no longer runs `legalize_test` or `geometry_contract_test`.
On 2026-09-10 they took 974 and 772 seconds, half an hour between them
and more than every other stage together, because each re-runs the layout
solvers (Resolve overlaps, Tidy flow) on babble and the dense fixture. The
weekend had no time for a half-hour push. The suites themselves are
unchanged and still run by hand:

    cd editor-godot && godot --headless --path . --script legalize_test.gd
    cd editor-godot && godot --headless --path . --script geometry_contract_test.gd

Run them before anything touches `legalize.gd`, Tidy flow, the layout
objective, the structural geometry, or the fixtures they measure
(dense-graph, dense-graph-legalized, first-synth, plucked-string, babble,
geometry-disagreement). Put them back in the gate's `suites` list when a
half-hour push is affordable again, or when they are faster: trimming
geometry_contract_test to its three small fixtures would keep the contract
on every push for a fraction of the time.

Also noted while reading legalize_test: its header says babble and
dense-graph-legalized are legal and must move nothing, but the checks now
accept repairs on both (babble 14 faults, 10 nodes moved; dense-graph-
legalized 23 faults, 16 moved). The fixtures have drifted from the header,
and the defining leave-it-alone case is no longer what is measured.
