#include "qoa_enc.h"
#include <algorithm>
#include <cmath>

namespace qoa {

static const int kQuant[17] = {7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6};
static const int kScale[16] = {1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048};
static const double kDq[8] = {0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7.0, -7.0};

struct Lms { int h[4]; int w[4]; };

static int recip(int s) { return ((1 << 16) + kScale[s] - 1) / kScale[s]; }
static int dequant(int s, int q) { return static_cast<int>(std::lround(kScale[s] * kDq[q])); }
static int qdiv(int v, int s) {
    const int r = recip(s);
    int n = static_cast<int>((static_cast<int64_t>(v) * r + (1 << 15)) >> 16);
    n = n + ((v > 0) - (v < 0)) - ((n > 0) - (n < 0));
    return n;
}
static int predict(const Lms& l) {
    int64_t p = 0;
    for (int i = 0; i < 4; ++i) p += static_cast<int64_t>(l.w[i]) * l.h[i];
    return static_cast<int>(p >> 13);
}
static void update(Lms& l, int sample, int residual) {
    const int d = residual >> 4;
    for (int i = 0; i < 4; ++i) l.w[i] += l.h[i] < 0 ? -d : d;
    l.h[0] = l.h[1]; l.h[1] = l.h[2]; l.h[2] = l.h[3]; l.h[3] = sample;
}
static int clamp16(int v) { return v < -32768 ? -32768 : (v > 32767 ? 32767 : v); }
static void put64(std::vector<uint8_t>& o, uint64_t v) { for (int i = 7; i >= 0; --i) o.push_back(static_cast<uint8_t>(v >> (i * 8))); }

std::vector<uint8_t> encode(const std::vector<int16_t>& pcm, int ch, int rate) {
    const uint32_t total = static_cast<uint32_t>(pcm.size() / ch);
    std::vector<uint8_t> out;
    out.insert(out.end(), {'q', 'o', 'a', 'f'});
    for (int i = 3; i >= 0; --i) out.push_back(static_cast<uint8_t>(total >> (i * 8)));
    std::vector<Lms> lms(ch);
    for (auto& l : lms) { l = {{0, 0, 0, 0}, {0, 0, -(1 << 13), 1 << 14}}; }
    std::vector<int> prev_sf(ch, 0);
    for (uint32_t f0 = 0; f0 < total; f0 += 5120) {
        const uint32_t fl = std::min<uint32_t>(5120, total - f0);
        const uint32_t slices = (fl + 19) / 20;
        const uint32_t fsize = 8 + 16 * ch + 8 * slices * ch;
        put64(out, (static_cast<uint64_t>(ch) << 56) | (static_cast<uint64_t>(rate) << 32) | (static_cast<uint64_t>(fl) << 16) | fsize);
        for (int c = 0; c < ch; ++c) {
            uint64_t h = 0, w = 0;
            for (int i = 0; i < 4; ++i) {
                h = (h << 16) | static_cast<uint16_t>(lms[c].h[i]);
                w = (w << 16) | static_cast<uint16_t>(lms[c].w[i]);
            }
            put64(out, h); put64(out, w);
        }
        for (uint32_t s0 = 0; s0 < fl; s0 += 20) {
            const uint32_t sl = std::min<uint32_t>(20, fl - s0);
            for (int c = 0; c < ch; ++c) {
                uint64_t best_err = UINT64_MAX, best_slice = 0;
                Lms best_lms = lms[c];
                int best_sf = 0;
                for (int k = 0; k < 16; ++k) {
                    const int sf = (prev_sf[c] + k) % 16;
                    Lms l = lms[c];
                    uint64_t slice = static_cast<uint64_t>(sf), err = 0;
                    for (uint32_t i = 0; i < sl; ++i) {
                        const int smp = pcm[(f0 + s0 + i) * ch + c];
                        const int pr = predict(l);
                        const int res = smp - pr;
                        const int sc = std::clamp(qdiv(res, sf), -8, 8);
                        const int q = kQuant[sc + 8];
                        const int dq = dequant(sf, q);
                        const int rec = clamp16(pr + dq);
                        const int64_t e = smp - rec;
                        err += static_cast<uint64_t>(e * e);
                        if (err > best_err) break;
                        update(l, rec, dq);
                        slice = (slice << 3) | static_cast<uint64_t>(q);
                    }
                    if (err < best_err) { best_err = err; best_slice = slice; best_lms = l; best_sf = sf; }
                }
                prev_sf[c] = best_sf;
                lms[c] = best_lms;
                best_slice <<= (20 - sl) * 3;      // (a short last slice: the rest left empty)
                put64(out, best_slice);
            }
        }
    }
    return out;
}

}  // namespace qoa
