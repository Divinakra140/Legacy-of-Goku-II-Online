#include "gba_music.h"
#include "gba_cpu.h"
#include "qoa_enc.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace gbamusic {

// where the game keeps its sound engine (Dragon Ball Z - The Legacy of Goku II, USA)
constexpr uint32_t kMain = 0x08000158u;        // the game's main (the boot code has copied the mixer to fast RAM by then)
constexpr uint32_t kSound = 0x030026BCu;        // the sound engine's object
constexpr uint32_t kMusic = 0x030026C8u;        // its music player
constexpr uint32_t kInit = 0x08020AF5u, kPlay = 0x08020A4Du, kFrame = 0x08020BD9u;   // (Thumb)
constexpr uint32_t kTable = 0x081D4B2Cu;        // the song table: 20 bytes a song
constexpr uint32_t kPlayed = kSound + 4, kMixed = kSound + 8;   // samples played (moved on by a timer) / mixed
constexpr int kRate = 15978;                    // the timer: 1050 cycles a sample
constexpr double kPerFrame = 280896.0 / 1050.0; // samples in one 60 Hz picture
constexpr int kMaxFrames = 60 * 300, kStateLen = 0x200;

struct Render {
    std::vector<int16_t> pcm;                   // stereo, interleaved
    std::vector<uint32_t> at;                   // the first sample of each frame
    std::vector<std::vector<uint8_t>> state;    // the music player each frame
};

static void write_text(const std::string& path, const std::string& s) {
    if (FILE* f = std::fopen(path.c_str(), "wb")) { std::fwrite(s.data(), 1, s.size(), f); std::fclose(f); }
}

// the bytes of the player that move with the song's place (not every frame): two equal sets = the same place
static std::vector<uint32_t> place_bytes(const Render& r) {
    std::vector<uint32_t> out;
    const size_t n = r.state.size();
    for (uint32_t i = 0; i < kStateLen; ++i) {
        size_t ch = 0;
        for (size_t k = 1; k < n; ++k) if (r.state[k][i] != r.state[k - 1][i]) ++ch;
        bool goes_down = false;      // a byte that only ever counts up (the times a channel went round) never repeats
        for (size_t k = 1; k < n && !goes_down; ++k) goes_down = r.state[k][i] < r.state[k - 1][i];
        if (ch >= 1 && ch * 25 < n && goes_down) out.push_back(i);
    }
    return out;
}

// the loop: the first frame whose place repeats an earlier one (at least 10 s apart) -> (earlier, length)
static bool find_loop(const Render& r, int& first, int& len) {
    const std::vector<uint32_t> pb = place_bytes(r);
    if (pb.empty()) return false;
    std::map<std::vector<uint8_t>, int> seen;
    for (size_t k = 0; k < r.state.size(); ++k) {
        std::vector<uint8_t> key;
        key.reserve(pb.size());
        for (uint32_t i : pb) key.push_back(r.state[k][i]);
        auto it = seen.find(key);
        if (it != seen.end()) {
            if (static_cast<int>(k) - it->second > 600) { first = it->second; len = static_cast<int>(k) - it->second; return true; }
        } else seen[key] = static_cast<int>(k);
    }
    return false;
}

// a song whose channels go round at different lengths never repeats every byte: its period from how loud it is
// frame by frame (the best match of the song with itself later on), made exact by the player's bytes
static bool find_loop_loose(const Render& r, int& first, int& len) {
    const int frames = static_cast<int>(r.at.size()) - 1;
    if (frames < 1800) return false;
    std::vector<double> loud(frames);
    for (int k = 0; k < frames; ++k) {
        double s = 0; size_t n = 0;
        for (uint32_t i = r.at[k] * 2; i < r.at[k + 1] * 2; ++i, ++n) s += std::abs(r.pcm[i]);
        loud[k] = n ? s / n : 0;
    }
    double mean = 0;
    for (double v : loud) mean += v;
    mean /= frames;
    for (double& v : loud) v -= mean;
    double best = 0; int lag = -1;
    for (int L = 600; L < frames - 600; ++L) {
        double ab = 0, aa = 0, bb = 0;
        for (int k = 0; k + L < frames; k += 2) { ab += loud[k] * loud[k + L]; aa += loud[k] * loud[k]; bb += loud[k + L] * loud[k + L]; }
        const double c = ab / std::sqrt(aa * bb + 1e-9);
        if (c > best) { best = c; lag = L; }
    }
    if (lag < 0 || best < 0.6) return false;
    const std::vector<uint32_t> pb = place_bytes(r);
    if (pb.empty()) return false;
    double best_m = -1; int best_l = lag;
    for (int L = lag - 150; L <= lag + 150; ++L) {
        if (L < 600 || L >= frames) continue;
        long same = 0, all = 0;
        for (int t = 60; t + L < frames; t += 5)
            for (uint32_t i : pb) { ++all; if (r.state[t][i] == r.state[t + L][i]) ++same; }
        const double m = all ? static_cast<double>(same) / all : 0;
        if (m > best_m) { best_m = m; best_l = L; }
    }
    len = best_l;
    first = 0;
    return true;
}

