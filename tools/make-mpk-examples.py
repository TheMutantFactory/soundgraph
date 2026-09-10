"""The Akai MPK mini set for the Axoloti: patches whose knobs and pads are mapped.

    python tools/make-mpk-examples.py            # writes examples/banks/axoloti-akai-mpk-mini/
                                                 # and examples/banks/axoloti-akai-mpk-mini.json

Every patch here is an existing example with a controller wired in: MidiCC nodes on
the eight knobs, a NoteTriggers row on the eight pads, and — where the board has room
for it — the drum kit on those pads beside the instrument. The set is generated rather
than drawn because the same wiring is repeated across two hundred presets, and a
change to the knob map has to reach all of them at once.

The controller numbers are the MPK mini mk3's factory program: knobs K1–K8 send CC 70
to 77 and the pads' bank A sends notes 36 to 43. A mk2 or a re-programmed mini differs;
change CONTROLLER and run this again. The pads' MIDI channel does not matter: the board
listens on every channel.

Program Change is the MPK's PROG CHANGE button plus a pad, which sends program 0 to 7
(bank B: 8 to 15). The bank asks for "prev-next" navigation, so on the board pad 1 is
the previous entry, pad 2 the next, pad 3 the first, and pads 4 to 8 are entries 3 to 7
as MIDI would have them. PROG SELECT changes the MPK's own internal program (which
numbers the knobs and pads send) and sends nothing by itself.
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
    # The joystick, read off the same tally: one axis is the pitch bend (the
    # wire's 14 bits, centre at rest), the other is CC 1 (0 at rest, up to 127).
    # Wired here as asked: the CC axis bends the pitch, the bend axis is the
    # volume — left quieter, right louder, the rest position as the knobs left it.
    "stick_pitch_cc": 1,
    "stick_volume_cc": 128,  # 128 is where the editor and the board keep the bend
}

PITCH_RANGE_OCTAVES = 2.0 / 12.0  # the stick bends up two semitones


def stick(prefix, x=0.0, y=1600.0):
    """The joystick as two MidiCC nodes: `<prefix>_pitch` in octaves (0 at rest)
    and `<prefix>_volume`, a gain from 0 (left) through 1 (rest) to 2 (right)."""
    return [
        knob_cc(f"{prefix}_pitch", CONTROLLER["stick_pitch_cc"], 0.0, PITCH_RANGE_OCTAVES, 0.0,
                glide=5.0, x=x, y=y),
        knob_cc(f"{prefix}_volume", CONTROLLER["stick_volume_cc"], 0.0, 2.0, 0.5,
                glide=20.0, x=x, y=y + 150),
    ]


def volume_stage(prefix, source, x=3000.0):
    """A Gain on `source` driven by the stick's volume; returns (nodes, wires, out)."""
    nodes = [node(f"{prefix}_vol", "Gain", {"gain": 1.0}, x=x, y=0)]
    wires = [wire(source, f"{prefix}_vol.in"), wire(f"{prefix}_volume.out", f"{prefix}_vol.gain")]
    return nodes, wires, f"{prefix}_vol.out"


def scaled(id, source, factor, x=0.0, y=0.0):
    """`source` times a constant factor, as a Multiply node."""
    return node(id, "Multiply", {"factor": factor}, x=x, y=y), wire(source, f"{id}.a")


def redirect_sources(connections, old_src, new_src):
    """Every wire that left old_src now leaves new_src."""
    a, b = old_src.split("."), new_src.split(".")
    for c in connections:
        if c["from"] == {"node": a[0], "port": a[1]}:
            c["from"] = {"node": b[0], "port": b[1]}

C4 = 261.6256  # the pitch a pad plays a game sound at: the keyboard's middle C


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
    """K<index> (1-based) as a MidiCC node scaled between low and high."""
    return knob_cc(id, CONTROLLER["knobs"][index - 1], low, high, resting, glide, x, y)


def knob_cc(id, cc, low, high, resting, glide=15.0, x=0.0, y=0.0):
    return node(id, "MidiCC", {"cc": cc, "low": low, "high": high, "resting": resting,
                               "glide": glide}, x=x, y=y)


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

    def bound(self, id, port):
        full = f"{self.prefix}_{id}"
        return any(c["to"]["node"] == full and c["to"]["port"] == port
                   for c in self.connections)

    def rewire_source(self, id, port, new_src):
        """Every wire leaving <id>.<port> now leaves new_src instead."""
        full = f"{self.prefix}_{id}"
        for c in self.connections:
            if c["from"]["node"] == full and c["from"]["port"] == port:
                a = new_src.split(".")
                c["from"] = {"node": a[0], "port": a[1]}


