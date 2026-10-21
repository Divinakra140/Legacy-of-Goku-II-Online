// godot_export GAME OUTDIR [ADVENTURE_DIR]
// Turns the player's own Legacy of Goku II (USA) game into the asset folder the Godot version loads:
//   sprites/set_N.png + set_N.json   every sprite set (characters, forms, enemies, people): one atlas,
//                                    a row per slot (anim*4+dir), 64x64 cells, draw offsets in the json
//   maps/Z_A/layerK.png, walk.png, meta.json   every map: its 4 layers, collision, exits, objects
//   floors/<adventure>/Z_A/...       the hand-made adventures' areas (from the shipped layout files)
//   data/*.json                      enemy stats, forms, starting fighters, level table, text
// Nothing of the game is shipped with the Godot version: it all comes from here, from your game.
#ifndef _WIN32
#include <unistd.h>
#endif
#include <array>
#include <cctype>
#include <unordered_map>
#include <unordered_set>
#include "../src/map_builder.h"
#include "../src/rom_tiles.h"
#include "../src/rom_sprites.h"
#include "../src/gba_music.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <deque>
#include <functional>
#include <queue>
#include <set>
#include <cmath>
#include <fstream>
#include <string>
#include <vector>

namespace romcat {
bool save_png_rgba(const std::string& path, const std::vector<uint8_t>& rgba, int w, int h);
bool save_png_gray(const std::string& path, const std::vector<uint8_t>& g, int w, int h);
}
namespace fs = std::filesystem;
using namespace mapbuild;

static std::vector<uint8_t> g_rom;
static Rom R;
static uint32_t u32(uint32_t a) { return R.r32(a); }
static uint16_t u16(uint32_t a) { return R.r16(a); }
static uint8_t u8(uint32_t a) { return R.r8(a); }
static bool romp(uint32_t a) { return a >= 0x08000000u && a - 0x08000000u + 4 <= g_rom.size(); }
static uint32_t g_objpal[256];   // RGBA (little-endian bytes r,g,b,a)
static uint8_t g_bgpal[768];

static std::string hex(uint32_t v) { char b[16]; std::snprintf(b, sizeof b, "\"%08x\"", v); return b; }
static void write_text(const fs::path& p, const std::string& s) { std::ofstream o(p, std::ios::binary); o << s; }
static std::string jstr(const std::string& s) {
    std::string o = "\"";
    for (char c : s) { const unsigned char u = static_cast<unsigned char>(c); if (c == '"' || c == '\\') { o += '\\'; o += c; } else if (u < 32 || u >= 127) o += ' '; else o += c; }
    return o + "\"";
}

// ---------------------------------------------------------------- sprites
static constexpr uint32_t kSpriteSets = 0x083B4E74u, kObjPalette = 0x081DA6C8u;
struct Frame { int ox = 0, oy = 0, w = 0, h = 0; std::vector<uint32_t> px; };
static bool decode_entry(uint32_t w0, uint32_t attrs, uint32_t gfx, Frame* f, bool raw);
static bool decode_frame(uint32_t e, Frame* f, bool raw = false) { return decode_entry(u32(e), u32(e + 4), u32(e + 8), f, raw); }
static bool decode_entry(uint32_t w0, uint32_t attrs, uint32_t gfx, Frame* f, bool raw) {
    if (!romp(gfx)) return false;
    uint32_t type = u32(gfx), size = u32(gfx + 4);
    if (raw) type = 0xFF;
    else if (type > 2 || size == 0 || size > 0x2000) return false;
    static const int kW[3][4] = {{8, 16, 32, 64}, {16, 32, 32, 64}, {8, 8, 16, 32}};
    static const int kH[3][4] = {{8, 16, 32, 64}, {8, 8, 16, 32}, {16, 32, 32, 64}};
    const int shape = static_cast<int>((attrs >> 14) & 3u), sz = static_cast<int>((attrs >> 30) & 3u);
    if (shape > 2) return false;
    const bool bpp8 = (attrs >> 13) & 1u, hflip = (attrs >> 28) & 1u, vflip = (attrs >> 29) & 1u;
    const int w = kW[shape][sz], h = kH[shape][sz];
    if (raw) size = static_cast<uint32_t>(w * h / (bpp8 ? 1 : 2));
    std::vector<uint8_t> px(std::max<uint32_t>(size, 0x800u), 0);
    const uint32_t off = gfx - 0x08000000u + (raw ? 0u : 8u);
    if (off >= g_rom.size()) return false;
    if (raw) std::memcpy(px.data(), &g_rom[off], std::min<size_t>(size, g_rom.size() - off));
    else if (type == 0) std::memcpy(px.data(), &g_rom[off], std::min<size_t>(size, g_rom.size() - off));
    else log2rom::decompress(&g_rom[off], g_rom.size() - off, type, px.data(), size);
    f->w = w; f->h = h;
    f->ox = static_cast<int8_t>(w0 & 0xFF); f->oy = static_cast<int8_t>((w0 >> 8) & 0xFF);
    f->px.assign(static_cast<size_t>(w * h), 0u);
    const int tw = w / 8, tb = bpp8 ? 64 : 32;
    for (int t = 0; t * tb < static_cast<int>(size) && t / tw < h / 8; ++t) {
        const int tx = t % tw, ty = t / tw;
        for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x) {
            const int v = bpp8 ? px[static_cast<size_t>(t * 64 + y * 8 + x)] : (px[static_cast<size_t>(t * 32 + y * 4 + x / 2)] >> ((x & 1) * 4)) & 15;
            if (!v) continue;
            int X = tx * 8 + x, Y = ty * 8 + y;
            if (hflip) X = w - 1 - X;
            if (vflip) Y = h - 1 - Y;
            f->px[static_cast<size_t>(Y * w + X)] = g_objpal[v];
        }
    }
    return true;
}
// the songs are recorded while you play: below the game's priority (a slow computer stayed smooth)
#ifdef _WIN32
extern "C" __declspec(dllimport) void* __stdcall GetCurrentProcess(void);
extern "C" __declspec(dllimport) int __stdcall SetPriorityClass(void*, unsigned long);
static void lower_priority() { SetPriorityClass(GetCurrentProcess(), 0x00004000u); }      // BELOW_NORMAL_PRIORITY_CLASS
#else
static void lower_priority() { if (nice(10) == -1) { /* (left as it was) */ } }
#endif

// how far the import is, for the game's loading bar: "[progress] step done of" (the game reads it as it comes)
static void progress(const char* step, int done, int of) {
    std::fprintf(stderr, "[progress] %s %d %d\n", step, done, of);
    std::fflush(stderr);
}

static int export_sprites(const fs::path& dir) {
    fs::create_directories(dir);
    int sets = 0;
    for (int s = 0; s < 400; ++s) {
        progress("sprites", std::min(s, 157), 158);
        const uint32_t set = u32(kSpriteSets + 4u * static_cast<uint32_t>(s));
        if (!romp(set)) { if (s > 150) break; continue; }
        int nslots = 0, holes = 0;   // (slot lists have holes: animations a set does not have - the foes' attack is anim 6, after 3 empty ones)
        for (int g = 0; g < 40; ++g) {   // an animation = 4 slots (down, up, left, right)
            bool any = false, bad = false;
            for (int d = 0; d < 4; ++d) {
                const uint32_t v = u32(set + 0x4Cu + 16u * static_cast<uint32_t>(g) + 4u * static_cast<uint32_t>(d));
                if (v == 0) continue;
                Frame tf;
                if (!romp(v) || !decode_frame(v, &tf)) { bad = true; break; }
                any = true;
            }
            if (bad) break;
            if (!any) { if (++holes > (s == 76 ? 8 : 4)) break; continue; }   // (Krillin: his flight comes after a longer gap)
            holes = 0; nslots = 4 * g + 4;
        }
        if (nslots == 0) continue;
        std::vector<uint32_t> starts;
        for (int k = 0; k < nslots; ++k) starts.push_back(u32(set + 0x4Cu + 4u * static_cast<uint32_t>(k)));
        std::vector<std::vector<Frame>> slots(static_cast<size_t>(nslots));
        int maxf = 1;
        for (int k = 0; k < nslots; ++k) {
            const uint32_t a = starts[static_cast<size_t>(k)];
            if (!a) continue;
            uint32_t lim = a + 12u * 24u;
            for (uint32_t x : starts) if (x > a && x < lim) lim = x;
            for (int n = 0; a + 12u * n < lim && n < 24; ++n) {
                Frame f;
                if (!decode_frame(a + 12u * static_cast<uint32_t>(n), &f)) break;
                slots[static_cast<size_t>(k)].push_back(std::move(f));
            }
            maxf = std::max(maxf, static_cast<int>(slots[static_cast<size_t>(k)].size()));
        }
        const int C = 64, W = C * maxf, H = C * nslots;
        std::vector<uint8_t> img(static_cast<size_t>(W) * H * 4, 0);
        std::string js = "{\"set\":" + std::to_string(s) + ",\"cell\":64,\"header\":[";
        for (uint32_t q = 0; q < 0x4C; q += 4) js += (q ? "," : "") + hex(u32(set + q));
        js += "],\"slots\":[";
        for (int k = 0; k < nslots; ++k) {
            js += k ? ",[" : "[";
            const auto& fr = slots[static_cast<size_t>(k)];
            for (size_t n = 0; n < fr.size(); ++n) {
                const Frame& f = fr[n];
                for (int y = 0; y < f.h; ++y) for (int x = 0; x < f.w; ++x) {
                    const uint32_t c = f.px[static_cast<size_t>(y * f.w + x)];
                    if (!c) continue;
                    uint8_t* p = &img[(static_cast<size_t>(k * C + y) * W + static_cast<size_t>(n) * C + x) * 4];
                    std::memcpy(p, &c, 4);
                }
                char b[96]; std::snprintf(b, sizeof b, "%s{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}", n ? "," : "", f.ox, f.oy, f.w, f.h);
                js += b;
            }
            js += "]";
        }
        js += "]}";
        romcat::save_png_rgba((dir / ("set_" + std::to_string(s) + ".png")).string(), img, W, H);
        write_text(dir / ("set_" + std::to_string(s) + ".json"), js);
        ++sets;
    }
    return sets;
}


// effect animations (12-byte frames in game tables, as the sprite sets): fx/NAME.png, a row per direction
// the foes' own attacks, as the game draws them: frame tables {offset x/y, w, h; OAM attributes; raw tiles}
// (laser: bare 8x8 tiles). Each sheet: one row of frames in square cells, offsets in the json.
static void export_enemy_fx(const fs::path& dir) {
    struct E { const char* name; std::vector<std::array<uint32_t, 3>> frames; };
    std::vector<E> list;
    auto table = [&](const char* name, std::initializer_list<std::pair<uint32_t, int>> parts) {
        E e{name, {}};
        for (const auto& pr : parts) for (int i = 0; i < pr.second; ++i) { const uint32_t a = pr.first + 12u * static_cast<uint32_t>(i); e.frames.push_back(std::array<uint32_t, 3>{u32(a), u32(a + 4), u32(a + 8)}); }
        list.push_back(e);
    };
    {   // the flying robots' laser: 4 vertical then 4 horizontal 8x8 tiles (8bpp)
        E e{"e_laser", {}};
        for (int i = 0; i < 8; ++i) e.frames.push_back(std::array<uint32_t, 3>{0x08080404u, 0x00002000u, 0x087032D0u + 64u * static_cast<uint32_t>(i)});
        list.push_back(e);
    }
    table("e_fire", {{0x08703164u, 4}, {0x087031A0u, 4}, {0x087031DCu, 4}, {0x08703218u, 4}});   // per direction: fireball, then it bursts
    table("e_bomb", {{0x086FFBFCu, 3}});
    table("e_smoke", {{0x086FF09Cu, 4}});
    table("e_ring", {{0x086E1590u, 4}});
    table("e_spark", {{0x086E272Cu, 6}});
    table("e_charge", {{0x08703B60u, 3}});
    table("e_beam", {{0x08704604u, 3}, {0x08704640u, 6}, {0x087046A0u, 6}, {0x08704700u, 6}, {0x08704760u, 3}});
    table("e_flame", {{0x086DD914u, 12}});
    table("e_missile", {{0x086E5DC8u, 4}});
    table("e_star", {{0x086FE048u, 3}});     // the ninjas' throwing star
    // the heroes' own special effects
    table("p_beam_blue", {{0x086E3458u, 3}, {0x086E3494u, 6}, {0x086E34F4u, 6}, {0x086E3554u, 6}, {0x086E35B4u, 3}});   // Kamehameha
    table("p_beam_red", {{0x086E3B48u, 2}, {0x086E4560u, 3}, {0x086E459Cu, 5}, {0x086E45F0u, 5}, {0x086E4644u, 5}, {0x086E4698u, 2}});   // Special Beam Cannon
    table("p_ball_blue", {{0x086E29B4u, 3}});
    table("p_ball_yellow", {{0x086DE8A4u, 3}});
    table("p_ball_cyan", {{0x086DEB6Cu, 3}});
    table("p_bigki", {{0x086E0B90u, 16}});   // per direction (down, up, left, right): 3 flying frames + the burst
    table("p_spirit", {{0x086F77D4u, 10}});
    table("p_boom", {{0x086DBC60u, 3}});
    table("p_ring", {{0x086DE64Cu, 2}});
    table("p_star", {{0x086E53DCu, 4}});
    table("s_kame", {{0x086E3458u, 32}});   // Kamehameha, all of it: per direction tail, head, body 8/16/32, two bursts, tail end
    table("s_sbc", {{0x086E4560u, 28}});    // Special Beam Cannon: per direction 2 tails, body 8/16/32, 2 heads
    table("s_sbc_charge", {{0x086E3B48u, 2}});
    table("y_boom", {{0x086DE634u, 4}});   // Gohan's blast bursting
    table("v_boom", {{0x086AF614u, 4}});   // Vegeta's blast bursting
    for (const E& x : list) {
        std::vector<Frame> fr;
        int C = 8;
        for (const auto& t : x.frames) { Frame f; if (!romp(t[2]) || !decode_entry(t[0], t[1], t[2], &f, true)) f.w = f.h = 0; fr.push_back(f); C = std::max({C, f.w, f.h}); }
        const int n = static_cast<int>(fr.size());
        std::vector<uint8_t> img(static_cast<size_t>(C * n) * C * 4, 0);
        std::string js = "{\"cell\":" + std::to_string(C) + ",\"frames\":[";
        for (int i = 0; i < n; ++i) {
            const Frame& f = fr[static_cast<size_t>(i)];
            for (int y = 0; y < f.h; ++y) for (int xx = 0; xx < f.w; ++xx) {
                const uint32_t c = f.px[static_cast<size_t>(y * f.w + xx)];
                if (c) std::memcpy(&img[(static_cast<size_t>(y) * (C * n) + static_cast<size_t>(i * C + xx)) * 4], &c, 4);
            }
            char b[96]; std::snprintf(b, sizeof b, "%s{\"w\":%d,\"h\":%d,\"ox\":%d,\"oy\":%d}", i ? "," : "", f.w, f.h, f.ox, f.oy);
            js += b;
        }
        js += "]}";
        romcat::save_png_rgba((dir / (std::string(x.name) + ".png")).string(), img, C * n, C);
        write_text(dir / (std::string(x.name) + ".json"), js);
    }
}
static void export_fx(const fs::path& dir) {
    fs::create_directories(dir);
    struct Fx { const char* name; uint32_t base; int dirs, frames; };
    static const Fx kFx[] = {{"kiblast", 0x0840e47cu, 4, 4}};
    for (const Fx& x : kFx) {
        const int C = 32;
        std::vector<uint8_t> img(static_cast<size_t>(C * x.frames) * C * x.dirs * 4, 0);
        std::string js = std::string("{\"cell\":32,\"slots\":[");
        for (int d = 0; d < x.dirs; ++d) {
            js += d ? ",[" : "[";
            for (int f = 0; f < x.frames; ++f) {
                Frame fr;
                if (!decode_frame(x.base + 12u * static_cast<uint32_t>(d * x.frames + f), &fr, true)) break;
                for (int y = 0; y < fr.h && y < C; ++y) for (int xx = 0; xx < fr.w && xx < C; ++xx) {
                    const uint32_t c = fr.px[static_cast<size_t>(y * fr.w + xx)];
                    if (c) std::memcpy(&img[(static_cast<size_t>(d * C + y) * (C * x.frames) + static_cast<size_t>(f * C + xx)) * 4], &c, 4);
                }
                char b[96]; std::snprintf(b, sizeof b, "%s{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}", f ? "," : "", fr.ox, fr.oy, fr.w, fr.h);
                js += b;
            }
            js += "]";
        }
        js += "]}";
        romcat::save_png_rgba((dir / (std::string(x.name) + ".png")).string(), img, C * x.frames, C * x.dirs);
        write_text(dir / (std::string(x.name) + ".json"), js);
    }
}

// ---------------------------------------------------------------- maps
static constexpr uint32_t kMapTable = 0x08409368u;
struct Area {
    int z = 0, a = 0, tw = 0, th = 0;
    std::vector<uint16_t> L[4];
    bool tilemap[4] = {};
    uint8_t pri[4] = {};
    std::vector<uint8_t> wa, wb;
    std::vector<uint32_t> tiles;   // own tile list (game-wide numbers), empty = the area's own slots
};
static const uint8_t* tile_px(const Area& A, int slot, bool* anim) {
    *anim = false;
    if (!slot) return nullptr;
    if (!A.tiles.empty()) {
        if (slot < static_cast<int>(A.tiles.size())) return romtiles::global_tile(A.tiles[static_cast<size_t>(slot)]);
        *anim = true; return nullptr;
    }
    if (slot >= romtiles::slot_count(A.z, A.a)) { *anim = true; return nullptr; }
    return romtiles::map_tile(A.z, A.a, slot);
}
// The game keeps a second collision map (bit 2): water and the narrow drops along ledges are marked in it.
// A thin band of it (at most 3 tiles) between two walkable spots is a ledge or step the game lets you cross
// (in the original a script hops you over); those are opened, so the land's parts join up. Water stays shut.
static std::vector<uint8_t> open_ledges(const std::vector<uint8_t>& w, int tw, int th) {
    std::vector<uint8_t> o(w.size());
    for (size_t i = 0; i < w.size(); ++i) o[i] = w[i] & 1;
    auto at = [&](int x, int y) -> int { return x < 0 || y < 0 || x >= tw || y >= th ? 0 : w[static_cast<size_t>(y) * tw + x]; };
    // only a long ledge (a line of 6 tiles or more) - a bench, a planter or a sign is a thing you walk round
    std::vector<uint8_t> longc(w.size(), 0);
    {
        std::vector<int> comp(w.size(), -1);
        for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
            const size_t i = static_cast<size_t>(y) * tw + x;
            if (w[i] != 2 || comp[i] >= 0) continue;
            std::vector<size_t> cells{i}, st{i}; comp[i] = 1;
            int x0 = x, x1 = x, y0 = y, y1 = y;
            while (!st.empty()) {
                const size_t c = st.back(); st.pop_back();
                const int cx = static_cast<int>(c % tw), cy = static_cast<int>(c / tw);
                x0 = std::min(x0, cx); x1 = std::max(x1, cx); y0 = std::min(y0, cy); y1 = std::max(y1, cy);
                const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                for (auto& d : d4) {
                    const int X = cx + d[0], Y = cy + d[1];
                    if (X < 0 || Y < 0 || X >= tw || Y >= th) continue;
                    const size_t n2 = static_cast<size_t>(Y) * tw + X;
                    if (w[n2] != 2 || comp[n2] >= 0) continue;
                    comp[n2] = 1; st.push_back(n2); cells.push_back(n2);
                }
            }
            if (std::max(x1 - x0, y1 - y0) + 1 >= 6) for (size_t c : cells) longc[c] = 1;
        }
    }
    for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
        if (at(x, y) != 2 || !longc[static_cast<size_t>(y) * tw + x]) continue;
        for (int d = 0; d < 2; ++d) {
            const int dx = d == 0 ? 1 : 0, dy = d == 0 ? 0 : 1;
            int a = 1, b = 1;
            while (a <= 3 && at(x - dx * a, y - dy * a) == 2) ++a;
            while (b <= 3 && at(x + dx * b, y + dy * b) == 2) ++b;
            if (a + b - 1 <= 3 && (at(x - dx * a, y - dy * a) & 1) && (at(x + dx * b, y + dy * b) & 1)) { o[static_cast<size_t>(y) * tw + x] = 1; break; }
        }
    }
    return o;
}

// INVISIBLE WALLS (Android port): a lone patch of wall (up to 48 cells: rows of flowers, clumps of tufts; walkable ground all round it) with nothing
// solid drawn on it - only ground, or a flower the game lets you walk over - is opened: what you see is what blocks.
// Real obstacles are bigger, or show something (a planter, a trunk, a rock, a post) and keep blocking.
// plain(i): nothing solid drawn on the cell; solid(i)/open(i): read and write the collision. Returns the cells opened.
template <class Plain, class Solid, class Open>
static int open_invisible_walls(int W, int H, Plain plain, Solid solid, Open open_cell) {
    const size_t N = static_cast<size_t>(W) * H;
    std::vector<uint8_t> seen(N, 0);
    int opened = 0;
    std::vector<size_t> comp, st;
    for (size_t s0 = 0; s0 < N; ++s0) {
        if (seen[s0] || !solid(s0)) continue;
        comp.clear(); st.assign(1, s0); seen[s0] = 1;
        bool small = true;
        while (!st.empty()) {
            const size_t c = st.back(); st.pop_back();
            comp.push_back(c);
            if (comp.size() > 48) small = false;     // (a row of flowers, a clump of grass tufts; a tree or a rock is solid-looking anyway)
            const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
            const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (auto& d : d4) {
                const int X = x + d[0], Y = y + d[1];
                if (X < 0 || Y < 0 || X >= W || Y >= H) { small = false; continue; }     // (the map's edge: never)
                const size_t j = static_cast<size_t>(Y) * W + X;
                if (!seen[j] && solid(j)) { seen[j] = 1; st.push_back(j); }
            }
        }
        if (!small) continue;
        bool all_plain = true;
        for (size_t c : comp) if (!plain(c)) { all_plain = false; break; }
        if (!all_plain) continue;
        for (size_t c : comp) { open_cell(c); ++opened; }
    }
    return opened;
}
static int g_walls_opened = 0;
static int g_canopy_opened = 0;     // cells under leaves made walkable
// ---- the title screen and the menus' galaxy (Android port's GBA-style menus): both are 8-bit pictures packed with
// the game's own packer, drawn with the title's 256 colours. The galaxy is a 128x128 square the game repeats.
static void export_ui(const fs::path& dir) {
    fs::create_directories(dir);
    const uint32_t kPalette = 0x081d4f50u;
    struct Pic { const char* name; uint32_t at; int w, h; };
    const Pic pics[] = {{"title.png", 0x08029294u, 240, 160}, {"galaxy.png", 0x080e18b0u, 128, 128}};
    for (const Pic& p : pics) {
        std::vector<uint8_t> px;
        if (!decode(R, p.at, &px) || px.size() < static_cast<size_t>(p.w * p.h)) { std::fprintf(stderr, "[export] %s: not found in this game\n", p.name); continue; }
        std::vector<uint8_t> img(static_cast<size_t>(p.w) * p.h * 4);
        for (int i = 0; i < p.w * p.h; ++i) {
            const uint16_t c = R.r16(kPalette + 2u * px[static_cast<size_t>(i)]);
            img[i * 4] = static_cast<uint8_t>((c & 31) * 255 / 31); img[i * 4 + 1] = static_cast<uint8_t>(((c >> 5) & 31) * 255 / 31);
            img[i * 4 + 2] = static_cast<uint8_t>(((c >> 10) & 31) * 255 / 31); img[i * 4 + 3] = 255;
        }
        romcat::save_png_rgba((dir / p.name).string(), img, p.w, p.h);
    }
    // the title menu's little Dragon Ball (beside the picked choice): width, height, then pixels in the title's colours
    {
        const uint32_t at = 0x081d4e9cu;
        const int w = R.r16(at), h = R.r16(at + 2);
        if (w == 8 && h == 8) {
            std::vector<uint8_t> img(64 * 4, 0);
            for (int i = 0; i < 64; ++i) {
                const uint8_t ci = R.r8(at + 4u + static_cast<uint32_t>(i));
                if (!ci) continue;
                const uint16_t c = R.r16(kPalette + 2u * ci);
                img[i * 4] = static_cast<uint8_t>((c & 31) * 255 / 31); img[i * 4 + 1] = static_cast<uint8_t>(((c >> 5) & 31) * 255 / 31);
                img[i * 4 + 2] = static_cast<uint8_t>(((c >> 10) & 31) * 255 / 31); img[i * 4 + 3] = 255;
            }
            romcat::save_png_rgba((dir / "ball.png").string(), img, 8, 8);
        }
    }
    // the menus' two fonts (the game's text routine at 0x08020ec2): a table of halfword offsets by character code;
    // a glyph = its width, then one 16-pixel column per halfword (bit 0 at the top). Saved as a strip of white glyphs
    // plus where each one is; the game adds the shadow when drawing (one pixel right and down).
    struct Fnt { const char* name; uint32_t at; };
    const Fnt fonts[] = {{"font_head", 0x081d6b1cu}, {"font_small", 0x08028724u}};
    for (const Fnt& f : fonts) {
        std::vector<std::pair<int, int>> where(256, {-1, 0});
        int total = 0;
        for (int c = 32; c < 256; ++c) {
            const uint16_t o = R.r16(f.at + 2u * c);
            if (!o) continue;
            const int w = R.r16(f.at + 2u * o);
            if (w < 1 || w > 24) continue;
            where[c] = {total, w};
            total += w + 1;
        }
        if (total == 0) { std::fprintf(stderr, "[export] %s: not found in this game\n", f.name); continue; }
        std::vector<uint8_t> img(static_cast<size_t>(total) * 16 * 4, 0);
        std::string js = "{\"h\":16,\"glyphs\":{";
        bool first = true;
        for (int c = 32; c < 256; ++c) {
            if (where[c].first < 0) continue;
            const uint32_t g = f.at + 2u * R.r16(f.at + 2u * c);
            for (int x = 0; x < where[c].second; ++x) {
                const uint16_t col = R.r16(g + 2u + 2u * x);
                for (int y = 0; y < 16; ++y) if ((col >> y) & 1) {
                    uint8_t* p = &img[(static_cast<size_t>(y) * total + where[c].first + x) * 4];
                    p[0] = p[1] = p[2] = p[3] = 255;
                }
            }
            char b[48]; std::snprintf(b, sizeof b, "%s\"%d\":[%d,%d]", first ? "" : ",", c, where[c].first, where[c].second);
            js += b; first = false;
        }
        js += "}}";
        romcat::save_png_rgba((dir / (std::string(f.name) + ".png")).string(), img, total, 16);
        write_text(dir / (std::string(f.name) + ".json"), js);
    }
    std::fprintf(stderr, "[export] title screen, menu galaxy and fonts\n");
}
static void write_area(const fs::path& d, const Area& A, const std::string& extra_json) {
    fs::create_directories(d);
    const int W = A.tw * 8, H = A.th * 8;
    std::string anim_cells = "[";
    bool first_anim = true;
    for (int k = 0; k < 4; ++k) {
        if (!A.tilemap[k] || A.L[k].empty()) continue;
        std::vector<uint8_t> img(static_cast<size_t>(W) * H * 4, 0);
        bool any = false;
        for (int ty = 0; ty < A.th; ++ty) for (int tx = 0; tx < A.tw; ++tx) {
            const uint16_t e = A.L[k][static_cast<size_t>(ty) * A.tw + tx];
            bool anim = false;
            const uint8_t* t = tile_px(A, e & 0x3FF, &anim);
            if (anim) {   // animated (water...): the game copies these in while it runs - listed for the importer's live pass
                char b[64]; std::snprintf(b, sizeof b, "%s[%d,%d,%d,%d]", first_anim ? "" : ",", k, tx, ty, e);
                anim_cells += b; first_anim = false; continue;
            }
            if (!t) continue;
            for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x) {
                const int sx = (e & 0x400) ? 7 - x : x, sy = (e & 0x800) ? 7 - y : y;
                const uint8_t c = t[sy * 8 + sx];
                if (!c) continue;
                uint8_t* p = &img[(static_cast<size_t>(ty * 8 + y) * W + tx * 8 + x) * 4];
                p[0] = g_bgpal[c * 3]; p[1] = g_bgpal[c * 3 + 1]; p[2] = g_bgpal[c * 3 + 2]; p[3] = 255;
                any = true;
            }
        }
        if (any) romcat::save_png_rgba((d / ("layer" + std::to_string(k) + ".png")).string(), img, W, H);
    }
    anim_cells += "]";
    std::vector<uint8_t> walk(static_cast<size_t>(A.tw) * A.th, 0);
    {
        std::vector<uint8_t> raw(walk.size(), 0);
        for (size_t i = 0; i < walk.size() && i < A.wa.size(); ++i) raw[i] = static_cast<uint8_t>((A.wa[i] ? 1 : 0) | ((i < A.wb.size() && A.wb[i]) ? 2 : 0));
        const std::vector<uint8_t> op = open_ledges(raw, A.tw, A.th);
        for (size_t i = 0; i < walk.size(); ++i) walk[i] = static_cast<uint8_t>(raw[i] | op[i]);
        auto plain = [&](size_t i) {       // only one layer shows anything here: the ground itself
            int shown = 0;
            for (int k = 0; k < 4; ++k) {
                if (!A.tilemap[k] || i >= A.L[k].size()) continue;
                bool anim = false;
                const uint8_t* t = tile_px(A, A.L[k][i] & 0x3FF, &anim);
                bool any = anim;
                if (t) for (int q = 0; q < 64 && !any; ++q) any = t[q] != 0;
                shown += any;
            }
            return shown <= 1;
        };
        g_walls_opened += open_invisible_walls(A.tw, A.th, plain, [&](size_t i) { return walk[i] == 0; }, [&](size_t i) { walk[i] = 1; });
        for (size_t i = 0; i < walk.size(); ++i) walk[i] = static_cast<uint8_t>(walk[i] * 85);
    }
    romcat::save_png_gray((d / "walk.png").string(), walk, A.tw, A.th);
    std::string js = "{\"zone\":" + std::to_string(A.z) + ",\"area\":" + std::to_string(A.a) + ",\"tw\":" + std::to_string(A.tw) + ",\"th\":" + std::to_string(A.th);
    js += ",\"pri\":[" + std::to_string(A.pri[0]) + "," + std::to_string(A.pri[1]) + "," + std::to_string(A.pri[2]) + "," + std::to_string(A.pri[3]) + "]";
    js += ",\"tilemap\":[" + std::string(A.tilemap[0] ? "1" : "0") + "," + (A.tilemap[1] ? "1" : "0") + "," + (A.tilemap[2] ? "1" : "0") + "," + (A.tilemap[3] ? "1" : "0") + "]";
    char bg[64]; std::snprintf(bg, sizeof bg, ",\"backdrop\":[%d,%d,%d]", g_bgpal[0], g_bgpal[1], g_bgpal[2]);
    js += bg;
    js += ",\"anim\":" + anim_cells + extra_json + "}";
    write_text(d / "meta.json", js);
}
static std::string rom_area_json(uint32_t entry, uint32_t var) {
    std::string js;
    const int name = u16(entry + 0x0C);
    js += ",\"name\":" + jstr(name > 0 ? romtiles::game_string(name) : std::string());
    const uint32_t arr = u32(var + 0x30);
    // the map's song: an index into the song table, or a script that picks one (-1: the land's usual song)
    const uint32_t song = u32(entry + 0x24);
    js += ",\"song\":" + std::to_string(song < 0x10000u ? static_cast<int>(song) : -1);
    js += ",\"arrival\":[" + std::to_string(arr & 0xFFFF) + "," + std::to_string(arr >> 16) + "]";
    js += ",\"exits\":[";
    const uint32_t en = u32(var + 0x40), ea = u32(var + 0x44);
    bool f = true;
    for (uint32_t i = 0; i < en && i < 32 && romp(ea); ++i) {
        const uint32_t r = u32(ea + 4u * i);
        if (!romp(r)) continue;
        char b[256];
        std::snprintf(b, sizeof b, "%s{\"handler\":\"%08x\",\"rect\":[%u,%u,%u,%u],\"dir\":%u,\"to\":[%u,%u],\"pos\":[%u,%u],\"raw\":\"%08x%08x%08x\"}", f ? "" : ",",
            u32(r), u16(r + 8), u16(r + 10), u16(r + 12), u16(r + 14), u8(r + 16), u8(r + 17), u8(r + 18), u16(r + 20), u16(r + 22), u32(r + 12), u32(r + 16), u32(r + 20));
        js += b; f = false;
    }
    js += "],\"objects\":[";
    // the map entry's object lists: +4 count / +0x14 enemies, +5 / +0x18, +6 / +0x1C, +7 / +0x10
    static const uint32_t kList[4] = {0x14, 0x18, 0x1C, 0x10};
    f = true;
    for (int L = 0; L < 4; ++L) {
        const uint32_t cnt = u8(entry + 4 + static_cast<uint32_t>(L)), arr2 = u32(entry + kList[L]);
        for (uint32_t i = 0; i < cnt && i < 64 && romp(arr2); ++i) {
            const uint32_t r = u32(arr2 + 4u * i);
            if (!romp(r)) continue;
            const uint32_t h = u32(r);
            const char* kind = h == 0x0800E77Fu ? "enemy" : h == 0x0800B711u ? "person" : h == 0x0800D6DFu ? "thing" : "other";
            const uint32_t pos = u32(r + 0xC);
            char bb[300];
            std::snprintf(bb, sizeof bb, "%s{\"list\":%d,\"kind\":\"%s\",\"handler\":\"%08x\",\"type\":%u,\"x\":%d,\"y\":%d,\"set\":%u,\"w4\":\"%08x\",\"w14\":\"%08x\",\"w18\":\"%08x\"}", f ? "" : ",",
                L, kind, h, u32(r + 8), static_cast<int16_t>(pos & 0xFFFF), static_cast<int16_t>(pos >> 16), u32(r + 0x10), u32(r + 4), u32(r + 0x14), u32(r + 0x18));
            js += bb; f = false;
        }
    }
    js += "]";
    return js;
}

