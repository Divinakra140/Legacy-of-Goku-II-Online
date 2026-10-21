// QOA ("Quite OK Audio") encoder: the small lossy audio format Godot plays (AudioStreamWAV, FORMAT_QOA).
// Written from the format's description (qoaformat.org): 20-sample slices, a 4-tap LMS predictor per channel,
// a 4-bit scale factor and 3-bit residuals per sample. Interleaved 16-bit samples in, a .qoa file out.
#pragma once
#include <cstdint>
#include <vector>

namespace qoa {
std::vector<uint8_t> encode(const std::vector<int16_t>& interleaved, int channels, int samplerate);
}