def drum_kit(prefix="d", base=None, lanes=8):
    """The 808-style kit from drums/kit.json on the pads. `lanes` keeps the first
    n drums (kick, snare, closed hat, open hat, clap, rim, cowbell, tom) for boards
    with less room."""
    kit = Part(load("drums/kit.json"), prefix)
    kit.drop("bus")     # the trigger-bus input another card would feed
    kit.drop("split")   # and the splitter that read it
    pads = kit.find("pads")
    pads["parameters"] = {"base": base if base is not None else CONTROLLER["pads_base"],
                          "shift": 0}
    groups = ["k", "s", "c", "o", "cl", "r", "b", "v"]
    for group in groups[lanes:]:
        for n in list(kit.nodes):
            if n["id"].startswith(f"{prefix}_{group}_"):
                kit.drop(n["id"][len(prefix) + 1:])
    return kit


def assemble(name, parts, extra_nodes, extra_connections, sum_to, level_knob=None):
    """One patch out of parts: each part's feed summed through Add nodes into
    `sum_to` (a node.port), then a master Gain into the Output."""
    nodes, connections, modules = [], [], {}
    for part in parts:
        nodes += part.nodes
        connections += part.connections
        modules.update(part.modules)
    nodes += extra_nodes
    connections += extra_connections
    nodes.append(node("master", "Gain", {"gain": 0.8}, x=3200, y=0))
    if level_knob is not None:
        nodes.append(knob("master_level", level_knob, 0.0, 1.0, 0.8, x=3000, y=200))
        connections.append(wire("master_level.out", "master.gain"))
    connections.append(wire(sum_to, "master.in"))
    nodes.append(node("out", "Output", host="stereo", x=3600, y=0))
    connections += [wire("master.out", "out.left"), wire("master.out", "out.right")]
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


def echo(prefix, source, time_knob, feedback_knob, wet_knob, x=2000):
    """A Delay on `source` with its time, feedback and wet level on three knobs.
    Returns (nodes, wires, wet_out)."""
    nodes = [
        node(f"{prefix}_delay", "Delay", {"time": 0.3, "feedback": 0.35, "mix": 1.0}, x=x, y=300),
        knob(f"{prefix}_time", time_knob, 0.05, 0.6, 0.42, x=x - 300, y=400),
        knob(f"{prefix}_fb", feedback_knob, 0.0, 0.7, 0.5, x=x - 300, y=550),
        node(f"{prefix}_wet", "Gain", {"gain": 0.0}, x=x + 300, y=300),
        knob(f"{prefix}_wet_level", wet_knob, 0.0, 0.8, 0.0, x=x - 300, y=700),
    ]
    wires = [wire(source, f"{prefix}_delay.in"), wire(f"{prefix}_time.out", f"{prefix}_delay.time"),
             wire(f"{prefix}_fb.out", f"{prefix}_delay.feedback"),
             wire(f"{prefix}_delay.out", f"{prefix}_wet.in"),
             wire(f"{prefix}_wet_level.out", f"{prefix}_wet.gain")]
    return nodes, wires, f"{prefix}_wet.out"


# ---- the patches -------------------------------------------------------------------