// animated map tiles (water, waterfalls): variant +0x0C count / +0x10 list of descriptors
// {u32 slot<<16 | tiles<<8 | frames, then per frame a pointer to {u32 duration, packed tiles}}
static void export_anim(const fs::path& d, uint32_t var) {
    const uint32_t n = u32(var + 0x0C), arr = u32(var + 0x10);
    std::string js = "[";
    std::vector<std::vector<uint8_t>> strips; int maxw = 0;
    for (uint32_t i = 0; i < n && i < 32 && romp(arr); ++i) {
        const uint32_t dsc = u32(arr + 4u * i);
        if (!romp(dsc)) continue;
        const uint32_t w = u32(dsc);
        const int slot = static_cast<int>(w >> 16), tiles = static_cast<int>((w >> 8) & 0xFF), frames = static_cast<int>(w & 0xFF);
        if (slot <= 0 || slot >= 1024 || tiles <= 0 || frames <= 0 || frames > 64) continue;
        js += (js.size() > 1 ? "," : "") + std::string("{\"slot\":") + std::to_string(slot) + ",\"tiles\":" + std::to_string(tiles) + ",\"row\":" + std::to_string(strips.size()) + ",\"durations\":[";
        for (int fr = 0; fr < frames; ++fr) {
            const uint32_t p = u32(dsc + 4u + 4u * static_cast<uint32_t>(fr));
            if (!romp(p)) break;
            js += (fr ? "," : "") + std::to_string(u32(p));
            std::vector<uint8_t> px(static_cast<size_t>(tiles) * 64, 0);
            log2rom::decompress(&g_rom[p + 4 - 0x08000000u], g_rom.size() - (p + 4 - 0x08000000u), 8, px.data(), px.size());
            strips.push_back(px);
            maxw = std::max(maxw, tiles);
        }
        js += "]}";
    }
    js += "]";
    if (strips.empty()) return;
    // anim.png: one row (8 px tall) per descriptor frame, tiles side by side
    const int W = maxw * 8, H = static_cast<int>(strips.size()) * 8;
    std::vector<uint8_t> img(static_cast<size_t>(W) * H * 4, 0);
    for (size_t r = 0; r < strips.size(); ++r) {
        const auto& px = strips[r];
        for (size_t t = 0; t * 64 < px.size(); ++t) for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x) {
            const uint8_t c = px[t * 64 + static_cast<size_t>(y * 8 + x)];
            if (!c) continue;
            uint8_t* q = &img[((r * 8 + static_cast<size_t>(y)) * W + t * 8 + static_cast<size_t>(x)) * 4];
            q[0] = g_bgpal[c * 3]; q[1] = g_bgpal[c * 3 + 1]; q[2] = g_bgpal[c * 3 + 2]; q[3] = 255;
        }
    }
    fs::create_directories(d);
    romcat::save_png_rgba((d / "anim.png").string(), img, W, H);
    write_text(d / "anim.json", js);
}
static uint32_t rom_var(int z, int a) {
    for (const auto& m : romtiles::maps()) if (m.z == z && m.a == a) return m.var;
    return 0;
}
static int export_maps(const fs::path& dir) {
    int n = 0, k = 0;
    const int total = static_cast<int>(romtiles::maps().size());
    for (const auto& m : romtiles::maps()) {
        progress("maps", k++, total);
        SrcMap sm;
        if (!load_src(R, m.z, m.a, &sm) || sm.tw <= 0 || sm.th <= 0) continue;
        Area A; A.z = m.z; A.a = m.a; A.tw = sm.tw; A.th = sm.th; A.wa = sm.wa; A.wb = sm.wb;
        for (int k = 0; k < 4; ++k) { A.L[k] = sm.L[k]; A.tilemap[k] = sm.tilemap[k]; A.pri[k] = sm.pri[k]; }
        write_area(dir / (std::to_string(m.z) + "_" + std::to_string(m.a)), A, rom_area_json(m.entry, m.var));
        export_anim(dir / (std::to_string(m.z) + "_" + std::to_string(m.a)), m.var);
        ++n;
    }
    return n;
}

// ---------------------------------------------------------------- adventure floors (.gen layout files)
static bool load_gen(const fs::path& p, Area* A, std::string* extra) {
    std::ifstream f(p, std::ios::binary);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (d.size() < 10) return false;
    A->z = d[0]; A->a = d[1];
    const int w = d[2] | d[3] << 8, h = d[4] | d[5] << 8, sx = d[6] | d[7] << 8, sy = d[8] | d[9] << 8;
    A->tw = w / 8; A->th = h / 8;
    size_t o = 10;
    for (int k = 0; k < 4; ++k) {
        if (o + 2 > d.size()) return false;
        const int cols = d[o], rows = d[o + 1]; o += 2;
        A->L[k].assign(static_cast<size_t>(A->tw) * A->th, 0);
        if (!cols) continue;
        A->tilemap[k] = true;
        for (int cy = 0; cy < rows; ++cy) for (int cx = 0; cx < cols; ++cx) {
            if (o + 2048 > d.size()) return false;
            for (int y = 0; y < 32; ++y) for (int x = 0; x < 32; ++x) {
                const int X = cx * 32 + x, Y = cy * 32 + y;
                const uint16_t e = static_cast<uint16_t>(d[o + 2 * (y * 32 + x)] | d[o + 2 * (y * 32 + x) + 1] << 8);
                if (X < A->tw && Y < A->th) A->L[k][static_cast<size_t>(Y) * A->tw + X] = e;
            }
            o += 2048;
        }
    }
    if (o + 16384 > d.size()) return false;
    A->wa.assign(static_cast<size_t>(A->tw) * A->th, 0); A->wb = A->wa;
    for (int y = 0; y < A->th && y < 256; ++y) for (int x = 0; x < A->tw && x < 256; ++x) {
        A->wa[static_cast<size_t>(y) * A->tw + x] = (d[o + y * 32 + (x >> 3)] >> (x & 7)) & 1;
        A->wb[static_cast<size_t>(y) * A->tw + x] = (d[o + 8192 + y * 32 + (x >> 3)] >> (x & 7)) & 1;
    }
    o += 16384;
    std::string ex = ",\"exits\":[";
    if (o < d.size()) {
        const int n = d[o++];
        for (int i = 0; i < n && o + 8 <= d.size(); ++i, o += 8) {
            char b[96]; std::snprintf(b, sizeof b, "%s{\"rect\":[%d,%d,%d,%d]}", i ? "," : "", d[o] | d[o + 1] << 8, d[o + 2] | d[o + 3] << 8, d[o + 4] | d[o + 5] << 8, d[o + 6] | d[o + 7] << 8);
            ex += b;
        }
    }
    ex += "]";
    // the area's own priorities / layer kinds come from the game map it stands on
    SrcMap sm;
    if (load_src(R, A->z, A->a, &sm)) for (int k = 0; k < 4; ++k) { A->pri[k] = sm.pri[k]; if (!sm.tilemap[k]) A->tilemap[k] = false; }
    *extra = ex + ",\"arrival\":[" + std::to_string(sx) + "," + std::to_string(sy) + "]";
    std::ifstream tf(p.string() + ".tiles", std::ios::binary);
    if (tf) { uint32_t v; while (tf.read(reinterpret_cast<char*>(&v), 4)) A->tiles.push_back(v); }
    return true;
}
static int export_floors(const fs::path& src, const fs::path& dir) {
    int n = 0;
    if (!fs::exists(src)) return 0;
    for (const auto& adv : fs::directory_iterator(src)) {
        if (!adv.is_directory()) continue;
        for (const auto& e : fs::directory_iterator(adv.path())) {
            if (e.path().extension() != ".gen") continue;
            Area A; std::string extra;
            if (!load_gen(e.path(), &A, &extra)) { std::fprintf(stderr, "[export] bad layout %s\n", e.path().string().c_str()); continue; }
            write_area(dir / adv.path().filename() / (std::to_string(A.z) + "_" + std::to_string(A.a)), A, extra);
            if (const uint32_t v = rom_var(A.z, A.a)) export_anim(dir / adv.path().filename() / (std::to_string(A.z) + "_" + std::to_string(A.a)), v);
            ++n;
        }
        if (fs::exists(adv.path() / "route.json")) fs::copy_file(adv.path() / "route.json", dir / adv.path().filename() / "route.json", fs::copy_options::overwrite_existing);
    }
    return n;
}


// ---------------------------------------------------------------- the building kit (one world from the game's pieces)
// kit/tiles.png   every distinct map tile of the whole game (all maps share one palette): id 1.. in rows of 64
// kit/maps/Z_A.bin every map written in those ids:
//   "LKM1", u16 tw, u16 th, u8 pri[4], u8 tilemap mask, u8 0, u8 0, then 4 layers of tw*th u32 cells
//   (bits 0-15 tile id, 16 h-flip, 17 v-flip, 18 animated - then bits 0-15 are the map's own slot), then tw*th u8 walk (1 = A, 2 = B)
// kit/maps.json   per map: zone, area, size, name, exits, objects
struct KExit { int x0, y0, x1, y1, dir, tz, ta, px, py; };
struct KObj { int kind, type, set, x, y; };
struct KitMap {
    std::string key, name, place; int z = 0, a = 0, tw = 0, th = 0;
    uint8_t pri[4] = {}, mask = 0, light = 0;
    std::vector<uint32_t> L[4]; std::vector<uint8_t> walk;
    std::vector<KExit> exits; std::vector<KObj> objs; int arr_x = 0, arr_y = 0;
};
static std::vector<KitMap> g_kit;
static std::map<int, std::array<int, 3>> g_anim_rgb;
static std::vector<uint32_t> g_sea;     // the sea: {w, h, then w*h cells of 2 layers}     // animated tile id -> its first picture's mean colour
struct AnimDesc { int slot = 0, tiles = 0; std::vector<std::vector<uint8_t>> frames; std::vector<uint32_t> dur; };
static std::vector<AnimDesc> read_anim(uint32_t var) {
    std::vector<AnimDesc> out;
    const uint32_t n = u32(var + 0x0C), arr = u32(var + 0x10);
    for (uint32_t i = 0; i < n && i < 32 && romp(arr); ++i) {
        const uint32_t dsc = u32(arr + 4u * i);
        if (!romp(dsc)) continue;
        const uint32_t w = u32(dsc);
        AnimDesc a; a.slot = static_cast<int>(w >> 16); a.tiles = static_cast<int>((w >> 8) & 0xFF);
        const int frames = static_cast<int>(w & 0xFF);
        if (a.slot <= 0 || a.slot >= 1024 || a.tiles <= 0 || frames <= 0 || frames > 64) continue;
        for (int fr = 0; fr < frames; ++fr) {
            const uint32_t p = u32(dsc + 4u + 4u * static_cast<uint32_t>(fr));
            if (!romp(p)) break;
            std::vector<uint8_t> px(static_cast<size_t>(a.tiles) * 64, 0);
            log2rom::decompress(&g_rom[p + 4 - 0x08000000u], g_rom.size() - (p + 4 - 0x08000000u), 8, px.data(), px.size());
            a.frames.push_back(px); a.dur.push_back(u32(p));
        }
        if (!a.frames.empty()) out.push_back(a);
    }
    return out;
}
static bool tile_is_grey(const uint8_t* t) {
    int n = 0;
    for (int i = 0; i < 64; ++i) {
        const uint8_t c = t[i];
        if (!c) continue;
        const int r = g_bgpal[c * 3], g = g_bgpal[c * 3 + 1], b = g_bgpal[c * 3 + 2];
        if (std::abs(r - g) > 14 || std::abs(g - b) > 14) return false;
        ++n;
    }
    return n > 0;
}
static int export_kit(const fs::path& dir) {
    fs::create_directories(dir / "maps");
    const int N = static_cast<int>(romtiles::id_globals().size());
    // animated tiles get game-wide ids too (N, N+1, ...): equal frames + timings = the same id in every map
    std::map<std::string, int> anim_key;
    std::vector<std::vector<std::vector<uint8_t>>> anim_store;
    std::vector<std::vector<uint32_t>> anim_dur;
    std::string js = "{\"tiles\":" + std::to_string(N) + ",\"cols\":64";
    char bg[64]; std::snprintf(bg, sizeof bg, ",\"backdrop\":[%d,%d,%d],\"maps\":[", g_bgpal[0], g_bgpal[1], g_bgpal[2]);
    js += bg;
    int n = 0, kk = 0;
    const int nmaps = static_cast<int>(romtiles::maps().size());
    for (const auto& m : romtiles::maps()) {
        progress("kit", kk++, nmaps);
        SrcMap sm;
        if (!load_src(R, m.z, m.a, &sm) || sm.tw <= 0 || sm.th <= 0) continue;
        const uint16_t* ids = romtiles::ids(m.z, m.a);
        const int sc = romtiles::slot_count(m.z, m.a);
        const std::vector<AnimDesc> ad = read_anim(m.var);
        auto anim_id = [&](int slot) -> int {
            for (const auto& a : ad) {
                if (slot < a.slot || slot >= a.slot + a.tiles) continue;
                const int j = slot - a.slot;
                std::string key;
                std::vector<std::vector<uint8_t>> fr;
                for (size_t f = 0; f < a.frames.size(); ++f) {
                    std::vector<uint8_t> px(a.frames[f].begin() + j * 64, a.frames[f].begin() + j * 64 + 64);
                    key.append(reinterpret_cast<const char*>(px.data()), 64);
                    key.append(reinterpret_cast<const char*>(&a.dur[f]), 4);
                    fr.push_back(px);
                }
                auto it = anim_key.find(key);
                if (it != anim_key.end()) return it->second;
                const int id = N + static_cast<int>(anim_store.size());
                anim_key[key] = id;
                anim_store.push_back(fr);
                anim_dur.push_back(a.dur);
                return id;
            }
            return -1;
        };
        // a light layer (the soft grey light of a room, blended by the GBA): almost only grey tiles
        uint8_t light = 0;
        int bottom = -1, used = 0, cover[4] = {};      // the layer drawn first: nothing under it to light, so a grey one covering the room is a stone floor
        for (int k = 0; k < 4; ++k) {
            if (!sm.tilemap[k] || !ids) continue;
            int tot = 0, grey = 0;
            for (int i = 0; i < sm.tw * sm.th; ++i) {
                const int slot = sm.L[k][static_cast<size_t>(i)] & 0x3FF;
                if (!slot || slot >= sc || !ids[slot]) continue;
                const uint8_t* t = romtiles::tile(ids[slot]);
                if (!t) continue;
                ++tot; grey += tile_is_grey(t) ? 1 : 0;
            }
            if (tot >= sm.tw * sm.th / 8 && grey * 100 >= tot * 85) light |= static_cast<uint8_t>(1 << k);
            cover[k] = tot; used += tot > 0 ? 1 : 0;
            if (tot > 0 && (bottom < 0 || sm.pri[k] > sm.pri[bottom] || (sm.pri[k] == sm.pri[bottom] && k > bottom))) bottom = k;
        }
        if (bottom >= 0 && used > 1 && cover[bottom] * 2 >= sm.tw * sm.th) light &= static_cast<uint8_t>(~(1u << bottom));
        std::vector<uint8_t> b;
        auto put8 = [&](uint32_t v) { b.push_back(static_cast<uint8_t>(v)); };
        auto put16 = [&](uint32_t v) { put8(v); put8(v >> 8); };
        auto put32 = [&](uint32_t v) { put16(v); put16(v >> 16); };
        b.insert(b.end(), {'L', 'K', 'M', '1'});
        put16(static_cast<uint32_t>(sm.tw)); put16(static_cast<uint32_t>(sm.th));
        for (int k = 0; k < 4; ++k) put8(sm.pri[k]);
        put8((sm.tilemap[0] ? 1u : 0u) | (sm.tilemap[1] ? 2u : 0u) | (sm.tilemap[2] ? 4u : 0u) | (sm.tilemap[3] ? 8u : 0u)); put8(light); put8(0); put8(0);
        for (int k = 0; k < 4; ++k) {
            for (int i = 0; i < sm.tw * sm.th; ++i) {
                uint32_t cell = 0;
                if (sm.tilemap[k] && static_cast<size_t>(i) < sm.L[k].size()) {
                    const uint16_t e = sm.L[k][static_cast<size_t>(i)];
                    const int slot = e & 0x3FF;
                    const uint32_t fl = ((e & 0x400) ? 1u << 16 : 0u) | ((e & 0x800) ? 1u << 17 : 0u);
                    if (slot && ids) {
                        if (slot >= sc) {
                            const int aid = anim_id(slot);
                            cell = aid >= 0 ? (static_cast<uint32_t>(aid) | (1u << 19) | fl) : (static_cast<uint32_t>(slot) | (1u << 18) | fl);
                        }
                        else if (ids[slot]) cell = ids[slot] | fl;
                    }
                }
                put32(cell);
            }
        }
        for (int i = 0; i < sm.tw * sm.th; ++i)
            put8((static_cast<size_t>(i) < sm.wa.size() && sm.wa[static_cast<size_t>(i)] ? 1u : 0u) | (static_cast<size_t>(i) < sm.wb.size() && sm.wb[static_cast<size_t>(i)] ? 2u : 0u));
        const std::string key = std::to_string(m.z) + "_" + std::to_string(m.a);
        {   // the same map kept for the lands (below)
            KitMap km; km.key = key; km.z = m.z; km.a = m.a; km.tw = sm.tw; km.th = sm.th;
            for (int k = 0; k < 4; ++k) km.pri[k] = sm.pri[k];
            km.mask = static_cast<uint8_t>(b[12]); km.light = light;
            size_t o = 16;
            for (int k = 0; k < 4; ++k) {
                km.L[k].resize(static_cast<size_t>(sm.tw) * sm.th);
                std::memcpy(km.L[k].data(), &b[o], km.L[k].size() * 4); o += km.L[k].size() * 4;
            }
            km.walk.assign(b.begin() + static_cast<long>(o), b.begin() + static_cast<long>(o) + sm.tw * sm.th);
            const int nm = u16(m.entry + 0x0C);
            km.name = nm > 0 ? romtiles::game_string(nm) : std::string();
            km.place = romtiles::place_name(m.z, m.a);
            const uint32_t arr = u32(m.var + 0x30); km.arr_x = static_cast<int>(arr & 0xFFFF); km.arr_y = static_cast<int>(arr >> 16);
            const uint32_t en = u32(m.var + 0x40), ea = u32(m.var + 0x44);
            for (uint32_t i = 0; i < en && i < 32 && romp(ea); ++i) {
                const uint32_t r = u32(ea + 4u * i);
                if (!romp(r)) continue;
                km.exits.push_back({u16(r + 8), u16(r + 10), u16(r + 12), u16(r + 14), u8(r + 16), u8(r + 17), u8(r + 18), u16(r + 20), u16(r + 22)});
            }
            static const uint32_t kList[4] = {0x14, 0x18, 0x1C, 0x10};
            for (int Ls = 0; Ls < 4; ++Ls) {
                const uint32_t cnt = u8(m.entry + 4 + static_cast<uint32_t>(Ls)), arr2 = u32(m.entry + kList[Ls]);
                for (uint32_t i = 0; i < cnt && i < 64 && romp(arr2); ++i) {
                    const uint32_t r = u32(arr2 + 4u * i);
                    if (!romp(r)) continue;
                    const uint32_t h = u32(r), pos = u32(r + 0xC);
                    km.objs.push_back({h == 0x0800E77Fu ? 0 : h == 0x0800B711u ? 1 : 2, static_cast<int>(u32(r + 8)), static_cast<int>(u32(r + 0x10)),
                        static_cast<int16_t>(pos & 0xFFFF), static_cast<int16_t>(pos >> 16)});
                }
            }
            g_kit.push_back(std::move(km));
        }
        { std::ofstream o(dir / "maps" / (key + ".bin"), std::ios::binary); o.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size())); }
        js += (n ? "," : "") + std::string("{\"key\":\"") + key + "\",\"zone\":" + std::to_string(m.z) + ",\"area\":" + std::to_string(m.a) +
            ",\"tw\":" + std::to_string(sm.tw) + ",\"th\":" + std::to_string(sm.th) + ",\"place\":" + jstr(romtiles::place_name(m.z, m.a)) + rom_area_json(m.entry, m.var) + "}";

        ++n;
    }
    // the atlas: tiles 0..N-1 and one entry per animated tile (its first frame) in rows of 64,
    // then one row per animated tile with all its frames from column 0 (how Godot plays tile animations)
    const int NA = static_cast<int>(anim_store.size());
    const int cols = 64;
    const int base_rows = (N + NA + cols - 1) / cols;
    int maxf = 1; for (const auto& a : anim_store) maxf = std::max(maxf, static_cast<int>(a.size()));
    const int rows = base_rows + NA;
    const int total = N + NA;
    std::vector<uint8_t> img(static_cast<size_t>(cols * 8) * rows * 8 * 4, 0);
    auto draw_at = [&](int cx, int cy, const uint8_t* t) {
        const int ox = cx * 8, oy = cy * 8;
        for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x) {
            const uint8_t c = t[y * 8 + x];
            if (!c) continue;
            uint8_t* p = &img[(static_cast<size_t>(oy + y) * cols * 8 + ox + x) * 4];
            p[0] = g_bgpal[c * 3]; p[1] = g_bgpal[c * 3 + 1]; p[2] = g_bgpal[c * 3 + 2]; p[3] = 255;
        }
    };
    for (int id = 1; id < N; ++id) if (const uint8_t* t = romtiles::tile(static_cast<uint16_t>(id))) draw_at(id % cols, id / cols, t);
    std::string aj = "[";
    for (int a = 0; a < NA; ++a) {
        const auto& fr = anim_store[static_cast<size_t>(a)];
        {
            long r = 0, g = 0, bl = 0, n = 0;
            for (uint8_t c : fr[0]) { if (!c) continue; r += g_bgpal[c * 3]; g += g_bgpal[c * 3 + 1]; bl += g_bgpal[c * 3 + 2]; ++n; }
            if (n) g_anim_rgb[N + a] = {static_cast<int>(r / n), static_cast<int>(g / n), static_cast<int>(bl / n)};
        }
        draw_at((N + a) % cols, (N + a) / cols, fr[0].data());
        const int nfr = std::min(static_cast<int>(fr.size()), cols);
        for (int f = 0; f < nfr; ++f) draw_at(f, base_rows + a, fr[static_cast<size_t>(f)].data());
        aj += (a ? "," : "") + std::string("{\"id\":") + std::to_string(N + a) + ",\"row\":" + std::to_string(base_rows + a) + ",\"frames\":" + std::to_string(nfr) + ",\"durations\":[";
        for (int f = 0; f < nfr; ++f) aj += (f ? "," : "") + std::to_string(anim_dur[static_cast<size_t>(a)][static_cast<size_t>(f)]);
        aj += "]}";
    }
    romcat::save_png_rgba((dir / "tiles.png").string(), img, cols * 8, rows * 8);
    write_text(dir / "anim.json", aj + "]");
    js += "]";
    js += ",\"anims\":" + std::to_string(NA) + ",\"atlas_total\":" + std::to_string(total) + "}";
    write_text(dir / "maps.json", js);
    return n;
}


// ---------------------------------------------------------------- the lands: the game's maps joined edge to edge
// For every land (zone) the outdoor maps are stitched together where their exits meet (the exit says where you
// arrive on the other side, which places the next map exactly). The original world does not always close up, so
// a land becomes a few seamless REGIONS; every other map (houses, caves...) is a region of its own behind its door.
// kit/lands/Z/lands.json   regions: name, kind, size, the maps in it, arrival, exits (rect -> region + arrival), enemies
// kit/lands/Z/R.bin        "LKR1", u16 tw, u16 th, then 5 layers of tw*th u32 cells (0 ground, 1-2 under the
//                          fighters, 3-4 over them), then tw*th u8 walk
// kit/lands/Z/R_mini.png   one pixel per tile (the minimap)
static int side_of(const KitMap& m, const KExit& e) {
    const int W = m.tw * 8, H = m.th * 8;
    const bool near_t = e.y0 <= 24, near_b = e.y1 >= H - 24, near_l = e.x0 <= 24, near_r = e.x1 >= W - 24;
    const int s = e.dir == 0 ? 3 : e.dir == 1 ? 2 : e.dir == 2 ? 0 : e.dir == 3 ? 1 : -1;   // 0 left 1 right 2 top 3 bottom
    const bool nearv[4] = {near_l, near_r, near_t, near_b};
    if (s >= 0 && nearv[s]) return s;
    const bool wide = (e.x1 - e.x0) > (e.y1 - e.y0);
    if (near_t && wide) return 2;
    if (near_b && wide) return 3;
    if (near_l && !wide) return 0;
    if (near_r && !wide) return 1;
    return -1;
}

// ---------------------------------------------------------------- growing land into the gaps
// The original maps of a land don't fill its rectangle: between them is nothing (black). Here the gaps are
// filled with land in the same style, cut from the land's own maps: 6x6-tile pieces laid every 4 tiles,
// each chosen so its 2-tile overlap matches what is already there (the original maps first, then what has
// been grown), working outward from the maps. Pieces of scenery (trees, cliffs, water) are preferred and
// everything grown is solid: it closes the world in, it never opens new paths.
static void compose_map(const KitMap& m, std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, int bx, int by) {
    std::vector<int> ks;
    for (int kk = 0; kk < 4; ++kk) {
        if (!((m.mask >> kk) & 1) || ((m.light >> kk) & 1)) continue;
        bool any = false; for (uint32_t c : m.L[kk]) if (c) { any = true; break; }
        if (any) ks.push_back(kk);
    }
    std::sort(ks.begin(), ks.end(), [&](int a2, int b2) { return m.pri[a2] != m.pri[b2] ? m.pri[a2] > m.pri[b2] : a2 > b2; });
    int under = 1, over = 3;
    for (size_t r = 0; r < ks.size(); ++r) {
        const int kk = ks[r];
        int wl = 0;
        if (r > 0) { const bool front = m.pri[kk] <= 1 && m.pri[kk] < m.pri[ks[0]]; wl = front ? std::min(over++, 4) : std::min(under++, 2); }
        for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
            const uint32_t c = m.L[kk][static_cast<size_t>(y) * m.tw + x];
            if (!c || (c & (1u << 18))) continue;
            const int X = bx + x, Y = by + y;
            if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
            WL[wl][static_cast<size_t>(Y) * W + X] = c;
        }
    }
    for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
        const int X = bx + x, Y = by + y;
        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
        walk[static_cast<size_t>(Y) * W + X] |= m.walk[static_cast<size_t>(y) * m.tw + x];
    }
}
// a tile that is only black (or nothing): the original maps pad their edges with it - the "black between the maps"
static bool tile_void(uint32_t c) {
    static std::vector<int8_t> memo;
    const uint32_t id = c & 0xFFFFu;
    if (c == 0) return true;
    if (c & (1u << 19)) return false;
    if (memo.size() <= id) memo.resize(id + 1, -1);
    if (memo[id] < 0) {
        const uint8_t* t = romtiles::tile(static_cast<uint16_t>(id));
        bool v = true;
        if (t) for (int i = 0; i < 64 && v; ++i) { const uint8_t q = t[i]; if (q && g_bgpal[q * 3] + g_bgpal[q * 3 + 1] + g_bgpal[q * 3 + 2] > 36) v = false; }
        memo[id] = v ? 1 : 0;
    }
    return memo[id] == 1;
}
// how much of a tile is nature: leaves and grass (green) or water (blue) - 0..1
static float tile_nature(uint32_t c) {
    static std::vector<float> memo;
    const uint32_t id = c & 0xFFFFu;
    if (c == 0) return -1.0f;
    if (c & (1u << 19)) return 0.6f;      // animated: water, waterfalls, flowers
    if (memo.size() <= id) memo.resize(id + 1, -2.0f);
    if (memo[id] < -1.5f) {
        const uint8_t* t = romtiles::tile(static_cast<uint16_t>(id));
        int n = 0, g = 0;
        if (t) for (int i = 0; i < 64; ++i) {
            const uint8_t q = t[i]; if (!q) continue;
            const int r = g_bgpal[q * 3], gg = g_bgpal[q * 3 + 1], b = g_bgpal[q * 3 + 2];
            ++n;
            const int sat = std::max({r, gg, b}) - std::min({r, gg, b});
            if ((gg > r + 8 && gg >= b - 8) || (b > r + 30 && gg >= r && sat > 60)) ++g;
        }
        memo[id] = n ? static_cast<float>(g) / n : -1.0f;
    }
    return memo[id];
}
static bool cell_void(const std::vector<uint32_t> (&WL)[5], size_t s) {
    for (int l = 0; l < 5; ++l) if (!tile_void(WL[l][s])) return false;
    return true;
}
struct GrowPool {
    static constexpr int B = 10;
    std::unordered_set<uint64_t> adjh[5], adjv[5];        // tiles seen side by side / one above the other
    struct Piece { std::array<uint32_t, B * B * 5> c; std::array<uint8_t, B * B> w{}; int walkn = 0; int structure = 0; int map = -1; int kinds = 0; float nature = 0; int sx = 0, sy = 0; int rare = 0; };
    std::unordered_map<uint64_t, int> by_pos;      // (map, x, y) -> the piece cut there
    std::unordered_map<int, float> map_nature;      // how green / watery each map is on average (0..1)
    std::unordered_map<int, std::vector<int>> by_map;
    std::vector<Piece> pieces;
    std::unordered_map<uint64_t, std::vector<int>> by_cell;   // (cell index in piece, ground tile) -> pieces
    std::unordered_map<uint64_t, std::vector<int>> by_left, by_top;   // exact first 3 columns / rows -> pieces
    // every whole cell (5 layers) the land uses, how often, and the ground tiles by what may sit right / below
    std::vector<std::array<uint32_t, 5>> cells; std::vector<int> cell_n;
    std::unordered_map<uint32_t, std::vector<int>> cells_by_ground;
    std::unordered_map<uint32_t, std::unordered_set<uint32_t>> right_of, below_of, left_of, above_of;
    std::unordered_map<uint64_t, std::pair<int, int>> cell_walk;    // whole cell -> (times walkable, times seen) in the land's maps
    static uint64_t sig(const uint32_t* c, int stride = 1) { uint64_t h = 1469598103934665603ull; for (int l = 0; l < 5; ++l) { h ^= c[l * stride]; h *= 1099511628211ull; } return h; }
};
// the first 3 columns (0) or rows (1) of an 8x8 piece, all layers, as one number
static uint64_t strip_hash(const uint32_t* c, int rows) {
    uint64_t h = 1469598103934665603ull;
    for (int a = 0; a < 3; ++a) for (int b = 0; b < GrowPool::B; ++b) {
        const int i = rows ? b : a, j = rows ? a : b;
        for (int l = 0; l < 5; ++l) { h ^= c[(j * GrowPool::B + i) * 5 + l]; h *= 1099511628211ull; }
    }
    return h;
}
static GrowPool make_pool(const std::vector<int>& maps) {
    GrowPool P;
    const int B = GrowPool::B;
    for (int k : maps) {
        const KitMap& m = g_kit[static_cast<size_t>(k)];
        if (m.tw < B || m.th < B) continue;
        std::vector<uint32_t> WL[5];
        for (auto& l : WL) l.assign(static_cast<size_t>(m.tw) * m.th, 0);
        std::vector<uint8_t> wk(static_cast<size_t>(m.tw) * m.th, 0);
        compose_map(m, WL, wk, m.tw, m.th, 0, 0);
        for (size_t s2 = 0; s2 < WL[0].size(); ++s2) if (cell_void(WL, s2)) for (int l = 0; l < 5; ++l) WL[l][s2] = 0;
        for (int l = 0; l < 5; ++l) for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
            const size_t s2 = static_cast<size_t>(y) * m.tw + x;
            if (!WL[0][s2]) continue;
            if (x + 1 < m.tw && WL[0][s2 + 1]) P.adjh[l].insert((static_cast<uint64_t>(WL[l][s2]) << 32) | WL[l][s2 + 1]);
            if (y + 1 < m.th && WL[0][s2 + m.tw]) P.adjv[l].insert((static_cast<uint64_t>(WL[l][s2]) << 32) | WL[l][s2 + m.tw]);
        }
        {
            std::map<std::array<uint32_t, 5>, int> seen;
            for (size_t s2 = 0; s2 < WL[0].size(); ++s2) {
                if (!WL[0][s2]) continue;
                std::array<uint32_t, 5> c{WL[0][s2], WL[1][s2], WL[2][s2], WL[3][s2], WL[4][s2]};
                seen[c]++;
                { auto& cw = P.cell_walk[GrowPool::sig(c.data())]; cw.first += wk[s2] & 1; cw.second++; }
                const int x = static_cast<int>(s2 % m.tw), y = static_cast<int>(s2 / m.tw);
                if (x + 1 < m.tw && WL[0][s2 + 1]) { P.right_of[WL[0][s2]].insert(WL[0][s2 + 1]); P.left_of[WL[0][s2 + 1]].insert(WL[0][s2]); }
                if (y + 1 < m.th && WL[0][s2 + m.tw]) { P.below_of[WL[0][s2]].insert(WL[0][s2 + m.tw]); P.above_of[WL[0][s2 + m.tw]].insert(WL[0][s2]); }
            }
            for (auto& [c, n] : seen) { P.cells.push_back(c); P.cell_n.push_back(n); }
        }
        for (int y = 0; y + B <= m.th; y += 2) for (int x = 0; x + B <= m.tw; x += 2) {
            GrowPool::Piece pc; bool ok = true;
            for (int j = 0; j < B && ok; ++j) for (int i = 0; i < B; ++i) {
                const size_t s2 = static_cast<size_t>(y + j) * m.tw + x + i;
                if (!WL[0][s2]) { ok = false; break; }
                for (int l = 0; l < 5; ++l) pc.c[static_cast<size_t>((j * B + i) * 5 + l)] = WL[l][s2];
                pc.w[static_cast<size_t>(j * B + i)] = wk[s2];
                pc.walkn += wk[s2] & 1;
                if (!(wk[s2] & 1)) {   // a solid bit that is not nature: a piece of a building, a fence, a sign
                    float nv = -1;
                    for (int l = 4; l >= 0 && nv < 0; --l) nv = tile_nature(WL[l][s2]);
                    if (nv < 0.25f) pc.structure++;
                }
            }
            if (!ok) continue;
            {   // how busy the piece is: nature repeats a few tiles, buildings and machines use many
                std::set<uint32_t> ks2;
                for (int q = 0; q < B * B; ++q) for (int l = 0; l < 5; ++l) if (pc.c[static_cast<size_t>(q * 5 + l)]) ks2.insert(pc.c[static_cast<size_t>(q * 5 + l)]);
                pc.kinds = static_cast<int>(ks2.size());
                float ns = 0; int nn = 0;
                for (int q = 0; q < B * B; ++q) for (int l = 4; l >= 0; --l) { const float v = tile_nature(pc.c[static_cast<size_t>(q * 5 + l)]); if (v >= 0) { ns += v; ++nn; break; } }
                pc.nature = nn ? ns / nn : 0;
            }
            const int id = static_cast<int>(P.pieces.size());
            pc.map = k; pc.sx = x; pc.sy = y;
            P.by_pos[(static_cast<uint64_t>(k) << 40) | (static_cast<uint64_t>(y) << 20) | static_cast<uint64_t>(x)] = id;
            P.by_map[k].push_back(id);
            P.pieces.push_back(pc);
            P.by_left[strip_hash(pc.c.data(), 0)].push_back(id);
            P.by_top[strip_hash(pc.c.data(), 1)].push_back(id);
            for (int q = 0; q < B * B; ++q) P.by_cell[(static_cast<uint64_t>(q) << 32) | (pc.c[static_cast<size_t>(q * 5)] & 0xFFFFFu)].push_back(id);
        }
    }
    // the same cell may come from several maps: one entry, counts added
    {
        std::map<std::array<uint32_t, 5>, int> all;
        for (size_t i = 0; i < P.cells.size(); ++i) all[P.cells[i]] += P.cell_n[i];
        P.cells.clear(); P.cell_n.clear();
        for (auto& [c, n] : all) { P.cells_by_ground[c[0]].push_back(static_cast<int>(P.cells.size())); P.cells.push_back(c); P.cell_n.push_back(n); }
        {   // each map's own share of nature: a city is framed by more city, a jungle by more jungle
            std::unordered_map<int, std::pair<double, int>> acc;
            for (const auto& pc : P.pieces) { acc[pc.map].first += pc.nature; acc[pc.map].second++; }
            for (auto& [k, v] : acc) P.map_nature[k] = static_cast<float>(v.first / std::max(1, v.second));
        }
        // tiles the land hardly uses (under a sign, a chest, a lamp) look like specks when repeated: pieces with them come last
        for (auto& pc : P.pieces) {
            pc.rare = 0;
            for (int q = 0; q < B * B; ++q) {
                std::array<uint32_t, 5> c; for (int l = 0; l < 5; ++l) c[static_cast<size_t>(l)] = pc.c[static_cast<size_t>(q * 5 + l)];
                auto it = all.find(c);
                if (it == all.end() || it->second < 4) ++pc.rare;
            }
        }
    }
    return P;
}
// the seams the pieces leave: a grown tile next to one it never sits beside in the game is swapped for a
// tile that fits all four of its neighbours (a few passes, like the pieces of a puzzle settling)
static int repair_seams(std::vector<uint32_t> (&WL)[5], const std::vector<uint8_t>& grown, int W, int H, const GrowPool& P) {
    auto pair_ok = [&](int l, uint32_t a, uint32_t b, bool horiz) { return horiz ? P.adjh[l].count((static_cast<uint64_t>(a) << 32) | b) > 0 : P.adjv[l].count((static_cast<uint64_t>(a) << 32) | b) > 0; };
    auto bad_at = [&](size_t s2, const uint32_t* c) {
        const int x = static_cast<int>(s2 % W), y = static_cast<int>(s2 / W);
        int bad = 0;
        const int nb[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
        for (auto& d : nb) {
            const int NX = x + d[0], NY = y + d[1];
            if (NX < 0 || NY < 0 || NX >= W || NY >= H) continue;
            const size_t n2 = static_cast<size_t>(NY) * W + NX;
            if (!WL[0][n2]) continue;
            for (int l = 0; l < 5; ++l) {
                const bool first = d[0] < 0 || d[1] < 0;
                const uint32_t a = first ? WL[l][n2] : c[l], b = first ? c[l] : WL[l][n2];
                if (!pair_ok(l, a, b, d[1] == 0)) bad += l == 0 ? 3 : 1;
            }
        }
        return bad;
    };
    int fixed = 0;
    for (int pass = 0; pass < 4; ++pass) {
        int changed = 0;
        for (size_t s2 = 0; s2 < WL[0].size(); ++s2) {
            if (!grown[s2]) continue;
            uint32_t cur[5] = {WL[0][s2], WL[1][s2], WL[2][s2], WL[3][s2], WL[4][s2]};
            const int b0 = bad_at(s2, cur);
            if (b0 == 0) continue;
            // ground tiles that fit next to all ground neighbours
            const int x = static_cast<int>(s2 % W), y = static_cast<int>(s2 / W);
            std::vector<uint32_t> ok_ground;
            const std::unordered_set<uint32_t>* sets[4] = {nullptr, nullptr, nullptr, nullptr};
            if (x > 0 && WL[0][s2 - 1]) { auto it = P.right_of.find(WL[0][s2 - 1]); if (it != P.right_of.end()) sets[0] = &it->second; }
            if (x + 1 < W && WL[0][s2 + 1]) { auto it = P.left_of.find(WL[0][s2 + 1]); if (it != P.left_of.end()) sets[1] = &it->second; }
            if (y > 0 && WL[0][s2 - W]) { auto it = P.below_of.find(WL[0][s2 - W]); if (it != P.below_of.end()) sets[2] = &it->second; }
            if (y + 1 < H && WL[0][s2 + W]) { auto it = P.above_of.find(WL[0][s2 + W]); if (it != P.above_of.end()) sets[3] = &it->second; }
            const std::unordered_set<uint32_t>* smallest = nullptr;
            for (auto* st : sets) if (st && (!smallest || st->size() < smallest->size())) smallest = st;
            if (!smallest) continue;
            int best = -1, bb = b0, bn = -1;
            for (uint32_t g : *smallest) {
                bool all = true;
                for (auto* st : sets) if (st && !st->count(g)) { all = false; break; }
                if (!all) continue;
                auto it = P.cells_by_ground.find(g);
                if (it == P.cells_by_ground.end()) continue;
                for (int ci : it->second) {
                    if (P.cell_n[static_cast<size_t>(ci)] < 6) continue;      // rare tiles (a sign, a lamp's corner) stand out as specks
                    const int b = bad_at(s2, P.cells[static_cast<size_t>(ci)].data());
                    if (b < bb || (b == bb && best >= 0 && P.cell_n[static_cast<size_t>(ci)] > bn)) { bb = b; best = ci; bn = P.cell_n[static_cast<size_t>(ci)]; }
                }
            }
            if (best >= 0 && bb < b0) {
                for (int l = 0; l < 5; ++l) WL[l][s2] = P.cells[static_cast<size_t>(best)][static_cast<size_t>(l)];
                ++changed;
            }
        }
        fixed += changed;
        if (!changed) break;
    }
    // bits of overlay left alone by a seam (half a bush, a lone tuft): taken away when the ground fits better without
    for (size_t s2 = 0; s2 < WL[0].size(); ++s2) {
        if (!grown[s2]) continue;
        for (int l = 1; l < 5; ++l) {
            if (!WL[l][s2]) continue;
            uint32_t cur[5] = {WL[0][s2], WL[1][s2], WL[2][s2], WL[3][s2], WL[4][s2]};
            const int b0 = bad_at(s2, cur);
            cur[l] = 0;
            if (bad_at(s2, cur) < b0) { WL[l][s2] = 0; ++fixed; }
        }
    }
    return fixed;
}

// The simplest way to grow land that fits: carry each map's edge on outward. Forests, cliff walls, water and
// meadows at a map's border repeat (a tree every few tiles), so the last few columns / rows of each side are
// repeated with their own period - the forest just goes on. Every empty tile takes the map nearest to it.
struct GrowRect { int x, y, w, h; int per[4]; int map = -1; };   // per side: 0 left 1 right 2 top 3 bottom
static int side_period(const std::vector<uint32_t> (&WL)[5], int W, const GrowRect& r, int side) {
    // try periods 1..10: how many tiles along the side repeat P tiles further in
    int bestP = 1; double best = -1;
    const int len = side < 2 ? r.h : r.w;
    for (int P = 1; P <= 10; ++P) {
        int same = 0, tot = 0;
        for (int t = 0; t < len; ++t) for (int k = 0; k < P; ++k) {
            int ax, ay, bx, by;
            if (side == 0) { ax = r.x + k; ay = r.y + t; bx = ax + P; by = ay; }
            else if (side == 1) { ax = r.x + r.w - 1 - k; ay = r.y + t; bx = ax - P; by = ay; }
            else if (side == 2) { ax = r.x + t; ay = r.y + k; bx = ax; by = ay + P; }
            else { ax = r.x + t; ay = r.y + r.h - 1 - k; bx = ax; by = ay - P; }
            if (bx < r.x || by < r.y || bx >= r.x + r.w || by >= r.y + r.h) continue;
            const size_t a = static_cast<size_t>(ay) * W + ax, b = static_cast<size_t>(by) * W + bx;
            ++tot;
            bool eq = true;
            for (int l = 0; l < 5; ++l) if (WL[l][a] != WL[l][b]) { eq = false; break; }
            same += eq;
        }
        if (!tot) continue;
        const double sc = static_cast<double>(same) / tot - P * 0.01;
        if (sc > best) { best = sc; bestP = P; }
    }
    return bestP;
}
static int extend_edges(std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, std::vector<GrowRect> rects, std::vector<uint8_t>& grown) {
    for (auto& r : rects) for (int sd = 0; sd < 4; ++sd) r.per[sd] = side_period(WL, W, r, sd);
    int n = 0;
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        const size_t s2 = static_cast<size_t>(y) * W + x;
        if (WL[0][s2] || WL[1][s2] || WL[2][s2] || WL[3][s2] || WL[4][s2]) continue;
        // the nearest map
        int bi = -1; long bd = 1L << 60;
        for (size_t i = 0; i < rects.size(); ++i) {
            const auto& r = rects[i];
            const long dx = x < r.x ? r.x - x : (x >= r.x + r.w ? x - (r.x + r.w - 1) : 0);
            const long dy = y < r.y ? r.y - y : (y >= r.y + r.h ? y - (r.y + r.h - 1) : 0);
            const long d = dx * dx + dy * dy;
            if (d < bd) { bd = d; bi = static_cast<int>(i); }
        }
        if (bi < 0) continue;
        const auto& r = rects[static_cast<size_t>(bi)];
        int sx = x, sy = y;
        if (x < r.x) { const int P = r.per[0]; sx = r.x + ((r.x - x - 1) % P + P - 1 - 2 * ((r.x - x - 1) % P)) ; sx = r.x + (P - 1 - (r.x - x - 1) % P); }
        else if (x >= r.x + r.w) { const int P = r.per[1]; sx = r.x + r.w - P + ((x - (r.x + r.w)) % P); }
        if (y < r.y) { const int P = r.per[2]; sy = r.y + (P - 1 - (r.y - y - 1) % P); }
        else if (y >= r.y + r.h) { const int P = r.per[3]; sy = r.y + r.h - P + ((y - (r.y + r.h)) % P); }
        sx = std::clamp(sx, r.x, r.x + r.w - 1); sy = std::clamp(sy, r.y, r.y + r.h - 1);
        const size_t src = static_cast<size_t>(sy) * W + sx;
        if (!WL[0][src]) continue;      // a hole in the map itself: left for the pieces
        for (int l = 0; l < 5; ++l) WL[l][s2] = WL[l][src];
        walk[s2] = 0;
        grown[s2] = 1;
        ++n;
    }
    return n;
}

