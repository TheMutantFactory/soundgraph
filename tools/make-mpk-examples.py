"""The Akai MPK mini set for the Axoloti: patches whose knobs and pads are mapped.

    python tools/make-mpk-examples.py            # writes examples/banks/axoloti-akai-mpk-mini/
                                                 # and examples/banks/axoloti-akai-mpk-mini.json

Every patch here is an existing example with a controller wired in. The knobs are two
rows of four, and every entry reads them the same way:

    top row      K1 pitch bend   K2 cutoff   K3 resonance   K4 an effect
    bottom row   K5 attack       K6 decay    K7 sustain     K8 release

K4 is an echo's level on the presets and the kit, the cutoff wobble on Poly Five and a
drive on the game sounds. The bottom row reaches the instrument's own envelope where it
has one (Poly Five, the three synths) and a VCA around the instrument where it does not
(the DX7 and FM voices, the kit, the game sounds); at rest every knob sits where the
source patch drew it, so an untouched entry is the example as written.

The pads are eight notes from 36. Pads 1 and 2 are the bank's previous and next entry
on every patch — the board swallows those two notes, the patches never hear them. On
the instruments pads 3 to 7 each start an arpeggio pattern and pad 8 stops it. On the
kit entry pads 3 to 8 are six drums and on the game entry pads 3 to 7 the five sounds.

The set is generated rather than drawn because the same wiring is repeated across two
hundred presets, and a change to the knob map has to reach all of them at once.

The controller numbers are what the bench's MPK sends (read off the board's own MIDI
tally): knobs K1 to K8 on CC 1 to 8, the pads' bank A on notes 36 to 43, the joystick's
up-down axis on CC 1 too and its left-right axis on the pitch-bend wire. A mk3 on its
factory program sends CC 70 to 77 from the knobs; change CONTROLLER and run this again.

Program Change (the MPK's PROG CHANGE button plus a pad, program 0 to 7) still loads
the entry it names, as MIDI has it; the pads are the way to walk the set. PROG SELECT
changes the MPK's own internal program (which numbers the knobs and pads send) and
sends nothing by itself.
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
EXAMPLES = REPO / "examples" / "patches"
OUT = REPO / "examples" / "banks" / "axoloti-akai-mpk-mini"
BANK = REPO / "examples" / "banks" / "axoloti-akai-mpk-mini.json"

CONTROLLER = {
    "name": "Akai MPK mini, knobs on CC 1-8, pads from note 36",
    # What the bench's MPK actually sends, read off the board's own MIDI tally
    # (hw.py scan): the knobs are CC 1 to 8. A mk3 on its factory program says 70
    # to 77 instead; change this line and run the script again.
    "knobs": [1, 2, 3, 4, 5, 6, 7, 8],  # K1..K8
    "pads_base": 36,                             # bank A: pads 1..8 are notes 36..43
    "navigation_pads": 2,                        # pads 1 and 2: previous and next entry
    # The joystick, read off the same tally: one axis is the pitch bend (the
    # wire's 14 bits, centre at rest), the other is CC 1 (0 at rest, up to 127).
    # Wired here as asked: the CC axis bends the pitch, the bend axis is the
    # volume — left quieter, right louder, the rest position as the knobs left it.
    # K1 sends CC 1 as well, so K1 *is* the stick's up axis: the pitch bend knob.
    "stick_pitch_cc": 1,
    "stick_volume_cc": 128,  # 128 is where the editor and the board keep the bend
}

PITCH_RANGE_OCTAVES = 2.0 / 12.0  # the stick bends up two semitones

# The first pad a patch hears: the navigation pads sit under it and the board
# swallows them.
PLAY_BASE = CONTROLLER["pads_base"] + CONTROLLER["navigation_pads"]

# The knob rows. K1 is the stick's CC, wired as the pitch bend wherever the stick is.
KNOB_CUTOFF, KNOB_RESONANCE, KNOB_EFFECT = 2, 3, 4
KNOB_ATTACK, KNOB_DECAY, KNOB_SUSTAIN, KNOB_RELEASE = 5, 6, 7, 8

# The bottom row's reach. Resting positions come from the source patch, so the
# knobs change nothing until they are turned.
ENVELOPE_RANGES = {"attack": (0.001, 1.0), "decay": (0.02, 1.5),
                   "sustain": (0.0, 1.0), "release": (0.02, 2.0)}


# ---- pieces ---------------------------------------------------------------------

def load(rel):
    return json.loads((EXAMPLES / rel).read_text(encoding="utf-8"))


def node(id, type, params=None, host=None, x=0.0, y=0.0, **extra):
    n = {"id": id, "type": type, "position": {"x": float(x), "y": float(y)}}
    if host:
        n["host"] = host
    if params:
        n["parameters"] = params
    n.update(extra)
    return n


def wire(src, dst):
    a, b = src.split("."), dst.split(".")
    return {"from": {"node": a[0], "port": a[1]}, "to": {"node": b[0], "port": b[1]}}


def knob(id, index, low, high, resting, glide=15.0, x=0.0, y=0.0):
    """K<index> (1-based) as a MidiCC node scaled between low and high. K1 is refused:
    on this MPK it sends CC 1, which is also the stick's up-down axis, and the stick
    sends 0 when let go — which the patch read as K1 turned all the way down, the
    cutoff four octaves under, and a bright preset gone silent. K1 reaches a patch
    only as the stick does, through stick_pitch()."""
    cc = CONTROLLER["knobs"][index - 1]
    if cc in (CONTROLLER["stick_pitch_cc"], CONTROLLER["stick_volume_cc"]):
        raise SystemExit(f"K{index} sends CC {cc}, which the stick also sends; use another knob")
    return knob_cc(id, cc, low, high, resting, glide, x, y)


def knob_cc(id, cc, low, high, resting, glide=15.0, x=0.0, y=0.0):
    return node(id, "MidiCC", {"cc": cc, "low": low, "high": high, "resting": resting,
                               "glide": glide}, x=x, y=y)


def stick_pitch(id, x=0.0, y=1600.0):
    """The stick's up axis (and K1, the same CC) as a frequency ratio: 1 at rest, two
    semitones up when pushed. A ratio on the note's frequency rather than octaves into
    an fm input: an fm input that moves costs an exp2 per sample per oscillator."""
    return knob_cc(id, CONTROLLER["stick_pitch_cc"], 1.0, 2.0 ** PITCH_RANGE_OCTAVES, 0.0,
                   glide=5.0, x=x, y=y)


def stick_volume(id, x=0.0, y=1750.0):
    """The stick's left-right axis as a gain: 0 at the left, 1 at rest, 2 at the right."""
    return knob_cc(id, CONTROLLER["stick_volume_cc"], 0.0, 2.0, 0.5, glide=20.0, x=x, y=y)