def poly5_pads(kit_lanes=4):
    """Poly Five on the keys, the kit on the pads.
    K1 cutoff  K2 resonance  K3 synth level  K4 detune
    K5 wobble rate  K8 drums level (K6 and K7 are free)
    Stick up: pitch bend, two semitones. Stick left/right: volume, quieter to louder.
    Two drums beside the five voices, kick and snare: the board's own counter puts the
    voices at 51% of a codec call and each drum at about 6%, and four drums put the
    whole patch at 95%, which is the chunkiness of a call that overruns.
    No echo here: the engine copies everything after the keyboard once per voice, so
    an echo on Poly Five is five delay lines, and with the stick that is past the
    board's 44 KB code window."""
    synth = Part(load("synths/poly-five.json"), "p")
    extra, wires = [], []
    # The detune constant becomes the knob, as a frequency ratio on osc_b rather than
    # octaves into its fm: a moving fm input is an exp2 per sample per voice, and K4
    # turning put the patch at 99% of a codec call. Up to 3.5% sharp, about a third
    # of a semitone, which is where the stock 0.007 octaves sat.
    synth.drop("detune")
    extra.append(knob("p_detune", 4, 1.0, 1.035, 0.14, x=0, y=600))
    extra.append(node("p_bent_b", "Multiply", {"factor": 1.0}, x=600, y=300))
    for c in synth.connections:
        if c["to"] == {"node": "p_osc_b", "port": "frequency"}:
            c["from"] = {"node": "p_bent_b", "port": "out"}
    wires += [wire("p_detune.out", "p_bent_b.b")]
    # In octaves around the filter's own 900 Hz, through cutoff_mod (which the envelope
    # sweep already drives; control inputs sum): a MidiCC's range stops at 1000, so a
    # knob in hertz could not reach the top of the filter.
    extra.append(knob("p_cutoff", 1, -3.0, 3.0, 0.5, x=0, y=800))
    # Summed with the envelope sweep by hand: one wire per input is the rule.
    extra.append(node("p_cm_sum", "Add", x=300, y=800))
    for c in synth.connections:
        if c["to"] == {"node": "p_filter", "port": "cutoff_mod"}:
            c["to"] = {"node": "p_cm_sum", "port": "b"}
    extra.append(node("p_cm_sum3", "Add", x=900, y=800))
    wires += [wire("p_cutoff.out", "p_cm_sum.a"), wire("p_cm_sum.out", "p_cm_sum3.a"),
              wire("p_cm_sum3.out", "p_filter.cutoff_mod")]
    extra.append(knob("p_resonance", 2, 0.0, 0.9, 0.35 / 0.9, x=0, y=950))
    wires.append(wire("p_resonance.out", "p_filter.resonance"))
    extra.append(node("p_level", "Gain", {"gain": 0.8}, x=1800, y=0))
    extra.append(knob("p_level_knob", 3, 0.0, 1.0, 0.8, x=1500, y=200))
    wires += [wire(synth.feeds[0], "p_level.in"), wire("p_level_knob.out", "p_level.gain")]
    # A wobble on the cutoff instead of an echo: the LFO is a global modulator, so it
    # exists once however many voices there are.
    extra += [node("p_wobble", "LFO", {"rate": 0.5, "shape": 0, "amount": 0.3, "offset": 0.0}, x=0, y=1100),
              knob("p_wobble_rate", 5, 0.0, 8.0, 0.0, x=-300, y=1100)]
    wires += [wire("p_wobble_rate.out", "p_wobble.rate"), wire("p_wobble.out", "p_cm_sum3.b")]
    # ---- the stick ----------------------------------------------------------------
    # Pitch as a ratio on the note's frequency, not octaves into fm: an fm input that
    # moves costs an exp2 per sample per oscillator (five percent of a codec call
    # each, ten oscillators here), and bending the stick pushed the patch from 86% into
    # overrun. A Multiply on the frequency is one multiply per sample. The detune knob
    # stays on osc_b's fm, where it is a Constant-like block and costs one exp2.
    extra.append(knob_cc("p_pitch_ratio", CONTROLLER["stick_pitch_cc"], 1.0,
                         2.0 ** PITCH_RANGE_OCTAVES, 0.0, glide=5.0, x=0, y=1600))
    extra.append(knob_cc("p_volume", CONTROLLER["stick_volume_cc"], 0.0, 2.0, 0.5,
                         glide=20.0, x=0, y=1750))
    extra.append(node("p_bent", "Multiply", {"factor": 1.0}, x=300, y=300))
    redirect_sources(synth.connections, "p_kb.frequency", "p_bent.out")
    wires += [wire("p_kb.frequency", "p_bent.a"), wire("p_pitch_ratio.out", "p_bent.b"),
              wire("p_bent.out", "p_bent_b.a")]
    kit = drum_kit("d", lanes=kit_lanes)
    extra.append(node("d_level", "Gain", {"gain": 0.7}, x=1800, y=1200))
    extra.append(knob("d_level_knob", 8, 0.0, 1.0, 0.7, x=1500, y=1400))
    wires += [wire(kit.feeds[0], "d_level.in"), wire("d_level_knob.out", "d_level.gain")]
    sum_nodes, sum_wires, mixed = summed(["p_level.out", "d_level.out"], "mix")
    vol_nodes, vol_wires, out = volume_stage("p", mixed)
    return assemble("Poly Five, pads", [synth, kit], extra + sum_nodes + vol_nodes,
                    wires + sum_wires + vol_wires, out)