// Tile by tile instead: outward from the maps, every empty tile takes a whole cell (all 5 layers) that the
// land's own maps put next to each of its already-placed neighbours - like a puzzle, so trees stay whole and
// cliffs keep their edges. Cells that are common in the land are picked more often.
static int grow_cells(std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, const GrowPool& P, uint32_t seed, std::vector<uint8_t>& grown) {
    const size_t N = static_cast<size_t>(W) * H;
    std::vector<int> dist(N, -1);
    std::deque<size_t> q;
    for (size_t i = 0; i < N; ++i) if (WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i]) { dist[i] = 0; q.push_back(i); }
    std::vector<size_t> order;
    while (!q.empty()) {
        const size_t c = q.front(); q.pop_front();
        const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
        const int nb[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
        for (auto& d : nb) {
            const int nx = x + d[0], ny = y + d[1];
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            const size_t n2 = static_cast<size_t>(ny) * W + nx;
            if (dist[n2] >= 0) continue;
            dist[n2] = dist[c] + 1;
            order.push_back(n2);
            q.push_back(n2);
        }
    }
    uint32_t rs = seed * 2654435761u + 7;
    auto rnd = [&]() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; };
    auto pair_ok = [&](int l, uint32_t a, uint32_t b, bool horiz) { return horiz ? P.adjh[l].count((static_cast<uint64_t>(a) << 32) | b) > 0 : P.adjv[l].count((static_cast<uint64_t>(a) << 32) | b) > 0; };
    int n = 0;
    std::vector<int> best_list;
    for (size_t s2 : order) {
        const int x = static_cast<int>(s2 % W), y = static_cast<int>(s2 / W);
        const std::unordered_set<uint32_t>* sets[4] = {nullptr, nullptr, nullptr, nullptr};
        if (x > 0 && WL[0][s2 - 1]) { auto it = P.right_of.find(WL[0][s2 - 1]); if (it != P.right_of.end()) sets[0] = &it->second; }
        if (x + 1 < W && WL[0][s2 + 1]) { auto it = P.left_of.find(WL[0][s2 + 1]); if (it != P.left_of.end()) sets[1] = &it->second; }
        if (y > 0 && WL[0][s2 - W]) { auto it = P.below_of.find(WL[0][s2 - W]); if (it != P.below_of.end()) sets[2] = &it->second; }
        if (y + 1 < H && WL[0][s2 + W]) { auto it = P.above_of.find(WL[0][s2 + W]); if (it != P.above_of.end()) sets[3] = &it->second; }
        const std::unordered_set<uint32_t>* smallest = nullptr;
        for (auto* st : sets) if (st && (!smallest || st->size() < smallest->size())) smallest = st;
        int bestbad = 1 << 30; best_list.clear();
        auto consider = [&](int ci) {
            const auto& c = P.cells[static_cast<size_t>(ci)];
            int bad = 0;
            const int nb[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
            for (auto& d : nb) {
                const int NX = x + d[0], NY = y + d[1];
                if (NX < 0 || NY < 0 || NX >= W || NY >= H) continue;
                const size_t n2 = static_cast<size_t>(NY) * W + NX;
                if (!WL[0][n2] && !WL[1][n2] && !WL[3][n2]) continue;
                for (int l = 0; l < 5; ++l) {
                    const bool first = d[0] < 0 || d[1] < 0;
                    if (!pair_ok(l, first ? WL[l][n2] : c[static_cast<size_t>(l)], first ? c[static_cast<size_t>(l)] : WL[l][n2], d[1] == 0)) bad += l == 0 ? 3 : 2;
                    if (bad > bestbad) return;
                }
            }
            if (bad < bestbad) { bestbad = bad; best_list.clear(); }
            if (bad == bestbad) best_list.push_back(ci);
        };
        if (smallest) {
            for (uint32_t g : *smallest) {
                bool all = true;
                for (auto* st : sets) if (st && !st->count(g)) { all = false; break; }
                if (!all) continue;
                auto it = P.cells_by_ground.find(g);
                if (it != P.cells_by_ground.end()) for (int ci : it->second) consider(ci);
            }
        }
        if (best_list.empty() || bestbad > 0) {
            // nothing fits all around: the least bad of a few hundred common cells
            for (int t = 0; t < 300; ++t) consider(static_cast<int>(rnd() % P.cells.size()));
        }
        if (best_list.empty()) continue;
        // weighted by how common the cell is
        long tot = 0; for (int ci : best_list) tot += P.cell_n[static_cast<size_t>(ci)];
        long pick = static_cast<long>(rnd() % static_cast<uint32_t>(std::max<long>(1, tot)));
        int chosen = best_list[0];
        for (int ci : best_list) { pick -= P.cell_n[static_cast<size_t>(ci)]; if (pick < 0) { chosen = ci; break; } }
        for (int l = 0; l < 5; ++l) WL[l][s2] = P.cells[static_cast<size_t>(chosen)][static_cast<size_t>(l)];
        walk[s2] = 0;
        grown[s2] = 1;
        ++n;
    }
    return n;
}
// smooth noise 0..1 (value noise, a cell every `sc` units)
static float vnoise(float x, float y, uint32_t seed) {
    auto h = [&](int a, int b) { uint32_t v = static_cast<uint32_t>(a) * 374761393u + static_cast<uint32_t>(b) * 668265263u + seed * 2246822519u; v = (v ^ (v >> 13)) * 1274126177u; return static_cast<float>((v ^ (v >> 16)) & 0xFFFF) / 65535.0f; };
    const int x0 = static_cast<int>(std::floor(x)), y0 = static_cast<int>(std::floor(y));
    float fx = x - x0, fy = y - y0; fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    const float a = h(x0, y0) + (h(x0 + 1, y0) - h(x0, y0)) * fx, b = h(x0, y0 + 1) + (h(x0 + 1, y0 + 1) - h(x0, y0 + 1)) * fx;
    return a + (b - a) * fy;
}
// mine: only these empty cells are grown (others left for another land's pool); open: the land grown is mostly
// walkable country (meadows, paths and clearings with woods between) instead of scenery you only look at
static int grow_land(std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, const GrowPool& P, uint32_t seed, const std::vector<GrowRect>& rects,
                     const std::vector<uint8_t>* mine = nullptr, bool open = false) {
    const int B = GrowPool::B, S = 6;
    if (P.pieces.empty()) return 0;
    std::vector<uint8_t> have(static_cast<size_t>(W) * H, 0);
    for (size_t i = 0; i < have.size(); ++i) {
        have[i] = WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i] ? 2 : 0;   // 2 = original
        if (have[i] && !walk[i] && cell_void(WL, i) && (!mine || (*mine)[i])) { have[i] = 0; for (int l = 0; l < 5; ++l) WL[l][i] = 0; }    // black padding: grown over
        if (!have[i] && mine && !(*mine)[i]) have[i] = 3;     // 3 = not this pool's to grow
    }
    if (std::getenv("LOG2_GROW_CELLS")) {
        std::vector<uint8_t> grown(have.size(), 0);
        const int nc = grow_cells(WL, walk, W, H, P, seed, grown);
        const int fx = repair_seams(WL, grown, W, H, P);
        std::fprintf(stderr, "[export]   %d tiles grown one by one, %d mended\n", nc, fx);
        if (const char* gm = std::getenv("LOG2_GROW_MASK")) { static int cnt2 = 0; std::ofstream o(std::string(gm) + "c" + std::to_string(cnt2++) + ".bin", std::ios::binary); o.write(reinterpret_cast<const char*>(&W), 4); o.write(reinterpret_cast<const char*>(&H), 4); o.write(reinterpret_cast<const char*>(grown.data()), static_cast<std::streamsize>(grown.size())); }
        return nc;
    }
    // where each tile comes from (map, x, y): the piece that carries on from there fits without a seam
    std::vector<int> srcm(have.size(), -1); std::vector<int16_t> srcx(have.size(), 0), srcy(have.size(), 0);
    for (const auto& r : rects) for (int y = 0; y < r.h; ++y) for (int x = 0; x < r.w; ++x) {
        const int X = r.x + x, Y = r.y + y;
        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
        const size_t s2 = static_cast<size_t>(Y) * W + X;
        if (have[s2] == 2) { srcm[s2] = r.map; srcx[s2] = static_cast<int16_t>(x); srcy[s2] = static_cast<int16_t>(y); }
    }
    std::vector<uint8_t> ext(have.size(), 0);
    const int ne = std::getenv("LOG2_GROW_EXTEND") ? extend_edges(WL, walk, W, H, rects, ext) : 0;
    std::fprintf(stderr, "[export]   %d tiles carried on from the edges\n", ne);
    for (size_t i = 0; i < have.size(); ++i) if (ext[i]) have[i] = 1;
    // the places to fill: every 4 tiles; first those next to land, outward (by distance)
    const int GX = (W + S - 1) / S + 1, GY = (H + S - 1) / S + 1;
    std::vector<int> dist(static_cast<size_t>(GX) * GY, -1);
    std::deque<int> q;
    auto empties = [&](int gx, int gy) { int n = 0, tot = 0; for (int j = 0; j < B; ++j) for (int i = 0; i < B; ++i) { const int X = gx * S - 1 + i, Y = gy * S - 1 + j; if (X < 0 || Y < 0 || X >= W || Y >= H) continue; const uint8_t hv = have[static_cast<size_t>(Y) * W + X]; if (hv == 3) continue; ++tot; if (!hv) ++n; } return std::make_pair(n, tot); };
    for (int gy = 0; gy < GY; ++gy) for (int gx = 0; gx < GX; ++gx) {
        auto [n, tot] = empties(gx, gy);
        if (tot && n < tot) { dist[static_cast<size_t>(gy) * GX + gx] = 0; q.push_back(gy * GX + gx); }
    }
    if (q.empty()) {   // nothing of this pool's to grow from (its part touches only another's): start at its edge
        for (int gy = 0; gy < GY; ++gy) for (int gx = 0; gx < GX; ++gx) { auto [n, tot] = empties(gx, gy); if (tot && n) { dist[static_cast<size_t>(gy) * GX + gx] = 0; q.push_back(gy * GX + gx); gy = GY; break; } }
    }
    while (!q.empty()) {
        const int c = q.front(); q.pop_front();
        const int gx = c % GX, gy = c / GX;
        const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
        for (auto& d : d4) {
            const int nx = gx + d[0], ny = gy + d[1];
            if (nx < 0 || ny < 0 || nx >= GX || ny >= GY || dist[static_cast<size_t>(ny) * GX + nx] >= 0) continue;
            dist[static_cast<size_t>(ny) * GX + nx] = dist[static_cast<size_t>(c)] + 1;
            q.push_back(ny * GX + nx);
        }
    }
    std::vector<int> order;
    for (int c = 0; c < GX * GY; ++c) if (dist[static_cast<size_t>(c)] >= 0) order.push_back(c);
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return dist[static_cast<size_t>(a)] < dist[static_cast<size_t>(b)]; });
    uint32_t rs = seed * 2654435761u + 1;
    auto rnd = [&]() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; };
    int placed = 0;
    std::vector<int> cand;
    // which piece went where (no piece twice side by side: the country does not repeat itself)
    std::vector<int> used_at(static_cast<size_t>(GX) * GY, -1);
    std::unordered_map<int, int> use_n;
    for (int c : order) {
        const int gx = c % GX, gy = c / GX;
        const int X0 = gx * S - 1, Y0 = gy * S - 1;
        auto [n, tot] = empties(gx, gy);
        if (!tot || n == 0) continue;
        const bool far = open && dist[static_cast<size_t>(c)] > 3;     // out in the country: fewer pieces tried (a big planet)
        const int capc = far ? 120 : 700;
        // candidates: pieces whose ground matches a cell that is already there
        cand.clear();
        for (int j = 0; j < B && cand.empty(); ++j) for (int i = 0; i < B; ++i) {
            const int X = X0 + i, Y = Y0 + j;
            if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
            const uint8_t hv = have[static_cast<size_t>(Y) * W + X];
            if (!hv || hv == 3) continue;
            auto it = P.by_cell.find((static_cast<uint64_t>(j * B + i) << 32) | (WL[0][static_cast<size_t>(Y) * W + X] & 0xFFFFFu));
            if (it != P.by_cell.end()) {
                const auto& v = it->second;
                if (static_cast<int>(v.size()) <= capc) cand = v; else for (int t = 0; t < capc; ++t) cand.push_back(v[rnd() % v.size()]);
                break;
            }
        }
        // pieces whose first columns / rows are exactly what lies there already (seamless)
        for (int rows = 0; rows < 2; ++rows) {
            uint32_t buf[GrowPool::B * GrowPool::B * 5] = {};
            bool full = true;
            for (int a = 0; a < 3 && full; ++a) for (int b = 0; b < B; ++b) {
                const int i = rows ? b : a, j = rows ? a : b;
                const int X = X0 + i, Y = Y0 + j;
                if (X < 0 || Y < 0 || X >= W || Y >= H || !have[static_cast<size_t>(Y) * W + X] || have[static_cast<size_t>(Y) * W + X] == 3) { full = false; break; }
                for (int l = 0; l < 5; ++l) buf[(j * B + i) * 5 + l] = WL[l][static_cast<size_t>(Y) * W + X];
            }
            if (!full) continue;
            auto it = (rows ? P.by_top : P.by_left).find(strip_hash(buf, rows));
            if (it != (rows ? P.by_top : P.by_left).end()) {
                const auto& v = it->second;
                for (int t = 0; t < static_cast<int>(std::min<size_t>(v.size(), far ? 80 : 300)); ++t) cand.push_back(v.size() <= 300 ? v[static_cast<size_t>(t)] : v[rnd() % v.size()]);
            }
        }
        // the nearest of the region's maps: its own pieces are preferred (the land around it in its style)
        int near_map = -1; long nd = 1L << 60;
        for (const auto& r : rects) {
            const int cx = X0 + B / 2, cy = Y0 + B / 2;
            const long dx = cx < r.x ? r.x - cx : (cx >= r.x + r.w ? cx - (r.x + r.w - 1) : 0);
            const long dy = cy < r.y ? r.y - cy : (cy >= r.y + r.h ? cy - (r.y + r.h - 1) : 0);
            if (dx * dx + dy * dy < nd) { nd = dx * dx + dy * dy; near_map = r.map; }
        }
        {   // carry on from the neighbours' sources (each looked-up piece continues what lies there exactly)
            int tries = 0;
            std::set<uint64_t> seen;
            for (int j = 0; j < B && tries < 10; ++j) for (int i = 0; i < B && tries < 10; ++i) {
                const int X = X0 + i, Y = Y0 + j;
                if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                const size_t s2 = static_cast<size_t>(Y) * W + X;
                if (!have[s2] || have[s2] == 3 || srcm[s2] < 0) continue;
                for (int dy = 0; dy <= 1; ++dy) for (int dx = 0; dx <= 1; ++dx) {
                    const int px = (srcx[s2] - i) & ~1, py = (srcy[s2] - j) & ~1;
                    const int qx = px + dx * 2 * ((srcx[s2] - i) & 1), qy = py + dy * 2 * ((srcy[s2] - j) & 1);
                    if (qx < 0 || qy < 0) continue;
                    const uint64_t key = (static_cast<uint64_t>(srcm[s2]) << 40) | (static_cast<uint64_t>(qy) << 20) | static_cast<uint64_t>(qx);
                    if (!seen.insert(key).second) continue;
                    auto it = P.by_pos.find(key);
                    if (it != P.by_pos.end()) { cand.push_back(it->second); ++tries; }
                }
            }
        }
        auto bm = P.by_map.find(near_map);
        if (bm != P.by_map.end() && !bm->second.empty()) for (int t = 0; t < (far ? 60 : 250); ++t) cand.push_back(bm->second[rnd() % bm->second.size()]);
        for (int t = 0; t < (far ? 25 : 60); ++t) cand.push_back(static_cast<int>(rnd() % P.pieces.size()));
        // open country: meadows (walkable pieces wanted) with woods and rocks between (scenery wanted)
        double walkw = -0.6;
        if (open && dist[static_cast<size_t>(c)] >= 2) {
            const float nz = vnoise(gx / 9.0f, gy / 9.0f, seed) * 0.75f + vnoise(gx / 3.0f, gy / 3.0f, seed + 7) * 0.25f;
            walkw = nz > 0.36f ? 1.4 : (nz > 0.30f ? 0.3 : -0.5);
        }
        int best = -1; double bs = -1e18;
        double natw = 40.0 + 110.0 * std::min(dist[static_cast<size_t>(c)], 3);   // away from the places nature takes over
        {   // ...but only as much as the nearest place is nature itself (between city blocks: pavement, not jungle)
            auto mn = P.map_nature.find(near_map);
            const float nat = mn != P.map_nature.end() ? mn->second : 0.5f;
            natw *= std::clamp((nat - 0.15f) / 0.35f, 0.0f, 1.0f);
        }
        for (int id : cand) {
            const auto& pc = P.pieces[static_cast<size_t>(id)];
            double sc = walkw * pc.walkn + (pc.map == near_map ? 6.0 : 0.0);      // scenery a little, the nearest map's style more
            if (near_map >= 0 && pc.map != near_map && g_kit[static_cast<size_t>(pc.map)].name != g_kit[static_cast<size_t>(near_map)].name) sc -= g_kit[static_cast<size_t>(near_map)].name.empty() ? 14.0 : 40.0;   // another place's look (city bits in the jungle)
            sc -= 0.9 * std::max(0, pc.kinds - 14);
            sc += natw * pc.nature;
            sc -= 5.0 * pc.rare;
            {   // no bits of buildings grown in the gaps (half a house, a cut-off wall): plain ground or nature
                auto mn2 = P.map_nature.find(near_map);
                const float nat2 = mn2 != P.map_nature.end() ? mn2->second : 0.5f;
                sc -= (nat2 < 0.3f ? 6.0 : 2.0) * pc.structure;
            }      // trees, grass and water around the places, as the game itself frames them      // busy pieces (buildings, machines) only where they fit very well
            for (int j = 0; j < B; ++j) for (int i = 0; i < B; ++i) {
                const int X = X0 + i, Y = Y0 + j;
                if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                const size_t s2 = static_cast<size_t>(Y) * W + X;
                const uint32_t* pcc = &pc.c[static_cast<size_t>((j * B + i) * 5)];
                if (have[s2] == 3) continue;
                if (have[s2]) {
                    // where the piece lies over land already there: the same tiles
                    const double w = 3.0;
                    for (int l = 0; l < 5; ++l) sc += (pcc[l] == WL[l][s2]) ? w : -w;
                    continue;
                }
                // a new tile next to land already there: only pairs the game itself puts side by side
                const int nb[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
                for (auto& d : nb) {
                    const int NX = X + d[0], NY = Y + d[1];
                    if (NX < 0 || NY < 0 || NX >= W || NY >= H) continue;
                    const size_t n2 = static_cast<size_t>(NY) * W + NX;
                    if (!have[n2] || have[n2] == 3) continue;   // an empty neighbour inside the piece gets the piece's own tile: fine by itself
                    for (int l = 0; l < 5; ++l) {
                        const uint32_t a = d[0] < 0 || d[1] < 0 ? WL[l][n2] : pcc[l];
                        const uint32_t b2 = d[0] < 0 || d[1] < 0 ? pcc[l] : WL[l][n2];
                        const bool ok = d[1] == 0 ? P.adjh[l].count((static_cast<uint64_t>(a) << 32) | b2) : P.adjv[l].count((static_cast<uint64_t>(a) << 32) | b2);
                        sc += ok ? 1.0 : -4.0;
                    }
                }
            }
            if (open) {
                for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) {
                    const int ux = gx + dx, uy = gy + dy;
                    if ((dx || dy) && ux >= 0 && uy >= 0 && ux < GX && uy < GY && used_at[static_cast<size_t>(uy) * GX + ux] == id) sc -= 14.0;
                }
                auto un = use_n.find(id);
                if (un != use_n.end()) sc -= 0.25 * std::min(un->second, 40);
                sc += (rnd() % 1000) * 0.004;     // a little chance: two equal pieces take turns
            }
            sc += (rnd() % 100) * 0.001;
            if (sc > bs) { bs = sc; best = id; }
        }
        if (best < 0) continue;
        const auto& pc = P.pieces[static_cast<size_t>(best)];
        for (int j = 0; j < B; ++j) for (int i = 0; i < B; ++i) {
            const int X = X0 + i, Y = Y0 + j;
            if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
            const size_t s2 = static_cast<size_t>(Y) * W + X;
            if (have[s2]) continue;
            for (int l = 0; l < 5; ++l) WL[l][s2] = pc.c[static_cast<size_t>((j * B + i) * 5 + l)];
            walk[s2] = 0;
            {   // walkable where the game mostly lets you walk on that very cell (no invisible walls in grown land)
                walk[s2] = pc.w[static_cast<size_t>(j * B + i)];
                auto cw = P.cell_walk.find(GrowPool::sig(&pc.c[static_cast<size_t>((j * B + i) * 5)]));
                if (cw != P.cell_walk.end()) walk[s2] = cw->second.first * 10 >= cw->second.second * 3 ? 3 : 0;
            }
            have[s2] = 1;
            srcm[s2] = pc.map; srcx[s2] = static_cast<int16_t>(pc.sx + i); srcy[s2] = static_cast<int16_t>(pc.sy + j);
        }
        used_at[static_cast<size_t>(c)] = best;
        use_n[best]++;
        ++placed;
    }
    std::vector<uint8_t> grown(have.size(), 0);
    for (size_t i = 0; i < have.size(); ++i) grown[i] = have[i] == 1;
    const int fx = repair_seams(WL, grown, W, H, P);
    for (size_t i = 0; i < have.size(); ++i) {
        if (!grown[i]) continue;
        const uint32_t c[5] = {WL[0][i], WL[1][i], WL[2][i], WL[3][i], WL[4][i]};
        auto cw = P.cell_walk.find(GrowPool::sig(c));
        if (cw != P.cell_walk.end()) walk[i] = cw->second.first * 10 >= cw->second.second * 3 ? 3 : 0;
    }
    if (const char* gm = std::getenv("LOG2_GROW_MASK")) {   // dev: which tiles were grown
        static int cnt = 0;
        std::ofstream o(std::string(gm) + std::to_string(cnt++) + ".bin", std::ios::binary);
        o.write(reinterpret_cast<const char*>(&W), 4); o.write(reinterpret_cast<const char*>(&H), 4);
        o.write(reinterpret_cast<const char*>(grown.data()), static_cast<std::streamsize>(grown.size()));
    }
    std::fprintf(stderr, "[export]   %d seams mended\n", fx);
    return placed;
}
// ---------------------------------------------------------------- COUNTRY THE WAY THE GAME BUILDS IT
// Learned from the game's own maps: every outdoor place is one ground (grass, sand, snow, pavement) laid as a
// small repeating pattern, with whole things standing on it - a tree, a rock, a bush, a stump, a flower bed -
// each one complete and with ground all round it. So the land between places is made the same way: the land's
// own ground pattern, and its own things copied whole from its maps (never a piece of one), in woods and
// clearings. Nothing is ever cut in half and no tile is ever put next to one it does not belong with.
struct CountryKit {
    int px = 1, py = 1;
    std::vector<std::array<uint32_t, 5>> motif;      // px*py cells
    std::set<uint32_t> ground;                       // the ground's tiles (layer 0)
    bool periodic = true;                            // a true repeating pattern; else the tiles mixed as the game mixes them
    std::vector<std::pair<uint32_t, int>> gw;        // ground tiles and how often
    std::set<uint64_t> gh, gv;                       // ground tiles seen side by side / one above the other
    struct Stamp { int w, h, mx, my, n; float nature; bool made = false; std::vector<std::array<uint32_t, 5>> c; std::vector<uint8_t> wk, solid; };
    std::vector<Stamp> stamps;
    float nature = 0;
    bool ok = false;
};
// tiles of things people made (benches, pads, lamps, signs): seen in the cities far more than out in nature
static bool city_name(const KitMap& m) {
    const std::string nm = !m.place.empty() ? m.place : m.name;
    return (nm.find("City") != std::string::npos || nm.find("Capsule") != std::string::npos || nm.find("Town") != std::string::npos || nm.find("Highway") != std::string::npos ||
            nm.find("Namek") != std::string::npos || nm.find("Ship") != std::string::npos || nm.find("Lab") != std::string::npos) && nm.find("Outside") == std::string::npos;
}
static void compose_map(const KitMap& m, std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, int bx, int by);
static const std::unordered_set<uint32_t>& manmade_tiles() {
    static std::unordered_set<uint32_t> out; static bool done = false;
    if (done) return out;
    done = true;
    std::unordered_map<uint32_t, std::pair<int, int>> cnt;      // tile -> (in cities, elsewhere)
    for (const auto& m : g_kit) {
        if (m.tw < 8 || m.th < 8 || m.name == "The World") continue;
        const bool city = city_name(m);
        std::vector<uint32_t> WL[5]; for (auto& l : WL) l.assign(static_cast<size_t>(m.tw) * m.th, 0);
        std::vector<uint8_t> wk(static_cast<size_t>(m.tw) * m.th, 0);
        compose_map(m, WL, wk, m.tw, m.th, 0, 0);
        for (int l = 0; l < 5; ++l) for (uint32_t c : WL[l]) if (c) { auto& e = cnt[c & 0xFFFFu]; (city ? e.first : e.second)++; }
    }
    for (auto& [t, e] : cnt) if (e.first >= 2 && e.first > 3 * e.second) out.insert(t);
    return out;
}
static CountryKit make_country_kit(const std::vector<int>& maps) {
    CountryKit K;
    // 1. the ground: the plain walkable cells of the land's maps (nothing standing on them)
    std::map<uint32_t, int> tcount;
    struct MapCells { int k, tw, th; std::vector<uint32_t> WL[5]; std::vector<uint8_t> wk; };
    std::vector<MapCells> mcs;
    for (int k : maps) {
        const KitMap& m = g_kit[static_cast<size_t>(k)];
        if (m.tw < 8 || m.th < 8) continue;
        MapCells mc; mc.k = k; mc.tw = m.tw; mc.th = m.th;
        for (auto& l : mc.WL) l.assign(static_cast<size_t>(m.tw) * m.th, 0);
        mc.wk.assign(static_cast<size_t>(m.tw) * m.th, 0);
        compose_map(m, mc.WL, mc.wk, m.tw, m.th, 0, 0);
        for (size_t i = 0; i < mc.wk.size(); ++i)
            if ((mc.wk[i] & 1) && mc.WL[0][i] && !mc.WL[1][i] && !mc.WL[2][i] && !mc.WL[3][i] && !mc.WL[4][i] && !(mc.WL[0][i] & (1u << 19))) tcount[mc.WL[0][i]]++;
        mcs.push_back(std::move(mc));
    }
    if (tcount.empty()) return K;
    std::vector<std::pair<int, uint32_t>> tv;
    for (auto& [t, n] : tcount) tv.push_back({n, t});
    std::sort(tv.rbegin(), tv.rend());
    // the ground set: the most used plain tiles that make up the bulk (a grass pattern is a few tiles)
    long tot = 0; for (auto& p : tv) tot += p.first;
    long acc = 0;
    for (auto& [n, t] : tv) { if (acc > tot * 0.55 && K.ground.size() >= 1) break; if (K.ground.size() >= 8) break; K.ground.insert(t); acc += n; }
    auto is_ground = [&](const MapCells& mc, size_t i) {
        return mc.WL[0][i] && K.ground.count(mc.WL[0][i]) && !mc.WL[1][i] && !mc.WL[2][i] && !mc.WL[3][i] && !mc.WL[4][i];
    };
    auto is_plain = [&](const MapCells& mc, size_t i) {     // any bare walkable ground (the grass has many tiles)
        return (mc.wk[i] & 1) && mc.WL[0][i] && !mc.WL[1][i] && !mc.WL[2][i] && !mc.WL[3][i] && !mc.WL[4][i] && !(mc.WL[0][i] & (1u << 19));
    };
    // 2. its pattern: the period (up to 4x4) it repeats with, read from the map with the most of it
    int bestm = -1; long bestn = 0;
    for (size_t mi = 0; mi < mcs.size(); ++mi) { long n = 0; for (size_t i = 0; i < mcs[mi].wk.size(); ++i) n += is_ground(mcs[mi], i); if (n > bestn) { bestn = n; bestm = static_cast<int>(mi); } }
    if (bestm < 0) return K;
    const MapCells& G = mcs[static_cast<size_t>(bestm)];
    double bs = -1;
    for (int py = 1; py <= 4; ++py) for (int px = 1; px <= 4; ++px) {
        long same = 0, n = 0;
        for (int y = 0; y + py < G.th; ++y) for (int x = 0; x + px < G.tw; ++x) {
            const size_t i = static_cast<size_t>(y) * G.tw + x;
            if (!is_ground(G, i)) continue;
            const size_t a = i + px, b = i + static_cast<size_t>(py) * G.tw;
            if (is_ground(G, a)) { ++n; same += G.WL[0][a] == G.WL[0][i]; }
            if (is_ground(G, b)) { ++n; same += G.WL[0][b] == G.WL[0][i]; }
        }
        if (!n) continue;
        const double sc = static_cast<double>(same) / n - 0.004 * px * py;
        if (sc > bs) { bs = sc; K.px = px; K.py = py; }
    }
    K.periodic = bs > 0.9;
    for (auto& [n, t] : tv) if (K.ground.count(t)) K.gw.push_back({t, n});
    for (auto& mc : mcs) for (int y = 0; y < mc.th; ++y) for (int x = 0; x < mc.tw; ++x) {
        const size_t i = static_cast<size_t>(y) * mc.tw + x;
        if (!is_ground(mc, i)) continue;
        if (x + 1 < mc.tw && is_ground(mc, i + 1)) K.gh.insert((static_cast<uint64_t>(mc.WL[0][i]) << 32) | mc.WL[0][i + 1]);
        if (y + 1 < mc.th && is_ground(mc, i + mc.tw)) K.gv.insert((static_cast<uint64_t>(mc.WL[0][i]) << 32) | mc.WL[0][i + mc.tw]);
    }
    K.motif.assign(static_cast<size_t>(K.px * K.py), {});
    for (int j = 0; j < K.py; ++j) for (int i = 0; i < K.px; ++i) {
        std::map<uint32_t, int> c;
        for (int y = j; y < G.th; y += K.py) for (int x = i; x < G.tw; x += K.px) { const size_t q = static_cast<size_t>(y) * G.tw + x; if (is_ground(G, q)) c[G.WL[0][q]]++; }
        uint32_t best = *K.ground.begin(); int bn = -1;
        for (auto& [t, n] : c) if (n > bn) { bn = n; best = t; }
        K.motif[static_cast<size_t>(j * K.px + i)] = {best, 0, 0, 0, 0};
    }
    // 3. the things standing on it: whole, with ground all round
    std::map<std::vector<uint32_t>, int> seen;
    float nat_sum = 0; int nat_n = 0;
    for (auto& mc : mcs) {
        std::vector<uint8_t> done(mc.wk.size(), 0);
        for (int y0 = 0; y0 < mc.th; ++y0) for (int x0 = 0; x0 < mc.tw; ++x0) {
            const size_t s0 = static_cast<size_t>(y0) * mc.tw + x0;
            if (done[s0] || is_plain(mc, s0) || (!mc.WL[0][s0] && !mc.WL[1][s0] && !mc.WL[3][s0])) continue;
            std::vector<size_t> comp{s0}, st{s0}; done[s0] = 1;
            int bx0 = x0, bx1 = x0, by0 = y0, by1 = y0; bool bad = false;
            while (!st.empty()) {
                const size_t c = st.back(); st.pop_back();
                const int cx = static_cast<int>(c % mc.tw), cy = static_cast<int>(c / mc.tw);
                bx0 = std::min(bx0, cx); bx1 = std::max(bx1, cx); by0 = std::min(by0, cy); by1 = std::max(by1, cy);
                if (bx1 - bx0 > 13 || by1 - by0 > 13) bad = true;
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                    const int X = cx + dx, Y = cy + dy;
                    if (X < 0 || Y < 0 || X >= mc.tw || Y >= mc.th) { bad = true; continue; }
                    const size_t n2 = static_cast<size_t>(Y) * mc.tw + X;
                    if (done[n2] || is_plain(mc, n2)) continue;
                    if (!mc.WL[0][n2] && !mc.WL[1][n2] && !mc.WL[3][n2]) { bad = true; continue; }
                    done[n2] = 1; st.push_back(n2); comp.push_back(n2);
                }
            }
            if (bad) continue;
            // ground all round (one cell out)
            for (int y = by0 - 1; y <= by1 + 1 && !bad; ++y) for (int x = bx0 - 1; x <= bx1 + 1; ++x) {
                if (x >= bx0 && x <= bx1 && y >= by0 && y <= by1) continue;
                if (x < 0 || y < 0 || x >= mc.tw || y >= mc.th || !is_plain(mc, static_cast<size_t>(y) * mc.tw + x)) { bad = true; break; }
            }
            if (bad) continue;
            CountryKit::Stamp S;
            S.w = bx1 - bx0 + 1; S.h = by1 - by0 + 1; S.mx = bx0 % K.px; S.my = by0 % K.py; S.n = 1;
            S.c.assign(static_cast<size_t>(S.w * S.h), {}); S.wk.assign(static_cast<size_t>(S.w * S.h), 3); S.solid.assign(static_cast<size_t>(S.w * S.h), 0);
            std::vector<uint32_t> keyv{static_cast<uint32_t>(S.w), static_cast<uint32_t>(S.h)};
            float ns = 0; int nn = 0;
            for (size_t c : comp) {
                const int x = static_cast<int>(c % mc.tw) - bx0, y = static_cast<int>(c / mc.tw) - by0;
                const size_t q = static_cast<size_t>(y) * S.w + x;
                for (int l = 0; l < 5; ++l) S.c[q][static_cast<size_t>(l)] = mc.WL[l][c];
                S.wk[q] = mc.wk[c] & 1 ? 3 : 0;
                S.solid[q] = 1;
                for (int l = 4; l >= 0; --l) { const float v = tile_nature(mc.WL[l][c]); if (v >= 0) { ns += v; ++nn; break; } }
            }
            for (size_t q = 0; q < S.c.size(); ++q) for (int l = 0; l < 5; ++l) keyv.push_back(S.solid[q] ? S.c[q][static_cast<size_t>(l)] : 0);
            S.nature = nn ? ns / nn : 0;
            {   int mm = 0, tc = 0;
                const auto& MT = manmade_tiles();
                for (size_t c : comp) for (int l = 0; l < 5; ++l) if (mc.WL[l][c]) { ++tc; if (MT.count(mc.WL[l][c] & 0xFFFFu)) ++mm; }
                S.made = tc && mm * 10 >= tc * 3;
            }
            nat_sum += S.nature; ++nat_n;
            // buildings (doors, windows: many cells, little nature) are not scattered about
            if (comp.size() > 9 && S.nature < 0.2f) continue;
            if (comp.size() > 60) continue;
            auto it = seen.find(keyv);
            if (it != seen.end()) { K.stamps[static_cast<size_t>(it->second)].n++; continue; }
            seen[keyv] = static_cast<int>(K.stamps.size());
            K.stamps.push_back(std::move(S));
        }
    }
    {   // how green the land is: nature from its ground
        float ns = 0; int nn = 0;
        for (auto& m : K.motif) { const float v = tile_nature(m[0]); if (v >= 0) { ns += v; ++nn; } }
        K.nature = nn ? ns / nn : 0;
    }
    K.ok = true;
    return K;
}
// lay the land's ground on every cell of mask, then scatter its things (woods where the noise says, open
// meadows between, a thicker line of them along `edge` cells - where two lands meet)
static int fill_country(std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, const std::vector<uint8_t>& mask, const CountryKit& K, uint32_t seed,
                        const std::vector<uint8_t>* edge = nullptr, bool nature_only = false) {
    if (!K.ok || K.motif.empty()) return 0;
    int n = 0;
    uint32_t rs = seed * 2654435761u + 99;
    auto rnd = [&]() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; };
    long gtot = 0; for (auto& g : K.gw) gtot += g.second;
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        const size_t i = static_cast<size_t>(y) * W + x;
        if (!mask[i]) continue;
        if (K.periodic || K.gw.size() < 2) {
            const auto& m = K.motif[static_cast<size_t>((y % K.py) * K.px + (x % K.px))];
            for (int l = 0; l < 5; ++l) WL[l][i] = m[static_cast<size_t>(l)];
        } else {
            // the ground tiles mixed the way the game mixes them: only pairs it puts side by side, the common ones most
            const uint32_t L = (x > 0 && mask[i - 1]) ? WL[0][i - 1] : 0, T = (y > 0 && mask[i - W]) ? WL[0][i - W] : 0;
            long tot = 0;
            for (auto& [t, c] : K.gw) if ((!L || K.gh.count((static_cast<uint64_t>(L) << 32) | t)) && (!T || K.gv.count((static_cast<uint64_t>(T) << 32) | t))) tot += c;
            uint32_t pick = K.gw[0].first;
            if (tot > 0) {
                long r = static_cast<long>(rnd() % static_cast<uint32_t>(tot));
                for (auto& [t, c] : K.gw) if ((!L || K.gh.count((static_cast<uint64_t>(L) << 32) | t)) && (!T || K.gv.count((static_cast<uint64_t>(T) << 32) | t))) { r -= c; if (r < 0) { pick = t; break; } }
            } else {
                long r = static_cast<long>(rnd() % static_cast<uint32_t>(std::max<long>(1, gtot)));
                for (auto& [t, c] : K.gw) { r -= c; if (r < 0) { pick = t; break; } }
            }
            WL[0][i] = pick; for (int l = 1; l < 5; ++l) WL[l][i] = 0;
        }
        walk[i] = 3;
        ++n;
    }
    if (K.stamps.empty()) return n;
    std::vector<uint8_t> used(mask.size(), 0);
    long tw = 0, twbig = 0;
    auto allowed = [&](const CountryKit::Stamp& st) {     // only nature's things out in the open (no pads, benches, signs)
        if (st.made) return false;
        int cells = 0; for (auto v : st.solid) cells += v;
        return st.nature >= 0.45f || (cells <= 2 && st.nature >= 0.2f);     // trees, bushes, flowers - never walls or buildings
    };
    (void)nature_only;
    for (const auto& s : K.stamps) { if (!allowed(s)) continue; tw += s.n; int cells = 0; for (auto v : s.solid) cells += v; if (cells >= 4 && s.nature >= 0.3f && !s.made) twbig += static_cast<long>(s.n) * cells; }
    if (tw == 0) return n;
    const bool green = K.nature > 0.3f;
    int placed = 0;
    for (int y = 1; y < H - 1; y += 2) for (int x = 1; x < W - 1; x += 2) {
        const size_t i = static_cast<size_t>(y) * W + x;
        if (!mask[i] || used[i]) continue;
        const float nz = vnoise(x / 23.0f, y / 23.0f, seed) * 0.7f + vnoise(x / 7.0f, y / 7.0f, seed + 3) * 0.3f;
        float dens = green ? (nz > 0.55f ? 0.6f : (nz > 0.42f ? 0.2f : 0.08f)) : (nz > 0.58f ? 0.45f : 0.09f);
        if (edge && (*edge)[i]) dens = 0.7f;
        if ((rnd() % 1000) >= static_cast<uint32_t>(dens * 1000)) continue;
        // a thing of the land, the common ones more often (in woods and along a land's edge: the big ones)
        const bool woods = dens >= 0.5f && twbig > 0;
        long pick = static_cast<long>(rnd() % static_cast<uint32_t>(std::max<long>(1, woods ? twbig : tw)));
        size_t si = 0;
        for (; si < K.stamps.size(); ++si) {
            int cells = 0; for (auto v : K.stamps[si].solid) cells += v;
            if (woods) { if (cells < 4 || K.stamps[si].nature < 0.3f || K.stamps[si].made) continue; pick -= static_cast<long>(K.stamps[si].n) * cells; }
            else { if (!allowed(K.stamps[si])) continue; pick -= K.stamps[si].n; }
            if (pick < 0) break;
        }
        if (si >= K.stamps.size()) continue;
        const auto& S = K.stamps[si];
        // the same step of the ground pattern as in the game's map (the ground under it lines up)
        int X0 = x - S.w / 2, Y0 = y - S.h / 2;
        X0 += ((S.mx - X0) % K.px + K.px) % K.px; Y0 += ((S.my - Y0) % K.py + K.py) % K.py;
        bool fits = true;
        for (int yy = Y0 - 1; yy <= Y0 + S.h && fits; ++yy) for (int xx = X0 - 1; xx <= X0 + S.w; ++xx) {
            if (xx < 0 || yy < 0 || xx >= W || yy >= H) { fits = false; break; }
            const size_t q = static_cast<size_t>(yy) * W + xx;
            if (!mask[q] || used[q]) { fits = false; break; }
        }
        if (!fits) continue;
        for (int yy = 0; yy < S.h; ++yy) for (int xx = 0; xx < S.w; ++xx) {
            const size_t q = static_cast<size_t>(yy) * S.w + xx;
            const size_t d = static_cast<size_t>(Y0 + yy) * W + X0 + xx;
            if (S.solid[q]) { for (int l = 0; l < 5; ++l) WL[l][d] = S.c[q][static_cast<size_t>(l)]; walk[d] = (S.c[q][1] || S.c[q][2] || S.c[q][3] || S.c[q][4] || S.w * S.h > 2) ? 0 : S.wk[q]; }     // a thing is solid (never walked through)
        }
        for (int yy = Y0 - 1; yy <= Y0 + S.h; ++yy) for (int xx = X0 - 1; xx <= X0 + S.w; ++xx) used[static_cast<size_t>(yy) * W + xx] = 1;
        ++placed;
    }
    return n;
}