def volume_stage(prefix, source, x=3000.0):
    """A Gain on `source` driven by the stick's volume; returns (nodes, wires, out)."""
    # The 0.8 is the master level; a Gain scales by its parameter and its wire both.
    nodes = [stick_volume(f"{prefix}_volume", x=x - 300, y=200),
             node(f"{prefix}_vol", "Gain", {"gain": 0.8}, x=x, y=0)]
    wires = [wire(source, f"{prefix}_vol.in"), wire(f"{prefix}_volume.out", f"{prefix}_vol.gain")]
    return nodes, wires, f"{prefix}_vol.out"


def redirect_sources(connections, old_src, new_src):
    """Every wire that left old_src now leaves new_src."""
    a, b = old_src.split("."), new_src.split(".")
    for c in connections:
        if c["from"] == {"node": a[0], "port": a[1]}:
            c["from"] = {"node": b[0], "port": b[1]}


def redirect_sinks(connections, old_dst, new_dst):
    """Every wire that reached old_dst now reaches new_dst."""
    a, b = old_dst.split("."), new_dst.split(".")
    for c in connections:
        if c["to"] == {"node": a[0], "port": a[1]}:
            c["to"] = {"node": b[0], "port": b[1]}


class Part:
    """A patch lifted out of an example, ids prefixed, its Output removed and
    remembered as `feeds` (what drove out.left) so parts can be summed."""

    def __init__(self, patch, prefix):
        self.prefix = prefix
        self.nodes = []
        self.connections = []
        self.modules = {}
        self.feeds = []
        p = lambda i: f"{prefix}_{i}"  # noqa: E731
        module_names = {name: f"{prefix}_{name}" for name in patch.get("modules", {})}
        for name, definition in patch.get("modules", {}).items():
            self.modules[module_names[name]] = definition
        outputs = {n["id"] for n in patch["nodes"] if n["type"] == "Output"}
        self.right = []
        for n in patch["nodes"]:
            if n["id"] in outputs:
                continue
            copy = dict(n)
            copy["id"] = p(n["id"])
            if copy.get("type") == "module" and copy.get("module") in module_names:
                copy["module"] = module_names[copy["module"]]
            self.nodes.append(copy)
        for c in patch["connections"]:
            src, dst = c["from"], c["to"]
            if dst["node"] in outputs:
                feed = f"{p(src['node'])}.{src['port']}"
                (self.feeds if dst["port"] == "left" else self.right).append(feed)
                continue
            self.connections.append(wire(f"{p(src['node'])}.{src['port']}",
                                         f"{p(dst['node'])}.{dst['port']}"))
        # A part that drove the two channels differently is folded to one: the
        # kit puts half its drums on each side, and the sum is the whole kit.
        if self.right and self.right != self.feeds:
            fold = f"{prefix}_fold"
            self.nodes.append(node(fold, "Add", x=2200, y=2000))
            self.connections += [wire(self.feeds[0], f"{fold}.a"), wire(self.right[0], f"{fold}.b")]
            self.feeds = [f"{fold}.out"]

    def find(self, id):
        for n in self.nodes:
            if n["id"] == f"{self.prefix}_{id}":
                return n
        raise KeyError(id)

    def drop(self, id):
        full = f"{self.prefix}_{id}"
        self.nodes = [n for n in self.nodes if n["id"] != full]
        self.connections = [c for c in self.connections
                            if c["from"]["node"] != full and c["to"]["node"] != full]

    def note_inputs(self):
        return [n["id"] for n in self.nodes if n["type"] == "Input" and n.get("host") == "note"]

    def rewire_source(self, id, port, new_src):
        """Every wire leaving <id>.<port> now leaves new_src instead."""
        redirect_sources(self.connections, f"{self.prefix}_{id}.{port}", new_src)


NOTE_36_HZ = 65.40639  # the pads' base note, the pitch the kit was drawn at


def note_hz(n):
    return 440.0 * 2.0 ** ((n - 69) / 12.0)


def octave_rows(prefix, base, octaves, x=0.0):
    """NoteTriggers rows at base, base+12, ... chained bus to bus, so every octave
    of the keyboard lands on the same eight lanes; returns (nodes, wires, bus_out).
    A kit whose only triggers sat at one low octave was silent from the keys at any
    other, which read at the bench as a dead patch."""
    nodes, wires = [], []
    previous = None
    for o in range(octaves - 1, -1, -1):
        rid = f"{prefix}_row{o}"
        nodes.append(node(rid, "NoteTriggers", {"base": base + 12 * o, "shift": 0}, x=x, y=200 * o))
        if previous is not None:
            wires.append(wire(f"{previous}.bus", f"{rid}.bus"))
        previous = rid
    return nodes, wires, f"{previous}.bus"