GAME_PADS = [  # pads 1..6; eight sounds put the board at 96% of a codec call
    ("game/coin.json", "coin"), ("game/jump.json", "jump"), ("game/powerup.json", "powerup"),
    ("game/hurt.json", "hurt"), ("game/explode.json", "explode"), ("sfxr/explosion.json", "boom"),
]


def game_pads():
    """Six game sounds on the first six pads, at middle C. K1 level"""
    parts, extra, wires = [], [], []
    extra.append(node("pads", "NoteTriggers", {"base": CONTROLLER["pads_base"], "shift": 0}))
    feeds = []
    for lane, (rel, prefix) in enumerate(GAME_PADS, start=1):
        part = Part(load(rel), prefix)
        inputs = [n for n in part.nodes if n["type"] == "Input" and n.get("host") == "note"]
        for inp in inputs:
            short = inp["id"][len(prefix) + 1:]
            # The pad is the trigger; the pitch is middle C; velocity is full.
            part.rewire_source(short, "trigger", f"pads.t{lane}")
            part.rewire_source(short, "gate", f"pads.t{lane}")
            pitch_id = f"{prefix}_pitch"
            part.nodes.append(node(pitch_id, "Constant", {"value": C4}, y=lane * 300))
            part.rewire_source(short, "frequency", f"{pitch_id}.out")
            vel_id = f"{prefix}_vel"
            part.nodes.append(node(vel_id, "Constant", {"value": 1.0}, y=lane * 300 + 100))
            part.rewire_source(short, "velocity", f"{vel_id}.out")
            part.drop(short)
        # Unused constants would be an error nowhere, but a tidy patch drops them.
        used = {c["from"]["node"] for c in part.connections}
        part.nodes = [n for n in part.nodes
                      if n["type"] != "Constant" or n["id"] in used]
        parts.append(part)
        feeds.append(part.feeds[0])
    # No echo here: eight sound effects already fill the board's close memory.
    sum_nodes, sum_wires, out = summed(feeds, "mix")
    return assemble("Game pads", parts, extra + sum_nodes, wires + sum_wires, out,
                    level_knob=1)


def kit_alone():
    """The kit on the pads and nothing else. K1 level  K2 echo time  K3 echo feedback  K4 echo level"""
    kit = drum_kit("d")
    echo_nodes, echo_wires, wet = echo("fx", kit.feeds[0], 2, 3, 4)
    sum_nodes, sum_wires, out = summed([kit.feeds[0], wet], "final", x=2800)
    return assemble("Drum pads", [kit], echo_nodes + sum_nodes, echo_wires + sum_wires,
                    out, level_knob=1)