static bool kit_outdoor(int i);
static bool cell_dark(const std::vector<uint32_t> (&WL)[5], size_t d);
// each place's own ground and things: a city's pavement and planters next to the city, the jungle's grass and
// trees next to the jungle (one kit per named place, from all the game's maps of that place)
static const CountryKit& place_kit(int k) {
    static std::map<std::string, CountryKit> kits;
    static std::map<int, CountryKit> land_kits;
    const KitMap& m = g_kit[static_cast<size_t>(k)];
    const std::string key = std::to_string(m.z) + ":" + (!m.place.empty() ? m.place : m.name);
    auto it = kits.find(key);
    if (it != kits.end()) return it->second;
    std::vector<int> same;
    for (size_t i = 0; i < g_kit.size(); ++i) {
        const KitMap& o = g_kit[i];
        if (o.z != m.z || o.tw < 8 || o.th < 8 || !kit_outdoor(static_cast<int>(i)) || o.name == "The World") continue;
        if ((!o.place.empty() ? o.place : o.name) == (!m.place.empty() ? m.place : m.name)) same.push_back(static_cast<int>(i));
    }
    CountryKit K = make_country_kit(same);
    if (!K.ok || K.stamps.size() < 3) {   // too little of it: the whole land's
        if (!land_kits.count(m.z)) {
            std::vector<int> all;
            for (size_t i = 0; i < g_kit.size(); ++i) if (g_kit[i].z == m.z && g_kit[i].tw >= 8 && g_kit[i].th >= 8 && kit_outdoor(static_cast<int>(i)) && g_kit[i].name != "The World") all.push_back(static_cast<int>(i));
            land_kits[m.z] = make_country_kit(all);
        }
        if (land_kits[m.z].ok && (!K.ok || land_kits[m.z].stamps.size() > K.stamps.size())) K = land_kits[m.z];
    }
    return kits[key] = K;
}
// fill every cell of `mask` with the country of the nearest of the game's maps (owner: the map at each map cell,
// -1 elsewhere; blocked: never crossed, e.g. the sea). Where two places' countries meet: a band of woods.
static int fill_by_places(std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, int W, int H, const std::vector<uint8_t>& mask,
                          const std::vector<int>& owner, const std::vector<uint8_t>* blocked, uint32_t seed) {
    const size_t N = static_cast<size_t>(W) * H;
    // which places may lend their country: a real outdoors (its ground not black, things of its own);
    // a city's pavement reaches only a little way out of the city (then the nature round it takes over)
    std::map<int, int> kind_of;     // map -> 0 none, 1 nature, 2 city
    auto kind = [&](int k) {
        auto it = kind_of.find(k);
        if (it != kind_of.end()) return it->second;
        const CountryKit& K = place_kit(k);
        int v = 0;
        if (K.ok && !K.motif.empty()) {
            std::vector<uint32_t> tmp[5]; for (int l = 0; l < 5; ++l) tmp[l] = {K.motif[0][static_cast<size_t>(l)]};
            if (!cell_dark(tmp, 0)) {
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                const std::string nm = !m.place.empty() ? m.place : m.name;
                const bool city = (nm.find("City") != std::string::npos || nm.find("Capsule") != std::string::npos || nm.find("Town") != std::string::npos || nm.find("Highway") != std::string::npos) && nm.find("Outside") == std::string::npos;
                v = nm.empty() ? 0 : ((city || K.stamps.size() < 5) ? 2 : 1);     // (no name of its own: lends nothing; a city or a small place: only round itself)
            }
        }
        return kind_of[k] = v;
    };
    auto bfs = [&](bool city_too, std::vector<int>& near, std::vector<int>& dist) {
        near.assign(N, -1); dist.assign(N, 0);
        std::deque<size_t> q;
        for (size_t i = 0; i < N; ++i) if (owner[i] >= 0) { const int kd = kind(owner[i]); if (kd == 1 || (kd == 2 && city_too)) { near[i] = owner[i]; q.push_back(i); } }
        while (!q.empty()) {
            const size_t c = q.front(); q.pop_front();
            const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
            const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (auto& d : d4) {
                const int X = x + d[0], Y = y + d[1];
                if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                const size_t n2 = static_cast<size_t>(Y) * W + X;
                if (near[n2] >= 0 || (blocked && (*blocked)[n2])) continue;
                near[n2] = near[c]; dist[n2] = dist[c] + 1;
                q.push_back(n2);
            }
        }
    };
    std::vector<int> near, dist, near2, dist2;
    bfs(true, near, dist);
    bfs(false, near2, dist2);
    for (size_t i = 0; i < N; ++i) {
        if (near[i] < 0 || kind(near[i]) != 2 || near2[i] < 0) continue;
        const int x = static_cast<int>(i % W), y = static_cast<int>(i / W);
        const float lim = 8.0f + vnoise(x / 9.0f, y / 9.0f, seed + 11) * 18.0f;      // a ragged, natural edge
        if (dist[i] > lim) near[i] = near2[i];
    }
    // group the cells by kit
    // (in the order each kit first appears across the map, not by where it sits in memory: that differs on every
    // run and every device, and so did the seeds and so EARTH - now every import makes the very same planet)
    std::vector<std::pair<const CountryKit*, std::vector<size_t>>> by;
    std::unordered_map<const CountryKit*, size_t> slot;
    for (size_t i = 0; i < N; ++i) if (mask[i] && near[i] >= 0) {
        const CountryKit* k = &place_kit(near[i]);
        auto it = slot.find(k);
        if (it == slot.end()) { it = slot.emplace(k, by.size()).first; by.push_back({k, {}}); }
        by[it->second].second.push_back(i);
    }
    int n = 0, ki = 0;
    for (auto& [K, cells] : by) {
        std::vector<uint8_t> m2(N, 0), edge(N, 0);
        for (size_t i : cells) m2[i] = 1;
        for (size_t i : cells) {
            const int x = static_cast<int>(i % W), y = static_cast<int>(i / W);
            for (int d = 1; d <= 3 && !edge[i]; ++d) {
                const int xs[4] = {x - d, x + d, x, x}, ys[4] = {y, y, y - d, y + d};
                for (int t = 0; t < 4; ++t) {
                    if (xs[t] < 0 || ys[t] < 0 || xs[t] >= W || ys[t] >= H) continue;
                    const size_t j = static_cast<size_t>(ys[t]) * W + xs[t];
                    if (mask[j] && near[j] >= 0 && &place_kit(near[j]) != K) { edge[i] = 1; break; }
                }
            }
        }
        bool nat = false;
        for (size_t i : cells) { nat = kind(near[i]) == 1; break; }
        n += fill_country(WL, walk, W, H, m2, *K, seed + static_cast<uint32_t>(ki++) * 7777, &edge, nat);
    }
    return n;
}

// COLLISION BY LOOK: over every map of the game, how often each look (a cell's 5 layers) can be walked on.
// A cell that looks like ground you walk on everywhere else is never an invisible wall; a cell that looks
// like a bench, a planter or a wall everywhere else is never walked through.
static std::unordered_map<uint64_t, std::pair<int, int>> g_look_walk;
static std::unordered_map<uint32_t, std::pair<int, int>> g_ground_walk;    // the ground tile alone (a look never seen whole)
static int g_decor_opened = 0;     // cells of the new land opened because what stands on them is walked over in the game (flowers)
static void build_look_walk();
static int fix_collision(const std::vector<uint32_t> (&WL)[5], std::vector<uint8_t>& walk, size_t from, size_t to, const std::vector<uint8_t>* keep = nullptr, const std::vector<uint8_t>* loose = nullptr) {
    if (g_look_walk.empty()) build_look_walk();
    int n = 0;
    for (size_t i = from; i < to; ++i) {
        if (!WL[0][i] && !WL[1][i] && !WL[2][i] && !WL[3][i] && !WL[4][i]) continue;
        const uint32_t F = ~(3u << 16);     // a tile and its mirror image walk the same
        const uint32_t c[5] = {WL[0][i] & F, WL[1][i] & F, WL[2][i] & F, WL[3][i] & F, WL[4][i] & F};
        auto it = g_look_walk.find(GrowPool::sig(c));
        if (it == g_look_walk.end() || it->second.second < 10) {
            // the new land makes looks the game never had whole: then the ground and what stands on it decide
            if (!(loose && (*loose)[i]) || (walk[i] & 1)) continue;
            auto gi = g_ground_walk.find(c[0]);
            if (gi == g_ground_walk.end() || gi->second.second < 10) continue;
            // what stands on the ground (a flower, a tuft of grass) is walked over when the game mostly lets you walk
            // over that very tile; anything never seen enough, or mostly solid (a trunk, a rock), keeps it a wall
            bool solid_top = false;
            for (int l = 1; l < 5 && !solid_top; ++l) {
                if (!c[l]) continue;
                auto ti = g_ground_walk.find(c[l]);
                if (ti == g_ground_walk.end() || ti->second.second < 10 || ti->second.first * 10 < ti->second.second * 3) solid_top = true;
            }
            if (!solid_top && gi->second.first * 10 >= gi->second.second * 3) { walk[i] = 3; ++n; ++g_decor_opened; }
            continue;
        }
        const double f = static_cast<double>(it->second.first) / it->second.second;
        // raised ground (the top of a plateau, a bridge: the game's second collision map) that looks like
        // ground you walk on elsewhere is walked on too - only things that are never ground (a bench) stay solid
        bool water = false;
        for (int l = 0; l < 5; ++l) water = water || (WL[l][i] & (1u << 19));
        // the game's own cells: opened only when the look is ground almost everywhere (never a wall, a roof, a house)
        const bool bare = !WL[1][i] && !WL[2][i] && !WL[3][i] && !WL[4][i];
        (void)bare;
        // the game's own maps keep the game's own collision (only things it lets you walk through are closed);
        // only the new land between places is opened where it is ground
        if (!(walk[i] & 1) && loose && (*loose)[i] && f >= 0.3 && !water && bare && !manmade_tiles().count(c[0] & 0xFFFFu)) { walk[i] = 3; ++n; }
        // the new land: ground with something small on it (flowers) that the game's maps let you walk over most of the time
        else if (!(walk[i] & 1) && loose && (*loose)[i] && f >= 0.3 && !water && !bare && !manmade_tiles().count(c[0] & 0xFFFFu)) { walk[i] = 3; ++n; ++g_decor_opened; }
        else if ((walk[i] & 1) && f <= 0.12 && !(keep && (*keep)[i])) { walk[i] = 0; ++n; }
    }
    return n;
}
// every land's regions, kept for EARTH (the whole planet as one map, built after the lands)
struct StoredReg {
    int W = 0, H = 0; std::vector<uint32_t> WL[5]; std::vector<uint8_t> walk;
    std::string name; bool out = false; int arrx = 0, arry = 0;
    std::vector<uint8_t> keep;
    std::vector<std::pair<int, std::pair<int, int>>> maps;      // (kit map, (x, y) px)
    struct Ex { int x0, y0, x1, y1, to, ax, ay; };
    std::vector<Ex> ex;
    struct XEx { int x0, y0, x1, y1, tmap, px, py, side, smap; };   // a way to another land (a map of it)
    std::vector<XEx> xex;
    std::vector<std::array<int, 4>> en;
};
struct StoredZone { int start = 0; std::vector<StoredReg> regs; std::map<int, std::array<int, 3>> where; };   // map -> (region, x, y)
static std::map<int, StoredZone> g_store;
static std::vector<uint32_t> g_tile_col;

