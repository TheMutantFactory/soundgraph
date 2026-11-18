# Dynamic scores

A **score** plays multitrack MIDI through SoundGraph patches, and lets each play-through
differ from the last inside bounds the author sets. It is a playlist of songs; for each
song, every MIDI track gets a list of acceptable instruments, and those instruments'
controls get a range and a rate of change to drift within. On top of that a track can
drop out and come back on a pattern (the house/techno move), parameters can be ramped by
hand, and instruments can change mid-song.

The format is `schema/score.schema.json`; files end `.score.json`. The editor half lives in
`editor-godot/score/`. The demo is `examples/scores/demo.score.json`.

```sh
tools/score.sh                                   # the demo score
tools/score.sh path/to/my.score.json            # another
tools/score.sh examples/scores/demo.score.json entertainer   # ... playing one song
```

or **File > Open score…** in the editor.

## The file

```json
{
  "schema_version": 1,
  "name": "Demo score",
  "seed": 1987,
  "patch_root": "../patches",
  "songs": [{
    "id": "entertainer", "title": "The Entertainer", "midi": "../midi/entertainer.mid",
    "parts": [{ "name": "Intro", "from_bar": 1 }, { "name": "Drop", "from_bar": 9 }],
    "tracks": [{
      "track": 2, "name": "Left hand", "gain_db": -2,
      "instruments": [
        { "patch": "synths/acid-bass.json", "preset": "Stock", "weight": 2,
          "vary": { "cutoff": { "min": 200, "max": 1400, "rate_min": 0.1, "rate_max": 0.4 } } },
        { "patch": "synths/mallard.json", "weight": 1 }
      ],
      "change": { "min_bars": 8, "max_bars": 16 },
      "vary":   { "gain_db": { "min": -3, "max": 0, "rate_min": 0.1, "rate_max": 0.3 } },
      "ramps":  { "resonance": { "points": [[1, 0.2], [9, 0.9]], "curve": "smooth" } },
      "parts":  { "Drop": { "phrase": { "unit": "bar", "pattern": "AAAB AABB", "in": "ramp", "ramp": 1 } } }
    }]
  }]
}
```

Paths are relative to the score file. `track` is the MIDI track's chunk index in the file
(a format 1 file's first chunk is usually the conductor track, so its first voice is 1).
Bars count from 1 and may be fractional; a beat is a quarter note.

## How each field plays

**Instruments.** One is picked by `weight` when the song starts. With `change`, another is
picked (never the same one, when there is a choice) after a hold of `min_bars`..`max_bars`
drawn at random, at the track's first rest after that. A track that never rests has its
held notes let go one bar later, so the change still happens. A note-off always goes to
the instrument that took its note-on. Every candidate's engine is made when the song
loads, so a change costs nothing at the moment it happens.

**Vary.** Each varied control glides from a random start toward a random target inside
`[min, max]`, at a speed drawn from `[rate_min, rate_max]`, then picks another target and
another speed. Rates are fractions of `[min, max]` per bar, so the same numbers mean the
same at any tempo and on any control. A `rate_min` of 0 lets it rest; both rates absent
(or 0) means the value is drawn once when the instrument starts and held. `min`/`max` are
clamped to the control's own declared range, and an `exponential` control (a cutoff) is
walked in its own scaled space. An instrument's own `vary` uses its patch's control ids;
the track's `vary` applies to whichever instrument plays, and is where `gain_db` (the
track level, an offset in dB) goes. A patch without controls can still be varied by
`"node:parameter"`, with the vary's own min and max as the range.

**Ramps.** Authored automation: `[bar, value]` points, held before the first and after the
last, `linear`, `smooth` or `step` between them, and optionally starting over every
`repeat_bars`. A ramp wins over a vary on the same key. Keys are the same as vary's.

**Phrase.** The drop-out pattern: steps of a `beat`, `half` a bar or a `bar`, each `A` (on)
or `B` (off), repeating from `from_bar` (or the start of the part it belongs to). `in` and
`out` say whether the track cuts or ramps back in and out; `ramp` is how many steps a ramp
takes. A dropped track keeps playing underneath, like a fader pulled down, so it comes
back mid-phrase rather than restarting.

**Parts.** A track's `parts` object replaces any of its fields while that part plays:
another instrument list, a phrase only in the breakdown, a ramp only in the build.

**Seed.** Every random draw comes from the score's `seed`, the song's id and the track:
the same seed plays the same take on any machine, from any start. The window's dice draws
a new seed; ⟲ replays the current one.

## The window

The playlist is on the left; ⏮ ▶ ⏭ move through it, and a song that does not loop moves on
by itself when it ends. **Editing** picks what an edit changes: the whole song, or one of
its parts (an override, made on first touch from what the song has). Each track row has:

- mute and solo, the phrase's level now, the instrument playing now, gain and transpose
- the instrument chips: click one to show its bounds, ▶ to hear it now, × to remove it,
  the number beside it is its weight; + adds a patch from the patch root
- **Change instrument every** min to max bars
- **Phrase**: the unit, a cell per step (click to flip A and B), the step count, cut or
  ramp in and out, and the ramp length
- **Bounds and ramps**: every control of the selected instrument, with Vary, min, max and
  the two rates, a ramp typed as `bar:value` pairs (`1:200 9:3000 17:200`), and a bar
  showing the control's whole range, the allowed band and a dot where it is now

Edits are heard on the next update; nothing restarts. Save writes the file, rebasing its
paths when it is saved somewhere else.

## Where it sits

The score is above the graph: no node, no patch schema change, nothing in `dsp-core`. The
player (`score_player.gd`) has no UI, so a game can play a score the same way (FFFF's
music box is where this came from). The rules above are the specification; a second
runtime (the web editor, `sg-render`) should follow them rather than re-derive them.
