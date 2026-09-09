// One patch per sfxr generator, with six rolls of that generator as its presets.
//
// sfxr has no preset list. Each of its seven buttons resets every parameter and then
// rolls a handful within ranges of its own — a coin is a random point in a small region
// of a 24-dimensional space, and pressing the button again lands somewhere else in it.
// The corpus patches under tests/sfxr/patches are one such point each, and eight of
// them are the game sounds. This makes the region itself something a person can walk:
// one patch per generator, a knob for exactly the parameters that generator rolls, and
// the six corpus seeds as its presets, so that stepping the preset strip is pressing the
// button again.
//
// The difficulty is that to_patch.cpp builds a different *graph* for different rolls:
// the oscillator's type follows wave_type, and the arpeggio, vibrato, filters and
// repeat are only there when the roll turned them on. A preset changes values, never
// structure. So the shelf patch is the union of the six graphs, and every part a roll
// may leave out is present with a switch that takes it out of the sound exactly:
//
//   - several oscillator types feed one Mixer, and a preset sets one level to 1 and the
//     rest to 0. `out += in * level` with those levels is the chosen wave, bit for bit.
//   - a filter some rolls skip sits beside a Mixer of its dry and wet paths, with a
//     Dry knob and a Wet knob. On is 0/1, off is 1/0, and the arithmetic is the same.
//   - the arpeggio's interval is 0 when a roll has none: pow(2, 0) is exactly 1.
//   - the vibrato's depth is 0 when a roll has none: pow(2, 0) again.
//   - the repeat's gate goes through a Multiply whose factor is the Repeat knob, and is
//     Added to the key's own trigger. At 0 the sum is the trigger itself; at 1 both
//     pulse at frame zero — the same single rising edge — and only the repeat after.
//
// Which is why tools/sfxr-shelf-check.mjs can ask for more than "close": every preset
// of every shelf patch must render sample for sample as the corpus patch it came from.
//
// Every number here comes from the conversions in to_patch.cpp, called rather than
// restated, so there is one mapping from sfxr's units to the vocabulary's and not two.
#include "to_shelf.h"

#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "to_patch.h"