static void write_lkr(const fs::path& f, int W, int H, const std::vector<uint32_t> (&WL)[5], const std::vector<uint8_t>& walk);
// (Android port) one land's grass is a pure neon green, and the grown country repeats it like a grid: that ground
// is laid again with the game's own yellow-green grass, its tiles mixed as the real maps mix them (same everywhere)
static int regrass(std::vector<uint32_t> (&WL)[5], int W, int H) {
    static const int kFrom[] = {9757, 9764, 10524, 10525, 10526, 10527, 10528, 10529, 10530, 10531, 10532, 10533, 10534, 10535,
                                10536, 10537, 10538, 10539, 10540, 10541, 10542, 10543};
    static const int kTo[][2] = {{334, 222}, {331, 143}, {326, 131}, {325, 131}, {324, 107}, {327, 91}, {330, 86}, {335, 75}};
    int total = 0; for (auto& t : kTo) total += t[1];
    int n = 0;
    const size_t N = static_cast<size_t>(W) * H;
    for (size_t i = 0; i < N; ++i) {
        const uint32_t v = WL[0][i]; const int id = static_cast<int>(v & 0xFFFFu);
        if (v & (1u << 19)) continue;
        bool hit = false; for (int f : kFrom) if (f == id) { hit = true; break; }
        if (!hit) continue;
        uint32_t h = static_cast<uint32_t>(i) * 2654435761u; h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
        int r = static_cast<int>(h % static_cast<uint32_t>(total)), pick = kTo[0][0];
        for (auto& t : kTo) { if (r < t[1]) { pick = t[0]; break; } r -= t[1]; }
        WL[0][i] = static_cast<uint32_t>(pick); ++n;
    }
    return n;
}
static void build_look_walk() {
    for (const auto& m : g_kit) {
        if (m.tw <= 0 || m.th <= 0 || m.name == "The World") continue;
        std::vector<uint32_t> WL[5];
        for (auto& l : WL) l.assign(static_cast<size_t>(m.tw) * m.th, 0);
        std::vector<uint8_t> wk(static_cast<size_t>(m.tw) * m.th, 0);
        compose_map(m, WL, wk, m.tw, m.th, 0, 0);
        for (size_t i = 0; i < wk.size(); ++i) {
            if (!WL[0][i] && !WL[1][i] && !WL[2][i] && !WL[3][i] && !WL[4][i]) continue;
            const uint32_t F = ~(3u << 16);
            const uint32_t c[5] = {WL[0][i] & F, WL[1][i] & F, WL[2][i] & F, WL[3][i] & F, WL[4][i] & F};
            auto& e = g_look_walk[GrowPool::sig(c)];
            e.first += wk[i] & 1; e.second++;
            for (int l = 0; l < 5; ++l) if (c[l]) { auto& g = g_ground_walk[c[l]]; g.first += wk[i] & 1; g.second++; }
        }
    }
    g_look_walk[0] = {0, 0};
    std::fprintf(stderr, "[export] collision: %zu looks of the game's cells measured\n", g_look_walk.size());
    if (const char* ts = std::getenv("LOG2_TILESTAT")) {      // (a check: how often the game lets you walk over these tiles)
        std::string all(ts); size_t a = 0;
        while (a < all.size()) {
            size_t b = all.find(',', a); if (b == std::string::npos) b = all.size();
            const uint32_t t = static_cast<uint32_t>(std::atoi(all.substr(a, b - a).c_str()));
            auto it = g_ground_walk.find(t);
            if (it != g_ground_walk.end()) std::fprintf(stderr, "[tilestat] %u walked %d of %d\n", t, it->second.first, it->second.second);
            else std::fprintf(stderr, "[tilestat] %u never seen\n", t);
            a = b + 1;
        }
    }
}
static void export_lands(const fs::path& dir) {
    std::map<std::string, int> idx;
    for (size_t i = 0; i < g_kit.size(); ++i) idx[g_kit[i].key] = static_cast<int>(i);
    // a colour per tile (its average) for the minimaps
    std::vector<uint32_t> tile_col;
    {
        const int N = static_cast<int>(romtiles::id_globals().size());
        tile_col.assign(static_cast<size_t>(N) + 4096, 0);
        for (int id = 1; id < N; ++id) {
            const uint8_t* t = romtiles::tile(static_cast<uint16_t>(id));
            if (!t) continue;
            int r = 0, g = 0, bb = 0, n = 0;
            for (int i = 0; i < 64; ++i) if (t[i]) { r += g_bgpal[t[i] * 3]; g += g_bgpal[t[i] * 3 + 1]; bb += g_bgpal[t[i] * 3 + 2]; ++n; }
            if (n) tile_col[static_cast<size_t>(id)] = 0xFF000000u | (static_cast<uint32_t>(bb / n) << 16) | (static_cast<uint32_t>(g / n) << 8) | static_cast<uint32_t>(r / n);
        }
        g_tile_col = tile_col;
    }
    std::map<int, std::vector<int>> by_zone;
    for (size_t i = 0; i < g_kit.size(); ++i) by_zone[g_kit[i].z].push_back(static_cast<int>(i));

    int zi = 0;
    for (auto& [z, list] : by_zone) {
        progress("lands", zi++, static_cast<int>(by_zone.size()));
        auto outdoor = [&](int i) {
            const KitMap& m = g_kit[static_cast<size_t>(i)];
            if (m.tw * m.th < 24 * 18) return false;
            for (const auto& e : m.exits) if (side_of(m, e) >= 0) return true;
            return false;
        };
        std::vector<std::vector<std::pair<int, std::pair<int, int>>>> regions;   // per region: (map, (x, y) px)
        std::map<int, int> region_of;
        std::map<int, std::pair<int, int>> at;
        std::set<std::pair<int, int>> seam;    // map pairs joined edge to edge (walk across, no exit)
        while (true) {
            int st = -1, best = -1;
            for (int i : list) if (outdoor(i) && !region_of.count(i)) { const int ne = static_cast<int>(g_kit[static_cast<size_t>(i)].exits.size()); if (ne > best) { best = ne; st = i; } }
            if (st < 0) break;
            const int R = static_cast<int>(regions.size());
            regions.push_back({{st, {0, 0}}}); region_of[st] = R; at[st] = {0, 0};
            std::deque<int> q{st};
            while (!q.empty()) {
                const int k = q.front(); q.pop_front();
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                const auto [ox, oy] = at[k];
                std::map<int, std::vector<std::pair<int, int>>> offs;   // target -> candidate offsets
                std::map<int, int> tside;
                for (const auto& e : m.exits) {
                    const int s = side_of(m, e);
                    auto it = idx.find(std::to_string(e.tz) + "_" + std::to_string(e.ta));
                    if (s < 0 || it == idx.end() || it->second == k || (z != 0 && g_kit[static_cast<size_t>(it->second)].z != z) || !outdoor(it->second)) continue;
                    const int t = it->second;
                    if (tside.count(t) && tside[t] != s) continue;
                    tside[t] = s;
                    const KitMap& T = g_kit[static_cast<size_t>(t)];
                    const int cx = (e.x0 + e.x1) / 2, cy = (e.y0 + e.y1) / 2;
                    if (s == 2) offs[t].push_back({ox + cx - e.px, oy - T.th * 8});
                    if (s == 3) offs[t].push_back({ox + cx - e.px, oy + m.th * 8});
                    if (s == 0) offs[t].push_back({ox - T.tw * 8, oy + cy - e.py});
                    if (s == 1) offs[t].push_back({ox + m.tw * 8, oy + cy - e.py});
                }
                for (auto& [t, v] : offs) {
                    std::vector<int> xs, ys; for (auto& p : v) { xs.push_back(p.first); ys.push_back(p.second); }
                    std::sort(xs.begin(), xs.end()); std::sort(ys.begin(), ys.end());
                    const int nx = (xs[xs.size() / 2] + 4) / 8 * 8 - (xs[xs.size() / 2] < 0 && xs[xs.size() / 2] % 8 ? 8 : 0);
                    const int ny = (ys[ys.size() / 2] + 4) / 8 * 8 - (ys[ys.size() / 2] < 0 && ys[ys.size() / 2] % 8 ? 8 : 0);
                    if (region_of.count(t)) {
                        if (region_of[t] == R && std::abs(at[t].first - nx) <= 16 && std::abs(at[t].second - ny) <= 16) seam.insert({std::min(k, t), std::max(k, t)});
                        continue;
                    }
                    const KitMap& T = g_kit[static_cast<size_t>(t)];
                    bool bad = false;
                    const int tol = 32;
                    for (const auto& [k2, p2] : regions[static_cast<size_t>(R)]) {
                        const KitMap& m2 = g_kit[static_cast<size_t>(k2)];
                        if (nx + tol < p2.first + m2.tw * 8 && p2.first + tol < nx + T.tw * 8 && ny + tol < p2.second + m2.th * 8 && p2.second + tol < ny + T.th * 8) { bad = true; break; }
                    }
                    if (bad) continue;
                    regions[static_cast<size_t>(R)].push_back({t, {nx, ny}}); region_of[t] = R; at[t] = {nx, ny};
                    seam.insert({std::min(k, t), std::max(k, t)});
                    q.push_back(t);
                }
            }
        }
        for (int i : list) if (!region_of.count(i)) { region_of[i] = static_cast<int>(regions.size()); at[i] = {0, 0}; regions.push_back({{i, {0, 0}}}); }
        // ONE WORLD: the outdoor regions of the land are set down next to each other, each where its way in
        // faces the way out of a region already placed, with a road between the two - so the whole land is
        // walked through (the road runs through grown land; no map of the game overlaps another)
        struct Corridor { int ka, ax, ay, kb, bx, by, sa; };   // road ends (px, inside each map), the side it leaves map ka
        std::map<int, std::vector<Corridor>> corridors;      // by region (index after merging)
        if (std::getenv("LOG2_NO_JOIN") == nullptr) {
            // the land's outdoor places (by name) - houses, caves and halls stay behind their doors
            std::set<std::string> land_names;
            {
                int b0 = -1; size_t bs0 = 0;
                for (size_t R = 0; R < regions.size(); ++R) if (regions[R].size() > bs0) { bs0 = regions[R].size(); b0 = static_cast<int>(R); }
                for (size_t R = 0; R < regions.size(); ++R) {
                    if (static_cast<int>(R) != b0 && regions[R].size() < 3) continue;   // big stitched stretches are the land's outdoors
                    for (auto& [k2, p2] : regions[R]) { const KitMap& m2 = g_kit[static_cast<size_t>(k2)]; if (outdoor(k2)) land_names.insert(!m2.place.empty() ? m2.place : m2.name); }
                }
            }
            auto is_out_region = [&](int R) {
                bool any = false;
                for (auto& [k2, p2] : regions[static_cast<size_t>(R)]) {
                    const KitMap& m2 = g_kit[static_cast<size_t>(k2)];
                    const std::string nm2 = !m2.place.empty() ? m2.place : m2.name;
                    const bool under = nm2.find("Cavern") != std::string::npos || nm2.find("Cave") != std::string::npos || nm2.find("Lab") != std::string::npos;
                    if (!outdoor(k2) || under || (!nm2.empty() && !land_names.count(nm2))) return false;
                    any = true;
                }
                return any;
            };
            auto dirv = [](int sd) { return sd == 0 ? std::make_pair(-1, 0) : sd == 1 ? std::make_pair(1, 0) : sd == 2 ? std::make_pair(0, -1) : std::make_pair(0, 1); };
            int big = -1; size_t bigsz = 0;
            for (size_t R = 0; R < regions.size(); ++R) if (is_out_region(static_cast<int>(R)) && regions[R].size() > bigsz) { bigsz = regions[R].size(); big = static_cast<int>(R); }
            std::vector<int> merged_into(regions.size(), -1);
            std::vector<Corridor> cors;
            if (big >= 0) {
                std::deque<int> qq{big};
                merged_into[static_cast<size_t>(big)] = big;
                while (!qq.empty()) {
                    const int A = qq.front(); qq.pop_front();
                    // (the maps of A as they are now, already moved)
                    for (size_t mi = 0; mi < regions[static_cast<size_t>(big)].size(); ++mi) {
                        const int k = regions[static_cast<size_t>(big)][mi].first;
                        if (region_of[k] != A && !(A == big)) continue;
                        const KitMap& m = g_kit[static_cast<size_t>(k)];
                        const auto pk = regions[static_cast<size_t>(big)][mi].second;
                        for (size_t ia = 0; ia < m.exits.size(); ++ia) {
                            const KExit& e = m.exits[ia];
                            auto it = idx.find(std::to_string(e.tz) + "_" + std::to_string(e.ta));
                            if (it == idx.end()) continue;
                            const int t = it->second;
                            const int B = region_of[t];
                            if (B < 0 || merged_into[static_cast<size_t>(B)] >= 0 || !is_out_region(B)) continue;
                            const int sa = side_of(m, e);
                            const bool dbg = std::getenv("LOG2_JOIN_DBG") != nullptr;
                            if (dbg) std::fprintf(stderr, "[join] z%d %s exit %zu -> %s (region %d) side %d\n", z, m.key.c_str(), ia, g_kit[static_cast<size_t>(t)].key.c_str(), B, sa);
                            int sa2 = sa;
                            if (sa2 < 0) {   // the side of the map nearest to the way out
                                const int cx = (e.x0 + e.x1) / 2, cy = (e.y0 + e.y1) / 2;
                                const int dl = cx, dr = m.tw * 8 - cx, dt = cy, db = m.th * 8 - cy;
                                const int mn = std::min({dl, dr, dt, db});
                                if (mn > 48) continue;     // a door in the middle of a map: not a way out of the land
                                sa2 = mn == dl ? 0 : mn == dr ? 1 : mn == dt ? 2 : 3;
                            }
                            // the way back in B (an exit of map t that leads to a map already placed)
                            const KitMap& T = g_kit[static_cast<size_t>(t)];
                            int ib = -1;
                            for (size_t j = 0; j < T.exits.size(); ++j) {
                                auto it2 = idx.find(std::to_string(T.exits[j].tz) + "_" + std::to_string(T.exits[j].ta));
                                if (it2 == idx.end() || side_of(T, T.exits[j]) < 0) continue;
                                if (it2->second == k) { ib = static_cast<int>(j); break; }
                                if (ib < 0 && merged_into[static_cast<size_t>(region_of[it2->second])] >= 0) ib = static_cast<int>(j);   // back to another placed map
                            }
                            // no way back: the road ends where the way out arrives in map t
                            KExit arrive_x{e.px - 4, e.py - 4, e.px + 4, e.py + 4, 0, 0, 0, 0, 0};
                            const KExit& eb = ib >= 0 ? T.exits[static_cast<size_t>(ib)] : arrive_x;
                            const int ax = pk.first + (e.x0 + e.x1) / 2, ay = pk.second + (e.y0 + e.y1) / 2;
                            const auto pt = at[t];     // t inside B (B's own coordinates)
                            const int bxl = pt.first + (eb.x0 + eb.x1) / 2, byl = pt.second + (eb.y0 + eb.y1) / 2;
                            const auto [dx, dy] = dirv(sa2);
                            bool placed = false;
                            for (int gap : {6, 10, 16, 24, 34, 48, 64, 90, 120, 160, 220}) {
                                for (int sh : {0, 8, -8, 16, -16, 32, -32, 56, -56, 90, -90}) {
                                    const int tx = ax + dx * gap * 8 + (dx == 0 ? sh * 8 : 0), ty = ay + dy * gap * 8 + (dy == 0 ? sh * 8 : 0);
                                    const int ox = (tx - bxl) / 8 * 8, oy = (ty - byl) / 8 * 8;
                                    // never on top of a map already placed (4 tiles apart at least)
                                    bool bad = false;
                                    for (auto& [k3, p3] : regions[static_cast<size_t>(B)]) {
                                        const KitMap& m3 = g_kit[static_cast<size_t>(k3)];
                                        const int x0 = p3.first + ox - 32, y0 = p3.second + oy - 32, x1 = p3.first + ox + m3.tw * 8 + 32, y1 = p3.second + oy + m3.th * 8 + 32;
                                        for (auto& [k4, p4] : regions[static_cast<size_t>(big)]) {
                                            const KitMap& m4 = g_kit[static_cast<size_t>(k4)];
                                            if (x0 < p4.first + m4.tw * 8 && p4.first < x1 && y0 < p4.second + m4.th * 8 && p4.second < y1) { bad = true; break; }
                                        }
                                        if (bad) break;
                                    }
                                    if (bad) continue;
                                    // and the road must not cross a map: the cells between the two exits are free
                                    const int cx0 = std::min(ax, tx), cx1 = std::max(ax, tx), cy0 = std::min(ay, ty), cy1 = std::max(ay, ty);
                                    for (auto& [k4, p4] : regions[static_cast<size_t>(big)]) {
                                        if (k4 == k) continue;
                                        const KitMap& m4 = g_kit[static_cast<size_t>(k4)];
                                        if (cx0 < p4.first + m4.tw * 8 && p4.first < cx1 + 8 && cy0 < p4.second + m4.th * 8 && p4.second < cy1 + 8) { bad = true; break; }
                                    }
                                    if (bad) continue;
                                    for (auto& [k3, p3] : regions[static_cast<size_t>(B)]) {
                                        p3.first += ox; p3.second += oy;
                                        at[k3] = p3;
                                        regions[static_cast<size_t>(big)].push_back({k3, p3});
                                    }
                                    merged_into[static_cast<size_t>(B)] = big;
                                    cors.push_back({k, (e.x0 + e.x1) / 2, (e.y0 + e.y1) / 2, t, (eb.x0 + eb.x1) / 2, (eb.y0 + eb.y1) / 2, sa2});
                                    seam.insert({std::min(k, t), std::max(k, t)});
                                    if (ib >= 0) {   // the way back is a road too (no door in the middle of it)
                                        auto it3 = idx.find(std::to_string(eb.tz) + "_" + std::to_string(eb.ta));
                                        if (it3 != idx.end()) seam.insert({std::min(t, it3->second), std::max(t, it3->second)});
                                    }
                                    qq.push_back(B);
                                    placed = true;
                                    break;
                                }
                                if (placed) break;
                            }
                            if (dbg && !placed) std::fprintf(stderr, "[join]   no room\n");
                        }
                    }
                }
                // ways that only lead INTO the placed world (no way out of it to them): from the other side
                for (bool progress = true; progress; ) {
                    progress = false;
                    for (size_t B = 0; B < regions.size() && !progress; ++B) {
                        if (merged_into[B] >= 0 || !is_out_region(static_cast<int>(B))) continue;
                        for (auto& [t, ptl] : regions[B]) {
                            const KitMap& T = g_kit[static_cast<size_t>(t)];
                            for (size_t ib = 0; ib < T.exits.size() && !progress; ++ib) {
                                const KExit& eb = T.exits[ib];
                                auto it = idx.find(std::to_string(eb.tz) + "_" + std::to_string(eb.ta));
                                if (it == idx.end()) continue;
                                const int k = it->second;
                                if (merged_into[static_cast<size_t>(region_of[k])] < 0) continue;
                                int sb = side_of(T, eb);
                                if (sb < 0) {
                                    const int cx = (eb.x0 + eb.x1) / 2, cy = (eb.y0 + eb.y1) / 2;
                                    const int dl = cx, dr = T.tw * 8 - cx, dt = cy, db = T.th * 8 - cy;
                                    const int mn = std::min({dl, dr, dt, db});
                                    if (mn > 48) continue;
                                    sb = mn == dl ? 0 : mn == dr ? 1 : mn == dt ? 2 : 3;
                                }
                                // the road leaves the placed map k where this way arrives, away from B
                                const auto pk = at[k];
                                const int ax = pk.first + eb.px, ay = pk.second + eb.py;
                                const int bxl = ptl.first + (eb.x0 + eb.x1) / 2, byl = ptl.second + (eb.y0 + eb.y1) / 2;
                                const auto [dx, dy] = dirv(sb);
                                for (int gap : {6, 10, 16, 24, 34, 48, 64, 90, 120, 160, 220}) {
                                    for (int sh : {0, 8, -8, 16, -16, 32, -32, 56, -56, 90, -90}) {
                                        const int tx = ax - dx * gap * 8 + (dx == 0 ? sh * 8 : 0), ty = ay - dy * gap * 8 + (dy == 0 ? sh * 8 : 0);
                                        const int ox = (tx - bxl) / 8 * 8, oy = (ty - byl) / 8 * 8;
                                        bool bad = false;
                                        for (auto& [k3, p3] : regions[B]) {
                                            const KitMap& m3 = g_kit[static_cast<size_t>(k3)];
                                            const int x0 = p3.first + ox - 32, y0 = p3.second + oy - 32, x1 = p3.first + ox + m3.tw * 8 + 32, y1 = p3.second + oy + m3.th * 8 + 32;
                                            for (auto& [k4, p4] : regions[static_cast<size_t>(big)]) {
                                                const KitMap& m4 = g_kit[static_cast<size_t>(k4)];
                                                if (x0 < p4.first + m4.tw * 8 && p4.first < x1 && y0 < p4.second + m4.th * 8 && p4.second < y1) { bad = true; break; }
                                            }
                                            if (bad) break;
                                        }
                                        const int cx0 = std::min(ax, tx), cx1 = std::max(ax, tx), cy0 = std::min(ay, ty), cy1 = std::max(ay, ty);
                                        for (auto& [k4, p4] : regions[static_cast<size_t>(big)]) {
                                            if (bad || k4 == k) break;
                                            const KitMap& m4 = g_kit[static_cast<size_t>(k4)];
                                            if (cx0 < p4.first + m4.tw * 8 && p4.first < cx1 + 8 && cy0 < p4.second + m4.th * 8 && p4.second < cy1 + 8) bad = true;
                                        }
                                        if (bad) continue;
                                        const int bx_local = (eb.x0 + eb.x1) / 2, by_local = (eb.y0 + eb.y1) / 2;
                                        for (auto& [k3, p3] : regions[B]) {
                                            p3.first += ox; p3.second += oy;
                                            at[k3] = p3;
                                            regions[static_cast<size_t>(big)].push_back({k3, p3});
                                        }
                                        merged_into[B] = big;
                                        cors.push_back({k, eb.px, eb.py, t, bx_local, by_local, sb ^ 1});
                                        seam.insert({std::min(k, t), std::max(k, t)});
                                        progress = true;
                                        break;
                                    }
                                    if (progress) break;
                                }
                            }
                            if (progress) break;
                        }
                    }
                }
                // regions joined into the big one go; the rest are renumbered
                std::vector<std::vector<std::pair<int, std::pair<int, int>>>> keep;
                std::vector<int> newidx(regions.size(), -1);
                for (size_t R = 0; R < regions.size(); ++R) {
                    if (merged_into[R] >= 0 && static_cast<int>(R) != big) continue;
                    newidx[R] = static_cast<int>(keep.size());
                    keep.push_back(regions[R]);
                }
                for (auto& [k2, r2] : region_of) r2 = merged_into[static_cast<size_t>(r2)] >= 0 ? newidx[static_cast<size_t>(big)] : newidx[static_cast<size_t>(r2)];
                regions = keep;
                corridors[newidx[static_cast<size_t>(big)]] = cors;
                std::fprintf(stderr, "[export] land %d: %zu ways joined into one world\n", z, cors.size());
            }
        }
        // normalise each region to start at 0,0
        std::vector<int> RW, RH;
        for (auto& reg : regions) {
            int x0 = 1 << 30, y0 = 1 << 30, x1 = -(1 << 30), y1 = -(1 << 30);
            for (auto& [k, p] : reg) { const KitMap& m = g_kit[static_cast<size_t>(k)]; x0 = std::min(x0, p.first); y0 = std::min(y0, p.second); x1 = std::max(x1, p.first + m.tw * 8); y1 = std::max(y1, p.second + m.th * 8); }
            for (auto& [k, p] : reg) { p.first -= x0; p.second -= y0; at[k] = p; }
            RW.push_back((x1 - x0) / 8); RH.push_back((y1 - y0) / 8);
        }
        const fs::path zd = dir / std::to_string(z);
        fs::create_directories(zd);
        std::string js = "{\"zone\":" + std::to_string(z) + ",\"regions\":[";
        int start = 0; size_t most = 0;
        for (size_t R = 0; R < regions.size(); ++R) if (regions[R].size() > most) { most = regions[R].size(); start = static_cast<int>(R); }
        StoredZone& SZ = g_store[z];
        SZ.start = start; SZ.regs.clear(); SZ.regs.resize(regions.size());
        for (auto& [k2, r2] : region_of) SZ.where[k2] = {r2, at[k2].first, at[k2].second};
        for (size_t R = 0; R < regions.size(); ++R) {
            const int W = RW[R], H = RH[R];
            StoredReg& SR = SZ.regs[R];
            std::vector<uint32_t> WL[5];
            for (auto& l : WL) l.assign(static_cast<size_t>(W) * H, 0);
            std::vector<uint8_t> walk(static_cast<size_t>(W) * H, 0);
            std::vector<uint8_t> keep(static_cast<size_t>(W) * H, 0);    // opened on purpose (a ledge, a seam, a road): left open
            std::string maps_js, ex_js, en_js;
            std::map<std::string, int> names;
            bool any_out = false;
            for (auto& [k, p] : regions[R]) {
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                any_out = any_out || outdoor(k);
                names[!m.place.empty() ? m.place : m.name] += m.tw * m.th;
                maps_js += (maps_js.empty() ? "" : ",") + std::string("[\"") + m.key + "\"," + std::to_string(p.first) + "," + std::to_string(p.second) + "]";
                // which world layer each map layer goes to (drawn order; "over" = drawn above the fighters)
                std::vector<int> ks;
                for (int kk = 0; kk < 4; ++kk) {
                    if (!((m.mask >> kk) & 1) || ((m.light >> kk) & 1)) continue;
                    bool any = false; for (uint32_t c : m.L[kk]) if (c) { any = true; break; }
                    if (any) ks.push_back(kk);
                }
                std::sort(ks.begin(), ks.end(), [&](int a2, int b2) { return m.pri[a2] != m.pri[b2] ? m.pri[a2] > m.pri[b2] : a2 > b2; });
                int under = 1, over = 3;
                const int bx = p.first / 8, by = p.second / 8;
                for (size_t r = 0; r < ks.size(); ++r) {
                    const int kk = ks[r];
                    int wl = 0;
                    if (r > 0) {
                        const bool front = m.pri[kk] <= 1 && m.pri[kk] < m.pri[ks[0]];
                        wl = front ? std::min(over++, 4) : std::min(under++, 2);
                    }
                    for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
                        const uint32_t c = m.L[kk][static_cast<size_t>(y) * m.tw + x];
                        if (!c || (c & (1u << 18))) continue;
                        const int X = bx + x, Y = by + y;
                        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                        WL[wl][static_cast<size_t>(Y) * W + X] = c;
                    }
                }
                {
                    const std::vector<uint8_t> op = open_ledges(m.walk, m.tw, m.th);
                    for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
                        const int X = bx + x, Y = by + y;
                        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                        walk[static_cast<size_t>(Y) * W + X] |= m.walk[static_cast<size_t>(y) * m.tw + x] | op[static_cast<size_t>(y) * m.tw + x];
                        if (op[static_cast<size_t>(y) * m.tw + x] && !(m.walk[static_cast<size_t>(y) * m.tw + x] & 1)) keep[static_cast<size_t>(Y) * W + X] = 1;
                    }
                }
                // exits: joined edges vanish (you walk across); the rest lead to their map's region
                SR.maps.push_back({k, p});
                for (const auto& e : m.exits) {
                    auto it = idx.find(std::to_string(e.tz) + "_" + std::to_string(e.ta));
                    if (it != idx.end() && z != 0 && g_kit[static_cast<size_t>(it->second)].z != z) {   // to another land: kept for EARTH
                        int sd = side_of(m, e);
                        if (sd < 0) {
                            const int cx = (e.x0 + e.x1) / 2, cy = (e.y0 + e.y1) / 2;
                            const int dl = cx, dr = m.tw * 8 - cx, dt = cy, db = m.th * 8 - cy;
                            const int mn = std::min({dl, dr, dt, db});
                            if (mn <= 48) sd = mn == dl ? 0 : mn == dr ? 1 : mn == dt ? 2 : 3;
                        }
                        SR.xex.push_back({p.first + e.x0, p.second + e.y0, p.first + e.x1, p.second + e.y1, it->second, e.px, e.py, sd, k});
                    }
                    if (it == idx.end() || (z != 0 && g_kit[static_cast<size_t>(it->second)].z != z)) continue;
                    const int t = it->second;
                    if (region_of[t] == static_cast<int>(R) && seam.count({std::min(k, t), std::max(k, t)})) {
                        // a joined edge: make sure you can walk from this exit to where the other map receives you
                        // (the original maps do not always line up exactly - never an invisible wall at a seam)
                        const auto tp2 = at[t];
                        const int ax = (p.first + (e.x0 + e.x1) / 2) / 8, ay = (p.second + (e.y0 + e.y1) / 2) / 8;
                        const int bx2 = (tp2.first + e.px) / 8, by2 = (tp2.second + e.py) / 8;
                        const bool vert = (e.x1 - e.x0) >= (e.y1 - e.y0);
                        const int half = std::clamp(((vert ? e.x1 - e.x0 : e.y1 - e.y0) / 8) / 2, 1, 3);
                        auto open = [&](int x, int y) { if (x >= 0 && y >= 0 && x < W && y < H) { walk[static_cast<size_t>(y) * W + x] |= 3; keep[static_cast<size_t>(y) * W + x] = 1; } };
                        if (vert) {
                            for (int y = std::min(ay, by2); y <= std::max(ay, by2); ++y) for (int d = -half; d <= half; ++d) open(ax + d, y);
                            for (int x = std::min(ax, bx2); x <= std::max(ax, bx2); ++x) for (int d = -1; d <= 1; ++d) open(x, by2 + d);
                        } else {
                            for (int x = std::min(ax, bx2); x <= std::max(ax, bx2); ++x) for (int d = -half; d <= half; ++d) open(x, ay + d);
                            for (int y = std::min(ay, by2); y <= std::max(ay, by2); ++y) for (int d = -1; d <= 1; ++d) open(bx2 + d, y);
                        }
                        continue;
                    }
                    const auto tp = at[t];
                    char b2[200];
                    std::snprintf(b2, sizeof b2, "%s{\"rect\":[%d,%d,%d,%d],\"to\":%d,\"arrive\":[%d,%d]}", ex_js.empty() ? "" : ",",
                        p.first + e.x0, p.second + e.y0, p.first + e.x1, p.second + e.y1, region_of[t], tp.first + e.px, tp.second + e.py);
                    ex_js += b2;
                    SR.ex.push_back({p.first + e.x0, p.second + e.y0, p.first + e.x1, p.second + e.y1, region_of[t], tp.first + e.px, tp.second + e.py});
                }
                for (const auto& o : m.objs) {
                    if (o.kind != 0) continue;
                    SR.en.push_back({o.type, o.set, p.first + o.x, p.second + o.y});
                    char b2[96];
                    std::snprintf(b2, sizeof b2, "%s[%d,%d,%d,%d]", en_js.empty() ? "" : ",", o.type, o.set, p.first + o.x, p.second + o.y);
                    en_js += b2;
                }
            }
            std::string nm; int bestn = -1;
            for (auto& [n2, c] : names) if (c > bestn && !n2.empty()) { bestn = c; nm = n2; }
            const KitMap& first = g_kit[static_cast<size_t>(regions[R][0].first)];
            SR.name = nm; SR.out = any_out; SR.arrx = regions[R][0].second.first + first.arr_x; SR.arry = regions[R][0].second.second + first.arr_y;
            js += (R ? "," : "") + std::string("{\"index\":") + std::to_string(R) + ",\"name\":" + jstr(nm) + ",\"kind\":\"" + (any_out ? "out" : "in") + "\",\"tw\":" + std::to_string(W) + ",\"th\":" + std::to_string(H) +
                ",\"arrival\":[" + std::to_string(regions[R][0].second.first + first.arr_x) + "," + std::to_string(regions[R][0].second.second + first.arr_y) + "]" +
                ",\"maps\":[" + maps_js + "],\"exits\":[" + ex_js + "],\"enemies\":[" + en_js + "]}";
            // the roads between joined regions: the ground at the way out, carried along to the way in
            if (corridors.count(static_cast<int>(R))) {
                for (const auto& c : corridors[static_cast<int>(R)]) {
                    const int ax = (at[c.ka].first + c.ax) / 8, ay = (at[c.ka].second + c.ay) / 8;
                    const int bx2 = (at[c.kb].first + c.bx) / 8, by2 = (at[c.kb].second + c.by) / 8;
                    if (ax < 0 || ay < 0 || ax >= W || ay >= H) continue;
                    // the road's look: the ground just inside the way out (all layers)
                    uint32_t road[5];
                    const size_t ra = static_cast<size_t>(ay) * W + ax;
                    for (int l = 0; l < 5; ++l) road[l] = WL[l][ra];
                    const bool vert_first = c.sa == 2 || c.sa == 3;
                    const int half = 2;
                    auto paint = [&](int x, int y) {
                        for (int dy = -half; dy <= half; ++dy) for (int dx = -half; dx <= half; ++dx) {
                            const int X = x + dx, Y = y + dy;
                            if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                            const size_t q = static_cast<size_t>(Y) * W + X;
                            if (WL[0][q] || WL[1][q] || WL[3][q]) { walk[q] |= 3; keep[q] = 1; continue; }   // map land: only opened
                            for (int l = 0; l < 5; ++l) WL[l][q] = road[l];
                            walk[q] = 3; keep[q] = 1;
                        }
                    };
                    // out of the way out first, then across, then into the way in
                    int x = ax, y = ay;
                    const int mx = vert_first ? ax : (ax + bx2) / 2, my = vert_first ? (ay + by2) / 2 : ay;
                    auto walk_to = [&](int tx, int ty) {
                        while (x != tx || y != ty) {
                            if (x != tx && (y == ty || !vert_first)) x += x < tx ? 1 : -1; else if (y != ty) y += y < ty ? 1 : -1;
                            paint(x, y);
                        }
                    };
                    if (vert_first) { walk_to(ax, my); walk_to(bx2, my); walk_to(bx2, by2); }
                    else { walk_to(mx, ay); walk_to(mx, by2); walk_to(bx2, by2); }
                }
            }
            // buildings the map's edge cuts in half (the rest of the house was in a map not next to this one):
            // where open land now lies past that edge, the cut piece is taken away and the ground carried on
            if (any_out && std::getenv("LOG2_NO_TRIM") == nullptr) {
                std::vector<int> cover(static_cast<size_t>(W) * H, -1);
                for (size_t mi = 0; mi < regions[R].size(); ++mi) {
                    const auto& [k2, p2] = regions[R][mi];
                    const KitMap& m2 = g_kit[static_cast<size_t>(k2)];
                    for (int y = 0; y < m2.th; ++y) for (int x = 0; x < m2.tw; ++x) {
                        const int X = p2.first / 8 + x, Y = p2.second / 8 + y;
                        if (X >= 0 && Y >= 0 && X < W && Y < H) cover[static_cast<size_t>(Y) * W + X] = static_cast<int>(mi);
                    }
                }
                auto structure = [&](size_t i) {
                    if ((walk[i] & 1) && !WL[3][i] && !WL[4][i]) return false;    // ground (a roof's edge drawn over it counts)
                    if (!WL[0][i] && !WL[1][i] && !WL[3][i]) return false;
                    if (cell_void(WL, i)) return false;
                    for (int l = 0; l < 5; ++l) if (WL[l][i] & (1u << 19)) return false;    // water
                    float nv = -1;
                    for (int l = 4; l >= 0 && nv < 0; --l) nv = tile_nature(WL[l][i]);
                    return nv < 0.25f;
                };
                std::vector<uint8_t> done(static_cast<size_t>(W) * H, 0);
                int trimmed = 0;
                for (size_t mi = 0; mi < regions[R].size(); ++mi) {
                    const auto& [k2, p2] = regions[R][mi];
                    const KitMap& m2 = g_kit[static_cast<size_t>(k2)];
                    const int mx = p2.first / 8, my = p2.second / 8;
                    // the map's usual ground (what the cut piece becomes)
                    std::map<std::array<uint32_t, 5>, int> gc; std::array<uint32_t, 5> ground{}; int gb = 0;
                    for (int y = 0; y < m2.th; ++y) for (int x = 0; x < m2.tw; ++x) {
                        const int X = mx + x, Y = my + y;
                        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                        const size_t i = static_cast<size_t>(Y) * W + X;
                        if (!(walk[i] & 1) || WL[2][i] || WL[3][i] || WL[4][i]) continue;
                        std::array<uint32_t, 5> c{WL[0][i], WL[1][i], 0, 0, 0};
                        if (++gc[c] > gb) { gb = gc[c]; ground = c; }
                    }
                    if (!gb) continue;
                    for (int y = 0; y < m2.th; ++y) for (int x = 0; x < m2.tw; ++x) {
                        if (x != 0 && y != 0 && x != m2.tw - 1 && y != m2.th - 1) continue;
                        const int X = mx + x, Y = my + y;
                        if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                        const size_t i = static_cast<size_t>(Y) * W + X;
                        if (done[i] || cover[i] != static_cast<int>(mi) || !structure(i)) continue;
                        // open land right past this edge?
                        const int ox2 = x == 0 ? -1 : (x == m2.tw - 1 ? 1 : 0), oy2 = y == 0 ? -1 : (y == m2.th - 1 ? 1 : 0);
                        const int PX = X + ox2, PY = Y + oy2;
                        if (PX >= 0 && PY >= 0 && PX < W && PY < H && cover[static_cast<size_t>(PY) * W + PX] >= 0) continue;
                        // the piece the edge cuts (only this map's, at most a house's worth)
                        std::vector<size_t> comp{i}, st{i}; done[i] = 1;
                        bool big = false;
                        while (!st.empty() && !big) {
                            const size_t c = st.back(); st.pop_back();
                            const int cx = static_cast<int>(c % W), cy = static_cast<int>(c / W);
                            const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                            for (auto& d : d4) {
                                const int NX = cx + d[0], NY = cy + d[1];
                                if (NX < 0 || NY < 0 || NX >= W || NY >= H) continue;
                                const size_t n2 = static_cast<size_t>(NY) * W + NX;
                                if (done[n2] || cover[n2] != static_cast<int>(mi) || !structure(n2)) continue;
                                done[n2] = 1; st.push_back(n2); comp.push_back(n2);
                                if (comp.size() > 700) { big = true; break; }
                            }
                        }
                        if (big) continue;     // a long wall or a cliff along the edge: it stays
                        {   // a door in it: the house stays (its way in must be seen)
                            bool door = false;
                            for (size_t c : comp) {
                                const int lx = (static_cast<int>(c % W) - mx) * 8 + 4, ly = (static_cast<int>(c / W) - my) * 8 + 4;
                                for (const auto& e : m2.exits) if (lx >= e.x0 - 12 && lx <= e.x1 + 12 && ly >= e.y0 - 12 && ly <= e.y1 + 12) { door = true; break; }
                                if (door) break;
                            }
                            if (door) {      // it stays, but solid all through (no walking on a roof that has no house under it)
                                for (size_t c : comp) walk[c] = 0;
                                continue;
                            }
                        }
                        {   // only what people built (a house, a wall of the city) - never a cliff or a rock
                            int mm = 0, tc = 0;
                            for (size_t c : comp) for (int l = 0; l < 5; ++l) if (WL[l][c]) { ++tc; if (manmade_tiles().count(WL[l][c] & 0xFFFFu)) ++mm; }
                            if (!tc || mm * 10 < tc * 3) continue;
                        }
                        {   // a building has many different tiles; a cliff or a rock wall repeats a few
                            std::set<uint64_t> looks;
                            for (size_t c : comp) { const uint32_t cc[5] = {WL[0][c], WL[1][c], WL[2][c], WL[3][c], WL[4][c]}; looks.insert(GrowPool::sig(cc)); }
                            if (comp.size() > 60 && looks.size() * 6 < comp.size()) continue;
                        }
                        for (size_t c : comp) {
                            for (int l = 0; l < 5; ++l) WL[l][c] = ground[static_cast<size_t>(l)];
                            walk[c] = 3;
                            ++trimmed;
                        }
                    }
                }
                if (trimmed) std::fprintf(stderr, "[export] land %d region %zu: %d tiles of cut-off buildings taken away\n", z, R, trimmed);
            }
            // the gaps between the maps: grown in the land's own style (outdoor regions only)
            if (any_out && regions[R].size() > 1 && std::getenv("LOG2_NO_GROW") == nullptr) {
                static std::map<int, GrowPool> pools;
                if (std::getenv("LOG2_OLD_GROW") && !pools.count(z)) { pools.clear(); std::vector<int> om; for (int i : list) if (outdoor(i)) om.push_back(i); pools[z] = make_pool(om); }   // one land's pieces at a time
                std::vector<GrowRect> rects;
                for (auto& [k2, p2] : regions[R]) { const KitMap& m2 = g_kit[static_cast<size_t>(k2)]; rects.push_back({p2.first / 8, p2.second / 8, m2.tw, m2.th, {1, 1, 1, 1}, k2}); }
                int n = 0;
                if (std::getenv("LOG2_OLD_GROW")) n = grow_land(WL, walk, W, H, pools[z], static_cast<uint32_t>(z * 977 + R), rects);
                else {
                    std::vector<uint8_t> mask(static_cast<size_t>(W) * H, 0);
                    for (size_t i = 0; i < mask.size(); ++i) {
                        const bool has = WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i];
                        if (!has || (!(walk[i] & 1) && cell_void(WL, i))) { mask[i] = 1; for (int l = 0; l < 5; ++l) WL[l][i] = 0; }
                    }
                    std::vector<int> owner(static_cast<size_t>(W) * H, -1);
                    for (auto& [k2, p2] : regions[R]) {
                        const KitMap& m2 = g_kit[static_cast<size_t>(k2)];
                        for (int y = 0; y < m2.th; ++y) for (int x = 0; x < m2.tw; ++x) {
                            const int X = p2.first / 8 + x, Y = p2.second / 8 + y;
                            if (X >= 0 && Y >= 0 && X < W && Y < H && !mask[static_cast<size_t>(Y) * W + X]) owner[static_cast<size_t>(Y) * W + X] = k2;
                        }
                    }
                    n = fill_by_places(WL, walk, W, H, mask, owner, nullptr, static_cast<uint32_t>(z * 977 + R));
                }
                std::fprintf(stderr, "[export] land %d region %zu: %d tiles of country\n", z, R, n);
            }
            // the region's file
            {   // the same look walked on in this very place: walked on everywhere in it (a story barrier, an
                // out-of-bounds stretch of the same ground: never an invisible wall)
                std::unordered_map<uint64_t, std::pair<int, int>> st;
                const uint32_t F = ~(3u << 16);
                auto sg = [&](size_t i) { const uint32_t c[5] = {WL[0][i] & F, WL[1][i] & F, WL[2][i] & F, WL[3][i] & F, WL[4][i] & F}; return GrowPool::sig(c); };
                for (size_t i = 0; i < walk.size(); ++i) {
                    if (!WL[0][i] && !WL[1][i] && !WL[3][i]) continue;
                    auto& e = st[sg(i)]; e.first += walk[i] & 1; e.second++;
                }
                int opened = 0;
                for (size_t i = 0; i < walk.size(); ++i) {
                    if ((walk[i] & 1) || (!WL[0][i] && !WL[1][i] && !WL[3][i])) continue;
                    bool water = false;
                    for (int l = 0; l < 5; ++l) water = water || (WL[l][i] & (1u << 19));
                    if (water || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i]) continue;     // bare ground only (a roof, a wall: never)
                    if (manmade_tiles().count(WL[0][i] & 0xFFFFu)) continue;
                    const auto& e = st[sg(i)];
                    if (false && e.second >= 6 && e.first * 10 >= e.second * 3) { walk[i] = 3; keep[i] = 1; ++opened; }
                }
                if (opened && std::getenv("LOG2_WORLD_LOG")) std::fprintf(stderr, "[export] land %d region %zu: %d invisible-wall tiles opened\n", z, R, opened);
            }
            fix_collision(WL, walk, 0, walk.size(), &keep);
            SR.keep = keep;
            regrass(WL, W, H);
            write_lkr(zd / (std::to_string(R) + ".bin"), W, H, WL, walk);
            std::vector<uint8_t> mini(static_cast<size_t>(W) * H * 4, 0);
            for (size_t i = 0; i < static_cast<size_t>(W) * H; ++i) {
                uint32_t col = 0;
                for (int l = 0; l < 5; ++l) {
                    const uint32_t c = WL[l][i];
                    if (!c) continue;
                    const uint32_t id = c & 0xFFFF;
                    if (c & (1u << 19)) col = 0xFFC08040u; else if (id < tile_col.size() && tile_col[id]) col = tile_col[id];
                }
                if (!walk[i] && col) col = (col & 0xFF000000u) | ((col & 0xFEFEFEu) >> 1);   // walls a little darker
                std::memcpy(&mini[i * 4], &col, 4);
            }
            romcat::save_png_rgba((zd / (std::to_string(R) + "_mini.png")).string(), mini, W, H);
            SR.W = W; SR.H = H;
            if (z > 0) { for (int l = 0; l < 5; ++l) SR.WL[l] = std::move(WL[l]); SR.walk = std::move(walk); }
        }
        js += "],\"start\":" + std::to_string(start) + "}";
        write_text(zd / "lands.json", js);
        std::fprintf(stderr, "[export] land %d: %zu regions, biggest %zu maps\n", z, regions.size(), most);
    }
}

