# Knobcon demo plan — the last three days

**Written:** 2026-09-08. **Show:** Thursday 2026-09-11. Three working days.

This is the plan for what gets shown and which examples carry it. It is deliberately
narrower than what the repository can do. The reliability rule in
docs/KNOBCon_2026.md decides every question below:

> Can this demo work thirty consecutive times in front of strangers?

## What the demo is

One sentence, said out loud at every station: **"The app isn't the synth. This graph is
the synth."** Every station is the same graph running somewhere else.

Five stations, in the order a visitor would naturally walk them. Station 1 is the demo;
stations 2 to 5 are the proof that it generalises. If time runs short, cut from the
bottom.

### Station 1 — The graph is the synth (the 90-second core)

The docs/KNOBCon_2026.md script, unchanged: play `first-synth.json` in the browser,
turn the cutoff, plug the LFO into the filter, hear it, save, then deploy to the
ESP32-S3 and hear the board play the same graph.

- **Examples:** `first-synth.json` for the lite page and for the deploy.
- **Path:** `tools/serve.py` → `/editor-web/` lite page → "Open in the full editor" →
  Web Serial deploy → board.
- **Blocker, must close today:** the Web Serial deploy button has never been clicked by
  a human (docs/known-issues.md, first entry). Everything around it is verified; the
  port chooser is gesture-gated so only a person can prove it. This is steps 7 to 9 of
  the script and it is the one thing on the critical path nobody has done.
- **Fallback if it fails and cannot be fixed by Tuesday evening:** deploy from the CLI
  with `sg-serial.py` while saying the same sentence. The plan document already allows
  it: "CLI deployment is acceptable before browser deployment."

### Station 2 — Patches are game sounds (the sfxr sandbox)

The platformer tab in the Godot editor. Coin, jump, hurt, explode, powerup, select,
shoot: eight patches under `examples/patches/game/`, each a graph, each derived from an
sfxr corpus case by `tools/game-sounds.mjs`. The ten-second exhibit: open the Graph
tab, change the jump patch, come back, jump. No reimport.

- **Examples:** `examples/patches/game/*.json` (all eight), and the **sfxr shelf**:
  `examples/patches/sfxr/`, one patch per sfxr button with its six rolls as presets.
  Open "sfxr: Pickup Coin", step the preset strip, and it is sfxr's button pressed six
  times — then turn Punch or Arpeggio Jump and it is a coin sfxr never rolled.
- **Talking point:** these are sfxr's sounds (Tomas Pettersson, 2007, MIT), reproduced
  by the graph within the tolerances `tests/sfxr/` measures, not sampled. A laptop tab
  with the original open (see "sfxr" below) lets a visitor compare.
- **Nothing to build.** Run it thirty times; the risk is the audio race the sandbox code
  already guards (`main.gd`, "eight more players and engines with the same race").

### Station 3 — Real music in (MIDI import and transcription)

New this week: Import MIDI takes the whole file. Until today it silently kept sixteen
bars and dropped four fifths of The Entertainer. Now all seven vendored tunes arrive
whole, pickups in place, and the editor suite pins every count against an independent
parser.

- **Examples:** `examples/midi/entertainer.mid` (2621 notes, 76 bars, the long one) and
  `examples/midi/greensleeves.mid` (four-voice chords, the polyphony case). Play them
  through `plucked-string.json` and one of `examples/patches/synths/` at 4 voices.
- **Know before saying it:** the roll draws bar lines every sixteen steps and the schema
  has no beats-per-bar, so 3/4 and 6/8 tunes play right but look shifted against the
  grid. Say "the timing is exact; the bar lines are the roll's" if asked. Do not add
  time signatures to the schema this week.
- **Transcription** (`sg-transcribe`, with the new `--quantize`) is a second act only if
  a two-minute run has been rehearsed with a known recording and it lands on-grid.
  Otherwise show the MIDI it already produced.

### Station 4 — It talks (Speech node, and the board that listens)

`typing.json`, `babble.json`, `yes-dear.json`, `r2d2.json` — the TMS5220 node through
the same graph model, and the roll typing text.

- **Board voice control** is a maybe. It hears "turn it down" reliably at volume 30
  and not at all at 60 (docs/current-phase.md, echo cancellation section). On a show
  floor that is the wrong half. Show it only at low volume with a headset-style
  distance, or not at all. Decide Tuesday after one run on the floor-like noise of a
  fan.

### Station 5 — Same graph, five machines (the physical proof)