def drum_kit(prefix="d", base=None, lanes=8, octaves=1):
    """The 808-style kit from drums/kit.json on the pads. `lanes` keeps the first
    n drums (kick, snare, closed hat, open hat, clap, rim, cowbell, tom) for boards
    with less room. With `octaves` above one the kit repeats up the keyboard, an
    octave per row, and its pitched drums follow the key: a kick on the row above
    plays an octave up."""
    kit = Part(load("drums/kit.json"), prefix)
    kit.drop("bus")     # the trigger-bus input another card would feed
    base = base if base is not None else PLAY_BASE
    pads = kit.find("pads")
    pads["parameters"] = {"base": base, "shift": 0}
    if octaves > 1:
        rows, wires, bus = octave_rows(prefix, base + 12, octaves - 1, x=-400)
        kit.nodes += rows
        kit.connections += wires + [wire(bus, f"{prefix}_split.bus")]
        # The key's frequency, scaled to each pitched drum's own tuning, so the row
        # an octave up plays an octave up. Noise drums stay as they are.
        kit.nodes.append(node(f"{prefix}_key", "Input", host="note", x=-400, y=-300))
        for n in list(kit.nodes):
            if n["type"] in ("SineOscillator", "SquareOscillator") and "frequency" in n.get("parameters", {}):
                short = n["id"][len(prefix) + 1:]
                factor = float(n["parameters"]["frequency"]) / NOTE_36_HZ
                kit.nodes.append(node(f"{prefix}_{short}_pitch", "Multiply", {"factor": factor}, x=-200, y=0))
                kit.connections += [wire(f"{prefix}_key.frequency", f"{prefix}_{short}_pitch.a"),
                                    wire(f"{prefix}_{short}_pitch.out", f"{n['id']}.frequency")]
    else:
        kit.drop("split")   # the splitter that read the bus another card would feed
    groups = ["k", "s", "c", "o", "cl", "r", "b", "v"]
    for group in groups[lanes:]:
        for n in list(kit.nodes):
            if n["id"].startswith(f"{prefix}_{group}_"):
                kit.drop(n["id"][len(prefix) + 1:])
    return kit


def assemble(name, parts, extra_nodes, extra_connections, sum_to):
    """One patch out of parts, `sum_to` (a node.port) into the Output. The master
    level lives in the volume stage every entry ends with."""
    nodes, connections, modules = [], [], {}
    for part in parts:
        nodes += part.nodes
        connections += part.connections
        modules.update(part.modules)
    nodes += extra_nodes
    connections += extra_connections
    nodes.append(node("out", "Output", host="stereo", x=3600, y=0))
    connections += [wire(sum_to, "out.left"), wire(sum_to, "out.right")]
    patch = {"schema_version": 2 if modules else 1,
             "metadata": {"name": name,
                          "controller": CONTROLLER["name"]},
             "nodes": nodes, "connections": connections}
    if modules:
        patch["modules"] = modules
    return patch


def summed(feeds, prefix, x=2400):
    """Add nodes chaining `feeds` into one signal; returns (nodes, wires, out)."""
    nodes, wires = [], []
    if not feeds:
        raise SystemExit("nothing to sum")
    acc = feeds[0]
    for k, feed in enumerate(feeds[1:]):
        nid = f"{prefix}_sum{k}"
        nodes.append(node(nid, "Add", x=x + 200 * k, y=0))
        wires += [wire(acc, f"{nid}.a"), wire(feed, f"{nid}.b")]
        acc = f"{nid}.out"
    return nodes, wires, acc


# ---- the knob rows -----------------------------------------------------------------------

def filter_knobs(prefix, filter_id, x=1200.0, y=200.0):
    """K2 and K3 on a StateVariableFilter: cutoff as octaves around the filter's own
    setting through cutoff_mod (a MidiCC's range stops at 1000, so a knob in hertz
    could not reach the top), and resonance. Resting: as the filter was drawn."""
    nodes = [knob(f"{prefix}_cutoff", KNOB_CUTOFF, -4.0, 2.5, 1.0, x=x, y=y),
             knob(f"{prefix}_resonance", KNOB_RESONANCE, 0.0, 0.85, 0.2 / 0.85, x=x, y=y + 150)]
    wires = [wire(f"{prefix}_cutoff.out", f"{filter_id}.cutoff_mod"),
             wire(f"{prefix}_resonance.out", f"{filter_id}.resonance")]
    return nodes, wires


def outer_filter(prefix, source, x=1500.0):
    """A lowpass on `source` with K2 and K3, resting wide open: -4..+2.5 octaves
    around 2 kHz is 125 Hz to 11 kHz. Returns (nodes, wires, out)."""
    nodes = [node(f"{prefix}_filter", "StateVariableFilter",
                  {"cutoff": 2000.0, "resonance": 0.2, "mode": 0}, x=x, y=0)]
    knob_nodes, knob_wires = filter_knobs(prefix, f"{prefix}_filter", x=x - 300, y=200)
    wires = [wire(source, f"{prefix}_filter.in")] + knob_wires
    return nodes + knob_nodes, wires, f"{prefix}_filter.out"


def envelope_knobs(prefix, target, attack, decay, sustain, release, x=0.0, y=2200.0):
    """The bottom row into an AdsrCV: K5 attack, K6 decay, K7 sustain, K8 release,
    each resting where the source patch had it. Returns (nodes, wires)."""
    nodes, wires = [], []
    for k, (name, value, index) in enumerate([("attack", attack, KNOB_ATTACK),
                                              ("decay", decay, KNOB_DECAY),
                                              ("sustain", sustain, KNOB_SUSTAIN),
                                              ("release", release, KNOB_RELEASE)]):
        low, high = ENVELOPE_RANGES[name]
        resting = min(max((float(value) - low) / (high - low), 0.0), 1.0)
        nid = f"{prefix}_{name}"
        nodes.append(knob(nid, index, low, high, resting, x=x, y=y + 150 * k))
        wires.append(wire(f"{nid}.out", f"{target}.{name}"))
    return nodes, wires


def knobs_on_own_envelope(part, envelope_id, prefix):
    """The part's amplitude ADSR becomes an AdsrCV with the bottom row on it."""
    env = part.find(envelope_id)
    env["type"] = "AdsrCV"
    p = env.get("parameters", {})
    return envelope_knobs(prefix, env["id"], p.get("attack", 0.005), p.get("decay", 0.12),
                          p.get("sustain", 0.6), p.get("release", 0.25))