namespace sfxr_map {
namespace {

std::string number(double value) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.6g", value);
    return buffer;
}

// The same grid to_patch.cpp lays its nodes on, and for the same reason: a file with no
// coordinates opens as a heap in anything without a layout engine.
constexpr double kColumnPitch = 560.0;
constexpr double kRowStep = 360.0;

struct Node {
    std::string id;
    std::string type;
    std::vector<std::pair<std::string, double>> parameters;
    int column = 0;
    int lane = 0;
    std::string host;
};

struct Connection {
    std::string from_node, from_port, to_node, to_port;
};

// What a knob is called and how far it turns. The ranges are curated to the region sfxr
// itself reaches rather than to the node's whole span, so a knob's sweep is the
// generator's; they widen to hold any preset value that falls outside.
struct Curation {
    const char* key;      // "node.parameter"
    const char* id;
    const char* label;
    const char* group;
    double min, max;
    const char* scaling;
};

const Curation kCurations[] = {
    {"trigger.transpose", "pitch", "Pitch", "Pitch", -48.0, 48.0, "linear"},
    {"slide.slide", "slide", "Slide", "Pitch", -2000.0, 2000.0, "linear"},
    {"slide.limit", "limit", "Limit", "Pitch", 3.0, 5000.0, "exponential"},
    {"wave.level1", "", "", "Wave", 0.0, 1.0, "linear"},
    {"wave.level2", "", "", "Wave", 0.0, 1.0, "linear"},
    {"wave.level3", "", "", "Wave", 0.0, 1.0, "linear"},
    {"wave.level4", "", "", "Wave", 0.0, 1.0, "linear"},
    {"osc.pulse_width", "pulse_width", "Pulse Width", "Wave", 0.01, 0.99, "linear"},
    {"osc.pulse_width_sweep", "pulse_sweep", "Pulse Sweep", "Wave", -4.0, 4.0, "linear"},
    {"osc_square.pulse_width", "pulse_width", "Pulse Width", "Wave", 0.01, 0.99, "linear"},
    {"osc_square.pulse_width_sweep", "pulse_sweep", "Pulse Sweep", "Wave", -4.0, 4.0,
     "linear"},
    {"arpeggio.time", "arp_time", "Arpeggio Time", "Arpeggio", 0.0, 0.5, "linear"},
    {"arpeggio.interval", "arp_jump", "Arpeggio Jump", "Arpeggio", -48.0, 48.0, "linear"},
    {"vibrato.rate", "vibrato_rate", "Vibrato Rate", "Vibrato", 0.1, 100.0, "exponential"},
    {"vibrato.amount", "vibrato_depth", "Vibrato Depth", "Vibrato", 0.0, 1.0, "linear"},
    {"lowpass.cutoff", "lowpass", "Lowpass", "Lowpass", 20.0, 20000.0, "exponential"},
    {"lowpass.resonance", "resonance", "Resonance", "Lowpass", 0.0, 1.0, "linear"},
    {"lowpass.cutoff_sweep", "lowpass_sweep", "Lowpass Sweep", "Lowpass", -20.0, 20.0,
     "linear"},
    {"lowpass_mix.level1", "lowpass_dry", "Dry", "Lowpass", 0.0, 1.0, "linear"},
    {"lowpass_mix.level2", "lowpass_wet", "Wet", "Lowpass", 0.0, 1.0, "linear"},
    {"highpass.cutoff", "highpass", "Highpass", "Highpass", 1.0, 20000.0, "exponential"},
    {"highpass.cutoff_sweep", "highpass_sweep", "Highpass Sweep", "Highpass", -20.0, 20.0,
     "linear"},
    {"highpass_mix.level1", "highpass_dry", "Dry", "Highpass", 0.0, 1.0, "linear"},
    {"highpass_mix.level2", "highpass_wet", "Wet", "Highpass", 0.0, 1.0, "linear"},
    {"phaser.offset", "phaser", "Phaser", "Phaser", 0.0, 24.0, "linear"},
    {"phaser.sweep", "phaser_sweep", "Phaser Sweep", "Phaser", -240.0, 240.0, "linear"},
    {"envelope.attack", "attack", "Attack", "Envelope", 0.0, 1.0, "linear"},
    {"envelope.hold", "hold", "Hold", "Envelope", 0.0, 1.0, "linear"},
    {"envelope.decay", "decay", "Decay", "Envelope", 0.0, 2.0, "linear"},
    {"envelope.punch", "punch", "Punch", "Envelope", 0.0, 1.0, "linear"},
    {"repeat.rate", "repeat_rate", "Repeat Rate", "Repeat", 1.0, 200.0, "exponential"},
    {"repeat_on.factor", "repeat", "Repeat", "Repeat", 0.0, 1.0, "linear"},
    {"amp.gain", "level", "Level", "Level", 0.0, 0.1, "linear"},
};

const Curation* curation_for(const std::string& key) {
    for (const Curation& curation : kCurations) {
        if (key == curation.key) return &curation;
    }
    return nullptr;
}

// The oscillator types in the order the Wave mixer's channels take them.
const char* const kWaveNames[] = {"square", "saw", "sine", "noise"};
const char* const kWaveLabels[] = {"Square", "Saw", "Sine", "Noise"};

struct Shape {
    std::set<int> waves;
    bool arpeggio = false;   // any roll has one
    bool vibrato = false;
    bool lowpass_any = false, lowpass_all = true;
    bool highpass_any = false, highpass_all = true;
    bool repeat_any = false, repeat_all = true;
};

Shape shape_of(const std::vector<ShelfSeed>& seeds) {
    Shape shape;
    for (const ShelfSeed& seed : seeds) {
        const sfxr_reference::Params& p = seed.params;
        shape.waves.insert(p.wave_type < 0 || p.wave_type > 3 ? 3 : p.wave_type);
        shape.arpeggio = shape.arpeggio || arpeggio_active(p);
        shape.vibrato = shape.vibrato || vibrato_active(p);
        shape.lowpass_any = shape.lowpass_any || lowpass_active(p);
        shape.lowpass_all = shape.lowpass_all && lowpass_active(p);
        shape.highpass_any = shape.highpass_any || highpass_active(p);
        shape.highpass_all = shape.highpass_all && highpass_active(p);
        shape.repeat_any = shape.repeat_any || repeat_active(p);
        shape.repeat_all = shape.repeat_all && repeat_active(p);
    }
    return shape;
}

// Every parameter of the union graph, valued for one roll. Keys are "node.parameter".
// Anything a roll leaves out is valued so that it does nothing — see the top of the file.
std::map<std::string, double> values_for(const sfxr_reference::Params& p, const Shape& shape) {
    std::map<std::string, double> values;
    values["trigger.transpose"] = transpose_semitones(p);
    values["slide.slide"] = slide_semitones_per_second(p);
    values["slide.acceleration"] = slide_acceleration(p);
    values["slide.limit"] = limit_frequency_hz(p);
    if (shape.arpeggio) {
        values["arpeggio.time"] = arpeggio_time_seconds(p);
        values["arpeggio.interval"] = arpeggio_active(p) ? arpeggio_interval_semitones(p) : 0.0;
    }
    const int wave = p.wave_type < 0 || p.wave_type > 3 ? 3 : p.wave_type;
    const bool one_wave = shape.waves.size() == 1;
    if (shape.waves.count(0)) {
        const std::string osc = one_wave ? "osc" : "osc_square";
        values[osc + ".pulse_width"] = pulse_width(p);
        values[osc + ".pulse_width_sweep"] = pulse_width_sweep(p);
    }
    if (shape.waves.count(3)) {
        const std::string osc = one_wave ? "osc" : "osc_noise";
        values[osc + ".steps"] = 32.0;
        values[osc + ".seed"] = 12345.0;
    }
    if (!one_wave) {
        int channel = 1;
        for (int type = 0; type < 4; ++type) {
            if (!shape.waves.count(type)) continue;
            values["wave.level" + std::to_string(channel)] = type == wave ? 1.0 : 0.0;
            ++channel;
        }
    }
    if (shape.vibrato) {
        const double rate = vibrato_rate_hz(p);
        values["vibrato.rate"] = vibrato_active(p) && rate >= 0.1 ? rate : 1.0;
        values["vibrato.shape"] = 0.0;
        values["vibrato.amount"] = vibrato_active(p) ? vibrato_octaves(p) : 0.0;
        values["vibrato.offset"] = 0.0;
    }
    if (shape.lowpass_any) {
        const bool on = lowpass_active(p);
        values["lowpass.cutoff"] = on ? lowpass_cutoff_hz(p) : 20000.0;
        values["lowpass.resonance"] = on ? lowpass_resonance(p) : 0.0;
        values["lowpass.mode"] = 0.0;
        values["lowpass.cutoff_sweep"] = on ? lowpass_sweep_octaves_per_second(p) : 0.0;
        if (!shape.lowpass_all) {
            values["lowpass_mix.level1"] = on ? 0.0 : 1.0;
            values["lowpass_mix.level2"] = on ? 1.0 : 0.0;
        }
    }
    if (shape.highpass_any) {
        const bool on = highpass_active(p);
        values["highpass.cutoff"] = on ? highpass_cutoff_hz(p) : 1.0;
        values["highpass.mode"] = 1.0;
        values["highpass.cutoff_sweep"] = on ? highpass_sweep_octaves_per_second(p) : 0.0;
        if (!shape.highpass_all) {
            values["highpass_mix.level1"] = on ? 0.0 : 1.0;
            values["highpass_mix.level2"] = on ? 1.0 : 0.0;
        }
    }
    values["phaser.offset"] = phaser_offset_ms(p);
    values["phaser.sweep"] = phaser_sweep_ms_per_second(p);
    values["phaser.depth"] = 1.0;
    values["envelope.attack"] = envelope_seconds(p.p_env_attack);
    values["envelope.hold"] = envelope_seconds(p.p_env_sustain);
    values["envelope.decay"] = envelope_seconds(p.p_env_decay);
    values["envelope.punch"] = static_cast<double>(p.p_env_punch);
    values["amp.gain"] = master_gain(p);
    if (shape.repeat_any) {
        values["repeat.rate"] = repeat_rate_hz(p);
        values["repeat.width"] = 1.0;
        if (!shape.repeat_all) values["repeat_on.factor"] = repeat_active(p) ? 1.0 : 0.0;
    }
    return values;
}

// The nodes and wires of the union graph. Parameter values are filled in afterwards
// from the first roll; here only the structure.
void build_graph(const Shape& shape, double fallback_frequency, std::vector<Node>& nodes,
                 std::vector<Connection>& connections) {
    int column = 0;

    // --- pitch chain: slide, then the arpeggio when any roll has one ----------------
    nodes.push_back({"slide", "Slide", {{"frequency", fallback_frequency}}, column++, 0});
    std::string pitch_source = "slide";
    if (shape.arpeggio) {
        nodes.push_back({"arpeggio", "Arpeggio", {{"frequency", fallback_frequency}},
                         column++, 0});
        connections.push_back({"slide", "frequency", "arpeggio", "frequency"});
        pitch_source = "arpeggio";
    }

    // --- oscillators: one, or one per type into a Mixer ------------------------------
    const bool one_wave = shape.waves.size() == 1;
    const int oscillator_column = column++;
    std::string signal;
    if (one_wave) {
        nodes.push_back({"osc", oscillator_type(*shape.waves.begin()), {}, oscillator_column, 0});
        connections.push_back({pitch_source, "frequency", "osc", "frequency"});
        signal = "osc";
    } else {
        int lane = 0;
        int channel = 1;
        std::vector<Connection> into_mixer;
        for (int type = 0; type < 4; ++type) {
            if (!shape.waves.count(type)) continue;
            const std::string id = std::string("osc_") + kWaveNames[type];
            nodes.push_back({id, oscillator_type(type), {}, oscillator_column, lane++});
            connections.push_back({pitch_source, "frequency", id, "frequency"});
            into_mixer.push_back({id, "out", "wave", "in" + std::to_string(channel++)});
        }
        nodes.push_back({"wave", "Mixer", {}, column++, 0});
        for (const Connection& wire : into_mixer) connections.push_back(wire);
        signal = "wave";
    }
    if (shape.vibrato) {
        nodes.push_back({"vibrato", "LFO", {}, oscillator_column - 1, -1});
        if (one_wave) {
            connections.push_back({"vibrato", "out", "osc", "fm"});
        } else {
            for (int type = 0; type < 4; ++type) {
                if (!shape.waves.count(type)) continue;
                connections.push_back({"vibrato", "out", std::string("osc_") + kWaveNames[type],
                                       "fm"});
            }
        }
    }

    // --- filters, in sfxr's order, each with a dry/wet Mixer when some roll skips it --
    if (shape.lowpass_any) {
        nodes.push_back({"lowpass", "StateVariableFilter", {}, column++, 0});
        connections.push_back({signal, "out", "lowpass", "in"});
        if (shape.lowpass_all) {
            signal = "lowpass";
        } else {
            nodes.push_back({"lowpass_mix", "Mixer", {}, column++, 0});
            connections.push_back({signal, "out", "lowpass_mix", "in1"});
            connections.push_back({"lowpass", "out", "lowpass_mix", "in2"});
            signal = "lowpass_mix";
        }
    }
    if (shape.highpass_any) {
        nodes.push_back({"highpass", "OnePoleFilter", {}, column++, 0});
        connections.push_back({signal, "out", "highpass", "in"});
        if (shape.highpass_all) {
            signal = "highpass";
        } else {
            nodes.push_back({"highpass_mix", "Mixer", {}, column++, 0});
            connections.push_back({signal, "out", "highpass_mix", "in1"});
            connections.push_back({"highpass", "out", "highpass_mix", "in2"});
            signal = "highpass_mix";
        }
    }
    nodes.push_back({"phaser", "Phaser", {}, column++, 0});
    connections.push_back({signal, "out", "phaser", "in"});
    signal = "phaser";

    // --- the key, the envelope, the amplifier -----------------------------------------
    Node keyboard{"trigger", "Input", {}, 0, 1};
    keyboard.host = "note";
    nodes.push_back(keyboard);
    connections.push_back({"trigger", "frequency", "slide", "frequency"});
    nodes.push_back({"envelope", "AhdEnvelope", {}, column - 1, 1});
    connections.push_back({"trigger", "trigger", "envelope", "gate"});
    nodes.push_back({"amp", "Gain", {}, column++, 0});
    connections.push_back({signal, "out", "amp", "in"});
    connections.push_back({"envelope", "out", "amp", "gain"});

    // --- restarting the pitch chain: the key, the repeat, or a switch between --------
    std::string restart_from = "trigger";
    std::string restart_port = "trigger";
    if (shape.repeat_any) {
        nodes.push_back({"repeat", "Retrigger", {}, 0, -1});
        if (shape.repeat_all) {
            restart_from = "repeat";
            restart_port = "gate";
        } else {
            nodes.push_back({"repeat_on", "Multiply", {}, 1, -1});
            nodes.push_back({"restart", "Add", {}, 1, -2});
            connections.push_back({"repeat", "gate", "repeat_on", "a"});
            connections.push_back({"trigger", "trigger", "restart", "a"});
            connections.push_back({"repeat_on", "out", "restart", "b"});
            restart_from = "restart";
            restart_port = "out";
        }
    }
    connections.push_back({restart_from, restart_port, "slide", "gate"});
    if (shape.arpeggio) connections.push_back({restart_from, restart_port, "arpeggio", "gate"});

    Node output{"out", "Output", {{"level", 1.0}, {"safety_limit", 0.0}}, column++, 0};
    output.host = "stereo";
    nodes.push_back(output);
    connections.push_back({"amp", "out", "out", "left"});
    connections.push_back({"amp", "out", "out", "right"});
}

std::string wave_label_for(const Shape& shape, const std::string& key, std::string& id) {
    // "wave.levelN" names the Nth present type.
    const int channel = key.back() - '0';
    int seen = 0;
    for (int type = 0; type < 4; ++type) {
        if (!shape.waves.count(type)) continue;
        if (++seen == channel) {
            id = std::string("wave_") + kWaveNames[type];
            return kWaveLabels[type];
        }
    }
    id = "wave";
    return "Wave";
}

}  // namespace