A printed table of the golden verdicts: Windows, browser WASM, Godot, ESP32-S3, Axoloti
— one manifest, every target within its declared tolerance. Beside it, the Axoloti with
an SD card baked by `tools/bake-bank.py`: power it on and it plays `first-synth` cold.

- **Examples:** the golden manifest cases; the SD bank with `first-synth`,
  `plucked-string`, `warehouse`.
- **Nothing to build.** Bake the card Tuesday, cold-boot it ten times.

## The examples shortlist

280 examples load-verified is a claim; a stranger clicks one. These are the ones the
frontends should offer first, in this order, each with its human-readable name and blurb
checked on Tuesday:

| # | file | why it is first-click |
|---|---|---|
| 1 | `synths/poly-five.json` | what the editor opens on: five voices, a bank of pages, chords under the keys |
| 1b | `first-synth.json` | the lite page's opener and the deploy patch; the same graph on every target |
| 3 | `plucked-string.json` | sounds like an instrument in one keypress |
| 4 | `game/coin.json`, `game/jump.json` | recognisable in a quarter second |
| 5 | `drums909/` | a beat from the roll, loud enough for a hall |
| 6 | one `dx7/` and one `fm/` favourite | the "we imported real presets" line |
| 7 | `warehouse.json` | the 85-node, 4-voice one that runs on the Axoloti |
| 8 | `typing.json` | it talks |

Everything else stays reachable through search, not the front row.

## Schedule

**Monday 2026-09-08 (today)**
- Land `transcribe-timing` and `midi-import-audit` on `main`, each with its tag, both
  through the gate. (Both are green as of this writing.)
- A human clicks Web Serial deploy against the S3. Record the result in known-issues.
- Pick the two MIDI tunes and the two FM presets by ear.

**Tuesday 2026-09-09**
- On the show laptop, restart the editor with `tools\run-demo.bat`: no rebuild, and it
  starts in 1:1 detail, at the 4K interface size, with the work area held at 200% after
  every load — twice the words on the nodes and the panels — whatever the last hand
  left behind. Fit (Ctrl+0) still frames a whole patch when one is needed.
- View → QR code → Medium, so the wordmark's QR scans from across the table. Keyboard →
  Play is the jukebox: Keys, Arpeggiate held keys, or Play the songs folder.
- Full dry run of all five stations, in order, on the laptop that goes to the show.
  Time each. Write the per-station checklist on one page.
- Reliability: thirty consecutive runs of station 1 end to end. Log every miss.
- Prebuild and stash: the S3 firmware binary, the wasm bundle, the Godot export, the
  Axoloti SD card. The only network the build needs is `esp_codec_dev` at build time;
  a prebuilt binary removes it.
- Offline path: `tools/serve.py` from a local checkout, no internet assumed.
- Check names and blurbs on the shortlist.

**Wednesday 2026-09-10**
- Freeze. No commits after noon except a fix for a station that failed the dry run.
- Print: the golden verdicts table, the QR to the lite page, the one-page checklist.
- Pack: two boards, spare cables, powered USB hub, the SD card and a spare, headphones
  for station 4, the laptop and a charger.
- One last cold run of every station from a fresh boot.

**Thursday 2026-09-11** — show.

## Decisions this plan leaves to you

1. **Which laptop and OS goes.** The gate is green on Windows; the Godot editor and
   wasm are also proven on macOS arm64. Only Chrome has run the browser build. Pick
   one and rehearse on it; do not switch on the day.
2. **Does the Axoloti station go.** It is the strongest physical proof and costs
   nothing to build, but it is a fifth thing to carry and explain.
3. **Does voice control go.** See station 4. My recommendation is no unless the
   Tuesday run at volume 45 is 2 of 2.
4. **The transcription second act.** Rehearse once; keep it only if it lands.

## sfxr, for the record

The sound-effects lineage the game sounds come from is **sfxr**, by Tomas "DrPetter"
Pettersson, 2007, MIT. Its synthesis model is vendored under
`tests/sfxr/reference/` with the arithmetic untouched, and 41 corpus cases render from
it. To play with the original: the Windows binary is at
`https://www.drpetter.se/project_sfxr.html`; the browser port jsfxr at
`https://sfxr.me` has the same seven generator buttons and the same parameter names
(`p_base_freq`, `p_env_decay`, …) that `tests/sfxr/cases/*.json` use, so a case's
parameters can be typed across for a side-by-side.