def vca_with_knobs(prefix, source, gate, x=1200.0):
    """An AdsrCV-driven Gain around a source that has no envelope of its own to reach:
    at rest a wall (attack at once, sustain 1, a two-second release under the source's
    own tails); the bottom row shortens it from there. Returns (nodes, wires, out)."""
    nodes = [node(f"{prefix}_env", "AdsrCV", {"attack": 0.001, "decay": 0.5, "sustain": 1.0,
                                              "release": 2.0}, x=x, y=600),
             node(f"{prefix}_vca", "Gain", {"gain": 1.0}, x=x, y=0)]
    wires = [wire(gate, f"{prefix}_env.gate"), wire(source, f"{prefix}_vca.in"),
             wire(f"{prefix}_env.out", f"{prefix}_vca.gain")]
    knob_nodes, knob_wires = envelope_knobs(prefix, f"{prefix}_env", 0.001, 0.5, 1.0, 2.0)
    return nodes + knob_nodes, wires + knob_wires, f"{prefix}_vca.out"


def echo(prefix, source, x=2000):
    """A Delay on `source`, its level on K4 (dry at rest). Returns (nodes, wires, wet_out)."""
    nodes = [
        node(f"{prefix}_delay", "Delay", {"time": 0.3, "feedback": 0.35, "mix": 1.0}, x=x, y=300),
        node(f"{prefix}_wet", "Gain", {"gain": 0.0}, x=x + 300, y=300),
        knob(f"{prefix}_wet_level", KNOB_EFFECT, 0.0, 0.8, 0.0, x=x - 300, y=700),
    ]
    wires = [wire(source, f"{prefix}_delay.in"),
             wire(f"{prefix}_delay.out", f"{prefix}_wet.in"),
             wire(f"{prefix}_wet_level.out", f"{prefix}_wet.gain")]
    return nodes, wires, f"{prefix}_wet.out"


# ---- the pads as an arpeggiator ------------------------------------------------------------

KEY_FLOOR_HZ = 130.0        # C3 and up are keys; under it are the pads (and a keyboard
                            # shifted two octaves down, which then plays the pads)

# Semitones over the root, eight steps, one pattern per playing pad (pads 3..7); the
# last playing pad, pad 8, is the stop. In octaves on the oscillator's fm input, which
# stays within a block, so it costs the oscillator nothing per sample.
ARP_PATTERNS = [
    ("major up",          [0, 4, 7, 12, 0, 4, 7, 12]),
    ("minor up",          [0, 3, 7, 12, 0, 3, 7, 12]),
    ("major up and down", [0, 4, 7, 12, 16, 12, 7, 4]),
    ("minor seventh",     [0, 3, 7, 10, 12, 10, 7, 3]),
    ("pentatonic run",    [0, 3, 5, 7, 10, 12, 15, 19]),
]
PLAYING_PADS = 8 - CONTROLLER["navigation_pads"]   # six: five patterns and the stop
STOP_LANE = PLAYING_PADS                             # the stop pad's lane, from 1


def lane(id, semitones, x, y):
    steps = {f"step{k + 1}": s / 12.0 for k, s in enumerate(semitones)}
    return node(id, "StepSequencer", {"length": len(semitones), **steps}, x=x, y=y)


def pad_machine(prefix, patterns, run_gate=None, x=0.0, y=3000.0):
    """The pads as an arpeggiator's brain: which pattern, and whether it runs.

    A NoteTriggers row on the pads is the only thing here that hears notes, and it is
    not a NoteInput, so nothing of this is copied per voice: the engine replicates a
    NoteInput's whole downstream cone as many times as the patch has voices, and a
    machine hung off one saw only its own voice's share of the pads. The row starts at
    the first playing pad (the two under it walk the bank, and the board swallows
    them). Its bus is a bitmask of the lanes firing, so held at the hit it names the
    pad as a power of two: the first playing pad is 1, the stop pad (the last) 32.
    The pads before the stop start a pattern each (at 120 bpm in sixteenths); the
    stop pad stops. Feedback-free, since the engine's rule
    is that a loop holds a delay. The pattern is picked by summing the first lane
    with the differences to the next, each switched in by a compare on the held pad;
    the lanes step in lockstep, so the sum is exactly the chosen pattern.

    Returns (nodes, wires, pattern_out, envelope_out); `run_gate`, if given, is a
    signal that must also be high for the clock to run."""
    p = lambda i: f"{prefix}_{i}"  # noqa: E731
    nodes = [
        node(p("pads"), "NoteTriggers", {"base": PLAY_BASE, "shift": 0}, x=x, y=y + 200),
        node(p("any"), "Compare", {"threshold": 0.5}, x=x + 300, y=y + 200),
        node(p("last"), "SampleHold", x=x + 600, y=y + 200),
        node(p("above"), "Compare", {"threshold": 0.5}, x=x + 900, y=y + 100),
        # Between the last pattern pad's bit and the stop pad's.
        node(p("ceiling"), "Constant", {"value": 1.5 * 2 ** (STOP_LANE - 2)}, x=x + 600, y=y + 400),
        node(p("below"), "Compare", {"threshold": 0.0}, x=x + 900, y=y + 300),
        node(p("run"), "Multiply", {"factor": 1.0}, x=x + 1200, y=y + 200),
        node(p("clock"), "Clock", {"bpm": 120.0, "division": 4, "swing": 0.0, "width": 70.0,
                                   "beats_per_bar": 4}, x=x + 1500, y=y + 400),
        node(p("env"), "ADSR", {"attack": 0.003, "decay": 0.12, "sustain": 0.4, "release": 0.15},
             x=x + 1800, y=y + 400),
    ]
    wires = [
        wire(f"{p('pads')}.bus", f"{p('any')}.a"),
        wire(f"{p('pads')}.bus", f"{p('last')}.in"), wire(f"{p('any')}.out", f"{p('last')}.trigger"),
        wire(f"{p('last')}.out", f"{p('above')}.a"),
        wire(f"{p('ceiling')}.out", f"{p('below')}.a"), wire(f"{p('last')}.out", f"{p('below')}.b"),
        wire(f"{p('above')}.out", f"{p('run')}.a"), wire(f"{p('below')}.out", f"{p('run')}.b"),
        wire(f"{p('clock')}.gate", f"{p('env')}.gate"),
    ]
    if run_gate:
        nodes.append(node(p("run_too"), "Multiply", {"factor": 1.0}, x=x + 1200, y=y + 500))
        wires += [wire(f"{p('run')}.out", f"{p('run_too')}.a"), wire(run_gate, f"{p('run_too')}.b"),
                  wire(f"{p('run_too')}.out", f"{p('clock')}.run")]
    else:
        wires.append(wire(f"{p('run')}.out", f"{p('clock')}.run"))
    first = patterns[0][1]
    nodes.append(lane(p("lane1"), first, x + 1800, y + 900))
    wires += [wire(f"{p('clock')}.gate", f"{p('lane1')}.clock"),
              wire(f"{p('clock')}.bar", f"{p('lane1')}.reset")]
    acc = f"{p('lane1')}.out"
    for k in range(1, len(patterns)):
        previous, current = patterns[k - 1][1], patterns[k][1]
        delta = [b - a for a, b in zip(previous, current)]
        threshold = 1.5 * 2 ** (k - 1)   # between pad k (2^(k-1)) and pad k+1 (2^k)
        nodes += [lane(p(f"dlane{k}"), delta, x + 1800, y + 900 + 200 * k),
                  node(p(f"sel{k}"), "Compare", {"threshold": threshold}, x=x + 2100, y=y + 900 + 200 * k),
                  node(p(f"pick{k}"), "Multiply", {"factor": 1.0}, x=x + 2400, y=y + 900 + 200 * k),
                  node(p(f"pat{k}"), "Add", x=x + 2700, y=y + 900 + 200 * k)]
        wires += [wire(f"{p('clock')}.gate", f"{p(f'dlane{k}')}.clock"),
                  wire(f"{p('clock')}.bar", f"{p(f'dlane{k}')}.reset"),
                  wire(f"{p('last')}.out", f"{p(f'sel{k}')}.a"),
                  wire(f"{p(f'dlane{k}')}.out", f"{p(f'pick{k}')}.a"),
                  wire(f"{p(f'sel{k}')}.out", f"{p(f'pick{k}')}.b"),
                  wire(acc, f"{p(f'pat{k}')}.a"), wire(f"{p(f'pick{k}')}.out", f"{p(f'pat{k}')}.b")]
        acc = f"{p(f'pat{k}')}.out"
    return nodes, wires, acc, f"{p('env')}.out"