def preset_with_pads(rel, name, kit_lanes):
    """A DX7 or FM preset on the keys with a filter, an echo and the kit.
    K1 cutoff  K2 resonance  K3 level  K4 wobble rate
    K5 echo time  K6 echo feedback  K7 echo level  K8 drums level
    Stick up: pitch bend, two semitones. Stick left/right: volume, quieter to louder."""
    voice = Part(load(rel), "v")
    extra, wires = [], []
    # ---- the stick ----------------------------------------------------------------
    # The preset's operators live inside a module, so the pitch goes in as a ratio on
    # the note's frequency: 1 at rest, 2^(2/12) with the stick pushed.
    extra += stick("v")
    extra.append(knob_cc("v_pitch_ratio", CONTROLLER["stick_pitch_cc"], 1.0,
                         2.0 ** PITCH_RANGE_OCTAVES, 0.0, glide=5.0, x=0, y=1900))
    extra.append(node("v_bent", "Multiply", {"factor": 1.0}, x=300, y=1900))
    note_inputs = [n["id"] for n in voice.nodes if n["type"] == "Input" and n.get("host") == "note"]
    for inp in note_inputs:
        redirect_sources(voice.connections, f"{inp}.frequency", "v_bent.out")
        wires.append(wire(f"{inp}.frequency", "v_bent.a"))
    wires.append(wire("v_pitch_ratio.out", "v_bent.b"))
    extra += [
        node("v_filter", "StateVariableFilter", {"cutoff": 2000.0, "resonance": 0.2, "mode": 0}, x=1500, y=0),
        # -4..+2.5 octaves around 2 kHz: 125 Hz to 11 kHz, resting wide open.
        knob("v_cutoff", 1, -4.0, 2.5, 1.0, x=1200, y=200),
        knob("v_resonance", 2, 0.0, 0.85, 0.2 / 0.85, x=1200, y=350),
        node("v_wobble", "LFO", {"rate": 0.5, "shape": 0, "amount": 0.3, "offset": 0.0}, x=1200, y=500),
        knob("v_wobble_rate", 4, 0.0, 8.0, 0.0, x=900, y=500),
        node("v_level", "Gain", {"gain": 0.8}, x=1800, y=0),
        knob("v_level_knob", 3, 0.0, 1.0, 0.8, x=1500, y=200),
    ]
    extra.append(node("v_cm_sum", "Add", x=1350, y=400))  # knob + wobble, one wire in
    wires += [wire(voice.feeds[0], "v_filter.in"), wire("v_cutoff.out", "v_cm_sum.a"),
              wire("v_wobble.out", "v_cm_sum.b"), wire("v_cm_sum.out", "v_filter.cutoff_mod"),
              wire("v_resonance.out", "v_filter.resonance"), wire("v_wobble_rate.out", "v_wobble.rate"),
              wire("v_filter.out", "v_level.in"),
              wire("v_level_knob.out", "v_level.gain")]
    echo_nodes, echo_wires, wet = echo("v", "v_level.out", 5, 6, 7)
    feeds = ["v_level.out", wet]
    parts = [voice]
    if kit_lanes > 0:
        kit = drum_kit("d", lanes=kit_lanes)
        extra.append(node("d_level", "Gain", {"gain": 0.7}, x=1800, y=1200))
        extra.append(knob("d_level_knob", 8, 0.0, 1.0, 0.7, x=1500, y=1400))
        wires += [wire(kit.feeds[0], "d_level.in"), wire("d_level_knob.out", "d_level.gain")]
        feeds.append("d_level.out")
        parts.append(kit)
    sum_nodes, sum_wires, mixed = summed(feeds, "mix")
    vol_nodes, vol_wires, out = volume_stage("v", mixed)
    return assemble(name, parts, extra + echo_nodes + sum_nodes + vol_nodes,
                    wires + echo_wires + sum_wires + vol_wires, out)


# ---- the set ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--kit-lanes", type=int, default=4,
                        help="drums on the pads beside a DX7/FM preset: 0 for none, 8 for the whole kit")
    parser.add_argument("--only", default=None, help="write just this entry (for a size probe)")
    parser.add_argument("--poly-kit-lanes", type=int, default=2,
                        help="drums beside Poly Five: it is the fullest patch and the closest to the 44 KB window")
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    entries = []

    def emit(entry_name, patch):
        if args.only and entry_name != args.only:
            return
        (OUT / f"{entry_name}.json").write_text(json.dumps(patch, indent=2) + "\n", encoding="utf-8")
        entries.append({"name": entry_name, "patch": f"axoloti-akai-mpk-mini/{entry_name}.json"})

    emit("poly5-pads", poly5_pads(args.poly_kit_lanes))
    emit("game-pads", game_pads())
    emit("drum-pads", kit_alone())
    for family in ("dx7", "fm"):
        for path in sorted((EXAMPLES / family).glob("*.json")):
            entry = f"{family}-{path.stem}"
            emit(entry, preset_with_pads(f"{family}/{path.name}", f"{family.upper()} {path.stem}",
                                         args.kit_lanes))

    if args.only:
        print(f"wrote {OUT / (args.only + '.json')}")
        return
    bank = {
        "schema_version": 1,
        "name": "Axoloti + Akai MPK mini",
        "target": "axoloti",
        "controller": CONTROLLER["name"],
        "program_change": "prev-next",
        "entries": entries,
    }
    BANK.write_text(json.dumps(bank, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} patches into {OUT} and {BANK}")


if __name__ == "__main__":
    main()