// where the loop really begins: the song jumps back there (a byte of the player - its place in the song's list -
// drops); the earliest such jump that happens again exactly one loop later. Without one: where the bytes first agree.
static int earliest_start(const Render& r, int first, int len) {
    const std::vector<uint32_t> pb = place_bytes(r);
    const int n = static_cast<int>(r.state.size());
    int best = first;
    for (uint32_t i : pb) {
        std::vector<char> drop(n, 0);
        for (int t = 1; t < n; ++t) drop[t] = r.state[t][i] < r.state[t - 1][i];
        for (int t = 1; t < best && t + len < n; ++t) {
            if (!drop[t]) continue;
            bool again = false;
            for (int d = -2; d <= 2 && !again; ++d) again = t + len + d < n && drop[t + len + d];
            if (again) {
                if (std::getenv("LOG2_LOOPDBG")) std::fprintf(stderr, "[music] loop start %d (byte +%03x)\n", t, i);
                best = t;
                break;
            }
        }
    }
    return best;
}

static Render render(const std::vector<uint8_t>& game, int song, bool& looped, int& loop_first, int& loop_len) {
    Render r;
    gbacpu::Machine m(game);
    looped = false;
    if (!m.boot_until(kMain) || !m.call(kInit, kSound) || !m.call(kPlay, kMusic, kTable + 20u * static_cast<uint32_t>(song))) return r;
    double acc = 0;
    uint32_t mixed = m.r32(kMixed) & 1023;
    for (int k = 0; k < kMaxFrames; ++k) {
        r.at.push_back(static_cast<uint32_t>(r.pcm.size() / 2));
        std::vector<uint8_t> st(kStateLen);
        for (int i = 0; i < kStateLen; ++i) st[i] = m.r8(kMusic + static_cast<uint32_t>(i));
        r.state.push_back(std::move(st));
        acc += kPerFrame;
        while (acc >= 16) {         // the game's timer: 16 more samples played
            acc -= 16;
            uint32_t v = m.r32(kPlayed);
            v = v >= 1024 ? 0 : v + 16;
            m.w32(kPlayed, v);
        }
        if (!m.call(kFrame, kSound, 0, 0, 0, 20000000)) break;
        const uint32_t now = m.r32(kMixed) & 1023;
        while (mixed != now) {      // the two channels the game mixes (the second runs half the ring ahead)
            r.pcm.push_back(static_cast<int16_t>(static_cast<int8_t>(m.ewram[mixed]) * 256));
            r.pcm.push_back(static_cast<int16_t>(static_cast<int8_t>(m.ewram[0x400 + ((mixed + 512) & 1023)]) * 256));
            mixed = (mixed + 1) & 1023;
        }
        // every 10 s: is the song going round already? (then a little more for the seam, and stop)
        if (!looped && k > 1200 && k % 600 == 0 && find_loop(r, loop_first, loop_len)) looped = true;
        if (looped && k >= loop_first + loop_len + 60) break;
    }
    r.at.push_back(static_cast<uint32_t>(r.pcm.size() / 2));
    looped = find_loop(r, loop_first, loop_len);       // (again on everything: the early look used fewer frames)
    if (!looped) {                                      // channels going round at different lengths
        looped = find_loop_loose(r, loop_first, loop_len);
        if (looped) loop_first = static_cast<int>(r.at.size()) - 1 - loop_len;     // (the start found below, from the jumps back)
    }
    return r;
}