def arp_voice(prefix, frequency, pattern, envelope, cutoff_mod, resonance, level, x=3000.0, y=3000.0):
    """The arpeggiator's sound: a saw on `frequency`, the pattern on its fm, a lowpass
    on the same knobs as the instrument, the machine's envelope on a VCA. Without a
    cutoff_mod it is a sine pluck and no filter, for the patch that cannot afford one.
    Returns (nodes, wires, out)."""
    p = lambda i: f"{prefix}_{i}"  # noqa: E731
    nodes = [node(p("vca"), "Gain", {"gain": level}, x=x + 600, y=y)]
    wires = [wire(pattern, f"{p('osc')}.fm"), wire(envelope, f"{p('vca')}.gain")]
    if cutoff_mod:
        nodes += [node(p("osc"), "SawOscillator", {"frequency": 220.0}, x=x, y=y),
                  node(p("filter"), "StateVariableFilter",
                       {"cutoff": 1200.0, "resonance": 0.3, "mode": 0}, x=x + 300, y=y)]
        wires += [wire(frequency, f"{p('osc')}.frequency"),
                  wire(f"{p('osc')}.out", f"{p('filter')}.in"),
                  wire(cutoff_mod, f"{p('filter')}.cutoff_mod"),
                  wire(f"{p('filter')}.out", f"{p('vca')}.in")]
        if resonance:
            wires.append(wire(resonance, f"{p('filter')}.resonance"))
    else:
        nodes.append(node(p("osc"), "SineOscillator", {"frequency": 220.0}, x=x, y=y))
        wires += [wire(frequency, f"{p('osc')}.frequency"), wire(f"{p('osc')}.out", f"{p('vca')}.in")]
    return nodes, wires, f"{p('vca')}.out"


def latched_arp(prefix, note_input, patterns, pitch_ratio, cutoff_mod, resonance, level=1.0):
    """The arpeggiator for a one-voice instrument: it plays on the last key pressed
    and keeps playing after the key is let go, until the stop pad. The root is the
    note input's frequency held at each key-down (a pad is a note too, and under
    KEY_FLOOR_HZ; it is not a key), and until a key has been played the clock is
    held off, since a saw at 0 Hz is a DC level the envelope would pulse.
    Returns (nodes, wires, out)."""
    p = lambda i: f"{prefix}_{i}"  # noqa: E731
    nodes = [
        node(p("is_key"), "Compare", {"threshold": KEY_FLOOR_HZ}, x=0, y=2600),
        node(p("key_hit"), "Multiply", {"factor": 1.0}, x=300, y=2600),
        node(p("root"), "SampleHold", x=600, y=2600),
        node(p("has_root"), "Compare", {"threshold": 20.0}, x=900, y=2700),
        node(p("bent"), "Multiply", {"factor": 1.0}, x=900, y=2600),
    ]
    wires = [
        wire(f"{note_input}.frequency", f"{p('is_key')}.a"),
        wire(f"{p('is_key')}.out", f"{p('key_hit')}.a"), wire(f"{note_input}.gate", f"{p('key_hit')}.b"),
        wire(f"{note_input}.frequency", f"{p('root')}.in"), wire(f"{p('key_hit')}.out", f"{p('root')}.trigger"),
        wire(f"{p('root')}.out", f"{p('has_root')}.a"),
        wire(f"{p('root')}.out", f"{p('bent')}.a"), wire(pitch_ratio, f"{p('bent')}.b"),
    ]
    m_nodes, m_wires, pattern, envelope = pad_machine(prefix, patterns, run_gate=f"{p('has_root')}.out")
    v_nodes, v_wires, out = arp_voice(prefix, f"{p('bent')}.out", pattern, envelope, cutoff_mod,
                                      resonance, level)
    return nodes + m_nodes + v_nodes, wires + m_wires + v_wires, out