// ---------------------------------------------------------------- EARTH: the whole planet as one map
// Every land's outdoors (West City, the jungle, the mountains, Gingertown, the islands...) set down on one big
// canvas where it lies on the planet, with wide country grown between them in each land's own style (walkable:
// meadows and paths with woods between), the ocean all round, roads where the game's own ways lead from land to
// land, and every house, cave and hall still behind its door. Written as land 0.
static bool kit_outdoor(int i) {
    const KitMap& m = g_kit[static_cast<size_t>(i)];
    if (m.tw * m.th < 24 * 18) return false;
    for (const auto& e : m.exits) if (side_of(m, e) >= 0) return true;
    return false;
}
static void write_lkr(const fs::path& f, int W, int H, const std::vector<uint32_t> (&WL)[5], const std::vector<uint8_t>& walk) {
    std::ofstream o(f, std::ios::binary);
    const uint8_t hd[8] = {'L', 'K', 'R', '2', static_cast<uint8_t>(W), static_cast<uint8_t>(W >> 8), static_cast<uint8_t>(H), static_cast<uint8_t>(H >> 8)};
    o.write(reinterpret_cast<const char*>(hd), 8);
    for (auto& l : WL) o.write(reinterpret_cast<const char*>(l.data()), static_cast<std::streamsize>(l.size() * 4));
    std::vector<uint8_t> w2(walk.size());
    for (size_t i = 0; i < walk.size(); ++i) w2[i] = walk[i] & 1;     // ready to use: no loop over every tile when the game loads it
    // (Android port) the field trees' trunks are drawn into the ground tiles: they block
    for (size_t i = 0; i < w2.size(); ++i) { const uint32_t id = WL[0][i] & 0xFFFFu; if (id >= 15729u && id <= 15734u) w2[i] = 0; }
    {   // (Android port) the clothes lying on the ground east of Gingertown are walked over, not walls
        static const uint32_t kClothes[] = {39783, 39784, 39785, 39786, 39787, 39788, 39789, 39790, 39791, 39816, 39820, 39821, 39824, 39825, 39826, 39828, 39829, 39830, 39831, 39836, 39837, 39838, 39842, 39843, 39844, 39845, 39848, 39849, 39851, 39862, 39863, 39865, 39866, 39867, 39868, 39869, 39870, 39871, 39872};
        for (size_t i = 0; i < w2.size(); ++i) {
            if (w2[i]) continue;
            bool any = false, other = false;
            for (int l = 1; l < 5; ++l) {
                if (!WL[l][i]) continue;
                const uint32_t id = WL[l][i] & 0xFFFFu; bool hit = false;
                for (uint32_t c : kClothes) if (c == id) { hit = true; break; }
                if (hit) any = true; else other = true;
            }
            if (any && !other && !(WL[0][i] & (1u << 19))) w2[i] = 1;      // (on grass or on paving: clothes never block)
        }
    }
    // (Android port) under a tree's leaves you walk on: a wall with only what is drawn OVER the hero (a canopy) above
    // plain ground the game lets you walk on elsewhere opens - the trunk (drawn under the hero) still blocks
    {
        std::vector<uint8_t> cano(w2.size(), 0);
        for (size_t i = 0; i < w2.size(); ++i) {
            if (w2[i] || !WL[0][i] || WL[1][i] || WL[2][i] || !(WL[3][i] || WL[4][i]) || (WL[0][i] & (1u << 19))) continue;
            bool leafy = true;      // what is drawn over the hero must be leaves: green, not dark (a cut-away room's black, a roof)
            for (int l = 3; l < 5 && leafy; ++l) {
                if (!WL[l][i]) continue;
                const uint32_t id = WL[l][i] & 0xFFFFu; const uint32_t c = id < g_tile_col.size() ? g_tile_col[id] : 0u;
                const int r = c & 255, g = (c >> 8) & 255, b = (c >> 16) & 255;
                if (!c || g < b + 10 || g < r - 20 || r + g + b < 120) leafy = false;      // greens, olives and the brown shading of leaves (not roofs' pinks and blues, not the dark)
            }
            auto gi = g_ground_walk.find(WL[0][i] & ~(3u << 16));
            if (gi != g_ground_walk.end() && gi->second.second >= 10 && gi->second.first * 10 >= gi->second.second * 3) cano[i] = leafy ? 2 : 1;
        }
        // only a tree's or a clump's leaves (a patch of up to 160 cells: a raised meadow ringed by cliffs is bigger and stays as it was): a solid jungle canopy stays a wall
        std::vector<uint8_t> seen(w2.size(), 0); std::vector<size_t> comp, st;
        for (size_t s0 = 0; s0 < cano.size(); ++s0) {
            if (!cano[s0] || seen[s0]) continue;
            comp.clear(); st.assign(1, s0); seen[s0] = 1;
            while (!st.empty()) {
                const size_t c = st.back(); st.pop_back(); comp.push_back(c);
                const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
                const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                for (auto& d : d4) {
                    const int X = x + d[0], Y = y + d[1];
                    if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                    const size_t j = static_cast<size_t>(Y) * W + X;
                    if (cano[j] && !seen[j]) { seen[j] = 1; st.push_back(j); }
                }
            }
            if (comp.size() > 160) continue;
            size_t nleaf = 0; for (size_t c : comp) nleaf += cano[c] == 2;
            int bx0 = W, bx1 = -1, by = -1;
            for (size_t c : comp) { const int x = static_cast<int>(c % W), y = static_cast<int>(c / W); bx0 = std::min(bx0, x); bx1 = std::max(bx1, x); by = std::max(by, y); }
            bool trunk_near = false;      // a trunk wall just under the leaves (the field trees: the trunk is drawn in the ground)
            for (int dy = 1; dy <= 3 && !trunk_near; ++dy) for (int x = bx0; x <= bx1 && !trunk_near; ++x) {
                if (by + dy >= H) break;
                const size_t j = static_cast<size_t>(by + dy) * W + x;
                if (!w2[j] && !cano[j] && WL[0][j]) trunk_near = true;
            }
            if (nleaf * 2 < comp.size() && !trunk_near) continue;      // a patch that is mostly leaves (its brown shading comes along); not dirt or a ledge
            // the trunk stays: a tree drawn wholly over the hero has its trunk at the bottom middle of its leaves
            int minx = W, maxx = -1, maxy = -1;
            for (size_t c : comp) { const int x = static_cast<int>(c % W), y = static_cast<int>(c / W); minx = std::min(minx, x); maxx = std::max(maxx, x); maxy = std::max(maxy, y); }
            const int mid = (minx + maxx) / 2;
            const bool trunk_below = trunk_near || (maxy + 1 < H && !w2[static_cast<size_t>(maxy + 1) * W + mid]);      // the trunk under the leaves already blocks
            for (size_t c : comp) {
                const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
                if (!trunk_below && y >= maxy - 1 && std::abs(x - mid) <= ((maxx - minx) >= 3 ? 1 : 0)) continue;
                w2[c] = 1; ++g_canopy_opened;
            }
        }
    }
    auto plain = [&](size_t i) {
        { const uint32_t id0 = WL[0][i] & 0xFFFFu; if (id0 >= 15729u && id0 <= 15734u) return false; }      // a field tree's trunk
        for (int l = 0; l < 5; ++l) if (WL[l][i] & (1u << 19)) {      // animated: water - or swaying flowers, walked over in the game
            auto ai = g_ground_walk.find(WL[l][i] & ~(3u << 16));
            if (ai == g_ground_walk.end() || ai->second.second < 10 || ai->second.first * 10 < ai->second.second * 3) return false;   // water
        }
        if (manmade_tiles().count(WL[0][i] & 0xFFFFu)) return false;               // a wall, a floor of a building
        auto col = [](uint32_t v) { const uint32_t id = v & 0xFFFF; return id < g_tile_col.size() ? g_tile_col[id] : 0u; };
        const uint32_t g0 = col(WL[0][i]);
        for (int l = 1; l < 5; ++l) {
            if (!WL[l][i]) continue;
            auto ti = g_ground_walk.find(WL[l][i] & ~(3u << 16));
            if (ti != g_ground_walk.end() && ti->second.second >= 10 && ti->second.first * 10 >= ti->second.second * 3) continue;   // walked over in the game (grass tufts: about half the time)
            // or it does not stand out from the ground under it (a strip of grass on grass): it cannot be seen, so it cannot block
            const uint32_t c = col(WL[l][i]);
            if (!g0 || !c) return false;
            const int d = std::abs(static_cast<int>(c & 255) - static_cast<int>(g0 & 255)) + std::abs(static_cast<int>((c >> 8) & 255) - static_cast<int>((g0 >> 8) & 255))
                        + std::abs(static_cast<int>((c >> 16) & 255) - static_cast<int>((g0 >> 16) & 255));
            if (d > 48) return false;
        }
        return true;
    };
    g_walls_opened += open_invisible_walls(W, H, plain,
        [&](size_t i) { return !w2[i] && (WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i]); }, [&](size_t i) { w2[i] = 1; });
    o.write(reinterpret_cast<const char*>(w2.data()), static_cast<std::streamsize>(w2.size()));
}
// a tile (all layers) that is only black or nearly (the dark round a cut-away room)
static bool cell_dark(const std::vector<uint32_t> (&WL)[5], size_t d) {
    for (int l = 0; l < 5; ++l) {
        const uint32_t c = WL[l][d];
        if (!c) continue;
        if (c & (1u << 19)) return false;
        const uint32_t id = c & 0xFFFF;
        const uint32_t col = id < g_tile_col.size() ? g_tile_col[id] : 0;
        const int lum = static_cast<int>((col & 0xFF) + ((col >> 8) & 0xFF) + ((col >> 16) & 0xFF));
        if (lum > 60) return false;
    }
    return true;
}
static void export_earth(const fs::path& dir) {
    if (std::getenv("LOG2_NO_EARTH") || g_store.empty()) return;
    // where each land lies (centres, in tiles): the north up top, West City in the middle, the islands to the south
    struct Anchor { int z, cx, cy; };
    const Anchor anchors[] = {{4, 862, 1230}, {8, 868, 365}, {2, 1657, 856}, {6, 212, 1018}, {10, 1556, 1323}, {7, 831, 1991}, {3, 1333, 267},
                              {13, 410, 268}, {12, 1242, 1884}, {1, 174, 1298}, {14, 1832, 1632}, {5, 339, 1872}, {9, 1600, 1671}, {11, 1516, 2018}};
    const int G = std::getenv("LOG2_EARTH_GAP") ? std::atoi(std::getenv("LOG2_EARTH_GAP")) : 44, M = 44, PAD = 30;
    struct Blk { int z, r, x, y, w, h, kind; int px = 0, py = 0, pw = 0, ph = 0; };   // kind 0 a land, 1 more of its outdoors, 2 a place behind doors (its plot)
    std::vector<Blk> blk;
    std::map<std::pair<int, int>, int> place_of;
    auto reg = [&](int z, int r) -> const StoredReg& { return g_store[z].regs[static_cast<size_t>(r)]; };
    auto clash = [&](int x, int y, int w, int h, int gap) { for (auto& b : blk) if (b.kind < 2 && x - gap < b.x + b.w && b.x < x + w + gap && y - gap < b.y + b.h && b.y < y + h + gap) return true; return false; };
    auto spiral = [&](int& bx, int& by, int w, int h, int gap) {
        if (!clash(bx, by, w, h, gap)) return;
        for (int r = 4; r < 4000; r += 4) for (int k = 0; k < 48; ++k) {
            const double an = k * 3.14159265 / 24;
            const int x = bx + static_cast<int>(std::cos(an) * r), y = by + static_cast<int>(std::sin(an) * r);
            if (!clash(x, y, w, h, gap)) { bx = x; by = y; return; }
        }
    };
    std::vector<Anchor> order(std::begin(anchors), std::end(anchors));
    for (auto& [z, SZ] : g_store) { bool f = false; for (auto& a : order) f = f || a.z == z; if (!f && z > 0) order.push_back({z, 1000, 1000}); }
    for (auto& a : order) {
        auto it = g_store.find(a.z);
        if (it == g_store.end()) continue;
        const StoredReg& S = it->second.regs[static_cast<size_t>(it->second.start)];
        if (S.WL[0].empty()) continue;
        int bx = a.cx - S.W / 2, by = a.cy - S.H / 2;
        spiral(bx, by, S.W, S.H, G);
        place_of[{a.z, it->second.start}] = static_cast<int>(blk.size());
        blk.push_back({a.z, it->second.start, bx, by, S.W, S.H, 0});
    }
    if (blk.empty()) return;
    std::map<int, int> blk_of;   // zone -> its land
    for (size_t i = 0; i < blk.size(); ++i) blk_of[blk[i].z] = static_cast<int>(i);
    // the rest of each land's outdoors (a stretch of road, a farm, the land round a house) is set down on the planet
    // too, next to where its way in leaves the land; rooms, caves and halls (dark all round) go behind their doors
    auto indoor = [&](const StoredReg& S) {
        if (!S.out || S.W * S.H < 30 * 30) return true;
        const std::string& n = S.name;
        for (const char* k : {"Cave", "Cavern", "Lab", "Ship", "Tower", "Arena", "Inside", "Room"}) if (n.find(k) != std::string::npos) return true;
        int vd = 0, tot = 0;
        for (int y = 0; y < S.H; ++y) for (int x = 0; x < S.W; ++x) {
            if (x > 1 && y > 1 && x < S.W - 2 && y < S.H - 2) continue;
            ++tot; if (cell_void(S.WL, static_cast<size_t>(y) * S.W + x)) ++vd;
        }
        if (S.W * S.H >= 5000) return false;      // a big stretch of the land (its edges are often black padding)
        return tot && vd * 10 > tot * 4;
    };
    {
        std::deque<int> q;
        for (size_t i = 0; i < blk.size(); ++i) q.push_back(static_cast<int>(i));
        while (!q.empty()) {
            const int bi = q.front(); q.pop_front();
            const Blk B = blk[static_cast<size_t>(bi)];
            const StoredReg& S = reg(B.z, B.r);
            for (const auto& e : S.ex) {
                if (place_of.count({B.z, e.to})) continue;
                const StoredReg& T = reg(B.z, e.to);
                if (T.WL[0].empty() || indoor(T)) continue;
                // which side of this place the way leaves by
                const int cx = (e.x0 + e.x1) / 16, cy = (e.y0 + e.y1) / 16;
                const int dl = cx, dr = B.w - cx, dt = cy, db = B.h - cy;
                const int mn = std::min({dl, dr, dt, db});
                const int ax = (e.ax) / 8, ay = (e.ay) / 8;    // where it arrives inside T
                int x, y;
                if (mn == dl) { x = B.x - T.W - 16; y = B.y + cy - ay; }
                else if (mn == dr) { x = B.x + B.w + 16; y = B.y + cy - ay; }
                else if (mn == dt) { x = B.x + cx - ax; y = B.y - T.H - 16; }
                else { x = B.x + cx - ax; y = B.y + B.h + 16; }
                spiral(x, y, T.W, T.H, 14);
                place_of[{B.z, e.to}] = static_cast<int>(blk.size());
                blk.push_back({B.z, e.to, x, y, T.W, T.H, 1});
                q.push_back(static_cast<int>(blk.size()) - 1);
            }
        }
        for (auto& [z, SZ] : g_store) {   // outdoors with no way from a placed one: beside their land
            if (z <= 0 || !blk_of.count(z)) continue;
            for (size_t r = 0; r < SZ.regs.size(); ++r) {
                if (place_of.count({z, static_cast<int>(r)})) continue;
                const StoredReg& T = SZ.regs[r];
                if (T.WL[0].empty() || indoor(T)) continue;
                const Blk& B = blk[static_cast<size_t>(blk_of[z])];
                int x = B.x + B.w + 16, y = B.y + B.h / 2 - T.H / 2;
                spiral(x, y, T.W, T.H, 14);
                place_of[{z, static_cast<int>(r)}] = static_cast<int>(blk.size());
                blk.push_back({z, static_cast<int>(r), x, y, T.W, T.H, 1});
            }
        }
    }
    int mnx = 1 << 30, mny = 1 << 30, mxx = -(1 << 30), mxy = -(1 << 30);
    for (auto& b : blk) { mnx = std::min(mnx, b.x); mny = std::min(mny, b.y); mxx = std::max(mxx, b.x + b.w); mxy = std::max(mxy, b.y + b.h); }
    for (auto& b : blk) { b.x += M - mnx; b.y += M - mny; }
    const int W = mxx - mnx + 2 * M, HP = mxy - mny + 2 * M;     // the planet; the places behind doors lie below it
    // ---- the places behind doors: each on its own plot, its own floor and walls carried on all round it
    int H = HP;
    {
        std::vector<std::pair<int, int>> inner;
        for (auto& [z, SZ] : g_store) {
            if (z <= 0) continue;
            for (size_t r = 0; r < SZ.regs.size(); ++r) {
                if (place_of.count({z, static_cast<int>(r)}) || SZ.regs[r].WL[0].empty()) continue;
                bool world_map = false;     // the game's flying map of the world: EARTH is the world now
                for (auto& [k, p] : SZ.regs[r].maps) world_map = world_map || g_kit[static_cast<size_t>(k)].name == "The World";
                if (!world_map) inner.push_back({z, static_cast<int>(r)});
            }
        }
        std::sort(inner.begin(), inner.end(), [&](auto a, auto b) { return reg(a.first, a.second).H > reg(b.first, b.second).H; });
        int x = 0, y = HP, rowh = 0;
        size_t row0 = blk.size();
        auto close_row = [&]() {      // every plot of a row as tall as the row, the last one to the edge: no gap anywhere
            for (size_t i = row0; i < blk.size(); ++i) blk[i].ph = rowh;
            if (blk.size() > row0) blk.back().pw = W - blk.back().px;
            row0 = blk.size();
        };
        for (auto [z, r] : inner) {
            const StoredReg& S = reg(z, r);
            const int pw = S.W + 2 * PAD, ph = S.H + 2 * PAD;
            if (x + pw > W && x > 0) { close_row(); x = 0; y += rowh; rowh = 0; }
            Blk b{z, r, x + PAD, y + PAD, S.W, S.H, 2};
            b.px = x; b.py = y; b.pw = std::min(pw, W - x); b.ph = ph;
            place_of[{z, r}] = static_cast<int>(blk.size());
            blk.push_back(b);
            if (std::getenv("LOG2_EARTH_DBG")) std::fprintf(stderr, "[earth] plot %d/%d %s at %d,%d size %dx%d\n", z, r, S.name.c_str(), b.x, b.y, S.W, S.H);
            x += pw; rowh = std::max(rowh, ph);
        }
        close_row();
        H = y + rowh;
    }
    const size_t N = static_cast<size_t>(W) * H;
    int n_out = 0, n_in = 0;
    for (auto& b : blk) (b.kind == 2 ? n_in : n_out)++;
    std::fprintf(stderr, "[earth] %d x %d tiles (planet %d high): %d outdoor places, %d behind doors\n", W, H, HP, n_out, n_in);
    // ---- the canvas
    std::vector<uint32_t> WL[5];
    for (auto& l : WL) l.assign(N, 0);
    std::vector<uint8_t> walk(N, 0), orig(N, 0), ocean(N, 0);     // ocean: 1 sea, 2 sea a road may cross, 3 behind doors
    std::vector<uint8_t> keep(N, 0);
    for (size_t bi = 0; bi < blk.size(); ++bi) {
        const auto& b = blk[bi];
        const StoredReg& S = reg(b.z, b.r);
        for (int y = 0; y < b.h; ++y) for (int x = 0; x < b.w; ++x) {
            const int X = b.x + x, Y = b.y + y;
            if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
            const size_t s = static_cast<size_t>(y) * b.w + x, d = static_cast<size_t>(Y) * W + X;
            for (int l = 0; l < 5; ++l) WL[l][d] = S.WL[l][s];
            walk[d] = S.walk[s];
            if (s < S.keep.size()) keep[d] = S.keep[s];
        }
        if (b.kind == 2) {
            // the plot: the room, and black all round it
            std::vector<uint8_t> content(static_cast<size_t>(b.pw) * b.ph, 0);
            int bx0 = 1 << 30, by0 = 1 << 30, bx1 = -1, by1 = -1;
            // how far each tile is from the floor (the dark around a room, far from any floor, is not the room)
            std::vector<int> fd(content.size(), 1 << 20);
            {
                std::deque<int> q;
                for (int y = 0; y < b.ph; ++y) for (int x = 0; x < b.pw; ++x) {
                    const size_t d = static_cast<size_t>(b.py + y) * W + b.px + x;
                    if (walk[d] & 1) { fd[static_cast<size_t>(y) * b.pw + x] = 0; q.push_back(y * b.pw + x); }
                }
                while (!q.empty()) {
                    const int c = q.front(); q.pop_front();
                    const int x = c % b.pw, y = c / b.pw;
                    const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                    for (auto& dd : d4) {
                        const int X = x + dd[0], Y = y + dd[1];
                        if (X < 0 || Y < 0 || X >= b.pw || Y >= b.ph) continue;
                        const int n2 = Y * b.pw + X;
                        if (fd[static_cast<size_t>(n2)] <= fd[static_cast<size_t>(c)] + 1) continue;
                        fd[static_cast<size_t>(n2)] = fd[static_cast<size_t>(c)] + 1;
                        q.push_back(n2);
                    }
                }
            }
            auto dark = [&](size_t d) { return cell_dark(WL, d); };
            for (int y = 0; y < b.ph; ++y) for (int x = 0; x < b.pw; ++x) {
                const int X = b.px + x, Y = b.py + y;
                const size_t d = static_cast<size_t>(Y) * W + X;
                ocean[d] = 3;
                const bool in = X >= b.x && Y >= b.y && X < b.x + b.w && Y < b.y + b.h;
                if (!in) continue;
                const bool has = WL[0][d] || WL[1][d] || WL[2][d] || WL[3][d] || WL[4][d];
                const int f = fd[static_cast<size_t>(y) * b.pw + x];
                // black is never the room (the dark round a cut-away room), but by a way out it stays walkable
                bool by_exit = false;
                if ((walk[d] & 1) && dark(d)) {
                    const int lx = (X - b.x) * 8 + 4, ly = (Y - b.y) * 8 + 4;
                    for (const auto& e : S.ex) if (lx >= e.x0 - 24 && lx <= e.x1 + 24 && ly >= e.y0 - 24 && ly <= e.y1 + 24) by_exit = true;
                    for (const auto& e : S.xex) if (lx >= e.x0 - 24 && lx <= e.x1 + 24 && ly >= e.y0 - 24 && ly <= e.y1 + 24) by_exit = true;
                }
                if (has && (by_exit || (!dark(d) && ((walk[d] & 1) || f <= 12)))) { content[static_cast<size_t>(y) * b.pw + x] = 1; bx0 = std::min(bx0, x); by0 = std::min(by0, y); bx1 = std::max(bx1, x); by1 = std::max(by1, y); }
            }
            if (bx1 < 0) continue;
            // everything round the room is black and solid, like the GBA (no mirrored copies of the room); the room itself untouched
            std::array<uint32_t, 5> blackc{}; {
                std::map<std::array<uint32_t, 5>, int> cnt; int bn = 0;
                for (int y = 0; y < b.h; ++y) for (int x = 0; x < b.w; ++x) {
                    const size_t d = static_cast<size_t>(b.y + y) * W + b.x + x;
                    if (!dark(d)) continue;
                    std::array<uint32_t, 5> c{WL[0][d], WL[1][d], WL[2][d], WL[3][d], WL[4][d]};
                    if (!c[0]) continue;
                    if (++cnt[c] > bn) { bn = cnt[c]; blackc = c; }
                }
            }
            for (int y = 0; y < b.ph; ++y) for (int x = 0; x < b.pw; ++x) {
                const size_t i = static_cast<size_t>(y) * b.pw + x;
                if (content[i]) continue;
                const int X = b.px + x, Y = b.py + y;
                if (X >= b.x && Y >= b.y && X < b.x + b.w && Y < b.y + b.h) continue;     // the room's own tiles stay as the GBA has them
                const size_t d = static_cast<size_t>(Y) * W + X;
                for (int l = 0; l < 5; ++l) WL[l][d] = blackc[static_cast<size_t>(l)];
                walk[d] = 0;
            }
            continue;
        }
        for (auto& [k, p] : S.maps) {
            const KitMap& m = g_kit[static_cast<size_t>(k)];
            for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
                const int X = b.x + p.first / 8 + x, Y = b.y + p.second / 8 + y;
                if (X >= 0 && Y >= 0 && X < W && Y < HP) orig[static_cast<size_t>(Y) * W + X] = static_cast<uint8_t>(std::min<size_t>(bi + 1, 255));
            }
        }
    }
    // ---- the ocean all round the planet (a coast that wanders, not a straight edge)
    std::array<uint32_t, 5> water{};
    {
        std::map<std::array<uint32_t, 5>, int> cnt;
        for (auto& b : blk) {
            if (b.kind != 0) continue;
            const StoredReg& S = reg(b.z, b.r);
            for (size_t s = 0; s < S.WL[0].size(); ++s) {
                if (!(S.WL[0][s] & (1u << 19)) || (S.walk[s] & 1) || S.WL[3][s] || S.WL[4][s]) continue;
                cnt[{S.WL[0][s], S.WL[1][s], S.WL[2][s], S.WL[3][s], S.WL[4][s]}]++;
            }
        }
        // the sea: water from any of the game's maps (blue, not walkable, nothing over it) - the commonest
        {
            auto blue = [&](uint32_t v) -> bool {
                int r = 0, g = 0, b = 0;
                if (v & (1u << 19)) { auto it = g_anim_rgb.find(static_cast<int>(v & 0xFFFF)); if (it == g_anim_rgb.end()) return false; r = it->second[0]; g = it->second[1]; b = it->second[2]; }
                else { const uint32_t id = v & 0xFFFF; if (id >= g_tile_col.size() || !g_tile_col[id]) return false; const uint32_t c = g_tile_col[id]; r = c & 255; g = (c >> 8) & 255; b = (c >> 16) & 255; }
                return b > r + 30 && b > g + 5;
            };
            std::map<uint32_t, int> wc;
            for (const auto& m : g_kit) {
                const size_t n = static_cast<size_t>(m.tw) * m.th;
                for (size_t q = 0; q < n; ++q) {
                    if (m.walk[q] & 1) continue;
                    uint32_t top = 0; int nl = 0;
                    for (int l = 0; l < 4; ++l) if (m.L[l][q] && !(m.L[l][q] & (1u << 18))) { top = m.L[l][q]; ++nl; }
                    if (nl == 1 && blue(top)) wc[top]++;
                }
            }
            // the sea is a pattern: a block of water cells that repeats (2 or 4 cells), taken from the game's own
            // lakes and seas - the one seen most
            // a cell as the planet lays it: the back layer on the ground, the next one over it (at most two)
            auto cellv = [&](const KitMap& m, int x, int y) -> std::pair<uint32_t, uint32_t> {
                const size_t q = static_cast<size_t>(y) * m.tw + x;
                if (m.walk[q] & 1) return {0, 0};
                int ord[4] = {0, 1, 2, 3};
                std::sort(ord, ord + 4, [&](int p1, int p2) { return m.pri[p1] != m.pri[p2] ? m.pri[p1] > m.pri[p2] : p1 > p2; });
                uint32_t v[2] = {0, 0}; int nl = 0; bool bl = false;
                for (int oi = 0; oi < 4; ++oi) {
                    const int l = ord[oi];
                    if (!((m.mask >> l) & 1) || ((m.light >> l) & 1)) continue;
                    const uint32_t c = m.L[l][q];
                    if (!c || (c & (1u << 18))) continue;
                    if (nl >= 2) return {0, 0};
                    v[nl++] = c;
                    bl = bl || blue(c);
                }
                if (!nl || !bl) return {0, 0};
                return {v[0], v[1]};
            };
            // the biggest block of open water in any of the game's maps (the Tropical Islands' sea): the planet's sea
            // is that block laid side by side (its waves are random enough that the joins don't show)
            int bestA = 0;
            for (const auto& m : g_kit) {
                for (int bh : {16, 12, 8}) for (int bw : {24, 16, 12, 8}) {
                    if (bw * bh <= bestA || bw > m.tw || bh > m.th) continue;
                    bool found = false;
                    for (int y = 0; y + bh <= m.th && !found; y += 2) for (int x = 0; x + bw <= m.tw && !found; x += 2) {
                        bool ok = true; bool anim = false;
                        for (int yy = 0; yy < bh && ok; ++yy) for (int xx = 0; xx < bw && ok; ++xx) {
                            const auto c = cellv(m, x + xx, y + yy);
                            if (!c.first) ok = false;
                            anim = anim || ((c.first | c.second) & (1u << 19));
                        }
                        if (!ok || !anim) continue;
                        found = true; bestA = bw * bh;
                        g_sea.assign({static_cast<uint32_t>(bw), static_cast<uint32_t>(bh)});
                        for (int yy = 0; yy < bh; ++yy) for (int xx = 0; xx < bw; ++xx) { const auto c = cellv(m, x + xx, y + yy); g_sea.push_back(c.first); g_sea.push_back(c.second); }
                        std::fprintf(stderr, "[earth] the sea: %dx%d of open water from map %s\n", bw, bh, m.key.c_str());
                    }
                }
            }
        }
        int best = 0;
        // the sea: the commonest animated ground that looks like water (blue) - not an animated meadow
        for (int pass = 0; pass < 2 && best == 0; ++pass)
            for (auto& [c, n] : cnt) {
                if (n <= best) continue;
                if (pass == 0) {
                    auto it = g_anim_rgb.find(static_cast<int>(c[0] & 0xFFFF));
                    if (it == g_anim_rgb.end()) continue;
                    const auto& rgb = it->second;
                    if (!(rgb[2] > rgb[0] + 25 && rgb[2] >= rgb[1])) continue;
                }
                best = n; water = c;
            }
        if (best > 0) {
            for (int y = 0; y < HP; ++y) for (int x = 0; x < W; ++x) {
                const size_t s = static_cast<size_t>(y) * W + x;
                if (orig[s] || ocean[s]) continue;
                const int d = std::min({x, y, W - 1 - x, HP - 1 - y});
                const float nz = vnoise(x / 19.0f, y / 19.0f, 99) * 26.0f + vnoise(x / 6.0f, y / 6.0f, 98) * 6.0f;
                if (d >= M - 6 || static_cast<float>(d) >= 8.0f + nz) continue;
                for (int l = 0; l < 5; ++l) WL[l][s] = water[static_cast<size_t>(l)];
                if (!g_sea.empty()) { const int sw = static_cast<int>(g_sea[0]), sh = static_cast<int>(g_sea[1]); const size_t k = 2 + 2 * static_cast<size_t>((y % sh) * sw + x % sw); for (int l = 0; l < 5; ++l) WL[l][s] = 0; WL[0][s] = g_sea[k]; WL[1][s] = g_sea[k + 1]; }
                walk[s] = 0; ocean[s] = 1;
            }
            // Master Roshi's island lies out at sea
            if (blk_of.count(11)) {
                const auto& b = blk[static_cast<size_t>(blk_of[11])];
                for (int y = b.y - 40; y < b.y + b.h + 40; ++y) for (int x = b.x - 40; x < b.x + b.w + 40; ++x) {
                    if (x < 0 || y < 0 || x >= W || y >= HP) continue;
                    const int dx = std::max({0, b.x - x, x - (b.x + b.w - 1)}), dy = std::max({0, b.y - y, y - (b.y + b.h - 1)});
                    const float r = 22.0f + vnoise(x / 9.0f, y / 9.0f, 77) * 12.0f;
                    const size_t s = static_cast<size_t>(y) * W + x;
                    if (orig[s] || ocean[s] || dx * dx + dy * dy > r * r || dx + dy < 3) continue;
                    for (int l = 0; l < 5; ++l) WL[l][s] = water[static_cast<size_t>(l)];
                    if (!g_sea.empty()) { const int sw = static_cast<int>(g_sea[0]), sh = static_cast<int>(g_sea[1]); const size_t k = 2 + 2 * static_cast<size_t>((y % sh) * sw + x % sw); for (int l = 0; l < 5; ++l) WL[l][s] = 0; WL[0][s] = g_sea[k]; WL[1][s] = g_sea[k + 1]; }
                    walk[s] = 0; ocean[s] = 2;
                }
            }
        }
        std::fprintf(stderr, "[earth] ocean tile %08x %08x (%d seen)\n", water[0], water[1], best);
        if (getenv("EXPORT_OCEAN_DEBUG"))
            for (auto& [c, n] : cnt) if (n > 200) { auto it = g_anim_rgb.find(static_cast<int>(c[0] & 0xFFFF)); std::fprintf(stderr, "  cand %08x %08x n=%d rgb=%d,%d,%d\n", c[0], c[1], n, it == g_anim_rgb.end() ? -1 : it->second[0], it == g_anim_rgb.end() ? -1 : it->second[1], it == g_anim_rgb.end() ? -1 : it->second[2]); }
    }
    // ---- whose country is where: every empty tile of the planet belongs to the nearest land that has country to grow
    std::vector<std::vector<int>> pool_maps(blk.size());
    static const std::set<int> country{2, 3, 4, 6, 7, 8, 10, 12, 13};     // the small places (an arena, a lone house) take their neighbours' country
    for (size_t i = 0; i < g_kit.size(); ++i) {
        auto bi = blk_of.find(g_kit[i].z);
        if (bi == blk_of.end() || !kit_outdoor(static_cast<int>(i)) || g_kit[i].tw < GrowPool::B || g_kit[i].th < GrowPool::B || !country.count(g_kit[i].z)) continue;
        pool_maps[static_cast<size_t>(bi->second)].push_back(static_cast<int>(i));
    }
    std::vector<int8_t> terr(N, -1);
    for (int y = 0; y < HP; ++y) for (int x = 0; x < W; ++x) {
        const size_t s = static_cast<size_t>(y) * W + x;
        if (ocean[s] || (orig[s] && !(cell_void(WL, s) && !(walk[s] & 1)))) continue;     // the maps' own black padding is grown over too
        long bd = 1L << 60; int bb = -1;
        for (size_t i = 0; i < blk.size(); ++i) {
            const auto& b = blk[i];
            if (b.kind == 2) continue;
            const int owner = blk_of[b.z];
            if (pool_maps[static_cast<size_t>(owner)].empty()) continue;
            const long dx = x < b.x ? b.x - x : (x >= b.x + b.w ? x - (b.x + b.w - 1) : 0);
            const long dy = y < b.y ? b.y - y : (y >= b.y + b.h ? y - (b.y + b.h - 1) : 0);
            const long d = dx * dx + dy * dy + static_cast<long>(vnoise(x / 31.0f, y / 31.0f, 50 + static_cast<uint32_t>(owner)) * 1800.0f);
            if (d < bd) { bd = d; bb = owner; }
        }
        terr[s] = static_cast<int8_t>(bb);
    }
    // ---- the country between the places: each place's own ground and things, the way the game builds it
    if (!std::getenv("LOG2_NO_GROW") && !std::getenv("LOG2_OLD_GROW")) {
        std::vector<uint8_t> mask(N, 0), blocked(N, 0);
        std::vector<int> owner(N, -1);
        for (size_t i = 0; i < static_cast<size_t>(W) * HP; ++i) {
            if (ocean[i]) { blocked[i] = 1; continue; }
            const bool has = WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i];
            if (!orig[i] && !(has && (walk[i] & 1) && keep[i])) mask[i] = 1;      // (blocks' own grown gaps were filled in their land already)
            else if (orig[i] && (!has || (!(walk[i] & 1) && cell_void(WL, i)))) mask[i] = 1;
        }
        for (size_t i = 0; i < static_cast<size_t>(W) * HP; ++i) if (!orig[i]) { /* outside any map */ }
        for (const auto& b : blk) {
            if (b.kind == 2) continue;
            for (auto& [k, p] : reg(b.z, b.r).maps) {
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
                    const int X = b.x + p.first / 8 + x, Y = b.y + p.second / 8 + y;
                    if (X < 0 || Y < 0 || X >= W || Y >= HP) continue;
                    const size_t i = static_cast<size_t>(Y) * W + X;
                    if (!mask[i]) owner[i] = k;
                }
            }
        }
        // inside a land's box but between its maps: already its land's country (keep it), only the open planet is filled
        for (const auto& b : blk) {
            if (b.kind == 2) continue;
            for (int y = b.y; y < b.y + b.h; ++y) for (int x = b.x; x < b.x + b.w; ++x) {
                const size_t i = static_cast<size_t>(y) * W + x;
                const bool has = WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i];
                if (!orig[i] && has && !cell_void(WL, i)) mask[i] = 0;
            }
        }
        const int n = fill_by_places(WL, walk, W, H, mask, owner, &blocked, 4242);
        std::fprintf(stderr, "[earth] %d tiles of country made the game's way\n", n);
    }
    if (!std::getenv("LOG2_NO_GROW") && std::getenv("LOG2_OLD_GROW")) {
        for (size_t i = 0; i < blk.size(); ++i) {
            if (blk[i].kind != 0 || pool_maps[i].empty()) continue;
            std::vector<uint8_t> mine(N, 0);
            size_t cnt = 0;
            for (size_t s = 0; s < N; ++s) if (terr[s] == static_cast<int8_t>(i)) { mine[s] = 1; ++cnt; }
            if (!cnt) continue;
            int n = 0;
            if (std::getenv("LOG2_OLD_GROW")) {
                GrowPool P = make_pool(pool_maps[i]);
                std::vector<GrowRect> rects;
                for (auto& b : blk) {
                    if (b.kind == 2 || b.z != blk[i].z) continue;
                    for (auto& [k, p] : reg(b.z, b.r).maps) { const KitMap& m = g_kit[static_cast<size_t>(k)]; rects.push_back({b.x + p.first / 8, b.y + p.second / 8, m.tw, m.th, {1, 1, 1, 1}, k}); }
                }
                n = grow_land(WL, walk, W, H, P, static_cast<uint32_t>(blk[i].z * 7919 + 3), rects, &mine, true);
            } else {
                const CountryKit K = make_country_kit(pool_maps[i]);
                // where this land meets another's: a thick line of its things (woods) instead of a seam
                std::vector<uint8_t> edge(N, 0);
                for (int y = 0; y < HP; ++y) for (int x = 0; x < W; ++x) {
                    const size_t s0 = static_cast<size_t>(y) * W + x;
                    if (!mine[s0]) continue;
                    bool e = false;
                    for (int d = 1; d <= 4 && !e; ++d) {
                        const int xs[4] = {x - d, x + d, x, x}, ys[4] = {y, y, y - d, y + d};
                        for (int q = 0; q < 4; ++q) {
                            if (xs[q] < 0 || ys[q] < 0 || xs[q] >= W || ys[q] >= HP) continue;
                            const size_t s1 = static_cast<size_t>(ys[q]) * W + xs[q];
                            if (terr[s1] >= 0 && terr[s1] != terr[s0]) { e = true; break; }
                        }
                    }
                    edge[s0] = e;
                }
                n = fill_country(WL, walk, W, H, mine, K, static_cast<uint32_t>(blk[i].z * 7919 + 3), &edge);
                std::fprintf(stderr, "[earth] land %d: ground %d tiles (pattern %dx%d), %zu things of its own\n", blk[i].z, static_cast<int>(K.ground.size()), K.px, K.py, K.stamps.size());
            }
            std::fprintf(stderr, "[earth] land %d: %zu tiles of country, %d done\n", blk[i].z, cnt, n);
        }
    }
    // the planet: never a black tile (a hole nothing grew in takes its nearest neighbour)
    {
        std::deque<size_t> q; std::vector<uint8_t> done(N, 0); int holes = 0;
        for (size_t s = 0; s < static_cast<size_t>(W) * HP; ++s) {
            const bool has = WL[0][s] || WL[1][s] || WL[3][s];
            if (has && !(cell_void(WL, s) && !(walk[s] & 1) && !orig[s])) { done[s] = 1; q.push_back(s); } else ++holes;
        }
        while (!q.empty()) {
            const size_t c = q.front(); q.pop_front();
            const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
            const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (auto& d : d4) {
                const int X = x + d[0], Y = y + d[1];
                if (X < 0 || Y < 0 || X >= W || Y >= HP) continue;
                const size_t n2 = static_cast<size_t>(Y) * W + X;
                if (done[n2]) continue;
                done[n2] = 1;
                for (int l = 0; l < 5; ++l) WL[l][n2] = WL[l][c];
                walk[n2] = walk[c] & 3;
                q.push_back(n2);
            }
        }
        std::fprintf(stderr, "[earth] %d black tiles filled\n", holes);
    }
    std::vector<uint8_t> grown_mask(N, 0);     // the new land: walkable wherever it is ground at all
    for (size_t i = 0; i < static_cast<size_t>(W) * HP; ++i) grown_mask[i] = !orig[i] && !ocean[i];
    std::fprintf(stderr, "[earth] collision: %d tiles mended (no invisible walls, nothing walked through)\n", fix_collision(WL, walk, 0, N, &keep, &grown_mask));
    std::fprintf(stderr, "[earth] %d tiles with flowers and the like on them made walkable\n", g_decor_opened);
    {   // plain ground (nothing standing on it) walked on in a third of the planet's places is ground everywhere
        std::unordered_map<uint32_t, std::pair<int, int>> st;
        const uint32_t F = ~(3u << 16);
        for (size_t i = 0; i < N; ++i) {
            if (!WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i] || (WL[0][i] & (1u << 19)) || ocean[i] == 1) continue;
            auto& e = st[WL[0][i] & F]; e.first += walk[i] & 1; e.second++;
        }
        int opened = 0;
        for (size_t i = 0; i < N; ++i) {
            if ((walk[i] & 1) || !WL[0][i] || WL[1][i] || WL[2][i] || WL[3][i] || WL[4][i] || (WL[0][i] & (1u << 19)) || ocean[i] == 1 || ocean[i] == 3) continue;
            const auto& e = st[WL[0][i] & F];
            if (e.second >= 20 && e.first * 10 >= e.second * 3 && !cell_dark(WL, i) && !manmade_tiles().count(WL[0][i] & 0xFFFFu) && !orig[i]) { walk[i] = 3; ++opened; }
        }
        std::fprintf(stderr, "[earth] %d plain-ground tiles opened (no invisible walls)\n", opened);
    }
    // ---- every way of every place, in planet pixels
    struct GEx { int x0, y0, x1, y1, ax, ay, sb, db; bool edge, drop; };
    std::vector<GEx> gex;
    for (size_t bi = 0; bi < blk.size(); ++bi) {
        const auto& b = blk[bi];
        const StoredReg& S = reg(b.z, b.r);
        const int ox = b.x * 8, oy = b.y * 8;
        auto edge_of = [&](int x0, int y0, int x1, int y1) {
            const int cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
            for (auto& [k, p] : S.maps) {
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                if (cx < p.first || cy < p.second || cx >= p.first + m.tw * 8 || cy >= p.second + m.th * 8) continue;
                const int mn = std::min({cx - p.first, p.first + m.tw * 8 - cx, cy - p.second, p.second + m.th * 8 - cy});
                return mn <= 40;
            }
            return false;
        };
        for (const auto& e : S.ex) {
            auto pi = place_of.find({b.z, e.to});
            if (pi == place_of.end()) continue;
            const auto& t = blk[static_cast<size_t>(pi->second)];
            gex.push_back({e.x0 + ox, e.y0 + oy, e.x1 + ox, e.y1 + oy, e.ax + t.x * 8, e.ay + t.y * 8, static_cast<int>(bi), pi->second, edge_of(e.x0, e.y0, e.x1, e.y1), false});
        }
        for (const auto& x : S.xex) {
            const int tz = g_kit[static_cast<size_t>(x.tmap)].z;
            auto zi = g_store.find(tz);
            if (zi == g_store.end()) continue;
            auto wi = zi->second.where.find(x.tmap);
            if (wi == zi->second.where.end()) continue;
            auto pi = place_of.find({tz, wi->second[0]});
            if (pi == place_of.end()) continue;
            const auto& t = blk[static_cast<size_t>(pi->second)];
            gex.push_back({x.x0 + ox, x.y0 + oy, x.x1 + ox, x.y1 + oy, wi->second[1] + x.px + t.x * 8, wi->second[2] + x.py + t.y * 8, static_cast<int>(bi), pi->second, x.side >= 0, false});
        }
    }
    // ---- roads
    struct Link { int ax, ay, bx, by; int ex; };     // ex: the way it replaces (-1 none)
    std::vector<Link> links;
    for (size_t i = 0; i < gex.size(); ++i) {
        const auto& e = gex[i];
        if (!e.edge || blk[static_cast<size_t>(e.sb)].kind == 2 || blk[static_cast<size_t>(e.db)].kind == 2) continue;
        links.push_back({(e.x0 + e.x1) / 16, (e.y0 + e.y1) / 16, e.ax / 8, e.ay / 8, static_cast<int>(i)});
    }
    const size_t n_way_links = links.size();
    std::vector<int> comp(blk.size());
    for (size_t i = 0; i < comp.size(); ++i) comp[i] = static_cast<int>(i);
    std::function<int(int)> find = [&](int a) { return comp[static_cast<size_t>(a)] == a ? a : comp[static_cast<size_t>(a)] = find(comp[static_cast<size_t>(a)]); };
    for (const auto& L : links) { const auto& e = gex[static_cast<size_t>(L.ex)]; comp[static_cast<size_t>(find(blk_of[blk[static_cast<size_t>(e.sb)].z]))] = find(blk_of[blk[static_cast<size_t>(e.db)].z]); }
    // every land still apart gets a road to its nearest neighbour (from where you can really walk out)
    std::vector<std::vector<size_t>> openings(blk.size());
    for (size_t i = 0; i < blk.size(); ++i) {
        const auto& b = blk[i];
        if (b.kind != 0) continue;
        const StoredReg& S = reg(b.z, b.r);
        std::vector<uint8_t> seen(static_cast<size_t>(b.w) * b.h, 0);
        std::deque<std::pair<int, int>> q;
        int sx = S.arrx / 8, sy = S.arry / 8;
        for (int r = 0; r < 20 && !(sx >= 0 && sy >= 0 && sx < b.w && sy < b.h && (S.walk[static_cast<size_t>(sy) * b.w + sx] & 1)); ++r) {
            bool f = false;
            for (int dy = -r; dy <= r && !f; ++dy) for (int dx = -r; dx <= r && !f; ++dx) {
                const int X = S.arrx / 8 + dx, Y = S.arry / 8 + dy;
                if (X >= 0 && Y >= 0 && X < b.w && Y < b.h && (S.walk[static_cast<size_t>(Y) * b.w + X] & 1)) { sx = X; sy = Y; f = true; }
            }
        }
        if (sx < 0 || sy < 0 || sx >= b.w || sy >= b.h) continue;
        seen[static_cast<size_t>(sy) * b.w + sx] = 1; q.push_back({sx, sy});
        while (!q.empty()) {
            auto [x, y] = q.front(); q.pop_front();
            const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            const size_t gs = static_cast<size_t>(b.y + y) * W + b.x + x;
            bool edge = false;
            for (auto& d : d4) {
                const int X = x + d[0], Y = y + d[1];
                const int GX = b.x + X, GY = b.y + Y;
                if (GX >= 0 && GY >= 0 && GX < W && GY < HP && !orig[static_cast<size_t>(GY) * W + GX]) edge = true;
                if (X < 0 || Y < 0 || X >= b.w || Y >= b.h) continue;
                const size_t s = static_cast<size_t>(Y) * b.w + X;
                if (seen[s] || !(S.walk[s] & 1)) continue;
                seen[s] = 1; q.push_back({X, Y});
            }
            if (edge) openings[i].push_back(gs);
        }
        if (openings[i].empty()) openings[i].push_back(static_cast<size_t>(b.y + sy) * W + b.x + sx);
    }
    {
        struct Pair { long d; int a, b; };
        std::vector<Pair> pairs;
        for (size_t a = 0; a < blk.size(); ++a) for (size_t c = a + 1; c < blk.size(); ++c) {
            if (blk[a].kind != 0 || blk[c].kind != 0 || openings[a].empty() || openings[c].empty()) continue;
            const auto& A = blk[a]; const auto& B = blk[c];
            const long dx = std::max({0, A.x - (B.x + B.w), B.x - (A.x + A.w)}), dy = std::max({0, A.y - (B.y + B.h), B.y - (A.y + A.h)});
            pairs.push_back({dx * dx + dy * dy, static_cast<int>(a), static_cast<int>(c)});
        }
        std::sort(pairs.begin(), pairs.end(), [](const Pair& p, const Pair& q) { return p.d < q.d; });
        int extra = 0;
        for (const auto& p : pairs) {
            const bool apart = find(p.a) != find(p.b);
            if (!apart && (extra >= 4 || p.d > 120L * 120L)) continue;
            const auto& B = blk[static_cast<size_t>(p.b)]; const auto& A = blk[static_cast<size_t>(p.a)];
            auto pick = [&](int from, const Blk& to) {
                size_t best = openings[static_cast<size_t>(from)][0]; long bd = 1L << 60;
                const int cx = to.x + to.w / 2, cy = to.y + to.h / 2;
                for (size_t s : openings[static_cast<size_t>(from)]) {
                    const long dx = static_cast<long>(s % W) - cx, dy = static_cast<long>(s / W) - cy;
                    if (dx * dx + dy * dy < bd) { bd = dx * dx + dy * dy; best = s; }
                }
                return best;
            };
            const size_t sa = pick(p.a, B), sb = pick(p.b, A);
            links.push_back({static_cast<int>(sa % W), static_cast<int>(sa / W), static_cast<int>(sb % W), static_cast<int>(sb / W), -1});
            if (!apart) ++extra;
            comp[static_cast<size_t>(find(p.a))] = find(p.b);
        }
    }
    {
        std::vector<float> g(N, 0); std::vector<uint32_t> stamp(N, 0); std::vector<int> par(N, -1);
        uint32_t gen = 0;
        int painted = 0, nroads = 0, kept = 0;
        auto cost = [&](size_t s) -> float {
            if (ocean[s] == 1 || ocean[s] == 3) return -1;
            if (ocean[s] == 2) return 5.0f;
            if (orig[s]) return (walk[s] & 1) ? 1.0f : -1.0f;     // never through a wall of the game's maps
            return (walk[s] & 1) ? 1.0f : 3.0f;
        };
        auto route = [&](const std::vector<size_t>& src, const std::function<bool(size_t)>& goal, int tx, int ty) {
            ++gen;
            using QE = std::pair<float, size_t>;
            std::priority_queue<QE, std::vector<QE>, std::greater<QE>> pq;
            auto hd = [&](size_t s) { return tx < 0 ? 0.0f : static_cast<float>(std::abs(static_cast<int>(s % W) - tx) + std::abs(static_cast<int>(s / W) - ty)); };
            for (size_t s : src) { stamp[s] = gen; g[s] = 0; par[s] = -1; pq.push({hd(s), s}); }
            long end = -1; int pops = 0;
            while (!pq.empty() && pops < 30000000) {
                auto [f, s] = pq.top(); pq.pop(); ++pops;
                if (f - hd(s) > g[s] + 0.01f) continue;
                if (goal(s)) { end = static_cast<long>(s); break; }
                const int x = static_cast<int>(s % W), y = static_cast<int>(s / W);
                const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                for (auto& d : d4) {
                    const int X = x + d[0], Y = y + d[1];
                    if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
                    const size_t n2 = static_cast<size_t>(Y) * W + X;
                    const float c = cost(n2);
                    if (c < 0) continue;
                    const float ng = g[s] + c;
                    if (stamp[n2] == gen && g[n2] <= ng) continue;
                    stamp[n2] = gen; g[n2] = ng; par[n2] = static_cast<int>(s);
                    pq.push({ng + hd(n2), n2});
                }
            }
            std::vector<size_t> path;
            for (long s = end; s >= 0; s = par[static_cast<size_t>(s)]) path.push_back(static_cast<size_t>(s));
            std::reverse(path.begin(), path.end());
            return path;
        };
        auto road_at = [&](size_t e) {
            std::array<uint32_t, 5> c{WL[0][e], WL[1][e], WL[2][e], WL[3][e], WL[4][e]};
            const int ex = static_cast<int>(e % W), ey = static_cast<int>(e / W);
            for (int r = 0; r <= 4; ++r) for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx) {
                const int X = ex + dx, Y = ey + dy;
                if (X < 0 || Y < 0 || X >= W || Y >= HP) continue;
                const size_t s = static_cast<size_t>(Y) * W + X;
                if ((walk[s] & 1) && WL[0][s] && !WL[1][s] && !WL[2][s] && !WL[3][s] && !WL[4][s] && !(WL[0][s] & (1u << 19))) return std::array<uint32_t, 5>{WL[0][s], 0, 0, 0, 0};
            }
            return c;
        };
        auto paint = [&](const std::vector<size_t>& path) {
            if (path.empty()) return;
            const auto ra = road_at(path.front()), rb = road_at(path.back());
            for (size_t pi = 0; pi < path.size(); ++pi) {
                const size_t s = path[pi];
                const auto& rd = pi * 2 < path.size() ? ra : rb;
                const int x = static_cast<int>(s % W), y = static_cast<int>(s / W);
                const bool wall_in_map = orig[s] && !(walk[s] & 1);
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                    const int X = x + dx, Y = y + dy;
                    if (X < 0 || Y < 0 || X >= W || Y >= HP) continue;
                    const size_t q2 = static_cast<size_t>(Y) * W + X;
                    if (ocean[q2] == 1 || ocean[q2] == 3) continue;
                    if (orig[q2]) { if (wall_in_map) walk[q2] |= 3; continue; }
                    if (!rd[0]) { walk[q2] |= 3; continue; }
                    for (int l = 0; l < 5; ++l) WL[l][q2] = rd[static_cast<size_t>(l)];
                    walk[q2] = 3;
                }
                ++painted;
            }
            ++nroads;
        };
        for (const auto& L : links) {
            if (L.ax < 0 || L.ay < 0 || L.bx < 0 || L.by < 0 || L.ax >= W || L.bx >= W || L.ay >= HP || L.by >= HP) continue;
            const size_t s0 = static_cast<size_t>(L.ay) * W + L.ax, s1 = static_cast<size_t>(L.by) * W + L.bx;
            if (L.ex >= 0) {
                // a way already walked by an earlier road (its way back): it goes too
                bool dup = false;
                for (const auto& K : links) {
                    if (&K == &L) break;
                    if (K.ex < 0 || !gex[static_cast<size_t>(K.ex)].drop) continue;
                    if (std::abs(K.ax - L.bx) + std::abs(K.ay - L.by) <= 10 && std::abs(K.bx - L.ax) + std::abs(K.by - L.ay) <= 10) { dup = true; break; }
                }
                if (dup) { gex[static_cast<size_t>(L.ex)].drop = true; continue; }
            }
            const auto path = route({s0}, [&](size_t s) { return s == s1; }, L.bx, L.by);
            if (path.empty()) continue;
            int carve = 0;
            for (size_t s : path) if (orig[s] && !(walk[s] & 1)) ++carve;
            if (L.ex >= 0 && carve > 6) { ++kept; continue; }    // only through walls: it stays a way (you step through at once)
            paint(path);
            if (L.ex >= 0) gex[static_cast<size_t>(L.ex)].drop = true;
        }
        std::fprintf(stderr, "[earth] %zu ways now walked as roads (%d stay ways)\n", n_way_links - static_cast<size_t>(kept), kept);
        // last: every stretch of the planet you cannot yet walk to from the rest gets its own road out
        for (int pass = 0; pass < 2; ++pass) {
            std::vector<int> lab(N, 0);
            std::vector<size_t> csize(1, 0);
            for (size_t s = 0; s < static_cast<size_t>(W) * HP; ++s) {
                if (lab[s] || !(walk[s] & 1) || ocean[s] == 3) continue;
                const int id = static_cast<int>(csize.size());
                size_t cnt = 0;
                std::vector<size_t> st{s}; lab[s] = id;
                while (!st.empty()) {
                    const size_t c = st.back(); st.pop_back(); ++cnt;
                    const int x = static_cast<int>(c % W), y = static_cast<int>(c / W);
                    if (x > 0 && !lab[c - 1] && (walk[c - 1] & 1)) { lab[c - 1] = id; st.push_back(c - 1); }
                    if (x + 1 < W && !lab[c + 1] && (walk[c + 1] & 1)) { lab[c + 1] = id; st.push_back(c + 1); }
                    if (y > 0 && !lab[c - W] && (walk[c - W] & 1)) { lab[c - W] = id; st.push_back(c - W); }
                    if (y + 1 < HP && !lab[c + W] && (walk[c + W] & 1)) { lab[c + W] = id; st.push_back(c + W); }
                }
                csize.push_back(cnt);
            }
            int mainc = 1;
            for (size_t i = 1; i < csize.size(); ++i) if (csize[i] > csize[static_cast<size_t>(mainc)]) mainc = static_cast<int>(i);
            std::vector<size_t> in_orig(csize.size(), 0);
            for (size_t s = 0; s < static_cast<size_t>(W) * HP; ++s) if (lab[s] && orig[s]) in_orig[static_cast<size_t>(lab[s])]++;
            std::vector<std::vector<size_t>> cells(csize.size());
            for (size_t s = 0; s < static_cast<size_t>(W) * HP; ++s) if (lab[s] && lab[s] != mainc && ((in_orig[static_cast<size_t>(lab[s])] >= 30 && csize[static_cast<size_t>(lab[s])] >= 30) || csize[static_cast<size_t>(lab[s])] >= 100)) cells[static_cast<size_t>(lab[s])].push_back(s);
            int joined = 0;
            for (size_t i = 1; i < csize.size(); ++i) {
                if (cells[i].empty()) continue;
                const auto path = route(cells[i], [&](size_t s) { return lab[s] == mainc; }, -1, -1);
                if (path.empty()) continue;
                paint(path);
                ++joined;
            }
            std::fprintf(stderr, "[earth] pass %d: %d stretches cut off joined to the rest\n", pass, joined);
            if (!joined) break;
        }
        std::fprintf(stderr, "[earth] %d roads, %d tiles long in all\n", nroads, painted);
    }
    // ---- foes in the country: each land's own kinds, spread over its open ground
    std::vector<std::array<int, 4>> wild;
    {
        uint32_t rs = 12345;
        auto rnd = [&]() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; };
        const int step = 28;
        for (int gy = 0; gy < HP / step; ++gy) for (int gx = 0; gx < W / step; ++gx) {
            const int x = gx * step + static_cast<int>(rnd() % step), y = gy * step + static_cast<int>(rnd() % step);
            const size_t s = static_cast<size_t>(y) * W + x;
            if (x < 2 || y < 2 || x >= W - 2 || y >= HP - 2 || orig[s] || ocean[s] || terr[s] < 0 || !(walk[s] & 1)) continue;
            bool roomy = true;
            for (int dy = -2; dy <= 2 && roomy; ++dy) for (int dx = -2; dx <= 2; ++dx) if (!(walk[s + static_cast<size_t>(dy * W + dx)] & 1)) { roomy = false; break; }
            if (!roomy) continue;
            const auto& b = blk[static_cast<size_t>(terr[s])];
            const auto& en = reg(b.z, b.r).en;
            if (en.empty()) continue;
            const auto& e = en[rnd() % en.size()];
            wild.push_back({e[0], e[1], x * 8 + 4, y * 8 + 4});
        }
        std::fprintf(stderr, "[earth] %zu foes roam the country\n", wild.size());
    }
    // ---- the files
    const fs::path zd = dir / "0";
    fs::remove_all(zd);
    fs::create_directories(zd);
    {   // (Android port) the snowy country had grass and flowers strewn through it in patches: there it is snow
        auto col = [](uint32_t v) -> uint32_t { const uint32_t id = v & 0xFFFFu; return id < g_tile_col.size() ? g_tile_col[id] : 0u; };
        auto is_snow = [&](uint32_t v) { const uint32_t c = col(v); if (!c) return false; const int r = c & 255, g = (c >> 8) & 255, b = (c >> 16) & 255; return r > 200 && g > 200 && b > 200; };
        auto is_green = [&](uint32_t v) { const uint32_t c = col(v); if (!c) return false; const int r = c & 255, g = (c >> 8) & 255, b = (c >> 16) & 255; return g > b + 40 && g >= r - 10; };
        const size_t NN = static_cast<size_t>(W) * H;
        std::vector<int> sum(NN, 0);       // snow cells in a 9x9 window (a summed table)
        std::vector<int> S2((static_cast<size_t>(W) + 1) * (H + 1), 0);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            const int v = is_snow(WL[0][static_cast<size_t>(y) * W + x]) ? 1 : 0;
            S2[static_cast<size_t>(y + 1) * (W + 1) + x + 1] = v + S2[static_cast<size_t>(y) * (W + 1) + x + 1] + S2[static_cast<size_t>(y + 1) * (W + 1) + x] - S2[static_cast<size_t>(y) * (W + 1) + x];
        }
        std::unordered_map<uint32_t, int> snowc;      // which snow tiles the snowy country uses, and how often
        auto cool = [&](uint32_t v) { const uint32_t c = col(v); const int r = c & 255, b = (c >> 16) & 255; return b >= r; };      // (the white-blue snow, not the beige edges)
        for (size_t i = 0; i < NN && i < grown_mask.size(); ++i) if (grown_mask[i] && is_snow(WL[0][i]) && cool(WL[0][i]) && !(WL[0][i] & (1u << 19))) snowc[WL[0][i] & 0xFFFFu]++;
        std::vector<std::pair<int, int>> pool;
        for (auto& kv : snowc) pool.push_back({static_cast<int>(kv.first), kv.second});
        std::sort(pool.begin(), pool.end(), [](auto& a, auto& b) { return a.second > b.second; });
        if (pool.size() > 8) pool.resize(8);
        int tot = 0; for (auto& q : pool) tot += q.second;
        int n = 0;
        if (tot > 0) for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            const size_t i = static_cast<size_t>(y) * W + x;
            if (i >= grown_mask.size() || !grown_mask[i] || !is_green(WL[0][i])) continue;
            const int x0 = std::max(0, x - 4), y0 = std::max(0, y - 4), x1 = std::min(W, x + 5), y1 = std::min(H, y + 5);
            const int cnt = S2[static_cast<size_t>(y1) * (W + 1) + x1] - S2[static_cast<size_t>(y0) * (W + 1) + x1] - S2[static_cast<size_t>(y1) * (W + 1) + x0] + S2[static_cast<size_t>(y0) * (W + 1) + x0];
            if (cnt * 10 < (x1 - x0) * (y1 - y0) * 4) continue;      // snow all round (40% of the window or more)
            uint32_t h = static_cast<uint32_t>(i) * 2654435761u; h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
            int r = static_cast<int>(h % static_cast<uint32_t>(tot)), pick = pool[0].first;
            for (auto& q : pool) { if (r < q.second) { pick = q.first; break; } r -= q.second; }
            WL[0][i] = static_cast<uint32_t>(pick);
            for (int l = 1; l < 5; ++l) if (WL[l][i] && is_green(WL[l][i])) WL[l][i] = 0;
            ++n;
        }
        (void)sum;
        if (std::getenv("LOG2_WORLD_LOG")) std::fprintf(stderr, "[earth] %d grass patches in the snow made snow\n", n);
    }
    {   // (Android port) the Northern Mountains' country was one ochre grass tile over and over: mixed as the forest's own maps mix it
        static const int kMix[][2] = {{2662, 3814}, {2658, 3141}, {2661, 3130}, {2659, 3107}, {2652, 3093}, {2650, 3083}, {2649, 3068}, {2653, 3055}, {2657, 3053}, {2656, 3019}, {2646, 3010}, {2648, 2992}};
        int tot = 0; for (auto& q : kMix) tot += q[1];
        int n = 0;
        for (size_t i = 0; i < grown_mask.size() && i < WL[0].size(); ++i) {
            if (!grown_mask[i] || (WL[0][i] & 0xFFFFu) != 2662u) continue;
            uint32_t h = static_cast<uint32_t>(i) * 2246822519u; h ^= h >> 15; h *= 3266489917u; h ^= h >> 16;
            int r = static_cast<int>(h % static_cast<uint32_t>(tot)), pick = kMix[0][0];
            for (auto& q : kMix) { if (r < q[1]) { pick = q[0]; break; } r -= q[1]; }
            WL[0][i] = static_cast<uint32_t>(pick); ++n;
        }
        if (std::getenv("LOG2_WORLD_LOG")) std::fprintf(stderr, "[earth] %d ochre grass tiles mixed\n", n);
    }
    { const int rg = regrass(WL, W, H); if (std::getenv("LOG2_WORLD_LOG")) std::fprintf(stderr, "[earth] %d neon grass tiles laid again\n", rg); }
    {   // (Android port) the green country was grass tile 334 over and over: mixed as the game's own maps mix their grass
        static const int kMix[][2] = {{334, 10516}, {331, 8150}, {326, 7909}, {325, 7899}, {324, 7700}, {327, 7231}, {330, 7088}, {335, 6478}, {328, 6064}, {337, 5982}, {332, 5616}, {336, 5305}, {329, 5235}, {333, 5187}};
        int tot = 0; for (auto& q : kMix) tot += q[1];
        for (size_t i = 0; i < grown_mask.size() && i < WL[0].size(); ++i) {
            if ((WL[0][i] & 0xFFFFu) != 334u || (WL[0][i] & (1u << 19))) continue;      // (the game's own maps too: only that one tile changes)
            uint32_t h = static_cast<uint32_t>(i) * 3266489917u; h ^= h >> 13; h *= 2654435761u; h ^= h >> 16;
            int r = static_cast<int>(h % static_cast<uint32_t>(tot)), pick = kMix[0][0];
            for (auto& q : kMix) { if (r < q[1]) { pick = q[0]; break; } r -= q[1]; }
            WL[0][i] = static_cast<uint32_t>(pick);
        }
    }
    write_lkr(zd / "0.bin", W, H, WL, walk);
    {
        std::vector<uint8_t> mini(N * 4, 0);
        for (size_t i = 0; i < N; ++i) {
            uint32_t col = 0;
            for (int l = 0; l < 5; ++l) {
                const uint32_t c = WL[l][i];
                if (!c) continue;
                const uint32_t id = c & 0xFFFF;
                if (c & (1u << 19)) col = ocean[i] ? 0xFFA05828u : 0xFFC08040u; else if (id < g_tile_col.size() && g_tile_col[id]) col = g_tile_col[id];
            }
            if (!(walk[i] & 1) && col && ocean[i] != 1 && ocean[i] != 2) col = (col & 0xFF000000u) | ((col & 0xFEFEFEu) >> 1);
            std::memcpy(&mini[i * 4], &col, 4);
        }
        romcat::save_png_rgba((zd / "0_mini.png").string(), mini, W, H);
    }
    auto snap = [&](int& ax, int& ay) {
        const int X = ax / 8, Y = ay / 8;
        for (int r = 0; r <= 30; ++r) for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx) {
            if (std::max(std::abs(dx), std::abs(dy)) != r) continue;
            const int x = X + dx, y = Y + dy;
            if (x < 1 || y < 1 || x >= W - 1 || y >= H - 1) continue;
            const size_t s = static_cast<size_t>(y) * W + x;
            if ((walk[s] & 1) && (walk[s - 1] & 1) && (walk[s + 1] & 1) && (walk[s - W] & 1)) { if (r) { ax = x * 8 + 4; ay = y * 8 + 6; } return true; }
        }
        return false;
    };
    std::string maps_js, ex_js, en_js;
    int n_ex = 0;
    for (const auto& b : blk) {
        const StoredReg& S = reg(b.z, b.r);
        const int ox = b.x * 8, oy = b.y * 8;
        for (auto& [k, p] : S.maps) maps_js += (maps_js.empty() ? "" : ",") + std::string("[\"") + g_kit[static_cast<size_t>(k)].key + "\"," + std::to_string(p.first + ox) + "," + std::to_string(p.second + oy) + "]";
        for (const auto& e : S.en) { char bb[96]; std::snprintf(bb, sizeof bb, "%s[%d,%d,%d,%d]", en_js.empty() ? "" : ",", e[0], e[1], e[2] + ox, e[3] + oy); en_js += bb; }
    }
    for (const auto& e : wild) { char bb[96]; std::snprintf(bb, sizeof bb, "%s[%d,%d,%d,%d]", en_js.empty() ? "" : ",", e[0], e[1], e[2], e[3]); en_js += bb; }
    // ways the game only lets you take one way here (you come out of a house, but the way in is a script):
    // a door back is made where you come out, in the wall behind you
    {
        int made = 0;
        const size_t n0 = gex.size();
        for (size_t i = 0; i < n0; ++i) {
            const GEx e = gex[i];
            if (e.drop) continue;
            bool back = false;
            for (size_t j = 0; j < gex.size() && !back; ++j) {
                const auto& f = gex[j];
                if (f.drop) continue;
                const int cx = (f.x0 + f.x1) / 2, cy = (f.y0 + f.y1) / 2;
                if (std::abs(cx - e.ax) + std::abs(cy - e.ay) <= 56) back = true;
            }
            if (back) continue;
            int ax = e.ax, ay = e.ay;
            if (!snap(ax, ay)) continue;
            // the wall next to the arrival (up first: you come out of a door facing down)
            const int dirs[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
            int bestd = -1, dist = 0;
            for (int k = 0; k < 4 && bestd < 0; ++k) for (int t = 4; t <= 28; t += 2) {
                const int X = (ax + dirs[k][0] * t) / 8, Y = (ay + dirs[k][1] * t) / 8;
                if (X < 0 || Y < 0 || X >= W || Y >= H) break;
                if (!(walk[static_cast<size_t>(Y) * W + X] & 1)) { bestd = k; dist = t; break; }
            }
            if (bestd < 0) continue;
            const int dx = dirs[bestd][0], dy = dirs[bestd][1];
            const int wx = ax + dx * dist, wy = ay + dy * dist;     // the wall's face
            GEx r{};
            if (dx == 0) { r.x0 = wx - 8; r.x1 = wx + 8; r.y0 = dy < 0 ? wy - 6 : wy - 4; r.y1 = dy < 0 ? wy + 4 : wy + 6; }
            else { r.y0 = wy - 8; r.y1 = wy + 8; r.x0 = dx < 0 ? wx - 6 : wx - 4; r.x1 = dx < 0 ? wx + 4 : wx + 6; }
            // back to just inside where the way out was
            r.ax = (e.x0 + e.x1) / 2; r.ay = (e.y0 + e.y1) / 2;
            const auto& sb = blk[static_cast<size_t>(e.sb)];
            const int mx = sb.x * 8 + sb.w * 4, my = sb.y * 8 + sb.h * 4;
            const int vx = mx - r.ax, vy = my - r.ay;
            const double vl = std::max(1.0, std::sqrt(static_cast<double>(vx) * vx + static_cast<double>(vy) * vy));
            r.ax += static_cast<int>(vx / vl * 20); r.ay += static_cast<int>(vy / vl * 20);
            r.sb = e.db; r.db = e.sb; r.edge = false; r.drop = false;
            gex.push_back(r); ++made;
        }
        std::fprintf(stderr, "[earth] %d doors back made (the game only had the way out)\n", made);
    }
    // rooms the game only takes you into with a story scene: a door of their own, in a wall of the place they
    // belong to (the same name, or their land), and a door back out if they have none
    {
        std::vector<std::vector<int>> out_e(blk.size());
        for (const auto& e : gex) if (!e.drop) out_e[static_cast<size_t>(e.sb)].push_back(e.db);
        std::vector<uint8_t> seen(blk.size(), 0);
        std::deque<int> q;
        auto reach_from = [&](int st) {
            if (seen[static_cast<size_t>(st)]) return;
            seen[static_cast<size_t>(st)] = 1; q.push_back(st);
            while (!q.empty()) {
                const int c = q.front(); q.pop_front();
                for (int d : out_e[static_cast<size_t>(c)]) if (!seen[static_cast<size_t>(d)]) { seen[static_cast<size_t>(d)] = 1; q.push_back(d); }
            }
        };
        for (size_t i = 0; i < blk.size(); ++i) if (blk[i].kind != 2) reach_from(static_cast<int>(i));
        std::vector<std::pair<int, int>> doors_at;     // planet tiles used by doors (old and new)
        for (const auto& e : gex) if (!e.drop) doors_at.push_back({(e.x0 + e.x1) / 16, (e.y0 + e.y1) / 16});
        // a wall you could walk into from below (a front of a building): the door goes there
        auto find_wall = [&](const Blk& h, int nx, int ny, int& cx, int& cy) {
            long bd = 1L << 60; bool ok = false;
            for (auto& [k, p] : reg(h.z, h.r).maps) {
                const KitMap& m = g_kit[static_cast<size_t>(k)];
                const int mx = h.x + p.first / 8, my = h.y + p.second / 8;
                for (int y = my + 1; y < my + m.th - 2; ++y) for (int x = mx + 1; x < mx + m.tw - 1; ++x) {
                    const size_t s0 = static_cast<size_t>(y) * W + x;
                    if (walk[s0] & 1) continue;
                    if (walk[s0 - W] & 1) continue;
                    bool front = true;
                    for (int dx = -1; dx <= 1 && front; ++dx) for (int dy = 1; dy <= 2; ++dy) if (!(walk[s0 + static_cast<size_t>(dy * W + dx)] & 1)) { front = false; break; }
                    if (!front || cell_dark(WL, s0)) continue;
                    bool near_door = false;
                    for (auto& [ux, uy] : doors_at) if (std::abs(ux - x) + std::abs(uy - y) < 6) { near_door = true; break; }
                    if (near_door) continue;
                    const long d = static_cast<long>(x - nx) * (x - nx) + static_cast<long>(y - ny) * (y - ny);
                    if (d < bd) { bd = d; cx = x; cy = y; ok = true; }
                }
            }
            return ok;
        };
        int made = 0;
        for (size_t i = 0; i < blk.size(); ++i) {
            const auto& R = blk[i];
            if (R.kind != 2 || seen[i]) continue;
            const StoredReg& S = reg(R.z, R.r);
            int rax = S.arrx + R.x * 8, ray = S.arry + R.y * 8;
            if (!snap(rax, ray)) continue;     // nothing to stand on (a dark scene room)
            {   // a story scene's backdrop is no room: no walls at all (a city seen from the sky, a ship in space),
                // nothing to stand on, or nothing drawn - no door to it (it showed as a jumble of tiles)
                const size_t n = S.walk.size();
                size_t nw = 0, nwf = 0, nempty = 0;
                std::set<std::array<uint32_t, 4>> kinds;
                for (size_t s = 0; s < n; ++s) {
                    const bool e = !S.WL[0][s] && !S.WL[1][s] && !S.WL[2][s] && !S.WL[3][s];
                    if (S.walk[s] & 1) { ++nw; if (!e) ++nwf; }
                    if (e) ++nempty;
                    if (kinds.size() < 64) kinds.insert({S.WL[0][s], S.WL[1][s], S.WL[2][s], S.WL[3][s]});
                }
                const double fw = n ? double(nw) / n : 0, fwf = n ? double(nwf) / n : 0, fe = n ? double(nempty) / n : 1;
                if (std::getenv("LOG2_EARTH_DBG")) std::fprintf(stderr, "[earth]   room %s (%d/%d): walk %.2f, walk on something %.2f, empty %.2f\n", S.name.c_str(), R.z, R.r, fw, fwf, fe);
                const bool nameless = S.name.empty() || S.name == "***";     // the game gives a story scene's stage no place name
                if (n == 0 || nameless || fw >= 0.98 || fw < 0.12 || fwf < 0.03 || kinds.size() < 8 || (fe >= 0.8 && fwf < 0.05)) {
                    if (std::getenv("LOG2_EARTH_DBG")) std::fprintf(stderr, "[earth]   no door: %s (%d/%d) is a scene's backdrop\n", S.name.c_str(), R.z, R.r);
                    continue;
                }
            }
            // the place it belongs to
            int host = -1;
            for (size_t j = 0; j < blk.size() && host < 0; ++j) {
                if (blk[j].kind == 2) continue;
                for (auto& [k, p] : reg(blk[j].z, blk[j].r).maps) if (!S.name.empty() && g_kit[static_cast<size_t>(k)].name == S.name) { host = static_cast<int>(j); break; }
            }
            if (host < 0) host = blk_of.count(R.z) ? blk_of[R.z] : (blk_of.count(4) ? blk_of[4] : 0);
            const Blk& h = blk[static_cast<size_t>(host)];
            const StoredReg& HS = reg(h.z, h.r);
            int cx = 0, cy = 0;
            if (!find_wall(h, h.x + HS.arrx / 8, h.y + HS.arry / 8, cx, cy)) continue;
            doors_at.push_back({cx, cy});
            GEx d{};
            d.x0 = cx * 8 - 8; d.x1 = cx * 8 + 16; d.y0 = (cy + 1) * 8 - 6; d.y1 = (cy + 1) * 8 + 4;
            d.ax = rax; d.ay = ray; d.sb = host; d.db = static_cast<int>(i); d.edge = false; d.drop = false;
            gex.push_back(d);
            out_e[static_cast<size_t>(host)].push_back(static_cast<int>(i));
            // a way back out (unless the room has one already)
            if (out_e[i].empty()) {
                const int dirs[4][2] = {{0, 1}, {0, -1}, {-1, 0}, {1, 0}};
                int bestd = -1, dist = 0;
                for (int k = 0; k < 4 && bestd < 0; ++k) for (int t = 4; t <= 40; t += 2) {
                    const int X = (rax + dirs[k][0] * t) / 8, Y = (ray + dirs[k][1] * t) / 8;
                    if (X < 0 || Y < 0 || X >= W || Y >= H) break;
                    if (!(walk[static_cast<size_t>(Y) * W + X] & 1)) { bestd = k; dist = t; break; }
                }
                if (bestd >= 0) {
                    const int dx = dirs[bestd][0], dy = dirs[bestd][1];
                    const int wx = rax + dx * dist, wy = ray + dy * dist;
                    GEx r{};
                    if (dx == 0) { r.x0 = wx - 8; r.x1 = wx + 8; r.y0 = dy < 0 ? wy - 6 : wy - 4; r.y1 = dy < 0 ? wy + 4 : wy + 6; }
                    else { r.y0 = wy - 8; r.y1 = wy + 8; r.x0 = dx < 0 ? wx - 6 : wx - 4; r.x1 = dx < 0 ? wx + 4 : wx + 6; }
                    r.ax = cx * 8 + 4; r.ay = (cy + 2) * 8 + 4;
                    r.sb = static_cast<int>(i); r.db = host; r.edge = false; r.drop = false;
                    gex.push_back(r);
                    out_e[i].push_back(host);
                }
            }
            reach_from(static_cast<int>(i));
            ++made;
            if (std::getenv("LOG2_EARTH_DBG")) std::fprintf(stderr, "[earth]   door to %s (%d/%d) in %s at %d,%d\n", S.name.c_str(), R.z, R.r, HS.name.c_str(), cx, cy);
        }
        std::fprintf(stderr, "[earth] %d rooms only a story scene led to: a door of their own\n", made);
    }
    int arrx = 0, arry = 0;
    {
        const auto& b = blk[static_cast<size_t>(blk_of.count(4) ? blk_of[4] : 0)];
        const StoredReg& S = reg(b.z, b.r);
        arrx = S.arrx + b.x * 8; arry = S.arry + b.y * 8; snap(arrx, arry);
    }
    for (auto e : gex) {
        if (e.drop || !snap(e.ax, e.ay)) continue;
        char bb[200];
        std::snprintf(bb, sizeof bb, "%s{\"rect\":[%d,%d,%d,%d],\"to\":0,\"arrive\":[%d,%d]}", ex_js.empty() ? "" : ",", e.x0, e.y0, e.x1, e.y1, e.ax, e.ay);
        ex_js += bb; ++n_ex;
    }
    std::string js = "{\"zone\":0,\"earth\":true,\"regions\":[{\"index\":0,\"name\":\"Earth\",\"kind\":\"out\",\"tw\":" + std::to_string(W) + ",\"th\":" + std::to_string(H) +
        ",\"planet_h\":" + std::to_string(HP) + ",\"arrival\":[" + std::to_string(arrx) + "," + std::to_string(arry) + "],\"maps\":[" + maps_js + "],\"exits\":[" + ex_js + "],\"enemies\":[" + en_js + "]}],\"start\":0,\"lands\":[";
    bool first = true;
    for (const auto& b : blk) if (b.kind == 0) { js += (first ? "" : ",") + std::string("[") + std::to_string(b.z) + "," + std::to_string(b.x * 8) + "," + std::to_string(b.y * 8) + "," + std::to_string(b.w * 8) + "," + std::to_string(b.h * 8) + "]"; first = false; }
    js += "]}";
    write_text(zd / "lands.json", js);
    std::fprintf(stderr, "[earth] written: one map, %d doors (all instant)\n", n_ex);
}