int export_songs(const std::vector<uint8_t>& game, const std::string& dir, const std::vector<int>& songs) {
    std::vector<int> list = songs;
    if (list.empty()) for (int i = 0; i < kSongs; ++i) list.push_back(i);
    int done = 0;
    for (int song : list) {
        if (song < 0 || song >= kSongs) continue;
        bool looped = false;
        int first = 0, len = 0;
        Render r = render(game, song, looped, first, len);
        if (r.pcm.empty()) { std::fprintf(stderr, "[music] song %d: could not be played\n", song); continue; }
        size_t keep = r.pcm.size() / 2;
        long lb = -1, le = -1;
        if (looped) {
            const int s = earliest_start(r, first, len);
            lb = r.at[s];
            le = r.at[s + len];
            keep = static_cast<size_t>(le);
            // the seam: the loop's first moments blend from how the song sounds coming round (the last notes ringing)
            const long fade = 640;
            for (long i = 0; i < fade && le + i < static_cast<long>(r.pcm.size() / 2); ++i) {
                const double t = static_cast<double>(i) / fade;
                for (int c = 0; c < 2; ++c) {
                    const double a = r.pcm[(le + i) * 2 + c], b = r.pcm[(lb + i) * 2 + c];
                    r.pcm[(lb + i) * 2 + c] = static_cast<int16_t>(std::lround(a * (1 - t) + b * t));
                }
            }
        } else {
            while (keep > 0 && std::abs(r.pcm[(keep - 1) * 2]) < 512 && std::abs(r.pcm[(keep - 1) * 2 + 1]) < 512) --keep;   // (a tune that ends: its silence cut)
            lb = 0;                  // no repeat found in five minutes: the whole of it goes round
            le = static_cast<long>(keep);
        }
        r.pcm.resize(keep * 2);
        if (const char* wd = std::getenv("LOG2_MUSIC_WAV")) {      // (a check: the song played round its loop twice)
            std::vector<int16_t> two(r.pcm);
            if (lb >= 0) two.insert(two.end(), r.pcm.begin() + lb * 2, r.pcm.end());
            char wn[64];
            std::snprintf(wn, sizeof wn, "/song_%02d_check.wav", song);
            if (FILE* f = std::fopen((std::string(wd) + wn).c_str(), "wb")) {
                const uint32_t bytes = static_cast<uint32_t>(two.size() * 2), rate = kRate, br = kRate * 4;
                const uint16_t one = 1, chs = 2, align = 4, bits = 16;
                const uint32_t riff = 36 + bytes, fmt = 16;
                std::fwrite("RIFF", 1, 4, f); std::fwrite(&riff, 4, 1, f); std::fwrite("WAVEfmt ", 1, 8, f); std::fwrite(&fmt, 4, 1, f);
                std::fwrite(&one, 2, 1, f); std::fwrite(&chs, 2, 1, f); std::fwrite(&rate, 4, 1, f); std::fwrite(&br, 4, 1, f);
                std::fwrite(&align, 2, 1, f); std::fwrite(&bits, 2, 1, f); std::fwrite("data", 1, 4, f); std::fwrite(&bytes, 4, 1, f);
                std::fwrite(two.data(), 2, two.size(), f);
                std::fclose(f);
            }
        }
        const std::vector<uint8_t> q = qoa::encode(r.pcm, 2, kRate);
        char nm[64];
        std::snprintf(nm, sizeof nm, "/song_%02d", song);
        if (FILE* f = std::fopen((dir + nm + ".qoa").c_str(), "wb")) { std::fwrite(q.data(), 1, q.size(), f); std::fclose(f); }
        char js[160];
        std::snprintf(js, sizeof js, "{\"rate\":%d,\"loop_begin\":%ld,\"loop_end\":%ld,\"samples\":%zu}", kRate, lb, le, keep);
        write_text(dir + nm + ".json", js);
        std::fprintf(stderr, "[music] song %d: %.1f s%s\n", song, keep / static_cast<double>(kRate), looped ? " (loops)" : "");
        ++done;
    }
    return done;
}

}  // namespace gbamusic