def held_arp(prefix, frequency, key_envelope, patterns, cutoff_mod, resonance, level=1.0):
    """The arpeggiator for a polyphonic instrument: every held key arpeggiates, in
    lockstep, so a held chord is a chord arpeggio, and each stops with its key's own
    envelope. The voice part sits in the instrument's voice cone (its frequency is
    the voice's, bent), so the engine copies it per voice; the machine does not.
    Returns (nodes, wires, out)."""
    p = lambda i: f"{prefix}_{i}"  # noqa: E731
    m_nodes, m_wires, pattern, envelope = pad_machine(prefix, patterns)
    v_nodes, v_wires, voice_out = arp_voice(prefix, frequency, pattern, envelope, cutoff_mod,
                                            resonance, level)
    nodes = [node(p("held"), "Gain", {"gain": 1.0}, x=3900, y=3000)]
    wires = [wire(voice_out, f"{p('held')}.in"), wire(key_envelope, f"{p('held')}.gain")]
    return m_nodes + v_nodes + nodes, m_wires + v_wires + wires, f"{p('held')}.out"


def keys_only(prefix, note_input, connections, x=0.0, y=-400.0):
    """The instrument's gate with the pads taken out of it: a pad is a note like any
    other to the voice, and without this the synth played a low note under every
    arpeggio it started. Returns (nodes, wires); rewires the gate's wires."""
    nodes = [node(f"{prefix}_is_key", "Compare", {"threshold": KEY_FLOOR_HZ}, x=x, y=y),
             node(f"{prefix}_gate", "Multiply", {"factor": 1.0}, x=x + 300, y=y)]
    redirect_sources(connections, f"{note_input}.gate", f"{prefix}_gate.out")
    wires = [wire(f"{note_input}.frequency", f"{prefix}_is_key.a"),
             wire(f"{note_input}.gate", f"{prefix}_gate.a"),
             wire(f"{prefix}_is_key.out", f"{prefix}_gate.b")]
    return nodes, wires


def voices_of(part, note_input):
    for n in part.nodes:
        if n["id"] == note_input:
            return int(n.get("parameters", {}).get("voices", 1))
    return 1


# ---- the patches -------------------------------------------------------------------

def poly5_pads(patterns):
    """Poly Five on the keys, the arpeggiator on pads 3 to 8: hold a chord, hit a pad.
    K1 pitch bend  K2 cutoff  K3 resonance  K4 wobble rate
    K5 attack  K6 decay  K7 sustain  K8 release (the voices' own envelope)
    Stick up: pitch bend, two semitones. Stick left/right: volume, quieter to louder.
    No echo here: the engine copies everything after the keyboard once per voice, so
    an echo on Poly Five is five delay lines, and with the stick that is past the
    board's 44 KB code window. The wobble stands in: an LFO is a global modulator,
    so it exists once however many voices there are."""
    synth = Part(load("synths/poly-five.json"), "p")
    # Four voices on the board, not five. The engine copies everything after the
    # keyboard once per voice, and with the arpeggiator's voice in that cone, five
    # voices and the pads' machine came to 114% of a codec call; four are 80%.
    synth.find("kb")["parameters"]["voices"] = 4
    extra, wires = [], []
    # The detune stays as drawn; the stick is a ratio on the note's frequency, so
    # bending is one multiply per sample per oscillator (an fm input that moves is an
    # exp2 per sample per oscillator, ten of them here, and bending overran the call).
    extra.append(stick_pitch("p_pitch_ratio", x=0, y=1600))
    extra.append(node("p_bent", "Multiply", {"factor": 1.0}, x=300, y=300))
    synth.rewire_source("kb", "frequency", "p_bent.out")
    wires += [wire("p_kb.frequency", "p_bent.a"), wire("p_pitch_ratio.out", "p_bent.b")]
    # Cutoff and resonance on the voices' own filter: the knob's octaves are summed with
    # the envelope sweep by hand, and with the wobble (one wire per input is the rule).
    # The knob and the wobble are summed once, outside the voices, and each voice adds
    # its own envelope sweep to that.
    extra.append(knob("p_cutoff", KNOB_CUTOFF, -3.0, 3.0, 0.5, x=0, y=800))
    extra += [node("p_wobble", "LFO", {"rate": 0.5, "shape": 0, "amount": 0.3, "offset": 0.0}, x=0, y=1100),
              knob("p_wobble_rate", KNOB_EFFECT, 0.0, 8.0, 0.0, x=-300, y=1100),
              node("p_mod", "Add", x=300, y=950)]
    wires += [wire("p_wobble_rate.out", "p_wobble.rate"),
              wire("p_cutoff.out", "p_mod.a"), wire("p_wobble.out", "p_mod.b")]
    extra.append(node("p_cm_sum", "Add", x=600, y=800))
    redirect_sinks(synth.connections, "p_filter.cutoff_mod", "p_cm_sum.a")
    wires += [wire("p_mod.out", "p_cm_sum.b"), wire("p_cm_sum.out", "p_filter.cutoff_mod")]
    extra.append(knob("p_resonance", KNOB_RESONANCE, 0.0, 0.9, 0.35 / 0.9, x=0, y=950))
    wires.append(wire("p_resonance.out", "p_filter.resonance"))
    env_nodes, env_wires = knobs_on_own_envelope(synth, "aenv", "p")
    key_nodes, key_wires = keys_only("p", "p_kb", synth.connections)
    # The synth's level, 0.8, folded into its own VCA's parameter (a Gain scales by
    # its parameter and its wire both) rather than a Gain per voice.
    synth.find("vca")["parameters"]["gain"] = 0.45 * 0.8
    # A sine pluck under the voices, with no filter of its own: the filtered saw the
    # other entries use is copied per voice here, and cost two per cent a voice.
    arp_nodes, arp_wires, arp_out = held_arp("a", "p_bent.out", "p_aenv.out", patterns,
                                             None, None, level=0.8)
    sum_nodes, sum_wires, mixed = summed([synth.feeds[0], arp_out], "mix")
    vol_nodes, vol_wires, out = volume_stage("p", mixed)
    return assemble("Poly Five, pads (four voices)", [synth],
                    extra + env_nodes + key_nodes + arp_nodes + sum_nodes + vol_nodes,
                    wires + env_wires + key_wires + arp_wires + sum_wires + vol_wires, out)


