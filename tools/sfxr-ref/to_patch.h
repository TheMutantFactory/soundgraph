// sfxr parameters -> a SoundGraph patch. See to_patch.cpp for every conversion and its
// derivation.
#ifndef SOUNDGRAPH_SFXR_TO_PATCH_H
#define SOUNDGRAPH_SFXR_TO_PATCH_H

#include <string>

#include "sfxr_reference.h"

namespace sfxr_map {

// Returns the patch as JSON text, ready to hand to sg-render.
std::string to_patch(const sfxr_reference::Params& params, const std::string& name);

// The conversions themselves, for to_shelf.cpp, which builds a patch out of several
// parameter sets and must not restate any of this arithmetic. Each is derived and
// explained where it is defined.
double base_frequency_hz(const sfxr_reference::Params& p);
double transpose_semitones(const sfxr_reference::Params& p);
double limit_frequency_hz(const sfxr_reference::Params& p);
double slide_semitones_per_second(const sfxr_reference::Params& p);
double slide_acceleration(const sfxr_reference::Params& p);
double pulse_width(const sfxr_reference::Params& p);
double pulse_width_sweep(const sfxr_reference::Params& p);
double envelope_seconds(float stage);
bool lowpass_active(const sfxr_reference::Params& p);
double lowpass_cutoff_hz(const sfxr_reference::Params& p);
double lowpass_resonance(const sfxr_reference::Params& p);
double lowpass_sweep_octaves_per_second(const sfxr_reference::Params& p);
bool highpass_active(const sfxr_reference::Params& p);
double highpass_cutoff_hz(const sfxr_reference::Params& p);
double highpass_sweep_octaves_per_second(const sfxr_reference::Params& p);
double phaser_offset_ms(const sfxr_reference::Params& p);
double phaser_sweep_ms_per_second(const sfxr_reference::Params& p);
bool vibrato_active(const sfxr_reference::Params& p);
double vibrato_rate_hz(const sfxr_reference::Params& p);
double vibrato_octaves(const sfxr_reference::Params& p);
bool arpeggio_active(const sfxr_reference::Params& p);
double arpeggio_time_seconds(const sfxr_reference::Params& p);
double arpeggio_interval_semitones(const sfxr_reference::Params& p);
bool repeat_active(const sfxr_reference::Params& p);
double repeat_rate_hz(const sfxr_reference::Params& p);
double master_gain(const sfxr_reference::Params& p);
const char* oscillator_type(int wave_type);

}  // namespace sfxr_map

#endif