std::string to_shelf(const std::string& preset_name, const std::vector<ShelfSeed>& seeds) {
    const Shape shape = shape_of(seeds);
    std::vector<std::map<std::string, double>> rolls;
    for (const ShelfSeed& seed : seeds) rolls.push_back(values_for(seed.params, shape));

    std::vector<Node> nodes;
    std::vector<Connection> connections;
    build_graph(shape, base_frequency_hz(seeds.front().params), nodes, connections);

    // Every parameter takes the first roll's value; the ones the rolls disagree on
    // become knobs, in the curation table's order so the panel reads in signal order.
    for (Node& node : nodes) {
        for (const auto& entry : rolls.front()) {
            const std::string& key = entry.first;
            if (key.compare(0, node.id.size() + 1, node.id + ".") != 0) continue;
            node.parameters.push_back({key.substr(node.id.size() + 1), entry.second});
        }
    }
    struct Knob {
        const Curation* curation;
        std::string key, id, label;
        double min, max;
        std::string scaling;
    };
    std::vector<Knob> knobs;
    for (const Curation& curation : kCurations) {
        const std::string key = curation.key;
        if (!rolls.front().count(key)) continue;
        bool varies = false;
        for (const auto& roll : rolls) {
            if (number(roll.at(key)) != number(rolls.front().at(key))) varies = true;
        }
        if (!varies) continue;
        Knob knob{&curation, key, curation.id, curation.label, curation.min, curation.max,
                  curation.scaling};
        if (key.compare(0, 5, "wave.") == 0) knob.label = wave_label_for(shape, key, knob.id);
        for (const auto& roll : rolls) {
            const double value = roll.at(key);
            if (value < knob.min) knob.min = value;
            if (value > knob.max) knob.max = value;
        }
        if (knob.scaling == "exponential" && knob.min <= 0.0) knob.scaling = "linear";
        knobs.push_back(knob);
    }

    // --- serialise --------------------------------------------------------------------
    std::string json;
    json += "{\n  \"schema_version\": 1,\n";
    json += "  \"metadata\": {\n";
    json += "    \"name\": \"" + preset_name + "\",\n";
    json += "    \"description\": \"sfxr's " + preset_name + " generator as one patch: a knob "
            "for every parameter it rolls, and " + std::to_string(seeds.size()) +
            " of its rolls as presets. Generated by sfxr-ref shelf. Do not edit by hand.\",\n";
    json += "    \"tags\": [\"sfxr\", \"shelf\"]\n  },\n";

    json += "  \"nodes\": [\n";
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        json += "    {\n      \"id\": \"" + nodes[i].id + "\",\n";
        json += "      \"type\": \"" + nodes[i].type + "\",\n";
        if (!nodes[i].host.empty()) json += "      \"host\": \"" + nodes[i].host + "\",\n";
        json += "      \"position\": {\"x\": " + number(nodes[i].column * kColumnPitch) +
                ", \"y\": " + number(nodes[i].lane * kRowStep) + "}";
        if (!nodes[i].parameters.empty()) {
            json += ",\n      \"parameters\": {\n";
            for (std::size_t k = 0; k < nodes[i].parameters.size(); ++k) {
                json += "        \"" + nodes[i].parameters[k].first + "\": " +
                        number(nodes[i].parameters[k].second);
                json += k + 1 < nodes[i].parameters.size() ? ",\n" : "\n";
            }
            json += "      }";
        }
        json += "\n    }";
        json += i + 1 < nodes.size() ? ",\n" : "\n";
    }
    json += "  ],\n";

    json += "  \"connections\": [\n";
    for (std::size_t i = 0; i < connections.size(); ++i) {
        json += "    {\n";
        json += "      \"from\": {\"node\": \"" + connections[i].from_node + "\", \"port\": \"" +
                connections[i].from_port + "\"},\n";
        json += "      \"to\": {\"node\": \"" + connections[i].to_node + "\", \"port\": \"" +
                connections[i].to_port + "\"}\n";
        json += "    }";
        json += i + 1 < connections.size() ? ",\n" : "\n";
    }
    json += "  ],\n";

    json += "  \"controls\": [\n";
    for (std::size_t i = 0; i < knobs.size(); ++i) {
        const Knob& knob = knobs[i];
        const std::string node = knob.key.substr(0, knob.key.find('.'));
        const std::string parameter = knob.key.substr(knob.key.find('.') + 1);
        json += "    {\"id\": \"" + knob.id + "\", \"label\": \"" + knob.label +
                "\", \"group\": \"" + knob.curation->group + "\", \"kind\": \"knob\",\n";
        json += "     \"target\": {\"node\": \"" + node + "\", \"parameter\": \"" + parameter +
                "\"},\n";
        json += "     \"min\": " + number(knob.min) + ", \"max\": " + number(knob.max) +
                ", \"default\": " + number(rolls.front().at(knob.key)) + ", \"scaling\": \"" +
                knob.scaling + "\"}";
        json += i + 1 < knobs.size() ? ",\n" : "\n";
    }
    json += "  ],\n";

    json += "  \"presets\": [\n";
    for (std::size_t s = 0; s < seeds.size(); ++s) {
        json += "    {\"name\": \"" + seeds[s].name + "\", \"tags\": [\"seed:" +
                std::to_string(seeds[s].seed) + "\"" + (s == 0 ? ", \"default\"" : "") +
                "],\n     \"values\": {";
        for (std::size_t i = 0; i < knobs.size(); ++i) {
            json += "\"" + knobs[i].id + "\": " + number(rolls[s].at(knobs[i].key));
            json += i + 1 < knobs.size() ? ", " : "";
        }
        json += "}}";
        json += s + 1 < seeds.size() ? ",\n" : "\n";
    }
    json += "  ]\n}\n";
    return json;
}

}  // namespace sfxr_map