def instrument_with_pads(rel, name, patterns, boost=1.0, own_envelope=None):
    """A synth, DX7 or FM preset on the keys with the arpeggiator on the pads.
    K1 pitch bend  K2 cutoff  K3 resonance  K4 echo level
    K5 attack  K6 decay  K7 sustain  K8 release
    Stick up: pitch bend, two semitones. Stick left/right: volume, quieter to louder.
    `own_envelope` names the source's amplitude ADSR when it has one the knobs can
    take over; otherwise the knobs shape a VCA around the whole voice. On a one-voice
    instrument the arpeggiator latches to the last key; on a polyphonic one every held
    key arpeggiates."""
    # The source's own ids wear "src_"; everything added here wears "v_", so a preset
    # with a node called "filter" (duo-lead has one) does not collide with ours.
    voice = Part(load(rel), "src")
    extra, wires = [], []
    note_input = voice.note_inputs()[0]
    # ---- the stick: the operators live inside a module, so the pitch goes in as a
    # ratio on the note's frequency: 1 at rest, 2^(2/12) with the stick pushed.
    extra.append(stick_pitch("v_pitch_ratio", x=0, y=1900))
    extra.append(node("v_bent", "Multiply", {"factor": 1.0}, x=300, y=1900))
    for inp in voice.note_inputs():
        redirect_sources(voice.connections, f"{inp}.frequency", "v_bent.out")
        wires.append(wire(f"{inp}.frequency", "v_bent.a"))
    wires.append(wire("v_pitch_ratio.out", "v_bent.b"))
    key_nodes, key_wires = keys_only("v", note_input, voice.connections)
    if own_envelope:
        env_nodes, env_wires = knobs_on_own_envelope(voice, own_envelope, "v")
        shaped = voice.feeds[0]
        key_envelope = f"src_{own_envelope}.out"
    else:
        env_nodes, env_wires, shaped = vca_with_knobs("v", voice.feeds[0], "v_gate.out")
        key_envelope = "v_env.out"
    filter_nodes, filter_wires, filtered = outer_filter("v", shaped)
    extra += [node("v_level", "Gain", {"gain": 0.8 * boost}, x=1800, y=0)]
    wires += [wire(filtered, "v_level.in")]
    if voices_of(voice, note_input) > 1:
        arp_nodes, arp_wires, arp_out = held_arp("a", "v_bent.out", key_envelope, patterns,
                                                 "v_cutoff.out", "v_resonance.out")
    else:
        arp_nodes, arp_wires, arp_out = latched_arp("a", note_input, patterns, "v_pitch_ratio.out",
                                                    "v_cutoff.out", "v_resonance.out")
    mix_nodes, mix_wires, mixed = summed(["v_level.out", arp_out], "mix")
    echo_nodes, echo_wires, wet = echo("v", mixed)
    sum_nodes, sum_wires, final = summed([mixed, wet], "final", x=2800)
    vol_nodes, vol_wires, out = volume_stage("v", final)
    return assemble(name, [voice],
                    extra + key_nodes + env_nodes + filter_nodes + arp_nodes + mix_nodes
                    + echo_nodes + sum_nodes + vol_nodes,
                    wires + key_wires + env_wires + filter_wires + arp_wires + mix_wires
                    + echo_wires + sum_wires + vol_wires, out)


# Pads 1..5 (eight sounds put the board at 96% of a codec call), each with the gain
# that brings its peak on the card to about 0.4, where Poly Five sits: as drawn, the game
# sounds peak between 0.05 and 0.14, eleven decibels under the synth, and the pads
# entry came up quiet on the board while matching the desktop's render exactly.
GAME_PADS = [
    ("game/coin.json", "coin", 10.0), ("game/jump.json", "jump", 16.0),
    ("game/powerup.json", "powerup", 8.0), ("game/hurt.json", "hurt", 16.0),
    ("game/explode.json", "explode", 5.6),
]
# Five, not six: the sfxr explosion doubled the game one, and with the envelope, the
# filter and the drive around them six sounds put the entry at 96% of a codec call.


def game_pads():
    """Five game sounds on pads 3 to 7 and on every octave of the keys, pitched to the key.
    K1 pitch bend  K2 cutoff  K3 resonance  K4 drive
    K5 attack  K6 decay  K7 sustain  K8 release (a VCA around the sounds)"""
    parts, extra, wires = [], [], []
    # Every octave of the keys fires the same six sounds, and each sound's pitch
    # follows the key, so the entry plays from wherever the keyboard sits.
    # Four octaves, not five: five rows put this entry at 91% of a codec call.
    rows, row_wires, bus = octave_rows("pads", PLAY_BASE, 4)
    extra += rows + [node("split", "TriggerBus", {"shift": 0}, y=1200),
                     node("key", "Input", host="note", y=-300),
                     stick_pitch("g_pitch_ratio", x=0, y=-500),
                     node("g_bent", "Multiply", {"factor": 1.0}, x=300, y=-300)]
    wires += row_wires + [wire(bus, "split.bus"), wire("key.frequency", "g_bent.a"),
                          wire("g_pitch_ratio.out", "g_bent.b")]
    feeds = []
    for lane_index, (rel, prefix, gain) in enumerate(GAME_PADS, start=1):
        part = Part(load(rel), prefix)
        part.nodes.append(node(f"{prefix}_norm", "Gain", {"gain": gain}, x=2000, y=lane_index * 300))
        part.connections.append(wire(part.feeds[0], f"{prefix}_norm.in"))
        part.feeds = [f"{prefix}_norm.out"]
        for inp in part.note_inputs():
            short = inp[len(prefix) + 1:]
            # The pad is the trigger; the pitch is the key's, bent; velocity is full.
            part.rewire_source(short, "trigger", f"split.t{lane_index}")
            part.rewire_source(short, "gate", f"split.t{lane_index}")
            part.rewire_source(short, "frequency", "g_bent.out")
            vel_id = f"{prefix}_vel"
            part.nodes.append(node(vel_id, "Constant", {"value": 1.0}, y=lane_index * 300 + 100))
            part.rewire_source(short, "velocity", f"{vel_id}.out")
            part.drop(short)
        # Unused constants would be an error nowhere, but a tidy patch drops them.
        used = {c["from"]["node"] for c in part.connections}
        part.nodes = [n for n in part.nodes
                      if n["type"] != "Constant" or n["id"] in used]
        parts.append(part)
        feeds.append(part.feeds[0])
    sum_nodes, sum_wires, mixed = summed(feeds, "mix")
    env_nodes, env_wires, shaped = vca_with_knobs("g", mixed, "key.gate", x=2600)
    filter_nodes, filter_wires, filtered = outer_filter("g", shaped, x=2800)
    # No echo here: six sound effects already fill the board's close memory. A drive
    # is the effect instead, clean at rest.
    extra += [node("g_drive", "Drive", {"drive": 1.0}, x=3000, y=0),
              knob("g_drive_knob", KNOB_EFFECT, 1.0, 12.0, 0.0, x=2800, y=500)]
    wires += [wire(filtered, "g_drive.in"), wire("g_drive_knob.out", "g_drive.drive")]
    vol_nodes, vol_wires, out = volume_stage("g", "g_drive.out")
    return assemble("Game pads", parts,
                    extra + sum_nodes + env_nodes + filter_nodes + vol_nodes,
                    wires + sum_wires + env_wires + filter_wires + vol_wires, out)