// ---------------------------------------------------------------- data
// the music: the song table the game's own sound code plays from (the music ripper uses it)
static constexpr uint32_t kSongTable = 0x081D4B2Cu, kSongCount = 44, kMusicCtx = 0x030026C8u;
static void export_songs(const fs::path& dir) {
    std::string js = "{\"table\":" + hex(kSongTable) + ",\"ctx\":" + hex(kMusicCtx) + ",\"title\":15,\"songs\":[";
    for (uint32_t k = 0; k < kSongCount; ++k) {
        const uint32_t r = kSongTable + 20u * k;
        // the order list (patterns) ends at 0xFF
        int n = 0;
        for (uint32_t o = u32(r + 4); romp(o) && n < 256 && u8(o + static_cast<uint32_t>(n)) != 0xFF; ) ++n;
        js += (k ? "," : "") + std::string("{\"record\":") + hex(r) + ",\"patterns\":" + std::to_string(n) + ",\"tempo\":" + std::to_string(u8(r + 16)) + "}";
    }
    js += "]}";
    write_text(dir / "songs.json", js);
}
// the sound effects: the game's own samples (8-bit, 8/16 kHz), 12-byte descriptors {data, flags, -, loop start,
// length, rate}; written as plain .wav files (sounds/sfx_NN.wav) any player opens - the game maps them to its sounds
static constexpr uint32_t kSfxTable = 0x080E15B0u, kSfxCount = 64;
static void export_sfx(const fs::path& dir) {
    fs::create_directories(dir);
    std::string js = "[";
    for (uint32_t i = 0; i < kSfxCount; ++i) {
        const uint32_t e = kSfxTable + 12u * i, p = u32(e);
        const uint32_t len = u16(e + 8), rate = u16(e + 10), loop = u16(e + 6), fl = u8(e + 4);
        if (!romp(p) || !romp(p + len) || rate < 2000) continue;
        std::vector<uint8_t> w(44 + len);
        auto put32 = [&](size_t o, uint32_t v) { for (int k = 0; k < 4; ++k) w[o + k] = static_cast<uint8_t>(v >> (8 * k)); };
        auto put16 = [&](size_t o, uint32_t v) { w[o] = static_cast<uint8_t>(v); w[o + 1] = static_cast<uint8_t>(v >> 8); };
        std::memcpy(&w[0], "RIFF", 4); put32(4, 36 + len); std::memcpy(&w[8], "WAVEfmt ", 8);
        put32(16, 16); put16(20, 1); put16(22, 1); put32(24, rate); put32(28, rate); put16(32, 1); put16(34, 8);
        std::memcpy(&w[36], "data", 4); put32(40, len);
        for (uint32_t k = 0; k < len; ++k) w[44 + k] = static_cast<uint8_t>(u8(p + k) ^ 0x80u);   // signed -> wav's unsigned
        char name[32]; std::snprintf(name, sizeof name, "sfx_%02u.wav", i);
        std::ofstream o(dir / name, std::ios::binary); o.write(reinterpret_cast<const char*>(w.data()), static_cast<std::streamsize>(w.size()));
        js += (js.size() > 1 ? "," : "") + std::string("{\"id\":") + std::to_string(i) + ",\"rate\":" + std::to_string(rate) + ",\"length\":" + std::to_string(len) +
              ",\"loop\":" + std::to_string((fl & 1) ? static_cast<int>(loop) : -1) + "}";
    }
    js += "]";
    write_text(dir / "sfx.json", js);
}

// the game's people: where each stands (map object +8: x | y << 16), how they look (sprite set) and what they
// say - the lines are read out of their scripts (the text sits in plain letters near the script's pointers)
static std::vector<std::string> person_lines(uint32_t start) {
    std::vector<std::string> out;
    std::set<uint32_t> seen;
    std::deque<std::pair<uint32_t, int>> st{{start, 0}};
    auto isptr = [](uint32_t v) { return v >= 0x083B0000u && v < 0x08420000u && !(v & 1); };
    while (!st.empty() && out.size() < 12) {
        auto [a, d] = st.front(); st.pop_front();
        if (seen.count(a) || d > 4 || !romp(a + 0x60)) continue;
        seen.insert(a);
        // printable runs of 10+ letters ending in a 0 inside the first 0x60 bytes
        uint32_t i = 0;
        while (i < 0x60) {
            uint32_t j = i;
            while (j < 0x60 + 400 && romp(a + j)) { const uint8_t c = u8(a + j); if ((c >= 0x20 && c < 0x7F) || c == '\n') ++j; else break; }
            if (j - i >= 10 && romp(a + j) && u8(a + j) == 0) {
                std::string t;
                for (uint32_t q = a + i; q < a + j; ++q) t.push_back(static_cast<char>(u8(q)));
                int alpha = 0; for (char c : t) alpha += std::isalpha(static_cast<unsigned char>(c)) ? 1 : 0;
                if (alpha * 10 > static_cast<int>(t.size()) * 6 && std::find(out.begin(), out.end(), t) == out.end()) out.push_back(t);
                i = j + 1;
            } else ++i;
        }
        for (uint32_t k = 0; k < 0x40; k += 4) { const uint32_t v = u32(a + k); if (isptr(v)) st.push_back({v, d + 1}); }
    }
    return out;
}
static void export_people(const fs::path& dir) {
    std::string js = "{";
    bool firstm = true;
    for (const auto& mr : romtiles::maps()) {
        const uint32_t entry = mr.entry;
        const uint32_t cnt = u8(entry + 5), arr = u32(entry + 0x18);   // list 1? people are in every list: scan all four
        (void)cnt; (void)arr;
        std::string ps;
        static const uint32_t kList[4] = {0x14, 0x18, 0x1C, 0x10};
        for (int L = 0; L < 4; ++L) {
            const uint32_t n = u8(entry + 4 + static_cast<uint32_t>(L)), a2 = u32(entry + kList[L]);
            for (uint32_t i = 0; i < n && i < 64 && romp(a2); ++i) {
                const uint32_t r = u32(a2 + 4u * i);
                if (!romp(r) || u32(r) != 0x0800B711u) continue;
                const uint32_t pos = u32(r + 8);
                std::string lines;
                for (const auto& t : person_lines(u32(r + 0x18))) lines += (lines.empty() ? "" : ",") + jstr(t);
                char b[160];
                std::snprintf(b, sizeof b, "%s{\"x\":%u,\"y\":%u,\"set\":%u,\"lines\":[", ps.empty() ? "" : ",", pos & 0xFFFF, pos >> 16, u32(r + 0x10));
                ps += b + lines + "]}";
            }
        }
        if (ps.empty()) continue;
        js += (firstm ? "" : ",") + std::string("\"") + std::to_string(mr.z) + "_" + std::to_string(mr.a) + "\":[" + ps + "]";
        firstm = false;
    }
    js += "}";
    write_text(dir / "people.json", js);
}
static void export_data(const fs::path& dir) {
    fs::create_directories(dir);
    std::string js = "[";
    for (uint32_t t = 0; t < 128; ++t) {
        const uint32_t e = 0x086D56ACu + 24u * t;
        char b[256];
        std::snprintf(b, sizeof b, "%s{\"type\":%u,\"exp\":%u,\"hp\":%u,\"w8\":%u,\"atk\":%u,\"b0d\":%u,\"lvl\":%u,\"b0f\":%u,\"w10\":%u,\"behaviour\":\"%08x\"}", t ? "," : "",
            t, u32(e), u32(e + 4), u32(e + 8), u8(e + 0xC), u8(e + 0xD), u8(e + 0xE), u8(e + 0xF), u32(e + 0x10), u32(e + 0x14));
        js += b;
    }
    write_text(dir / "enemies.json", js + "]");
    {   // the foes' behaviour scripts (LoG2's own enemy AI: a behaviour table and its node data), as raw words for the game's interpreter
        static const uint32_t kAiRanges[][2] = {{0x086D1B00u, 0x086D5700u}, {0x086FF300u, 0x08700000u}, {0x08701D00u, 0x08702000u}, {0x08703800u, 0x08703C00u}, {0x08704600u, 0x08704900u}};
        std::string ai = "{\"table\":\"086d5194\",\"count\":152,\"ranges\":[";
        for (size_t r = 0; r < sizeof kAiRanges / sizeof kAiRanges[0]; ++r) {
            char h[32]; std::snprintf(h, sizeof h, "%s[\"%08x\",[", r ? "," : "", kAiRanges[r][0]);
            ai += h;
            for (uint32_t a2 = kAiRanges[r][0]; a2 < kAiRanges[r][1]; a2 += 4) ai += (a2 != kAiRanges[r][0] ? "," : "") + std::to_string(u32(a2));
            ai += "]]";
        }
        write_text(dir / "ai.json", ai + "]}");
    }
    js = "[";
    for (uint32_t i = 0; i < 80; ++i) {
        const uint32_t e = 0x081D967Cu + 20u * i;
        js += i ? ",[" : "[";
        for (uint32_t k = 0; k < 20; ++k) js += (k ? "," : "") + std::to_string(u8(e + k));
        js += "]";
    }
    write_text(dir / "forms.json", js + "]");
    js = "[";
    for (uint32_t c = 0; c < 6; ++c) {
        const uint32_t r = 0x081D9548u + 0x1Cu * c;
        char b[256];
        std::snprintf(b, sizeof b, "%s{\"hp\":%u,\"maxhp\":%u,\"ep\":%u,\"maxep\":%u,\"form\":%u,\"str\":%.3f,\"pwr\":%.3f,\"end\":%.3f,\"exp\":%u,\"abilities\":%u}", c ? "," : "",
            u16(r), u16(r + 2), u16(r + 4), u16(r + 6), u8(r + 8), u16(r + 0xA) / 256.0, u16(r + 0xC) / 256.0, u16(r + 0xE) / 256.0, u32(r + 0x10), u32(r + 0x14));
        js += b;
    }
    write_text(dir / "fighters.json", js + "]");
    js = "[";
    const uint32_t lt = u32(0x080042ECu);
    for (uint32_t L = 0; L < 100; ++L) js += (L ? "," : "") + std::to_string(romp(lt) ? u32(lt + 4u * L) : 0u);
    write_text(dir / "levels.json", js + "]");
    js = "[";
    for (int i = 0; i < 2600; ++i) js += (i ? "," : "") + jstr(romtiles::game_string(i));
    write_text(dir / "strings.json", js + "]");
    js = "[";
    for (uint32_t i = 0; i < 46; ++i) {
        const uint32_t e = 0x086ADE24u + 56u * i;
        char b[160]; std::snprintf(b, sizeof b, "%s{\"id\":%u,\"stack\":%u,\"msg\":%u,\"max\":%u,\"use\":\"%08x\",\"give\":\"%08x\"}", i ? "," : "", i, u8(e), u8(e + 2), u8(e + 3), u32(e + 0x30), u32(e + 0x34));
        js += b;
    }
    write_text(dir / "items.json", js + "]");
}

// ---------------------------------------------------------------- music repair
// Songs recorded by the ripper before v19 used 2053 instead of 2048 for QOA's largest scale step, so every
// player (Godot too) drifted away from the song after each loud hit: crackling noise. They are decoded here
// the way they were written and written again correctly. "rom_NN.qoa.ok" beside a file = already right.
namespace qoafix {
static const int kRecip[16] = {65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32};
static const int kQuant[17] = {7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6};
static void table(int dq[16][8], bool old) {
    static const int sc[16] = {1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1717, 2048};
    static const double m[8] = {0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7};
    for (int s = 0; s < 16; ++s) for (int q = 0; q < 8; ++q) {
        const double x = (s == 15 && old ? 2053 : sc[s]) * m[q];
        dq[s][q] = static_cast<int>(x < 0 ? -std::floor(-x + 0.5) : std::floor(x + 0.5));
    }
}
struct Lms { int h[4] = {0, 0, 0, 0}; int w[4] = {0, 0, -(1 << 13), 1 << 14}; };
static int predict(const Lms& l) { int p = 0; for (int i = 0; i < 4; ++i) p += l.w[i] * l.h[i]; return p >> 13; }
static void update(Lms& l, int sample, int r) { const int d = r >> 4; for (int i = 0; i < 4; ++i) l.w[i] += l.h[i] < 0 ? -d : d; for (int i = 0; i < 3; ++i) l.h[i] = l.h[i + 1]; l.h[3] = sample; }
static uint64_t be64(const uint8_t* p) { uint64_t v = 0; for (int i = 0; i < 8; ++i) v = (v << 8) | p[i]; return v; }
static bool decode(const std::vector<uint8_t>& d, bool old, std::vector<int16_t>& out, uint32_t& rate) {
    if (d.size() < 16 || std::memcmp(d.data(), "qoaf", 4) != 0) return false;
    const uint32_t total = (d[4] << 24) | (d[5] << 16) | (d[6] << 8) | d[7];
    int dq[16][8]; table(dq, old);
    size_t p = 8;
    out.clear(); out.reserve(total);
    while (p + 24 <= d.size() && out.size() < total) {
        const uint64_t fh = be64(&d[p]); p += 8;
        if ((fh >> 56) != 1) return false;      // mono only (what the ripper writes)
        rate = static_cast<uint32_t>((fh >> 32) & 0xFFFFFF);
        const int fs = static_cast<int>((fh >> 16) & 0xFFFF);
        Lms l;
        const uint64_t hh = be64(&d[p]), ww = be64(&d[p + 8]); p += 16;
        for (int i = 0; i < 4; ++i) { l.h[i] = static_cast<int16_t>(hh >> (48 - 16 * i)); l.w[i] = static_cast<int16_t>(ww >> (48 - 16 * i)); }
        for (int s0 = 0; s0 < fs && p + 8 <= d.size(); s0 += 20) {
            const uint64_t sl = be64(&d[p]); p += 8;
            const int sf = static_cast<int>(sl >> 60);
            for (int i = 0; i < 20 && s0 + i < fs; ++i) {
                const int q = static_cast<int>((sl >> (57 - 3 * i)) & 7);
                const int r = dq[sf][q];
                const int v = std::clamp(predict(l) + r, -32768, 32767);
                update(l, v, r);
                out.push_back(static_cast<int16_t>(v));
            }
        }
    }
    return true;
}
static int qdiv(int v, int sf) {
    const int r = kRecip[sf];
    int n = static_cast<int>((static_cast<int64_t>(v) * r + (1 << 15)) >> 16);
    return n + ((v > 0) - (v < 0)) - ((n > 0) - (n < 0));
}
static void put64(std::vector<uint8_t>& o, uint64_t v) { for (int i = 7; i >= 0; --i) o.push_back(static_cast<uint8_t>(v >> (8 * i))); }
static std::vector<uint8_t> encode(const std::vector<int16_t>& x, uint32_t rate) {
    std::vector<uint8_t> o;
    put64(o, (0x716F6166ULL << 32) | static_cast<uint32_t>(x.size()));
    Lms lms; int dq[16][8]; table(dq, false);
    for (size_t f0 = 0; f0 < x.size(); f0 += 5120) {
        const size_t fl = std::min<size_t>(5120, x.size() - f0), slices = (fl + 19) / 20;
        put64(o, (1ULL << 56) | (static_cast<uint64_t>(rate) << 32) | (static_cast<uint64_t>(fl) << 16) | (8 + 16 + 8 * slices));
        // weights that do not fit the file's 16 bits would make players drift: start them afresh
        for (int i = 0; i < 4; ++i) if (lms.w[i] > 32767 || lms.w[i] < -32768) { lms.w[0] = 0; lms.w[1] = 0; lms.w[2] = -(1 << 13); lms.w[3] = 1 << 14; break; }
        uint64_t hh = 0, ww = 0;
        for (int i = 0; i < 4; ++i) { hh = (hh << 16) | static_cast<uint16_t>(lms.h[i]); ww = (ww << 16) | static_cast<uint16_t>(lms.w[i]); }
        put64(o, hh); put64(o, ww);
        for (size_t s0 = 0; s0 < fl; s0 += 20) {
            const size_t sl = std::min<size_t>(20, fl - s0);
            uint64_t best = 0, best_err = ~0ULL; Lms best_lms;
            for (int sf = 0; sf < 16; ++sf) {
                Lms l = lms; uint64_t slice = static_cast<uint64_t>(sf), err = 0;
                for (size_t i = 0; i < sl; ++i) {
                    const int smp = x[f0 + s0 + i], pr = predict(l);
                    const int q = kQuant[std::clamp(qdiv(smp - pr, sf), -8, 8) + 8];
                    const int dd = dq[sf][q];
                    const int rec = std::clamp(pr + dd, -32768, 32767);
                    const int64_t e = smp - rec;
                    // as the reference encoder: big weights cost extra, so they stay small and no player overflows
                    int64_t wp = ((static_cast<int64_t>(l.w[0]) * l.w[0] + static_cast<int64_t>(l.w[1]) * l.w[1] + static_cast<int64_t>(l.w[2]) * l.w[2] + static_cast<int64_t>(l.w[3]) * l.w[3]) >> 18) - 0x8ff;
                    if (wp < 0) wp = 0;
                    err += static_cast<uint64_t>(e * e) + static_cast<uint64_t>(wp * wp);
                    if (err > best_err) break;
                    update(l, rec, dd);
                    slice = (slice << 3) | static_cast<uint64_t>(q);
                }
                if (err < best_err) { best_err = err; best = slice; best_lms = l; }
            }
            lms = best_lms;
            put64(o, best << ((20 - sl) * 3));
        }
    }
    return o;
}
static bool fix_file(const fs::path& f) {
    fs::path ok = f; ok += ".ok";
    if (fs::exists(ok)) return false;
    std::ifstream in(f, std::ios::binary);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    in.close();
    std::vector<int16_t> pcm; uint32_t rate = 32768;
    if (!decode(d, true, pcm, rate) || pcm.empty()) return false;
    const std::vector<uint8_t> o = encode(pcm, rate);
    if (std::getenv("LOG2_QOA_CHECK")) {
        std::vector<int16_t> back; uint32_t r2 = 0; decode(o, false, back, r2);
        double sg = 0, er = 0; for (size_t i = 0; i < pcm.size() && i < back.size(); ++i) { sg += double(pcm[i]) * pcm[i]; er += double(pcm[i] - back[i]) * (pcm[i] - back[i]); }
        std::vector<int16_t> godot; decode(d, false, godot, r2);
        double e2 = 0; for (size_t i = 0; i < pcm.size() && i < godot.size(); ++i) e2 += double(pcm[i] - godot[i]) * (pcm[i] - godot[i]);
        std::fprintf(stderr, "[qoa] %s: mended %.1f dB, as played before %.1f dB\n", f.filename().string().c_str(), 10 * std::log10(sg / std::max(1.0, er)), 10 * std::log10(sg / std::max(1.0, e2)));
    }
    fs::path tmp = f; tmp += ".part";
    { std::ofstream w(tmp, std::ios::binary); w.write(reinterpret_cast<const char*>(o.data()), static_cast<std::streamsize>(o.size())); }
    std::error_code ec; fs::rename(tmp, f, ec);
    if (ec) return false;
    write_text(ok, "1\n");
    return true;
}
static int fix_dir(const fs::path& dir) {
    int n = 0; std::error_code ec;
    if (!fs::is_directory(dir, ec)) return 0;
    for (const auto& e : fs::directory_iterator(dir, ec)) {
        const std::string nm = e.path().filename().string();
        if (nm.size() > 4 && nm.rfind("rom_", 0) == 0 && nm.substr(nm.size() - 4) == ".qoa" && fix_file(e.path())) ++n;
    }
    return n;
}
}  // namespace qoafix

#include "lib_export.inc"
// (Android port) EARTH ships ready made (the game writes it to kit/lands/0 before importing - tile numbers and
// walls, from builtin/earth): only its minimap is drawn here, from this cartridge's tiles. No country is grown:
// that step needed most of the import's memory (700 MB) and froze 4 GB computers.
static void earth_mini(const fs::path& dir) {
    std::ifstream f(dir / "0" / "0.bin", std::ios::binary);
    std::vector<uint8_t> raw((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (raw.size() < 8 || std::memcmp(raw.data(), "LKR2", 4) != 0) { std::fprintf(stderr, "[earth] no Earth to draw the minimap from\n"); return; }
    const int W = raw[4] | raw[5] << 8, H = raw[6] | raw[7] << 8;
    const size_t N = static_cast<size_t>(W) * H;
    if (raw.size() < 8 + N * 21) return;
    auto cell = [&](int l, size_t i) { uint32_t v; std::memcpy(&v, &raw[8 + (static_cast<size_t>(l) * N + i) * 4], 4); return v; };
    const uint8_t* walk = &raw[8 + N * 20];
    std::vector<uint8_t> mini(N * 4, 0);
    for (size_t i = 0; i < N; ++i) {
        uint32_t col = 0;
        bool water = false;
        for (int l = 0; l < 5; ++l) {
            const uint32_t c = cell(l, i);
            if (!c) continue;
            const uint32_t id = c & 0xFFFF;
            if (c & (1u << 19)) { col = (walk[i] & 1) ? 0xFFC08040u : 0xFFA05828u; water = true; }
            else if (id < g_tile_col.size() && g_tile_col[id]) { col = g_tile_col[id]; water = false; }
        }
        if (!(walk[i] & 1) && col && !water) col = (col & 0xFF000000u) | ((col & 0xFEFEFEu) >> 1);
        std::memcpy(&mini[i * 4], &col, 4);
    }
    romcat::save_png_rgba((dir / "0" / "0_mini.png").string(), mini, W, H);
    std::fprintf(stderr, "[earth] the shipped Earth's minimap drawn (%d x %d)\n", W, H);
}

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: godot_export GAME OUTDIR [ADVENTURE_LAYOUT_DIR]\n"); return 2; }
    if (std::string(argv[1]) == "qoa2wav") {   // dev: godot_export qoa2wav IN.qoa OUT.wav (16-bit mono)
        std::ifstream in(argv[2], std::ios::binary);
        std::vector<uint8_t> d((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::vector<int16_t> pcm; uint32_t rate = 32768;
        if (!qoafix::decode(d, false, pcm, rate)) return 1;
        std::vector<uint8_t> w(44 + pcm.size() * 2);
        auto put32 = [&](size_t o, uint32_t v) { for (int k = 0; k < 4; ++k) w[o + k] = static_cast<uint8_t>(v >> (8 * k)); };
        std::memcpy(&w[0], "RIFF", 4); put32(4, static_cast<uint32_t>(36 + pcm.size() * 2)); std::memcpy(&w[8], "WAVEfmt ", 8);
        put32(16, 16); w[20] = 1; w[22] = 1; put32(24, rate); put32(28, rate * 2); w[32] = 2; w[34] = 16;
        std::memcpy(&w[36], "data", 4); put32(40, static_cast<uint32_t>(pcm.size() * 2));
        std::memcpy(&w[44], pcm.data(), pcm.size() * 2);
        std::ofstream o(argv[3], std::ios::binary); o.write(reinterpret_cast<const char*>(w.data()), static_cast<std::streamsize>(w.size()));
        return 0;
    }
    if (std::string(argv[1]) == "library" && argc >= 4) return libx::run(argv[2], argv[3]);   // godot_export library GAME OUTDIR
    if (std::string(argv[1]) == "music") {    // godot_export music GAME OUTDIR [SONG...]: the game's own songs, as QOA with their loops
        if (argc < 4) { std::fprintf(stderr, "usage: godot_export music GAME OUTDIR [SONG...]\n"); return 2; }
        lower_priority();      // recorded while you play: the game gets the processor first
        std::ifstream gf(argv[2], std::ios::binary);
        std::vector<uint8_t> game((std::istreambuf_iterator<char>(gf)), std::istreambuf_iterator<char>());
        if (game.size() < 0x200000) { std::fprintf(stderr, "[music] not a game file: %s\n", argv[2]); return 1; }
        fs::create_directories(argv[3]);
        std::vector<int> songs;
        for (int i = 4; i < argc; ++i) songs.push_back(std::atoi(argv[i]));
        const int n = gbamusic::export_songs(game, argv[3], songs);
        std::fprintf(stderr, "[music] %d songs\n", n);
        return n > 0 ? 0 : 1;
    }
    if (std::string(argv[1]) == "fixqoa") {   // godot_export fixqoa FILE_OR_DIR...: mend songs recorded before v19
        int n = 0;
        for (int i = 2; i < argc; ++i) n += fs::is_directory(argv[i]) ? qoafix::fix_dir(argv[i]) : (qoafix::fix_file(argv[i]) ? 1 : 0);
        std::fprintf(stderr, "[export] %d songs mended\n", n);
        return 0;
    }
    std::ifstream f(argv[1], std::ios::binary);
    g_rom.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (g_rom.size() < 0x800000 || std::memcmp(&g_rom[0xAC], "ALFE", 4) != 0) { std::fprintf(stderr, "[export] not a Legacy of Goku II (USA) game: %s\n", argv[1]); return 1; }
    R = Rom{g_rom.data(), g_rom.size()};
    romtiles::init(R);
    romtiles::palette_rgb(g_bgpal);
    for (int i = 0; i < 256; ++i) {
        const uint16_t c = u16(kObjPalette + 2u * static_cast<uint32_t>(i));
        const uint32_t r = (c & 31u) << 3, g = ((c >> 5) & 31u) << 3, b = ((c >> 10) & 31u) << 3;
        g_objpal[i] = 0xFF000000u | (b << 16) | (g << 8) | r;
    }
    const fs::path out = argv[2];
    fs::create_directories(out);
    const bool only_floors = argc > 4 && std::string(argv[4]) == "floors";
    const bool no_earth = argc > 4 && std::string(argv[4]) == "noearth";      // EARTH comes with the game: not grown here
    if (argc > 4 && std::string(argv[4]) == "kit") {
        const int k = export_kit(out / "kit");
        std::fprintf(stderr, "[export] kit: %d maps\n", k);
        export_lands(out / "kit" / "lands");
        export_earth(out / "kit" / "lands");
        return 0;
    }
    if (!only_floors) {
        progress("start", 0, 1);
        std::fprintf(stderr, "[export] sprites...\n");
        const int s = export_sprites(out / "sprites");
        export_fx(out / "fx");
        export_enemy_fx(out / "fx");
        std::fprintf(stderr, "[export] %d sprite sets\n[export] maps...\n", s);
        const int m = export_maps(out / "maps");
        std::fprintf(stderr, "[export] %d maps\n", m);
        progress("data", 0, 1);
        export_data(out / "data");
        // the music ripper is gone: your own songs go in the music folder
        export_people(out / "data");
        export_sfx(out / "sounds");
        const int k = export_kit(out / "kit");
        std::fprintf(stderr, "[export] building kit: %d maps\n", k);
        export_lands(out / "kit" / "lands");
        progress("earth", 0, 1);
        if (no_earth) earth_mini(out / "kit" / "lands");
        else export_earth(out / "kit" / "lands");
    }
    if (argc > 3) { const int fl = export_floors(argv[3], out / "floors"); std::fprintf(stderr, "[export] %d adventure areas\n", fl); }
    // (no music from the game: you bring your own songs)
    std::fprintf(stderr, "[export] %d tiles under tree leaves walkable\n", g_canopy_opened); std::fprintf(stderr, "[export] %d invisible-wall tiles opened (lone walls with nothing solid on them)\n", g_walls_opened);
    progress("ui", 0, 1);
    export_ui(out / "ui");
    progress("done", 1, 1);
    write_text(out / "version.txt", "36\n");
    std::fprintf(stderr, "[export] done: %s\n", out.string().c_str());
    return 0;
}