def kit_alone():
    """Six drums on pads 3 to 8 (kick, snare, closed and open hat, clap, rim) and on
    every octave of the keys, pitched to the key.
    K1 pitch bend  K2 cutoff  K3 resonance  K4 echo level
    K5 attack  K6 decay  K7 sustain  K8 release (a VCA around the kit)"""
    kit = drum_kit("d", lanes=PLAYING_PADS, octaves=5)
    extra, wires = [], []
    # The pitched drums follow the key through their own Multiplies; the bend goes in
    # between the key and them.
    extra += [stick_pitch("d_pitch_ratio", x=-700, y=-500),
              node("d_bent", "Multiply", {"factor": 1.0}, x=-400, y=-500)]
    kit.rewire_source("key", "frequency", "d_bent.out")
    wires += [wire("d_key.frequency", "d_bent.a"), wire("d_pitch_ratio.out", "d_bent.b")]
    env_nodes, env_wires, shaped = vca_with_knobs("d", kit.feeds[0], "d_key.gate", x=2400)
    filter_nodes, filter_wires, filtered = outer_filter("d", shaped, x=2600)
    echo_nodes, echo_wires, wet = echo("fx", filtered)
    sum_nodes, sum_wires, final = summed([filtered, wet], "final", x=2800)
    vol_nodes, vol_wires, out = volume_stage("d", final)
    return assemble("Drum pads", [kit],
                    extra + env_nodes + filter_nodes + echo_nodes + sum_nodes + vol_nodes,
                    wires + env_wires + filter_wires + echo_wires + sum_wires + vol_wires, out)


# ---- the set ---------------------------------------------------------------------------

# The synths whose own amplitude envelope the bottom row takes over, and the level
# headroom each needs (mallard peaks at 0.13 on the card as drawn, a third of the
# others; its level reaches three times as far).
SYNTHS = [("acid-bass", "aenv", 1.0), ("duo-lead", "aenv", 1.0), ("mallard", "aenv", 3.0)]


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default=None, help="write just this entry (for a size probe)")
    parser.add_argument("--patterns", type=int, default=len(ARP_PATTERNS),
                        help="how many of the arpeggiator's patterns to wire (fewer for a size probe)")
    args = parser.parse_args()
    patterns = ARP_PATTERNS[:args.patterns]
    if len(patterns) > PLAYING_PADS - 1:
        raise SystemExit(f"{len(patterns)} patterns, but only {PLAYING_PADS - 1} pads before the stop")

    OUT.mkdir(parents=True, exist_ok=True)
    entries = []

    def emit(entry_name, patch):
        if args.only and entry_name != args.only:
            return
        (OUT / f"{entry_name}.json").write_text(json.dumps(patch, indent=2) + "\n", encoding="utf-8")
        entries.append({"name": entry_name, "patch": f"axoloti-akai-mpk-mini/{entry_name}.json"})

    # The order is the set list, and the first eight are what the PROG CHANGE pads
    # reach directly (pads 4 to 8 name entries 3 to 7; pad 3 is entry 0, pads 1 and 2
    # walk). Synths first, the kit fifth, three DX7 voices, then the game sounds and
    # the rest of the presets.
    emit("poly5-pads", poly5_pads(patterns))
    for stem, envelope, boost in SYNTHS:
        emit(f"synth-{stem}", instrument_with_pads(f"synths/{stem}.json", f"Synth {stem}", patterns,
                                                   boost, own_envelope=envelope))
    emit("drum-pads", kit_alone())
    for stem in ("ep-road", "bell-glass", "bass-round"):
        emit(f"dx7-{stem}", instrument_with_pads(f"dx7/{stem}.json", f"DX7 {stem}", patterns))
    emit("game-pads", game_pads())
    for family in ("dx7", "fm"):
        for path in sorted((EXAMPLES / family).glob("*.json")):
            entry = f"{family}-{path.stem}"
            if any(e["name"] == entry for e in entries):
                continue  # already placed among the first eight
            emit(entry, instrument_with_pads(f"{family}/{path.name}", f"{family.upper()} {path.stem}",
                                             patterns))

    if args.only:
        print(f"wrote {OUT / (args.only + '.json')}")
        return
    bank = {
        "schema_version": 1,
        "name": "Axoloti + Akai MPK mini",
        "target": "axoloti",
        "controller": CONTROLLER["name"],
        "navigation_notes": {"previous": CONTROLLER["pads_base"],
                             "next": CONTROLLER["pads_base"] + 1},
        "entries": entries,
    }
    BANK.write_text(json.dumps(bank, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} patches into {OUT} and {BANK}")


if __name__ == "__main__":
    main()
