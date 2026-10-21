// map_builder.cpp - new floors from the game's own maps.
//
// 1. Tile bank: every map's tile index has a global id by how it looks
//    (bank ids, measured offline from each map's loaded graphics). A source
//    map's tile can be used in a floor built on area B if B's graphics hold
//    a tile that looks the same (the index is remapped to B's).
// 2. Cells: a map cell = its 4 layer entries + 2 walk bits. Which cell may
//    stand right of / below which is learned from every source map.
// 3. Wave function collapse grows the floor cell by cell, constrained by a
//    room plan (rooms, corridors, the way in and the way on). Only pairs
//    that exist in the real maps are ever placed: no broken seams.
// 4. Tests: the way in must reach the way on over walkable cells.
#include "map_builder.h"
#include <algorithm>
#include <functional>
#include <tuple>
#include <array>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <atomic>
#include <random>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <thread>
#include <mutex>

#include "adv_maps.inc"
namespace mapbuild {

// the same numbers from the same seed with every C++ library (the standard's distributions and
// shuffle differ between Windows' and Linux's - floors made by one were not the floors of the other)
template <class R> inline double mb_unit(R& rng) { return static_cast<double>(rng() & 0xFFFFFFFFu) / 4294967296.0; }
template <class It, class R> inline void mb_shuffle(It first, It last, R& rng) {
    const auto n = last - first;
    for (auto i = n - 1; i > 0; --i) { const auto j = static_cast<decltype(i)>((rng() & 0xFFFFFFFFu) % static_cast<uint32_t>(i + 1)); std::swap(first[i], first[j]); }
}

// ---------------------------------------------------------------- decode
namespace {
struct BR {
    const Rom& rom; uint32_t a; uint32_t w = 0; int rem = 0;
    BR(const Rom& r, uint32_t addr) : rom(r), a(addr) {}
    int bit() { if (!rem) { w = rom.r32(a); a += 4; rem = 32; } const int v = static_cast<int>(w >> 31); w <<= 1; --rem; return v; }
    uint32_t bits(int n) { uint32_t v = 0; while (n-- > 0) v = (v << 1) | static_cast<uint32_t>(bit()); return v; }
};
}
bool decode(const Rom& rom, uint32_t desc, std::vector<uint8_t>* out) {
    out->clear();
    if (!rom.ok(desc, 8)) return false;
    const uint32_t kind = rom.r32(desc), size = rom.r32(desc + 4);
    if (size > 0x40000) return false;
    if (kind == 0) {
        if (!rom.ok(desc + 8, size)) return false;
        out->assign(rom.p + (desc + 8 - 0x08000000u), rom.p + (desc + 8 - 0x08000000u) + size);
        return true;
    }
    BR r(rom, desc + 8);
    int dbits = 8, lbits = static_cast<int>(kind), lbase = 0; uint32_t last = 1;
    auto gamma = [&]() { uint32_t v = 1; for (;;) { v = (v << 1) | static_cast<uint32_t>(r.bit()); if (!r.bit()) break; if (v > 0x1000000u) return v; } return v; };
    auto cp = [&](uint32_t dist, uint32_t n) {
        for (uint32_t i = 0; i < n; ++i) { if (dist == 0 || dist > out->size()) return false; out->push_back((*out)[out->size() - dist]); }
        return true;
    };
    while (out->size() <= size) {
        if (r.bit()) { out->push_back(static_cast<uint8_t>((r.bits(lbits) + static_cast<uint32_t>(lbase)) & 0xFF)); continue; }
        if (r.bit()) {
            const uint32_t c = gamma();
            uint32_t dist, n;
            if (c == 2) { dist = last; n = gamma(); }
            else {
                dist = r.bits(dbits) + ((c - 3) << dbits); last = dist; n = gamma();
                if (dist >= 0x10000) n += 3; else if (dist >= 0x37FF) n += 2; else if (dist >= 0x27F) n += 1; else if (dist <= 0x7F) n += 4;
            }
            if (!cp(dist, n)) return false;
            continue;
        }
        if (r.bit() == 0) {
            const uint32_t dist = r.bits(7);
            if (dist) { last = dist; if (!cp(dist, r.bits(2) + 2)) return false; }
            else { const uint32_t c = r.bits(2); if (c == 0) break; dbits = static_cast<int>(r.bits(static_cast<int>(c) + 3)); }
            continue;
        }
        const int sc = static_cast<int>(r.bits(4)) - 1;
        if (sc == 0) out->push_back(0);
        else if (sc > 0) { if (!cp(static_cast<uint32_t>(sc), 1)) return false; }
        else if (r.bit()) { do { for (int i = 0; i < 256; ++i) out->push_back(static_cast<uint8_t>(r.bits(8))); } while (r.bit()); }
        else { lbase = 0; lbits = 7 + r.bit(); if (lbits == 7) lbase = static_cast<int>(r.bits(8)); }
    }
    return out->size() == size;
}

// ---------------------------------------------------------------- sources
namespace {
constexpr uint32_t kMapTable = 0x08409368u;
uint32_t entry_of(const Rom& rom, int z, int a) {
    for (int i = 0; i < 600; ++i) {
        const uint32_t e = kMapTable + 56u * static_cast<uint32_t>(i);
        const int ez = rom.r8(e);
        if (ez == 0 || ez > 40) break;
        if (ez == z && rom.r8(e + 1) == a) return e;
    }
    return 0;
}
}
bool load_src(const Rom& rom, int z, int a, SrcMap* m) {
    const uint32_t e = entry_of(rom, z, a);
    if (!e) return false;
    const uint32_t var = rom.r32(rom.r32(e + 0x2C));
    if (!rom.ok(var, 0x44) || rom.made(var)) return false;
    m->z = z; m->a = a;
    const int w = rom.r16(var + 8) + 240, h = rom.r16(var + 10) + 160;
    m->tw = w / 8; m->th = h / 8;   // whole tiles only
    for (int k = 0; k < 4; ++k) m->pri[k] = rom.r8(var + 4 + static_cast<uint32_t>(k)) & 3;
    const size_t cells = static_cast<size_t>(m->tw) * m->th;
    std::vector<uint8_t> buf;
    for (int k = 0; k < 4; ++k) {
        m->L[k].assign(cells, 0);
        const uint32_t res = rom.r32(var + 0x14 + 4u * k);
        if (!rom.ok(res, 0x18)) continue;
        m->tilemap[k] = rom.r32(res) == 0x080056A1u;
        if (!m->tilemap[k]) continue;   // an effect layer (clouds, light...): not map tiles
        const int cols = rom.r8(res + 0x14), rows = rom.r8(res + 0x15);
        const int ox = static_cast<int>(rom.r32(res + 0x0C) >> 16) * 8, oy = static_cast<int>(rom.r32(res + 0x10) >> 16) * 8;
        for (int c = 0; c < cols * rows; ++c) {
            const uint32_t d = rom.r32(res + 0x18 + 4u * c);
            if (!rom.ok(d, 8) || !decode(rom, d, &buf) || buf.size() < 0x800) continue;
            const int cx = (c % cols) * 32 - ox, cy = (c / cols) * 32 - oy;
            for (int y = 0; y < 32; ++y)
                for (int x = 0; x < 32; ++x) {
                    const int wx = cx + x, wy = cy + y;
                    if (wx < 0 || wy < 0 || wx >= m->tw || wy >= m->th) continue;
                    m->L[k][static_cast<size_t>(wy) * m->tw + wx] = static_cast<uint16_t>(buf[(y * 32 + x) * 2] | (buf[(y * 32 + x) * 2 + 1] << 8));
                }
        }
    }
    for (int k = 0; k < 2; ++k) {
        auto& W = k ? m->wb : m->wa;
        W.assign(cells, 0);
        const uint32_t p = rom.r32(var + 0x34 + 4u * k);
        if (!decode(rom, p, &buf) || buf.size() < 0x2000) continue;
        if (const char* dw = getenv("MB_DUMPW")) { char nm[32]; snprintf(nm, sizeof nm, "%d_%d", z, a); if (std::string(dw) == nm) { FILE* f = fopen((std::string("/tmp/mb_dump_w_") + nm + (k ? "b" : "a") + ".bin").c_str(), "wb"); if (f) { fwrite(buf.data(), 1, buf.size(), f); fclose(f); } } }
        for (int y = 0; y < m->th && y < 256; ++y)
            for (int x = 0; x < m->tw && x < 256; ++x)
                W[static_cast<size_t>(y) * m->tw + x] = (buf[y * 32 + (x >> 3)] >> (x & 7)) & 1;
    }
    const uint32_t cnt = rom.r32(var + 0x0C), p = rom.r32(var + 0x10);
    if (rom.ok(p) && cnt > 0 && cnt < 32)
        for (uint32_t q = p; q < p + 40u * cnt + 8u; q += 4) {
            const uint32_t hnd = rom.r32(q);
            if (hnd != 0x0800D9C3u && hnd != 0x0800C233u) continue;
            m->exits.push_back(Rect{rom.r16(q + 8), rom.r16(q + 10), rom.r16(q + 12), rom.r16(q + 14)});
        }
    return true;
}

// ---------------------------------------------------------------- library
namespace {
// a cell: 4 layer entries as (entry flags << 16) | tile (the area's slot, or a game-wide tile id on a mixed floor)
struct Key { uint32_t e[4]; uint8_t wa, wb; bool operator==(const Key& o) const { return std::memcmp(e, o.e, 16) == 0 && wa == o.wa && wb == o.wb; } };
struct KeyHash { size_t operator()(const Key& k) const { uint64_t h = 1469598103934665603ull; const uint8_t* p = reinterpret_cast<const uint8_t*>(k.e); for (int i = 0; i < 16; ++i) h = (h ^ p[i]) * 1099511628211ull; h = (h ^ k.wa) * 1099511628211ull; h = (h ^ k.wb) * 1099511628211ull; return static_cast<size_t>(h); } };

struct Grid { int w = 0, h = 0; std::vector<int> k; int at(int x, int y) const { return k[static_cast<size_t>(y) * w + x]; } };

// All cells of the source maps, re-expressed in the base area's graphics,
// and which cells may stand next to which (every layer's own pair must
// occur somewhere in a real map).
struct Lib {
    std::vector<Key> keys; std::vector<double> freq;
    std::vector<Grid> grids;
    std::vector<int> grid_region;             // mixed floor: which region each grid shows
    std::vector<int> grid_zone;               // the zone of each grid's map
    std::vector<uint8_t> key_regions;         // mixed floor: bit r = this cell is seen in region r's maps
    int bridges = 0;                          // mixed floor: cells that join the regions
    std::vector<uint64_t> region_set[8];      // mixed floor: bitset of the cells seen in region r
    bool global = false;                      // keys hold game-wide tile ids
    uint64_t serial = 0;                      // (a number of its own: per-thread caches know a new library at an old address)
    int N = 0, NW = 0;
    std::vector<uint64_t> adj[4];            // 0 right, 1 left, 2 down, 3 up
    std::vector<uint8_t> walk;
    std::vector<uint8_t> path;               // walkable cells that look like a path (dirt / a track) - see find_paths
    std::vector<uint8_t> liquid;             // cells of water (or lava): solid, drawn with the area's animated tiles
    int liquid_n = 0;
    int path_n = 0;
    std::vector<std::vector<int>> occ;       // key -> packed (grid, x, y)
    std::vector<std::vector<uint16_t>> nbr[4];   // adjacency as lists
    std::vector<uint64_t> walkset;              // keys you can walk on
    std::vector<uint16_t> degree[4];
    std::vector<std::vector<std::pair<uint16_t, uint32_t>>> obs[4];   // obs[d][n]: keys t (with count) seen with n at direction d of t
    std::vector<int> lv[4]; int nv[4] = {0, 0, 0, 0};
    std::vector<uint8_t> hp[4], vp[4];            // per layer: this tile beside / above that one somewhere
    bool loose_ok(int d, int a, int b) const {    // d 0: b right of a, 2: b below a - every layer on its own
        for (int l = 0; l < 4; ++l) { const size_t i = static_cast<size_t>(lv[l][static_cast<size_t>(a)]) * nv[l] + lv[l][static_cast<size_t>(b)]; if (!(d == 0 ? hp[l][i] : vp[l][i])) return false; }
        return true;
    }
    std::unordered_map<uint64_t, uint32_t> pairc[2];   // how often a stands left of (0) / above (1) b in real maps
    uint32_t pc(int d, int a, int b) const {   // d: b is at direction d of a
        const bool v = d >= 2; if (d == 1 || d == 3) std::swap(a, b);
        auto it = pairc[v].find(static_cast<uint64_t>(a) << 32 | static_cast<uint32_t>(b)); return it == pairc[v].end() ? 0u : it->second; }
    bool ok(int d, int a, int b) const { return (adj[d][static_cast<size_t>(a) * NW + (b >> 6)] >> (b & 63)) & 1; }
};

const uint16_t* ids_of(const std::vector<BankMap>& bank, int z, int a) {
    for (const auto& b : bank) if (b.z == z && b.a == a) return b.ids;
    return nullptr;
}

bool build_lib(const Rom& rom, int bz, int ba, const std::vector<BankMap>& bank,
               const std::vector<std::pair<int, int>>& sources, Lib* L, const Options& opt) {
    const uint16_t* base = ids_of(bank, bz, ba);
    if (!base) return false;
    std::unordered_map<uint16_t, uint16_t> where;
    for (int t = 1023; t >= 0; --t) if (base[t]) where[base[t]] = static_cast<uint16_t>(t);
    std::unordered_map<Key, int, KeyHash> index;
    // mirrored maps too (left <-> right): a real map seen in a mirror is just as
    // seamless, and it gives the builder twice the ways to fit pieces together
    static const bool mirror = getenv("MB_MIRROR") && getenv("MB_MIRROR")[0] == '1';   // off: tested, no gain (mirrored cells rarely meet the originals)
    const bool mix = !opt.regions.empty();
    L->global = mix;
    // layers the new floor can draw on: the ordinary tile-map layers of the area
    bool base_layer[4] = {true, true, true, true};
    { SrcMap bm; if (load_src(rom, bz, ba, &bm)) for (int l = 0; l < 4; ++l) base_layer[l] = bm.tilemap[l]; }
    int cur_region = 0;
    auto add_grid = [&](const SrcMap& m, const uint16_t* ids, bool flip) {
        Grid g; g.w = m.tw; g.h = m.th; g.k.assign(static_cast<size_t>(m.tw) * m.th, -1);
        int good = 0;
        for (int y = 0; y < m.th; ++y)
        for (int x = 0; x < m.tw; ++x) {
            const size_t i = static_cast<size_t>(y) * m.tw + (flip ? m.tw - 1 - x : x);   // source cell
            Key k{}; bool okk = true;
            // drawing order of the layers (back first): a foreign animated tile on a
            // layer with something drawn behind it is left out (a flower on grass:
            // the grass shows); on the backmost layer the cell cannot be used
            int backmost = -1;
            const bool own_map = m.z == bz && m.a == ba;
            { int best = -1; for (int l = 0; l < 4; ++l) if (!m.L[l].empty() && (m.L[l][i] & 0x3FF)) { const int key = m.pri[l] * 8 + l; if (key > best) { best = key; backmost = l; } } }
            for (int l = 0; l < 4 && okk; ++l) {
                uint16_t e = m.L[l][i]; const uint16_t t = e & 0x3FF;
                if (t == 0) { k.e[l] = static_cast<uint32_t>(e & 0xFC00) << 16; continue; }
                if (!base_layer[l]) { okk = false; break; }   // the area has no tile map there
                if (flip) e ^= 0x400;   // the tile drawn mirrored
                if (mix) {   // any tile of the game; animated ones only of the area's own zone (its animations run)
                    const uint16_t id = ids[t];
                    if (!id || (id >= 0xC000 && !own_map)) { okk = false; break; }
                    k.e[l] = static_cast<uint32_t>(e & 0xFC00) << 16 | id;
                    continue;
                }
                // animated tiles (water, flowers...) run the area's own animation:
                // only the area's own map may use them - borrowed ones looked
                // wrong (a fountain drawn with the grass animation). On a layer
                // with something behind it the borrowed one is just left out.
                if (ids[t] >= 0xC000 && !own_map) { okk = false; break; }   // (leaving it out left holes: the cell is not used)
                auto it = where.find(ids[t]);
                if (!ids[t] || it == where.end()) { okk = false; break; }
                k.e[l] = static_cast<uint32_t>(e & 0xFC00) << 16 | it->second;
            }
            if (!okk) continue;
            k.wa = m.wa[i]; k.wb = m.wb[i];
            auto r = index.emplace(k, static_cast<int>(L->keys.size()));
            if (r.second) { L->keys.push_back(k); L->freq.push_back(0); }
            g.k[static_cast<size_t>(y) * m.tw + x] = r.first->second;
            L->freq[static_cast<size_t>(r.first->second)] += 1; ++good;
        }
        if (good > m.tw * m.th / 4) { L->grids.push_back(std::move(g)); L->grid_region.push_back(cur_region); L->grid_zone.push_back(m.z); }
    };
    // sources that share most of this area's graphics first; stop once the
    // library is big enough (a bigger one fits more, but every repair gets slower)
    int used = 0;
    if (mix) {
        // each region: its own maps, until it has its share of cells
        for (size_t r = 0; r < opt.regions.size(); ++r) {
            cur_region = static_cast<int>(r);
            const size_t start = L->keys.size();
            for (const auto& s : opt.regions[r]) {
                if (L->keys.size() - start >= static_cast<size_t>(opt.region_cells)) break;
                const uint16_t* ids = ids_of(bank, s.first, s.second);
                SrcMap m;
                if (!ids || !load_src(rom, s.first, s.second, &m) || m.tw < 20 || m.th < 20) continue;
                add_grid(m, ids, false);
                ++used;
            }
        }
    }
    std::vector<std::pair<double, size_t>> order;
    for (size_t i = 0; i < sources.size() && !mix; ++i) {
        const uint16_t* ids = ids_of(bank, sources[i].first, sources[i].second);
        if (!ids) continue;
        int n = 0, in = 0;
        for (int t = 1; t < 1024; ++t) if (ids[t]) { ++n; in += where.count(ids[t]) ? 1 : 0; }
        const bool self = sources[i].first == bz && sources[i].second == ba;
        if (n) order.push_back({self ? 2.0 : static_cast<double>(in) / n, i});
    }
    std::stable_sort(order.begin(), order.end(), [](const auto& x, const auto& y) { return x.first > y.first; });
    static const int kTarget = getenv("MB_TARGET") ? atoi(getenv("MB_TARGET")) : 5000;
    for (const auto& o : order) {
        const auto& s = sources[o.second];
        if (used >= 6 && static_cast<int>(L->keys.size()) >= kTarget) break;
        if (o.first < 0.25) break;   // hardly anything of it would fit
        const uint16_t* ids = ids_of(bank, s.first, s.second);
        SrcMap m;
        if (!load_src(rom, s.first, s.second, &m) || m.tw < 20 || m.th < 20) continue;
        add_grid(m, ids, false);
        if (mirror) add_grid(m, ids, true);
        ++used;
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "library: %d source maps, %zu cells\n", used, L->keys.size());
    if (getenv("MB_DEBUG") && mix) { int n0 = 0, n1 = 0; for (int r : L->grid_region) (r ? n1 : n0)++; fprintf(stderr, "  grids: region 0 %d, others %d\n", n0, n1); }
    {   // no invisible walls: a cell whose look is walkable ground almost everywhere in the real maps but
        // solid in one (a map's hidden border or a story barrier) is taken as walkable - otherwise a
        // plain patch of grass could block the way in a new floor with nothing to see there
        struct VisHash { size_t operator()(const std::array<uint32_t, 4>& e) const { uint64_t h = 1469598103934665603ull; for (uint32_t v : e) h = (h ^ v) * 1099511628211ull; return static_cast<size_t>(h); } };
        std::unordered_map<std::array<uint32_t, 4>, std::pair<double, double>, VisHash> seen;   // look -> (walkable, solid) counts
        auto vis = [](const Key& k) { return std::array<uint32_t, 4>{k.e[0], k.e[1], k.e[2], k.e[3]}; };
        for (size_t i = 0; i < L->keys.size(); ++i) { auto& c = seen[vis(L->keys[i])]; (L->keys[i].wa ? c.first : c.second) += L->freq[i]; }
        int fixed = 0;
        const uint16_t* bids = ids_of(bank, bz, ba);
        for (auto& k : L->keys) {
            if (k.wa) continue;
            bool empty = true, water = false;
            for (uint32_t v : k.e) { const uint32_t id = v & 0xFFFF; if (id) empty = false; if (id && (L->global ? id >= 0xC000 : (id < 1024 && bids && bids[id] >= 0xC000))) water = true; }
            if (empty || water) continue;   // (water - animated tiles - is never an invisible wall: you walked on the waterfall)
            const auto& c = seen[vis(k)];
            if (c.first >= 2.0 * c.second && c.first >= 3.0) { k.wa = 1; k.wb = 1; ++fixed; }
        }
        if (getenv("MB_DEBUG") || getenv("LOG2_WORLD_LOG")) if (fixed) fprintf(stderr, "  %d hidden-wall cells made walkable\n", fixed);
    }
    L->N = static_cast<int>(L->keys.size());
    if (L->N < 16 || L->grids.empty()) return false;
    L->NW = (L->N + 63) / 64;
    // per-layer pair tables
    auto& lv = L->lv; auto& nv = L->nv;
    for (int l = 0; l < 4; ++l) {
        // the ground layer carries the walk bits along: walls must meet floors as in real maps
        std::unordered_map<uint64_t, int> vals;
        lv[l].resize(static_cast<size_t>(L->N));
        for (int t = 0; t < L->N; ++t) {
            const Key& k = L->keys[static_cast<size_t>(t)];
            const uint64_t v = k.e[l] | ((l == 3 && getenv("MB_WALKPAIR")) ? (static_cast<uint64_t>(k.wa) << 32 | static_cast<uint64_t>(k.wb) << 33) : 0ull);
            lv[l][static_cast<size_t>(t)] = vals.emplace(v, static_cast<int>(vals.size())).first->second;
        }
        nv[l] = static_cast<int>(vals.size());
    }
    auto& hp = L->hp; auto& vp = L->vp;
    for (int l = 0; l < 4; ++l) { hp[l].assign(static_cast<size_t>(nv[l]) * nv[l], 0); vp[l].assign(static_cast<size_t>(nv[l]) * nv[l], 0); }
    for (const auto& g : L->grids)
        for (int y = 0; y < g.h; ++y)
            for (int x = 0; x < g.w; ++x) {
                const int a = g.at(x, y);
                if (a < 0) continue;
                const int r = x + 1 < g.w ? g.at(x + 1, y) : -1, d = y + 1 < g.h ? g.at(x, y + 1) : -1;
                for (int l = 0; l < 4; ++l) {
                    if (r >= 0) hp[l][static_cast<size_t>(lv[l][a]) * nv[l] + lv[l][r]] = 1;
                    if (d >= 0) vp[l][static_cast<size_t>(lv[l][a]) * nv[l] + lv[l][d]] = 1;
                }
            }
    for (auto& a : L->adj) a.assign(static_cast<size_t>(L->N) * L->NW, 0);
    if (!getenv("MB_LOOSE") && !getenv("MB_STRICT")) {
        // every PAIR of layers must meet as somewhere in a real map (catches an
        // edge tile of one layer landing over the wrong tile of another)
        std::vector<uint64_t> acc[4];
        for (int d = 0; d < 4; ++d) acc[d].assign(static_cast<size_t>(L->N) * L->NW, ~0ull);
        // projections: each layer alone, and (is layer l drawn here?, layer m's tile)
        const bool full_pairs = getenv("MB_PAIRS") != nullptr;
        for (int l = 0; l < 4; ++l)
            for (int m = 0; m < 4; ++m) {
                if (full_pairs ? (m <= l) : false) continue;
                std::unordered_map<uint64_t, int> vid; std::vector<int> v(static_cast<size_t>(L->N));
                for (int t = 0; t < L->N; ++t) {
                    const auto& k = L->keys[static_cast<size_t>(t)];
                    uint64_t val;
                    if (full_pairs) val = static_cast<uint64_t>(k.e[l]) << 32 | k.e[m];
                    else if (l == m) val = k.e[l];
                    else val = ((k.e[l] & 0xFFFF) ? (1ull << 40) : 0ull) | k.e[m];
                    v[static_cast<size_t>(t)] = vid.emplace(val, static_cast<int>(vid.size())).first->second;
                }
                const int nv2 = static_cast<int>(vid.size());
                std::vector<uint64_t> members(static_cast<size_t>(nv2) * L->NW, 0);
                for (int t = 0; t < L->N; ++t) members[static_cast<size_t>(v[static_cast<size_t>(t)]) * L->NW + (t >> 6)] |= 1ull << (t & 63);
                std::vector<std::vector<int>> part[2];   // 0 right, 2 down (and mirrored)
                std::unordered_map<uint64_t, char> seen;
                std::vector<std::vector<int>> pr[4]; for (auto& q : pr) q.resize(static_cast<size_t>(nv2));
                for (const auto& g : L->grids)
                    for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
                        const int a = g.at(x, y); if (a < 0) continue;
                        const int va = v[static_cast<size_t>(a)];
                        for (int dd = 0; dd < 2; ++dd) {
                            const int b = dd == 0 ? (x + 1 < g.w ? g.at(x + 1, y) : -1) : (y + 1 < g.h ? g.at(x, y + 1) : -1);
                            if (b < 0) continue;
                            const int vb = v[static_cast<size_t>(b)];
                            const uint64_t key = (static_cast<uint64_t>(dd) << 60) | (static_cast<uint64_t>(va) << 30) | static_cast<uint64_t>(vb);
                            if (!seen.emplace(key, 1).second) continue;
                            pr[dd * 2][static_cast<size_t>(va)].push_back(vb); pr[dd * 2 + 1][static_cast<size_t>(vb)].push_back(va);
                        }
                    }
                std::vector<uint64_t> row(static_cast<size_t>(L->NW));
                for (int d = 0; d < 4; ++d)
                    for (int val = 0; val < nv2; ++val) {
                        std::fill(row.begin(), row.end(), 0);
                        for (int w : pr[d][static_cast<size_t>(val)]) { const uint64_t* mm = &members[static_cast<size_t>(w) * L->NW]; for (int i = 0; i < L->NW; ++i) row[static_cast<size_t>(i)] |= mm[i]; }
                        const uint64_t* mine = &members[static_cast<size_t>(val) * L->NW];
                        for (int i = 0; i < L->NW; ++i) { uint64_t b = mine[i]; while (b) { const int t = i * 64 + __builtin_ctzll(b); b &= b - 1;
                            uint64_t* dst = &acc[d][static_cast<size_t>(t) * L->NW]; for (int j = 0; j < L->NW; ++j) dst[j] &= row[static_cast<size_t>(j)]; } }
                    }
            }
        for (int d = 0; d < 4; ++d) L->adj[d] = acc[d];
    } else if (getenv("MB_STRICT")) {   // joint: the whole stack of layers must meet as in a real map
        auto setp = [&](int d, int a, int b) { L->adj[d][static_cast<size_t>(a) * L->NW + (b >> 6)] |= 1ull << (b & 63); };
        for (const auto& g : L->grids)
            for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
                const int a = g.at(x, y); if (a < 0) continue;
                if (x + 1 < g.w) { const int b = g.at(x + 1, y); if (b >= 0) { setp(0, a, b); setp(1, b, a); } }
                if (y + 1 < g.h) { const int b = g.at(x, y + 1); if (b >= 0) { setp(2, a, b); setp(3, b, a); } }
            }
    } else
    for (int a = 0; a < L->N; ++a)
        for (int b = 0; b < L->N; ++b) {
            bool h = true, v = true;
            for (int l = 0; l < 4 && (h || v); ++l) {
                const size_t i = static_cast<size_t>(lv[l][a]) * nv[l] + lv[l][b];
                h = h && hp[l][i]; v = v && vp[l][i];
            }
            if (h) { L->adj[0][static_cast<size_t>(a) * L->NW + (b >> 6)] |= 1ull << (b & 63); L->adj[1][static_cast<size_t>(b) * L->NW + (a >> 6)] |= 1ull << (a & 63); }
            if (v) { L->adj[2][static_cast<size_t>(a) * L->NW + (b >> 6)] |= 1ull << (b & 63); L->adj[3][static_cast<size_t>(b) * L->NW + (a >> 6)] |= 1ull << (a & 63); }
        }
    // Mixed floor: the two regions' own pieces never stood side by side in a real
    // map. Let a piece of one region stand next to a piece of the other when the
    // picture continues across the edge (the touching pixel rows / columns look
    // alike, as close as real neighbours in the game's maps) - that is where
    // one land turns into the other.
    if (mix && opt.tile_pixels && opt.palette && opt.regions.size() >= 2 && !getenv("MB_NOLOOK")) {
        std::vector<uint8_t> kr(static_cast<size_t>(L->N), 0);
        for (size_t gi = 0; gi < L->grids.size(); ++gi) for (int k : L->grids[gi].k) if (k >= 0) kr[static_cast<size_t>(k)] |= static_cast<uint8_t>(1u << std::min(L->grid_region[gi], 7));
        // each cell's picture (back layers first), then its four edges
        std::vector<std::array<uint8_t, 96>> edge(static_cast<size_t>(L->N));   // R, L, D, U: 8 px x RGB
        for (int t = 0; t < L->N; ++t) {
            uint8_t px[64][3];
            for (int i = 0; i < 64; ++i) { px[i][0] = opt.palette[0]; px[i][1] = opt.palette[1]; px[i][2] = opt.palette[2]; }
            static const int order[4] = {3, 2, 1, 0};
            for (int l : order) {
                const uint32_t e = L->keys[static_cast<size_t>(t)].e[l]; const uint16_t id = static_cast<uint16_t>(e & 0xFFFF);
                if (!id) continue;
                const uint8_t* tp = opt.tile_pixels(id);
                if (!tp) continue;
                const bool hf = (e >> 16) & 0x400, vf = (e >> 16) & 0x800;
                for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x) {
                    const uint8_t c = tp[(vf ? 7 - y : y) * 8 + (hf ? 7 - x : x)];
                    if (c) { px[y * 8 + x][0] = opt.palette[c * 3]; px[y * 8 + x][1] = opt.palette[c * 3 + 1]; px[y * 8 + x][2] = opt.palette[c * 3 + 2]; }
                }
            }
            auto& E = edge[static_cast<size_t>(t)];
            for (int i = 0; i < 8; ++i) for (int ch = 0; ch < 3; ++ch) {
                E[static_cast<size_t>(0 * 24 + i * 3 + ch)] = px[i * 8 + 7][ch];   // right column
                E[static_cast<size_t>(1 * 24 + i * 3 + ch)] = px[i * 8 + 0][ch];   // left column
                E[static_cast<size_t>(2 * 24 + i * 3 + ch)] = px[7 * 8 + i][ch];   // bottom row
                E[static_cast<size_t>(3 * 24 + i * 3 + ch)] = px[0 * 8 + i][ch];   // top row
            }
        }
        auto seam = [&](int a, int b, bool vert) {   // a left of / above b
            const auto& A = edge[static_cast<size_t>(a)]; const auto& B = edge[static_cast<size_t>(b)];
            const int oa = vert ? 2 * 24 : 0, ob = vert ? 3 * 24 : 24;
            int c = 0; for (int i = 0; i < 24; ++i) c += std::abs(static_cast<int>(A[static_cast<size_t>(oa + i)]) - static_cast<int>(B[static_cast<size_t>(ob + i)]));
            return c;
        };
        // how close real neighbours are: a low percentile of the seams in the maps
        std::vector<int> real;
        for (const auto& g : L->grids)   // every neighbour pair in the real maps (different cells only)
            for (int y = 0; y < g.h && real.size() < 400000; ++y) for (int x = 0; x < g.w; ++x) {
                const int ka = g.at(x, y); if (ka < 0) continue;
                if (x + 1 < g.w) { const int kb = g.at(x + 1, y); if (kb >= 0 && kb != ka) real.push_back(seam(ka, kb, false)); }
                if (y + 1 < g.h) { const int kb = g.at(x, y + 1); if (kb >= 0 && kb != ka) real.push_back(seam(ka, kb, true)); }
            }
        std::stable_sort(real.begin(), real.end());
        static const double kPct = getenv("MB_JOINPCT") ? atof(getenv("MB_JOINPCT")) : 0.35;
        const int T = real.empty() ? 0 : real[static_cast<size_t>(real.size() * kPct)];
        if (getenv("MB_DEBUG") && !real.empty()) { fprintf(stderr, "  real seams:"); for (double q : {0.5, 0.8, 0.9, 0.95, 0.98, 0.99}) fprintf(stderr, " p%.0f=%d", q * 100, real[static_cast<size_t>(real.size() * q)]); fprintf(stderr, " (of %zu)\n", real.size()); }
        std::vector<int> only[2];
        for (int t = 0; t < L->N; ++t) { if (kr[static_cast<size_t>(t)] == 1) only[0].push_back(t); else if (kr[static_cast<size_t>(t)] == 2) only[1].push_back(t); }
        long added = 0;
        auto setp = [&](int d, int a, int b) { uint64_t& w = L->adj[d][static_cast<size_t>(a) * L->NW + (b >> 6)]; if (!((w >> (b & 63)) & 1)) { w |= 1ull << (b & 63); ++added; } };
        for (int side = 0; side < 2; ++side)
            for (int a : only[side]) for (int b : only[1 - side]) {
                if (L->keys[static_cast<size_t>(a)].wa != L->keys[static_cast<size_t>(b)].wa) continue;   // walls meet walls, ground meets ground
                if (seam(a, b, false) <= T) { setp(0, a, b); setp(1, b, a); }
                if (seam(a, b, true) <= T) { setp(2, a, b); setp(3, b, a); }
            }
        if (getenv("MB_DEBUG")) fprintf(stderr, "  join by look: seam limit %d, %ld pairs added (%zu + %zu own cells)\n", T, added, only[0].size(), only[1].size());
    }
    if (getenv("MB_DEBUG")) { for (int d = 0; d < 4; ++d) { long n = 0; for (int t = 0; t < L->N; ++t) for (int i = 0; i < L->NW; ++i) { uint64_t b = L->adj[d][static_cast<size_t>(t) * L->NW + i]; if (i == L->NW - 1 && (L->N & 63)) b &= (1ull << (L->N & 63)) - 1; n += __builtin_popcountll(b); } fprintf(stderr, "adj[%d] pairs %ld\n", d, n); } }
    for (int d = 0; d < 4; ++d) {
        L->nbr[d].assign(static_cast<size_t>(L->N), {}); L->degree[d].assign(static_cast<size_t>(L->N), 0);
        for (int t = 0; t < L->N; ++t) {
            const uint64_t* a = &L->adj[d][static_cast<size_t>(t) * L->NW];
            for (int i = 0; i < L->NW; ++i) { uint64_t b = a[i]; if (i == L->NW - 1 && (L->N & 63)) b &= (1ull << (L->N & 63)) - 1; while (b) { L->nbr[d][static_cast<size_t>(t)].push_back(static_cast<uint16_t>(i * 64 + __builtin_ctzll(b))); b &= b - 1; } }
            L->degree[d][static_cast<size_t>(t)] = static_cast<uint16_t>(std::min<size_t>(L->nbr[d][static_cast<size_t>(t)].size(), 0xFFFE));
        }
    }
    if (getenv("MB_CHAIN") && mix) {   // dev: how many steps from a region-0-only cell to a region-1-only cell (right / down)
        std::vector<uint8_t> seen_in(static_cast<size_t>(L->N), 0);
        for (size_t gi = 0; gi < L->grids.size(); ++gi) for (int k : L->grids[gi].k) if (k >= 0) seen_in[static_cast<size_t>(k)] |= static_cast<uint8_t>(1 << std::min(L->grid_region[gi], 1));
        for (int d = 0; d < 4; ++d) {
            std::vector<int> dist(static_cast<size_t>(L->N), -1); std::vector<int> q;
            for (int t = 0; t < L->N; ++t) if (seen_in[static_cast<size_t>(t)] == 1) { dist[static_cast<size_t>(t)] = 0; q.push_back(t); }
            int best = -1;
            for (size_t h = 0; h < q.size() && best < 0; ++h) { const int t = q[h]; for (uint16_t u : L->nbr[d][static_cast<size_t>(t)]) if (dist[u] < 0) { dist[u] = dist[static_cast<size_t>(t)] + 1; if (seen_in[u] == 2) { best = dist[u]; break; } q.push_back(u); } }
            int shared = 0; for (auto v : seen_in) shared += v == 3;
            fprintf(stderr, "  chain dir %d: %d steps (shared cells %d)\n", d, best, shared);
        }
    }
    L->key_regions.assign(static_cast<size_t>(L->N), 0);
    for (size_t gi = 0; gi < L->grids.size(); ++gi) for (int k : L->grids[gi].k) if (k >= 0) L->key_regions[static_cast<size_t>(k)] |= static_cast<uint8_t>(1u << std::min(L->grid_region[gi], 7));
    L->walk.resize(static_cast<size_t>(L->N));
    for (int t = 0; t < L->N; ++t) L->walk[static_cast<size_t>(t)] = L->keys[static_cast<size_t>(t)].wa;
    L->walkset.assign(static_cast<size_t>(L->NW), 0);
    for (int t = 0; t < L->N; ++t) if (L->walk[static_cast<size_t>(t)]) L->walkset[static_cast<size_t>(t >> 6)] |= 1ull << (t & 63);
    for (const auto& g : L->grids)
        for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
            const int a = g.at(x, y); if (a < 0) continue;
            if (x + 1 < g.w && g.at(x + 1, y) >= 0) ++L->pairc[0][static_cast<uint64_t>(a) << 32 | static_cast<uint32_t>(g.at(x + 1, y))];
            if (y + 1 < g.h && g.at(x, y + 1) >= 0) ++L->pairc[1][static_cast<uint64_t>(a) << 32 | static_cast<uint32_t>(g.at(x, y + 1))];
        }
    for (auto& o : L->obs) o.assign(static_cast<size_t>(L->N), {});
    for (const auto& [k, c] : L->pairc[0]) { const int a = static_cast<int>(k >> 32), b = static_cast<int>(k & 0xFFFFFFFFu); L->obs[0][static_cast<size_t>(b)].push_back({static_cast<uint16_t>(a), c}); L->obs[1][static_cast<size_t>(a)].push_back({static_cast<uint16_t>(b), c}); }
    for (const auto& [k, c] : L->pairc[1]) { const int a = static_cast<int>(k >> 32), b = static_cast<int>(k & 0xFFFFFFFFu); L->obs[2][static_cast<size_t>(b)].push_back({static_cast<uint16_t>(a), c}); L->obs[3][static_cast<size_t>(a)].push_back({static_cast<uint16_t>(b), c}); }
    L->occ.assign(static_cast<size_t>(L->N), {});
    for (size_t gi = 0; gi < L->grids.size(); ++gi) {
        const auto& g = L->grids[gi];
        for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) { const int k = g.at(x, y); if (k >= 0) L->occ[static_cast<size_t>(k)].push_back(static_cast<int>(gi << 20 | y << 10 | x)); }
    }
    if (mix) for (size_t r = 0; r < opt.regions.size() && r < 8; ++r) {
        L->region_set[r].assign(static_cast<size_t>(L->NW), 0);
        for (int t = 0; t < L->N; ++t) if ((L->key_regions[static_cast<size_t>(t)] >> r) & 1) L->region_set[r][static_cast<size_t>(t >> 6)] |= 1ull << (t & 63);
    }
    if (mix) {   // how well the regions join: shared cells really seen next to both regions' own cells
        int bridges = 0;
        for (int t = 0; t < L->N; ++t) {
            if (L->key_regions[static_cast<size_t>(t)] != 3) continue;
            bool r0 = false, r1 = false;
            for (int d = 0; d < 4; ++d) for (const auto& o : L->obs[d][static_cast<size_t>(t)]) { const uint8_t b = L->key_regions[o.first]; r0 |= b == 1; r1 |= b == 2; }
            bridges += r0 && r1;
        }
        L->bridges = bridges;
        if (getenv("MB_DEBUG")) fprintf(stderr, "  join: %d bridge cells\n", bridges);
    }
    return true;
}


// Paths: the walkable cells of the area's maps fall in two looks - the ground
// (grass, snow, sand: most of it) and a path (a dirt track, a road). Split the
// walkable cells by their average colour into two groups (2-means, weighted by
// how often each is seen); the smaller group is the path when it is clearly
// different and common enough. New floors then lay a path along the way
// through (entrance -> rooms -> way on).
void find_paths(Lib& L, const Options& opt, const uint16_t* base) {
    L.path.assign(static_cast<size_t>(L.N), 0); L.path_n = 0;
    if (!opt.tile_pixels || !opt.palette || getenv("MB_NOPATH")) return;
    std::vector<std::array<float, 3>> col(static_cast<size_t>(L.N), {0, 0, 0});
    std::vector<uint8_t> have(static_cast<size_t>(L.N), 0);
    for (int t = 0; t < L.N; ++t) {
        if (!L.walk[static_cast<size_t>(t)]) continue;
        float px[64][3];
        for (int i = 0; i < 64; ++i) { px[i][0] = opt.palette[0]; px[i][1] = opt.palette[1]; px[i][2] = opt.palette[2]; }
        bool any = false;
        static const int order[4] = {3, 2, 1, 0};
        for (int l : order) {
            const uint32_t e = L.keys[static_cast<size_t>(t)].e[l]; uint32_t id = e & 0xFFFF;
            if (!id) continue;
            if (!L.global) id = (base && id < 1024) ? base[id] : 0;
            if (!id || id >= 0xC000) continue;
            const uint8_t* tp = opt.tile_pixels(static_cast<uint16_t>(id));
            if (!tp) continue;
            any = true;
            for (int i = 0; i < 64; ++i) if (tp[i]) { px[i][0] = opt.palette[tp[i] * 3]; px[i][1] = opt.palette[tp[i] * 3 + 1]; px[i][2] = opt.palette[tp[i] * 3 + 2]; }
        }
        if (!any) continue;
        auto& c = col[static_cast<size_t>(t)];
        for (int i = 0; i < 64; ++i) for (int ch = 0; ch < 3; ++ch) c[static_cast<size_t>(ch)] += px[i][ch] / 64.0f;
        have[static_cast<size_t>(t)] = 1;
    }
    // k-means (k = 4) over the walkable looks, weighted by how often each is seen
    auto d2 = [](const std::array<float, 3>& a, const std::array<float, 3>& b) { float s = 0; for (int i = 0; i < 3; ++i) s += (a[i] - b[i]) * (a[i] - b[i]); return s; };
    static const int K = getenv("MB_PATHK") ? atoi(getenv("MB_PATHK")) : 6;
    std::vector<std::array<float, 3>> cen;
    int top = -1; for (int t = 0; t < L.N; ++t) if (have[static_cast<size_t>(t)] && (top < 0 || L.freq[static_cast<size_t>(t)] > L.freq[static_cast<size_t>(top)])) top = t;
    if (top < 0) return;
    cen.push_back(col[static_cast<size_t>(top)]);
    while (static_cast<int>(cen.size()) < K) {   // farthest-point seeding
        float best = -1; int bt = -1;
        for (int t = 0; t < L.N; ++t) if (have[static_cast<size_t>(t)]) { float m = 1e30f; for (auto& c : cen) m = std::min(m, d2(col[static_cast<size_t>(t)], c)); const float sc = m * static_cast<float>(std::sqrt(L.freq[static_cast<size_t>(t)])); if (sc > best) { best = sc; bt = t; } }
        if (bt < 0) break; cen.push_back(col[static_cast<size_t>(bt)]);
    }
    std::vector<uint8_t> grp(static_cast<size_t>(L.N), 0);
    std::vector<double> wsum(cen.size(), 0);
    for (int it = 0; it < 15; ++it) {
        std::vector<std::array<double, 3>> S(cen.size(), {0, 0, 0}); std::fill(wsum.begin(), wsum.end(), 0.0);
        for (int t = 0; t < L.N; ++t) {
            if (!have[static_cast<size_t>(t)]) continue;
            int bi = 0; for (size_t i = 1; i < cen.size(); ++i) if (d2(col[static_cast<size_t>(t)], cen[i]) < d2(col[static_cast<size_t>(t)], cen[static_cast<size_t>(bi)])) bi = static_cast<int>(i);
            grp[static_cast<size_t>(t)] = static_cast<uint8_t>(bi);
            const double w = L.freq[static_cast<size_t>(t)]; wsum[static_cast<size_t>(bi)] += w;
            for (int ch = 0; ch < 3; ++ch) S[static_cast<size_t>(bi)][static_cast<size_t>(ch)] += col[static_cast<size_t>(t)][static_cast<size_t>(ch)] * w;
        }
        for (size_t i = 0; i < cen.size(); ++i) if (wsum[i] > 0) for (int ch = 0; ch < 3; ++ch) cen[i][static_cast<size_t>(ch)] = static_cast<float>(S[i][static_cast<size_t>(ch)] / wsum[i]);
    }
    double wt = 0; for (double w : wsum) wt += w;
    auto hsv = [](const std::array<float, 3>& c, float* h, float* sat, float* v) {
        const float r = c[0] / 255, g = c[1] / 255, b = c[2] / 255, mx = std::max({r, g, b}), mn = std::min({r, g, b}), d = mx - mn;
        float hh = 0; if (d > 1e-6f) { if (mx == r) hh = 60 * std::fmod((g - b) / d, 6.0f); else if (mx == g) hh = 60 * ((b - r) / d + 2); else hh = 60 * ((r - g) / d + 4); }
        if (hh < 0) hh += 360; *h = hh; *sat = mx > 0 ? d / mx : 0; *v = mx;
    };
    int ground = 0; for (size_t i = 1; i < cen.size(); ++i) if (wsum[i] > wsum[static_cast<size_t>(ground)]) ground = static_cast<int>(i);
    float gh, gs, gv; hsv(cen[static_cast<size_t>(ground)], &gh, &gs, &gv);
    // the path: an earthy look (brown / tan: hue 15-45, not very saturated), clearly unlike the ground, common enough
    int pathc = -1; double pbest = 0; std::vector<uint8_t> ispath(cen.size(), 0);
    for (size_t i = 0; i < cen.size(); ++i) {
        if (static_cast<int>(i) == ground) continue;
        float h, sa, v; hsv(cen[i], &h, &sa, &v);
        const double share = wsum[i] / std::max(1e-9, wt);
        const bool earthy = h >= 15 && h <= 45 && sa >= 0.25f && sa <= 0.78f && v >= 0.3f;
        const bool unlike = std::abs(h - gh) >= 12 || std::abs(sa - gs) >= 0.2f;
        if (getenv("MB_DEBUG")) fprintf(stderr, "paths: look %zu %.0f,%.0f,%.0f hue %.0f sat %.2f share %.2f%s\n", i, cen[i][0], cen[i][1], cen[i][2], h, sa, share, earthy && unlike ? " (path-like)" : "");
        if (earthy && unlike && share >= 0.03) { ispath[i] = 1; if (share > pbest) { pbest = share; pathc = static_cast<int>(i); } }
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "paths: ground look %d (hue %.0f), path look %d\n", ground, gh, pathc);
    if (pathc < 0) return;
    const bool one_is_path = true; (void)one_is_path;
    for (int t = 0; t < L.N; ++t) if (have[static_cast<size_t>(t)] && ispath[grp[static_cast<size_t>(t)]]) { L.path[static_cast<size_t>(t)] = 1; ++L.path_n; }
    if (getenv("MB_DEBUG")) fprintf(stderr, "paths: %d path cells of %d\n", L.path_n, L.N);
}
// ---------------------------------------------------------------- plan
// T: 1 floor, 0 wall, -1 either (a band around the floor)
struct Pt { int x, y; };
// a point on a side (0 left, 1 right, 2 top, 3 bottom), away from the corners
Pt edge_point(int side, int tw, int th, std::mt19937& rng) {
    auto rnd = [&](int lo, int hi) { return lo + static_cast<int>(rng() % static_cast<uint32_t>(std::max(1, hi - lo + 1))); };
    switch (side) {
    case 0: return {0, rnd(th / 3, 2 * th / 3)};
    case 1: return {tw - 1, rnd(th / 3, 2 * th / 3)};
    case 2: return {rnd(tw / 3, 2 * tw / 3), 0};
    default: return {rnd(tw / 3, 2 * tw / 3), th - 1};
    }
}
thread_local std::vector<uint8_t> g_pathplan;   // 2: the path's middle, 1: beside it, 0: elsewhere (floor coords)
thread_local int g_pathW = 0;
struct Room { int x0, y0, x1, y1; };
thread_local std::vector<Room> g_rooms;   // the plan's clearings (landmarks go there)
void make_plan(int tw, int th, const Options& o, std::mt19937& rng, std::vector<int8_t>* T, Pt* pin, Pt* pout, bool water = false) {
    std::vector<uint8_t> F(static_cast<size_t>(tw) * th, 0);
    auto rnd = [&](int lo, int hi) { return lo + static_cast<int>(rng() % static_cast<uint32_t>(std::max(1, hi - lo + 1))); };
    auto carve = [&](int x0, int y0, int x1, int y1) {
        for (int y = std::max(0, std::min(y0, y1)); y <= std::min(th - 1, std::max(y0, y1)); ++y)
            for (int x = std::max(0, std::min(x0, x1)); x <= std::min(tw - 1, std::max(x0, x1)); ++x) F[static_cast<size_t>(y) * tw + x] = 1;
    };
    const int is = o.in_side >= 0 ? o.in_side : 3;
    int os = o.out_side >= 0 ? o.out_side : (is ^ 1);
    if (os == is) os = is ^ 1;
    *pin = edge_point(is, tw, th, rng); *pout = edge_point(os, tw, th, rng);
    struct R { int x0, y0, x1, y1; };
    std::vector<R> rooms;
    for (int i = 0; i < o.rooms; ++i) {
        const int w = rnd(10, 16), h = rnd(8, 11);
        const int x0 = rnd(4, tw - 5 - w), y0 = rnd(4, th - 5 - h);
        rooms.push_back({x0, y0, x0 + w, y0 + h});
    }
    // visit the rooms in order from the way in to the way on
    auto d2 = [](Pt a, int x, int y) { return (a.x - x) * (a.x - x) + (a.y - y) * (a.y - y); };
    std::stable_sort(rooms.begin(), rooms.end(), [&](const R& a, const R& b) {
        const int ka = d2(*pin, (a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2) - d2(*pout, (a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2);
        const int kb = d2(*pin, (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2) - d2(*pout, (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2);
        return ka < kb;
    });
    const int cw = getenv("MB_CW") ? atoi(getenv("MB_CW")) : 3;   // corridors 7 tiles wide: room for the fighter's body box
    // corridor legs: leave an edge straight away from it, reach the last edge straight into it
    auto leg = [&](Pt a, Pt b, bool vertical_first) {
        if (vertical_first) { carve(a.x - cw, a.y, a.x + cw, b.y); carve(a.x, b.y - cw, b.x, b.y + cw); }
        else { carve(a.x, a.y - cw, b.x, a.y + cw); carve(b.x - cw, a.y, b.x + cw, b.y); }
    };
    // the path: along the middle of the corridor legs (a gentle wobble, like a trodden track)
    std::vector<uint8_t> PL(F.size(), 0);
    auto pathline = [&](Pt a, Pt b, bool vertical_first) {
        auto seg = [&](int x0, int y0, int x1, int y1) {
            const int n = std::max(std::abs(x1 - x0), std::abs(y1 - y0));
            const double ph = (rng() % 1000) * 0.00628;
            for (int i = 0; i <= n; ++i) {
                const double t = n ? static_cast<double>(i) / n : 0.0;
                int x = x0 + static_cast<int>(std::lround((x1 - x0) * t)), y = y0 + static_cast<int>(std::lround((y1 - y0) * t));
                const int wob = static_cast<int>(std::lround(1.2 * std::sin(i * 0.25 + ph)));
                if (x0 == x1) x += wob; else y += wob;
                if (x >= 0 && y >= 0 && x < tw && y < th) PL[static_cast<size_t>(y) * tw + x] = 1;
            }
        };
        if (vertical_first) { seg(a.x, a.y, a.x, b.y); seg(a.x, b.y, b.x, b.y); }
        else { seg(a.x, a.y, b.x, a.y); seg(b.x, a.y, b.x, b.y); }
    };
    g_rooms.clear();
    for (const auto& r : rooms) g_rooms.push_back({r.x0, r.y0, r.x1, r.y1});
    Pt p = *pin; bool first = true;
    for (const auto& r : rooms) {
        carve(r.x0, r.y0, r.x1, r.y1);
        const Pt c{(r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2};
        const bool vf = first ? is >= 2 : (rng() & 1);
        leg(p, c, vf); pathline(p, c, vf);
        p = c; first = false;
    }
    leg(p, *pout, !(os >= 2));   // the final leg ends perpendicular to the out edge
    pathline(p, *pout, !(os >= 2));
    g_pathplan.assign(F.size(), 0); g_pathW = tw;
    for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
        int best = 9;
        for (int dy = -3; dy <= 3; ++dy) for (int dx = -3; dx <= 3; ++dx) {
            const int xx = x + dx, yy = y + dy;
            if (xx >= 0 && yy >= 0 && xx < tw && yy < th && PL[static_cast<size_t>(yy) * tw + xx]) best = std::min(best, std::max(std::abs(dx), std::abs(dy)));
        }
        g_pathplan[static_cast<size_t>(y) * tw + x] = static_cast<uint8_t>(best <= 1 ? 2 : (best <= 3 ? 1 : 0));
    }
    // the layout's own shape on top of the clearings and ways
    std::vector<uint8_t> Wt(F.size(), 0);   // water planned
    auto near_path = [&](int x, int y, int r) { for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx) { const int xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < tw && yy < th && PL[static_cast<size_t>(yy) * tw + xx]) return true; } return false; };
    const int lay = o.layout;
    if (lay == 1 || ((lay == 2 || lay == 3) && !water)) {   // an open field: open nearly to the edges (a wavy border), a few islands of trees / rocks (rivers / lakes: painted in once the floor stands - place_water)
        const double p1 = (rng() % 1000) * 0.00628, p2 = (rng() % 1000) * 0.00628;
        for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
            const int bx = 4 + static_cast<int>(2.0 + 1.6 * std::sin(y * 0.23 + p1) + 1.2 * std::sin(y * 0.07 + p2));
            const int by = 4 + static_cast<int>(2.0 + 1.6 * std::sin(x * 0.19 + p2) + 1.2 * std::sin(x * 0.05 + p1));
            if (x >= bx && x < tw - bx && y >= by && y < th - by) F[static_cast<size_t>(y) * tw + x] = 1;
        }
        const int n = 3 + static_cast<int>(rng() % 4u);
        for (int i = 0, tries = 0; i < n && tries < 200; ++tries) {
            const int rx = rnd(3, 6), ry = rnd(2, 5), cx = rnd(8, tw - 9), cy = rnd(7, th - 8);
            bool ok = true;
            for (int y = cy - ry - 3; y <= cy + ry + 3 && ok; ++y) for (int x = cx - rx - 3; x <= cx + rx + 3 && ok; ++x) if (near_path(x, y, 2)) ok = false;
            if (std::abs(cx - pin->x) + std::abs(cy - pin->y) < 14 || std::abs(cx - pout->x) + std::abs(cy - pout->y) < 14) ok = false;
            if (!ok) continue;
            for (int y = cy - ry; y <= cy + ry; ++y) for (int x = cx - rx; x <= cx + rx; ++x) {
                const double dx = (x - cx) / static_cast<double>(rx), dy = (y - cy) / static_cast<double>(ry);
                if (dx * dx + dy * dy <= 1.0 && x > 0 && y > 0 && x < tw - 1 && y < th - 1) F[static_cast<size_t>(y) * tw + x] = 0;
            }
            ++i;
        }
    } else if (lay == 2 && water) {   // a river across the way: a wavy band of water, a ford where the way crosses it
        const bool across_x = (is >= 2) == (os >= 2) ? (is >= 2) : true;   // (the way runs up/down: the river runs left/right)
        const int len = across_x ? tw : th, span = across_x ? th : tw;
        const int mid = span / 2 + rnd(-span / 8, span / 8);
        const int wdt = rnd(3, 5);
        const double ph = (rng() % 1000) * 0.00628, amp = 2.0 + (rng() % 300) * 0.01;
        for (int u = 0; u < len; ++u) {
            const int c = mid + static_cast<int>(std::lround(amp * std::sin(u * 0.11 + ph) + 1.2 * std::sin(u * 0.29 + ph * 2)));
            for (int v = c - wdt / 2; v <= c + (wdt - 1) / 2; ++v) {
                const int x = across_x ? u : v, y = across_x ? v : u;
                if (x < 0 || y < 0 || x >= tw || y >= th) continue;
                if (near_path(x, y, 3)) continue;   // (the ford: the way stays dry)
                Wt[static_cast<size_t>(y) * tw + x] = 1;
            }
            // banks: open ground along the river, so it runs through the field, not inside the woods
            for (int v = c - wdt / 2 - 3; v <= c + (wdt - 1) / 2 + 3; ++v) {
                const int x = across_x ? u : v, y = across_x ? v : u;
                if (x > 2 && y > 2 && x < tw - 3 && y < th - 3) F[static_cast<size_t>(y) * tw + x] = 1;
            }
        }
    } else if (lay == 3 && water) {   // a lake in the roomiest open part, off the way
        int bx = -1, by = -1, bs = -1; const int rx = rnd(6, 9), ry = rnd(4, 6);
        for (int cy = ry + 5; cy < th - ry - 5; cy += 2) for (int cx = rx + 5; cx < tw - rx - 5; cx += 2) {
            bool ok = true;
            for (int y = cy - ry - 2; y <= cy + ry + 2 && ok; ++y) for (int x = cx - rx - 2; x <= cx + rx + 2 && ok; ++x) if (near_path(x, y, 2)) ok = false;
            if (!ok) continue;
            int sc = 0; for (int y = cy - ry; y <= cy + ry; ++y) for (int x = cx - rx; x <= cx + rx; ++x) sc += F[static_cast<size_t>(y) * tw + x];
            sc += static_cast<int>(rng() % 20u);
            if (sc > bs) { bs = sc; bx = cx; by = cy; }
        }
        if (bx >= 0) {
            const double ph = (rng() % 1000) * 0.00628;
            for (int y = by - ry - 3; y <= by + ry + 3; ++y) for (int x = bx - rx - 3; x <= bx + rx + 3; ++x) {
                if (x < 1 || y < 1 || x >= tw - 1 || y >= th - 1) continue;
                const double a = std::atan2(y - by, x - bx), wob = 1.0 + 0.18 * std::sin(a * 3 + ph);
                const double dx = (x - bx) / (rx * wob), dy = (y - by) / (ry * wob), d = dx * dx + dy * dy;
                if (d <= 1.0) Wt[static_cast<size_t>(y) * tw + x] = 1;
                if (d <= 2.2) F[static_cast<size_t>(y) * tw + x] = 1;   // (a shore all round)
            }
        }
    }
    auto f = [&](int x, int y) { return x >= 0 && y >= 0 && x < tw && y < th && F[static_cast<size_t>(y) * tw + x]; };
    T->assign(F.size(), 0);
    for (int y = 0; y < th; ++y)
        for (int x = 0; x < tw; ++x) {
            bool core = f(x, y);
            for (int dy = -1; dy <= 1 && core; ++dy) for (int dx = -1; dx <= 1 && core; ++dx) core = f(x + dx, y + dy) || y + dy < 0 || y + dy >= th;
            bool nearf = false;
            for (int dy = -2; dy <= 2 && !nearf; ++dy) for (int dx = -2; dx <= 2 && !nearf; ++dx) nearf = f(x + dx, y + dy);
            (*T)[static_cast<size_t>(y) * tw + x] = static_cast<int8_t>(core ? 1 : (nearf ? -1 : 0));
        }
    // water: its middle is water, its edge either (the shore pieces come from real maps)
    for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
        if (!Wt[static_cast<size_t>(y) * tw + x]) continue;
        bool inner = true;
        for (int dy = -1; dy <= 1 && inner; ++dy) for (int dx = -1; dx <= 1 && inner; ++dx) { const int xx = x + dx, yy = y + dy; inner = xx < 0 || yy < 0 || xx >= tw || yy >= th || Wt[static_cast<size_t>(yy) * tw + xx]; }
        (*T)[static_cast<size_t>(y) * tw + x] = static_cast<int8_t>(inner ? 2 : -1);
    }
}

// ---------------------------------------------------------------- quilt
struct Canvas {
    int w, h; std::vector<int> k; std::vector<int> org;   // org: packed source position (grid,y,x) or -1
    int& at(int x, int y) { return k[static_cast<size_t>(y) * w + x]; }
};

struct Cand { double score; int g, sx, sy; };
double seam_w() { const char* e = getenv("MB_SEAMW"); return e ? atof(e) : 10.0; }

// best seam through the left overlap (columns [0,O) of the patch). old keeps
// columns [0,cut) on each row. Returns total bad pairs; path[y] = cut.
int seam(const Lib& L, const Canvas& C, int x0, int y0, const Grid& g, int sx, int sy,
         int P, int O, bool vertical, std::vector<int>* path) {
    // accessors in "seam space": u along the seam (rows for a left seam), v across (0..O)
    auto old = [&](int u, int v) { return vertical ? C.k[static_cast<size_t>(y0 + u) * C.w + x0 + v] : C.k[static_cast<size_t>(y0 + v) * C.w + x0 + u]; };
    auto nw = [&](int u, int v) { return vertical ? g.at(sx + v, sy + u) : g.at(sx + u, sy + v); };
    const int dAcross = vertical ? 0 : 2, dAlong = vertical ? 2 : 0;   // pair directions
    const int INF = 1 << 20;
    static thread_local std::vector<int> cost, back;
    cost.assign(static_cast<size_t>(P) * (O + 1), INF); back.assign(static_cast<size_t>(P) * (O + 1), 0);
    auto rowc = [&](int u, int x) {
        int c = 0;
        for (int v = 0; v < x; ++v) if (old(u, v) < 0) return INF;
        if (x == 0) { const int prev = vertical ? (x0 > 0 ? C.k[static_cast<size_t>(y0 + u) * C.w + x0 - 1] : -1) : (y0 > 0 ? C.k[static_cast<size_t>(y0 - 1) * C.w + x0 + u] : -1);
                      if (prev >= 0 && !L.ok(dAcross, prev, nw(u, 0))) c++; }
        else if (!L.ok(dAcross, old(u, x - 1), nw(u, x))) c++;
        return c;
    };
    for (int x = 0; x <= O; ++x) cost[static_cast<size_t>(x)] = rowc(0, x);
    for (int u = 1; u < P; ++u)
        for (int x2 = 0; x2 <= O; ++x2) {
            const int rc = rowc(u, x2);
            if (rc >= INF) continue;
            int best = INF, bi = 0;
            for (int x1 = 0; x1 <= O; ++x1) {
                const int pc = cost[static_cast<size_t>(u - 1) * (O + 1) + x1];
                if (pc >= INF) continue;
                int c = pc;
                for (int v = std::min(x1, x2); v < std::max(x1, x2) && c < best; ++v) {
                    const int up = v < x1 ? old(u - 1, v) : nw(u - 1, v);
                    const int dn = v < x2 ? old(u, v) : nw(u, v);
                    if (up < 0 || dn < 0 || !L.ok(dAlong, up, dn)) ++c;
                }
                if (c < best) { best = c; bi = x1; }
            }
            if (best < INF) { cost[static_cast<size_t>(u) * (O + 1) + x2] = best + rc; back[static_cast<size_t>(u) * (O + 1) + x2] = bi; }
        }
    int bx = 0, bc = INF;
    for (int x = 0; x <= O; ++x) if (cost[static_cast<size_t>(P - 1) * (O + 1) + x] < bc) { bc = cost[static_cast<size_t>(P - 1) * (O + 1) + x]; bx = x; }
    if (path) {
        path->assign(static_cast<size_t>(P), 0);
        for (int u = P - 1; u >= 0; --u) { (*path)[static_cast<size_t>(u)] = bx; if (u) bx = back[static_cast<size_t>(u) * (O + 1) + bx]; }
    }
    return bc;
}

int count_bad(const Lib& L, const std::vector<int>& K, int W, int H, int x0, int y0, int x1, int y1, std::vector<uint8_t>* mark) {
    x0 = std::max(0, x0); y0 = std::max(0, y0); x1 = std::min(W, x1); y1 = std::min(H, y1);
    int n = 0;
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const int a = K[static_cast<size_t>(y) * W + x];
            if (a < 0) continue;
            if (x + 1 < x1) { const int b = K[static_cast<size_t>(y) * W + x + 1]; if (b >= 0 && !L.ok(0, a, b)) { ++n; if (mark) (*mark)[static_cast<size_t>(y) * W + x] = (*mark)[static_cast<size_t>(y) * W + x + 1] = 1; } }
            if (y + 1 < y1) { const int b = K[static_cast<size_t>(y + 1) * W + x]; if (b >= 0 && !L.ok(2, a, b)) { ++n; if (mark) (*mark)[static_cast<size_t>(y) * W + x] = (*mark)[static_cast<size_t>(y + 1) * W + x] = 1; } }
        }
    return n;
}

int fix_as_you_go(const Lib& L, std::vector<int>& K, int W, int H, int x0, int y0, int x1, int y1, std::mt19937& rng);
// landmarks laid down before the quilting (cells >= 0 stay; the pieces around them seam onto them)
thread_local const std::vector<int>* g_seed_k = nullptr;
thread_local const std::vector<int>* g_seed_org = nullptr;
struct SeedSrc { int x, y, w, h, g, sx, sy; };
thread_local std::vector<SeedSrc> g_seed_src;   // where each landmark came from: pieces that continue its own surroundings
thread_local std::vector<int>* g_quilt_org = nullptr;   // (out) where each cell of the last quilt came from
struct LmWin { int g, sx, sy, w, h; };
thread_local std::vector<LmWin> g_lm_pull;
thread_local long g_pull_hits = 0;
thread_local const std::vector<uint8_t>* g_reserve = nullptr;   // cells kept open for a building (nothing standing there): building number + 1
thread_local std::vector<std::unordered_map<uint32_t, char>> g_res_ground;   // per kept room: the ground the building stood on
thread_local uint8_t g_ground_mask = 0;
thread_local const std::vector<uint8_t>* g_keyobj = nullptr;    // key -> something stands on it   // landmarks of the area: pieces that bring one whole into a clearing are preferred
bool quilt(const Lib& L, const std::vector<int8_t>& T, int W, int H, std::mt19937& rng, std::vector<int>* out, int* seam_bad, int P0, int O0, const std::vector<int8_t>* R = nullptr) {
    int P = getenv("MB_P") ? atoi(getenv("MB_P")) : P0, O = getenv("MB_O") ? atoi(getenv("MB_O")) : O0;
    P = std::min({P, W, H}); O = std::min(O, P / 2);   // (a small floor: pieces no bigger than it)
    const int step = P - O;
    Canvas C{W, H, std::vector<int>(static_cast<size_t>(W) * H, -1), std::vector<int>(static_cast<size_t>(W) * H, -1)};
    const bool seeded = g_seed_k && g_seed_k->size() == C.k.size();
    if (seeded) { C.k = *g_seed_k; C.org = *g_seed_org; }
    auto fixed = [&](size_t ci) { return seeded && (*g_seed_k)[ci] >= 0; };
    std::vector<int> ys, xs;
    for (int y = 0; y + P < H; y += step) ys.push_back(y);
    if (ys.empty() || ys.back() != H - P) ys.push_back(H - P);
    for (int x = 0; x + P < W; x += step) xs.push_back(x);
    if (xs.empty() || xs.back() != W - P) xs.push_back(W - P);
    // per grid: prefix sums of walk and of missing cells
    struct Pre { std::vector<int> miss; };
    std::vector<Pre> pre(L.grids.size());
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        const auto& g = L.grids[gi]; auto& m = pre[gi].miss; m.assign(static_cast<size_t>(g.w + 1) * (g.h + 1), 0);
        for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x)
            m[static_cast<size_t>(y + 1) * (g.w + 1) + x + 1] = (g.at(x, y) < 0) + m[static_cast<size_t>(y) * (g.w + 1) + x + 1] + m[static_cast<size_t>(y + 1) * (g.w + 1) + x] - m[static_cast<size_t>(y) * (g.w + 1) + x];
    }
    auto U = [](std::mt19937& r) { return mb_unit(r); };
    *seam_bad = 0;
    std::vector<Cand> cands; std::vector<int> pathL, pathT;
    for (int y0 : ys)
        for (int x0 : xs) {
            const bool hasL = C.k[static_cast<size_t>(y0 + P - 1) * W + x0] >= 0;
            const bool hasT = C.k[static_cast<size_t>(y0) * W + x0 + P - 1] >= 0;
            cands.clear();
            static const int kRegW = getenv("MB_REGW") ? atoi(getenv("MB_REGW")) : 12;
            static const int kLmPull = getenv("MB_LMPULL") ? atoi(getenv("MB_LMPULL")) : 40;
            static const int kResW = getenv("MB_RESW") ? atoi(getenv("MB_RESW")) : 10;
            static const int kWaterW = getenv("MB_WATERW") ? atoi(getenv("MB_WATERW")) : 12;
            auto plan_cost = [&](const Grid& g, int sx, int sy) {
                int c = 0;
                const int greg = R ? L.grid_region[static_cast<size_t>(&g - L.grids.data())] : 0;
                for (int y = 0; y < P; ++y) for (int x = 0; x < P; ++x) {
                    if (R) { const int r = (*R)[static_cast<size_t>(y0 + y) * W + x0 + x]; if (r >= 0 && r != greg) c += kRegW; }   // a piece of the wrong region here
                    const int kk = g.at(sx + x, sy + y);
                    if (L.path_n && !g_pathplan.empty() && g_pathW == W) {   // a path along the planned track, none elsewhere
                        const int pp = g_pathplan[static_cast<size_t>(y0 + y) * W + x0 + x];
                        const bool ip = L.path[static_cast<size_t>(kk)];
                        if (pp == 2) c += ip ? 0 : 2; else if (pp == 0 && ip) c += 1;
                    }
                    if (g_reserve) { const int rv = (*g_reserve)[static_cast<size_t>(y0 + y) * W + x0 + x];
                        if (rv) {
                            if ((*g_keyobj)[static_cast<size_t>(kk)]) c += kResW;
                            else { const Key& key = L.keys[static_cast<size_t>(kk)];
                                for (int l = 0; l < 4; ++l) if (((g_ground_mask >> l) & 1) && !g_res_ground[static_cast<size_t>(rv - 1)].count(static_cast<uint32_t>(l) << 16 | (key.e[l] & 0x3FF))) { c += 2; break; } }
                        } }
                    const int t = T[static_cast<size_t>(y0 + y) * W + x0 + x]; if (t < 0) continue;
                    const int w = L.walk[static_cast<size_t>(kk)];
                    if (t == 2) { c += (L.liquid.empty() || L.liquid[static_cast<size_t>(kk)]) ? 0 : kWaterW; continue; }   // (water planned here: it really is water there - a weak pull left it grass)
                    if (t == 1 && !w) c += 3; else if (t == 0 && w) c += 1;
                    else if (t == 0 && !L.liquid.empty() && L.liquid[static_cast<size_t>(kk)]) c += 1;   // (no stray water in the woods)
                }
                if (!g_lm_pull.empty() && !g_rooms.empty()) {   // a landmark whole inside this piece, standing in a clearing off the path
                    const int gi = static_cast<int>(&g - L.grids.data());
                    for (const auto& lw : g_lm_pull) {
                        if (lw.g != gi || lw.sx < sx || lw.sy < sy || lw.sx + lw.w > sx + P || lw.sy + lw.h > sy + P) continue;
                        const int fx = x0 + lw.sx - sx, fy = y0 + lw.sy - sy, cx = fx + lw.w / 2, cy = fy + lw.h / 2;
                        bool in_room = false;
                        for (const auto& r : g_rooms) if (cx >= r.x0 - 3 && cx <= r.x1 + 3 && cy >= r.y0 - 3 && cy <= r.y1 + 3) { in_room = true; break; }
                        if (!in_room) continue;
                        bool on_path = false;
                        if (!g_pathplan.empty() && g_pathW == W)
                            for (int y = 0; y < lw.h && !on_path; ++y) for (int x = 0; x < lw.w && !on_path; ++x) on_path = g_pathplan[static_cast<size_t>(fy + y) * W + fx + x] == 2;
                        if (on_path) continue;
                        c -= kLmPull; ++g_pull_hits; break;
                    }
                }
                return c;
            };
            auto usable = [&](size_t gi, int sx, int sy) {
                const auto& g = L.grids[gi];
                if (sx < 0 || sy < 0 || sx + P > g.w || sy + P > g.h) return false;
                const auto& m = pre[gi].miss; const int s = g.w + 1;
                return m[static_cast<size_t>(sy + P) * s + sx + P] - m[static_cast<size_t>(sy) * s + sx + P] - m[static_cast<size_t>(sy + P) * s + sx] + m[static_cast<size_t>(sy) * s + sx] == 0;
            };
            for (size_t gi = 0; gi < L.grids.size(); ++gi) {
                const auto& g = L.grids[gi];
                for (int sy = 0; sy + P <= g.h; sy += 1)
                    for (int sx = 0; sx + P <= g.w; sx += 1) {
                        if (!usable(gi, sx, sy)) continue;
                        cands.push_back({plan_cost(g, sx, sy) + U(rng) * 6.0, static_cast<int>(gi), sx, sy});
                    }
            }
            if (cands.empty()) return false;
            std::stable_sort(cands.begin(), cands.end(), [](const Cand& a, const Cand& b) { return a.score < b.score; });
            const size_t kTop = getenv("MB_TOP") ? static_cast<size_t>(atoi(getenv("MB_TOP"))) : 1500;
            if (cands.size() > kTop) cands.resize(kTop);
            // anchored candidates: continue what is already there
            if (hasL || hasT) {
                const int kAnch = getenv("MB_ANCH") ? atoi(getenv("MB_ANCH")) : 400;
                for (int i = 0; i < kAnch; ++i) {
                    const int u = static_cast<int>(rng() % P), v = static_cast<int>(rng() % O);
                    const int cx = hasL ? v : u, cy = hasL ? u : v;
                    const int o = C.org[static_cast<size_t>(y0 + cy) * W + x0 + cx];
                    int gi, yy, xx;
                    if (o >= 0 && i < 40) { gi = o >> 20; yy = (o >> 10) & 1023; xx = o & 1023; }
                    else {
                        const int k = C.k[static_cast<size_t>(y0 + cy) * W + x0 + cx];
                        if (k < 0 || L.occ[static_cast<size_t>(k)].empty()) continue;
                        const auto& oc = L.occ[static_cast<size_t>(k)]; const int p = oc[rng() % oc.size()];
                        gi = p >> 20; yy = (p >> 10) & 1023; xx = p & 1023;
                    }
                    const int sx = xx - cx, sy = yy - cy;
                    if (!usable(static_cast<size_t>(gi), sx, sy)) continue;
                    cands.push_back({plan_cost(L.grids[static_cast<size_t>(gi)], sx, sy) + U(rng) * 6.0, gi, sx, sy});
                }
            }
            if (seeded) {   // a piece over a landmark is the landmark's own surroundings (then its seams lie where any piece's do)
                int bo = 0; const SeedSrc* bs = nullptr;
                for (const auto& sd : g_seed_src) {
                    const int ow = std::min(sd.x + sd.w, x0 + P) - std::max(sd.x, x0), oh = std::min(sd.y + sd.h, y0 + P) - std::max(sd.y, y0);
                    if (ow > 0 && oh > 0 && ow * oh > bo) { bo = ow * oh; bs = &sd; }
                }
                if (bs) {
                    const int sx = bs->sx + (x0 - bs->x), sy = bs->sy + (y0 - bs->y);
                    if (usable(static_cast<size_t>(bs->g), sx, sy)) {
                        const auto& g = L.grids[static_cast<size_t>(bs->g)];
                        int bad = 0;
                        if (hasL) bad += seam(L, C, x0, y0, g, sx, sy, P, O, true, nullptr);
                        if (hasT) bad += seam(L, C, x0, y0, g, sx, sy, P, O, false, nullptr);
                        if (bad <= P / 3) { cands.clear(); cands.push_back({0.0, bs->g, sx, sy}); }
                    }
                }
            }
            // pick: fewest bad seam pairs, then plan; when every seam is bad, look wider
            double best = 1e18; int bi = -1, bbad = 0;
            size_t from = 0;
            for (int round = 0; round < 3; ++round) {
            for (size_t i = from; i < cands.size(); ++i) {
                const auto& c = cands[i]; const auto& g = L.grids[static_cast<size_t>(c.g)];
                int bad = 0;
                if (hasL) bad += seam(L, C, x0, y0, g, c.sx, c.sy, P, O, true, nullptr);
                if (hasT && bad < 1000) bad += seam(L, C, x0, y0, g, c.sx, c.sy, P, O, false, nullptr);
                // agreement with what is already there (same texture in step: water /
                // grass patterns keep their phase, so nothing unfixable is left behind)
                int agree = 0;
                static const double aw = getenv("MB_AGREE") ? atof(getenv("MB_AGREE")) : 0.3;
                if (aw > 0 && (hasL || hasT))
                    for (int y = 0; y < P; ++y) for (int x = 0; x < P; ++x) {
                        const int k = C.k[static_cast<size_t>(y0 + y) * W + x0 + x];
                        if (k >= 0 && k == g.at(c.sx + x, c.sy + y)) ++agree;
                    }
                if (seeded) {   // a landmark inside this piece: its new cells must meet it
                    for (int y = 0; y < P; ++y) for (int x = 0; x < P; ++x) {
                        const size_t ci = static_cast<size_t>(y0 + y) * W + x0 + x;
                        if (!fixed(ci)) continue;
                        const int a = (*g_seed_k)[ci];
                        if (x + 1 < P && !fixed(ci + 1) && !L.ok(0, a, g.at(c.sx + x + 1, c.sy + y))) ++bad;
                        if (x > 0 && !fixed(ci - 1) && !L.ok(1, a, g.at(c.sx + x - 1, c.sy + y))) ++bad;
                        if (y + 1 < P && !fixed(ci + W) && !L.ok(2, a, g.at(c.sx + x, c.sy + y + 1))) ++bad;
                        if (y > 0 && !fixed(ci - W) && !L.ok(3, a, g.at(c.sx + x, c.sy + y - 1))) ++bad;
                    }
                }
                const double s = bad * seam_w() + c.score - agree * aw;
                if (s < best) { best = s; bi = static_cast<int>(i); bbad = bad; }
            }
            if (bi >= 0 && bbad == 0) break;
            if (!(hasL || hasT)) break;
            if (seeded && cands.size() == 1 && bi == 0) break;   // (the landmark's own piece: no other)
            from = cands.size();
            const int kMore = getenv("MB_MORE") ? atoi(getenv("MB_MORE")) : 1500;
            for (int i = 0; i < kMore; ++i) {
                const int u = static_cast<int>(rng() % P), v = static_cast<int>(rng() % O);
                const int cx = (hasL && (!hasT || (i & 1))) ? v : u, cy = (hasL && (!hasT || (i & 1))) ? u : v;
                const int k = C.k[static_cast<size_t>(y0 + cy) * W + x0 + cx];
                if (k < 0 || L.occ[static_cast<size_t>(k)].empty()) continue;
                const auto& oc = L.occ[static_cast<size_t>(k)]; const int p = oc[rng() % oc.size()];
                const int gi = p >> 20, sx = (p & 1023) - cx, sy = ((p >> 10) & 1023) - cy;
                if (!usable(static_cast<size_t>(gi), sx, sy)) continue;
                cands.push_back({plan_cost(L.grids[static_cast<size_t>(gi)], sx, sy) + U(rng) * 6.0, gi, sx, sy});
            }
            }
            if (bi < 0) return false;
            const auto& c = cands[static_cast<size_t>(bi)]; const auto& g = L.grids[static_cast<size_t>(c.g)];
            if (getenv("MB_DEBUG") && !g_lm_pull.empty()) { const long h0 = g_pull_hits; const int pc = plan_cost(g, c.sx, c.sy); if (g_pull_hits > h0) fprintf(stderr, "  piece at %d,%d brings a landmark (plan %d, bad %d)\n", x0, y0, pc, bbad); }
            if (R && getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '5') { int n[3] = {0, 0, 0}; for (int y = 0; y < P; ++y) for (int x = 0; x < P; ++x) n[(*R)[static_cast<size_t>(y0 + y) * W + x0 + x] + 1]++; fprintf(stderr, "    patch %d,%d: grid region %d, plan band %d r0 %d r1 %d, bad %d score %.0f\n", x0, y0, L.grid_region[static_cast<size_t>(c.g)], n[0], n[1], n[2], bbad, best); }
            std::vector<uint8_t> take(static_cast<size_t>(P) * P, 1);
            if (hasL) { seam(L, C, x0, y0, g, c.sx, c.sy, P, O, true, &pathL); for (int y = 0; y < P; ++y) for (int x = 0; x < pathL[static_cast<size_t>(y)]; ++x) take[static_cast<size_t>(y) * P + x] = 0; }
            if (hasT) { seam(L, C, x0, y0, g, c.sx, c.sy, P, O, false, &pathT); for (int x = 0; x < P; ++x) for (int y = 0; y < pathT[static_cast<size_t>(x)]; ++y) take[static_cast<size_t>(y) * P + x] = 0; }
            for (int y = 0; y < P; ++y)
                for (int x = 0; x < P; ++x) {
                    const size_t ci = static_cast<size_t>(y0 + y) * W + x0 + x;
                    if (!take[static_cast<size_t>(y) * P + x] && C.k[ci] >= 0) continue;
                    if (fixed(ci)) continue;
                    C.k[ci] = g.at(c.sx + x, c.sy + y);
                    C.org[ci] = c.g << 20 | (c.sy + y) << 10 | (c.sx + x);
                }
            static const bool inc = getenv("MB_INC") != nullptr;   // (tried: did not help)
            if (inc && bbad > 0) {   // mend the new seams now, while the cells right / below are still open
                std::vector<int> before = C.k;
                bbad = fix_as_you_go(L, C.k, W, H, x0 - 1, y0 - 1, x0 + P + 1, y0 + P + 1, rng);
                for (size_t ci = 0; ci < C.k.size(); ++ci) if (C.k[ci] != before[ci]) C.org[ci] = -1;
            }
            *seam_bad += bbad;
        }
    *out = C.k;
    if (g_quilt_org) *g_quilt_org = C.org;
    return true;
}

// ---------------------------------------------------------------- repair
// Re-solve the cells around bad seams, cell by cell, with every other cell
// fixed: arc consistency (support counting) + weighted choice.
extern thread_local uint64_t g_work;
// mixed floor: the planned region of every cell of the whole floor (repairs keep to it)
thread_local const std::vector<int8_t>* g_reg = nullptr; thread_local int g_regW = 0;
thread_local const std::vector<uint64_t>* g_clearset = nullptr;   // (when set: "must walk" cells take only these keys)
struct Repair {
    int ox = 0, oy = 0;   // where this (sub-)grid sits in the floor
    const Lib& L; int W, H;
    std::vector<uint64_t> dom; std::vector<int> cnt; std::vector<uint16_t> sup;
    const std::vector<std::vector<uint16_t>>* nbr;
    std::vector<std::pair<int, int>> rem; bool bad = false; int fail_cell = -1;
    Repair(const Lib& l, int w, int h) : L(l), W(w), H(h), nbr(l.nbr) {}
    uint64_t* D(int c) { return &dom[static_cast<size_t>(c) * L.NW]; }
    bool has(int c, int t) { return (D(c)[t >> 6] >> (t & 63)) & 1; }
    int nb(int c, int d) const { const int x = c % W, y = c / W;
        switch (d) { case 0: return x + 1 < W ? c + 1 : -1; case 1: return x > 0 ? c - 1 : -1; case 2: return y + 1 < H ? c + W : -1; default: return y > 0 ? c - W : -1; } }
    std::vector<int> idx;             // cell -> slot in sup (-1: a fixed cell with only fixed neighbours, never touched)
    uint16_t& S(int c, int d, int t) { return sup[(static_cast<size_t>(idx[static_cast<size_t>(c)]) * 4 + d) * L.N + t]; }
    void remove(int c, int t) { if (!has(c, t)) return; D(c)[t >> 6] &= ~(1ull << (t & 63)); if (--cnt[static_cast<size_t>(c)] == 0) bad = true; rem.push_back({c, t}); }
    bool flush() {
        while (!rem.empty() && !bad) {
            const auto [n, t] = rem.back(); rem.pop_back();
            for (int d = 0; d < 4; ++d) {
                const int c = nb(n, d); if (c < 0 || idx[static_cast<size_t>(c)] < 0) continue;
                for (uint16_t u : nbr[d][static_cast<size_t>(t)]) { uint16_t& s = S(c, d ^ 1, u); if (s && --s == 0) remove(c, u); }
            }
        }
        if (bad) { rem.clear(); return false; }
        return true;
    }
    // sub-grid solve: K is the sub-grid (W x H), free[c] marks cells to re-solve
    bool solve(std::vector<int>& K, const std::vector<uint8_t>& free, std::mt19937& rng, const std::vector<uint8_t>* mustwalk = nullptr) {
        const int cells = W * H;
        std::vector<uint64_t> init(static_cast<size_t>(cells) * L.NW, 0);
        for (int c = 0; c < cells; ++c) {
            uint64_t* d = &init[static_cast<size_t>(c) * L.NW];
            if (free[static_cast<size_t>(c)] || K[static_cast<size_t>(c)] < 0) {
                for (int i = 0; i < L.NW; ++i) d[i] = (i == L.NW - 1 && (L.N & 63)) ? ((1ull << (L.N & 63)) - 1) : ~0ull;
                if (mustwalk && (*mustwalk)[static_cast<size_t>(c)]) { const std::vector<uint64_t>& ws = g_clearset ? *g_clearset : L.walkset; for (int i = 0; i < L.NW; ++i) d[i] &= ws[static_cast<size_t>(i)]; }
                if (g_reg) {   // mixed floor: a cell outside the border band only takes its region's cells
                    const int r = (*g_reg)[static_cast<size_t>(oy + c / W) * g_regW + ox + c % W];
                    if (r >= 0 && r < 8 && !L.region_set[r].empty()) for (int i = 0; i < L.NW; ++i) d[i] &= L.region_set[r][static_cast<size_t>(i)];
                }
            }
            else d[K[static_cast<size_t>(c)] >> 6] |= 1ull << (K[static_cast<size_t>(c)] & 63);
        }
        // cheap first pass: a free cell next to fixed cells can only be what fits
        // all of them (bitset rows) - small domains make everything below fast,
        // and an empty one means this region cannot be solved at all
        for (int c = 0; c < cells; ++c) {
            if (!(free[static_cast<size_t>(c)] || K[static_cast<size_t>(c)] < 0)) continue;
            uint64_t* d = &init[static_cast<size_t>(c) * L.NW];
            for (int dd = 0; dd < 4; ++dd) {
                const int n = nb(c, dd);
                if (n < 0 || free[static_cast<size_t>(n)] || K[static_cast<size_t>(n)] < 0) continue;
                const uint64_t* row = &L.adj[dd ^ 1][static_cast<size_t>(K[static_cast<size_t>(n)]) * L.NW];
                for (int i = 0; i < L.NW; ++i) d[i] &= row[i];
            }
            bool any = false; for (int i = 0; i < L.NW && !any; ++i) any = d[i] != 0;
            if (!any) { fail_cell = c; return false; }
        }
        // only free cells and their neighbours take part; everything else is fixed and consistent
        idx.assign(static_cast<size_t>(cells), -1);
        std::vector<int> active;
        for (int c = 0; c < cells; ++c) {
            bool a = free[static_cast<size_t>(c)] || K[static_cast<size_t>(c)] < 0;
            for (int d = 0; d < 4 && !a; ++d) { const int n = nb(c, d); a = n >= 0 && (free[static_cast<size_t>(n)] || K[static_cast<size_t>(n)] < 0); }
            if (a) { idx[static_cast<size_t>(c)] = static_cast<int>(active.size()); active.push_back(c); }
        }
        std::vector<uint16_t> sup0(active.size() * 4 * static_cast<size_t>(L.N), 0);
        std::vector<int> cnt0(static_cast<size_t>(cells), 0);
        dom = init;
        for (int c = 0; c < cells; ++c) { int k = 0; for (int i = 0; i < L.NW; ++i) k += __builtin_popcountll(D(c)[i]); cnt0[static_cast<size_t>(c)] = k; }
        for (int c : active)
            for (int d = 0; d < 4; ++d) {
                const int n = nb(c, d); uint16_t* o = &sup0[(static_cast<size_t>(idx[static_cast<size_t>(c)]) * 4 + d) * L.N];
                if (n < 0) { std::fill(o, o + L.N, 0xFFFF); continue; }
                if (cnt0[static_cast<size_t>(n)] == L.N) { std::memcpy(o, L.degree[d].data(), sizeof(uint16_t) * L.N); continue; }
                const uint64_t* dn = D(n);
                for (int i = 0; i < L.NW; ++i) { uint64_t b = dn[i]; while (b) { const int u = i * 64 + __builtin_ctzll(b); b &= b - 1; for (uint16_t t : nbr[d ^ 1][static_cast<size_t>(u)]) if (o[t] < 0xFFFE) ++o[t]; } }
            }
        for (int att = 0; att < 8; ++att) {
            g_work += (active.size() * static_cast<size_t>(L.N)) >> 10;
            dom = init; cnt = cnt0; sup = sup0; bad = false; rem.clear();
            for (int c : active) {
                thread_local std::vector<int> ts; ts.clear();
                const uint64_t* dc = D(c);
                for (int i = 0; i < L.NW; ++i) { uint64_t bb = dc[i]; while (bb) { ts.push_back(i * 64 + __builtin_ctzll(bb)); bb &= bb - 1; } }
                for (int t : ts) for (int d = 0; d < 4; ++d) if (S(c, d, t) == 0) { remove(c, t); break; }
            }
            if (!flush()) {
                fail_cell = -1; for (int c = 0; c < cells; ++c) if (!cnt[static_cast<size_t>(c)]) { fail_cell = c; break; }
                if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '2') {
                    int e = -1; for (int c = 0; c < cells; ++c) if (!cnt[static_cast<size_t>(c)]) { e = c; break; }
                    int nfree = 0, badfix = 0; for (int c = 0; c < cells; ++c) nfree += free[static_cast<size_t>(c)];
                    for (int c = 0; c < cells; ++c) if (!free[static_cast<size_t>(c)]) for (int d = 0; d < 4; d += 2) { const int n = nb(c, d); if (n >= 0 && !free[static_cast<size_t>(n)] && !L.ok(d, K[static_cast<size_t>(c)], K[static_cast<size_t>(n)])) ++badfix; }
                    fprintf(stderr, "    repair %dx%d: impossible (empty cell %d,%d free=%d nfree=%d badfixed=%d)\n", W, H, e % W, e / W, e >= 0 ? free[static_cast<size_t>(e)] : -1, nfree, badfix);
                }
                return false;
            }
            bool fail = false;
            for (;;) {
                int best = -1, bc = 1 << 30;
                for (int c : active) { const int n = cnt[static_cast<size_t>(c)]; if (n > 1) { const int s = n * 16 + static_cast<int>(rng() & 15); if (s < bc) { bc = s; best = c; } } }
                if (best < 0) break;
                double tot = 0; uint64_t* d = D(best);
                // keep what was there when it still fits, else prefer what a neighbour
                // already decided continues into (fewer stray specks)
                const int was = K[static_cast<size_t>(best)];
                // how likely each piece is next to the neighbours already decided
                // (as often as that pair stands together in real maps): smooth
                // fills instead of speckled noise
                static const bool mrf = !getenv("MB_NOMRF");
                int dn[4]; int ndec = 0;
                for (int dd = 0; dd < 4; ++dd) {
                    dn[dd] = -1; const int n = nb(best, dd);
                    if (n < 0 || cnt[static_cast<size_t>(n)] != 1) continue;
                    const uint64_t* q = D(n); for (int i = 0; i < L.NW; ++i) if (q[i]) { dn[dd] = i * 64 + __builtin_ctzll(q[i]); break; }
                    ++ndec;
                }
                int preg = -1;
                if (g_reg) { const int gx = ox + best % W, gy = oy + best / W; preg = (*g_reg)[static_cast<size_t>(gy) * g_regW + gx]; }
                int ppath = -1;
                if (L.path_n && !g_pathplan.empty() && g_pathW > 0) { const int gx = ox + best % W, gy = oy + best / W; const size_t pi = static_cast<size_t>(gy) * g_pathW + gx; if (pi < g_pathplan.size()) ppath = g_pathplan[pi]; }
                auto regw = [&](int t) {
                    double r = preg < 0 ? 1.0 : (((L.key_regions[static_cast<size_t>(t)] >> preg) & 1) ? 20.0 : 0.02);
                    if (ppath == 2) r *= L.path[static_cast<size_t>(t)] ? 4.0 : 1.0; else if (ppath == 0 && L.path[static_cast<size_t>(t)]) r *= 0.4;
                    return r;
                };
                auto wt = [&](int t) {
                    double w = L.freq[static_cast<size_t>(t)] * regw(t);
                    if (mrf && ndec) {
                        for (int dd = 0; dd < 4; ++dd) if (dn[dd] >= 0) w *= (L.pc(dd, t, dn[dd]) + 0.05) / L.freq[static_cast<size_t>(t)];
                    }
                    if (t == was) w *= 40.0;
                    return w;
                };
                int pick = -1;
                if (mrf && ndec) {
                    // candidates: pieces really seen next to the decided neighbour
                    // with the shortest list (sparse), still in this cell's domain
                    int bd = -1; size_t bn = ~size_t(0);
                    for (int dd = 0; dd < 4; ++dd) if (dn[dd] >= 0 && L.obs[dd][static_cast<size_t>(dn[dd])].size() < bn) { bn = L.obs[dd][static_cast<size_t>(dn[dd])].size(); bd = dd; }
                    thread_local std::vector<std::pair<int, double>> cw; cw.clear();
                    double ctot = 0;
                    for (const auto& [t, c] : L.obs[bd][static_cast<size_t>(dn[bd])]) {
                        if (!has(best, t)) continue;
                        const double w = wt(t);
                        cw.push_back({t, w}); ctot += w;
                    }
                    if (ctot > 0) {
                        double r = mb_unit(rng) * ctot;
                        for (const auto& [t, w] : cw) { pick = t; r -= w; if (r <= 0) break; }
                    }
                }
                if (pick < 0) {   // nothing seen together: by how common each piece is
                    auto wt0 = [&](int t) { double w = L.freq[static_cast<size_t>(t)] * regw(t); if (t == was) w *= 40.0; return w; };
                    for (int i = 0; i < L.NW; ++i) { uint64_t b = d[i]; while (b) { const int t = i * 64 + __builtin_ctzll(b); b &= b - 1; tot += wt0(t); } }
                    double r = mb_unit(rng) * tot; int last = -1;
                    for (int i = 0; i < L.NW && pick < 0; ++i) { uint64_t b = d[i]; while (b) { const int t = i * 64 + __builtin_ctzll(b); b &= b - 1; last = t; r -= wt0(t); if (r <= 0) { pick = t; break; } } }
                    if (pick < 0) pick = last;
                }
                static const bool slow = getenv("MB_SLOWCOLLAPSE") != nullptr;
                if (slow) { for (int i = 0; i < L.NW; ++i) { uint64_t b = d[i]; while (b) { const int t = i * 64 + __builtin_ctzll(b); b &= b - 1; if (t != pick) remove(best, t); } } }
                else {
                // collapse: the neighbours' supports from this cell are now just "allowed next to pick or not"
                std::memset(d, 0, sizeof(uint64_t) * L.NW); d[pick >> 6] = 1ull << (pick & 63); cnt[static_cast<size_t>(best)] = 1;
                for (int dd = 0; dd < 4 && !bad; ++dd) {
                    const int n = nb(best, dd);
                    if (n < 0) continue;
                    const uint64_t* al = &L.adj[dd][static_cast<size_t>(pick) * L.NW];
                    uint64_t* dn = D(n);
                    for (int i = 0; i < L.NW; ++i) {
                        uint64_t b = dn[i];
                        while (b) {
                            const int u = i * 64 + __builtin_ctzll(b); b &= b - 1;
                            const bool ok = (al[i] >> (u & 63)) & 1;
                            S(n, dd ^ 1, u) = ok ? 1 : 0;
                            if (!ok) remove(n, u);
                        }
                    }
                }
                }
                if (!flush()) { fail = true; fail_cell = best; for (int c = 0; c < cells; ++c) if (!cnt[static_cast<size_t>(c)]) { fail_cell = c; break; } break; }
            }
            if (fail) { if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '2') fprintf(stderr, "    repair %dx%d: contradiction\n", W, H); continue; }
            for (int c = 0; c < cells; ++c) for (int i = 0; i < L.NW; ++i) if (D(c)[i]) { K[static_cast<size_t>(c)] = i * 64 + __builtin_ctzll(D(c)[i]); break; }
            return true;
        }
        return false;
    }
};


// Quilting: mend the bad pairs of a just-laid piece at once. Cells not laid yet
// are open (any piece), so there is far more room than in a finished floor.
void expand_rigid(const Lib& L, const std::vector<int>& K, int W, int H, std::vector<uint8_t>& fr, int maxit);
int fix_as_you_go(const Lib& L, std::vector<int>& K, int W, int H, int x0, int y0, int x1, int y1, std::mt19937& rng) {
    std::vector<uint8_t> mark(static_cast<size_t>(W) * H, 0);
    int nb = count_bad(L, K, W, H, x0, y0, x1, y1, &mark);
    for (int r = 2; r <= 4 && nb > 0; ++r) {
        std::vector<uint8_t> fr(mark.size(), 0);
        int bx0 = W, by0 = H, bx1 = -1, by1 = -1;
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            if (!mark[static_cast<size_t>(y) * W + x]) continue;
            for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx) {
                const int xx = x + dx, yy = y + dy;
                if (xx < 0 || yy < 0 || xx >= W || yy >= H || K[static_cast<size_t>(yy) * W + xx] < 0) continue;
                fr[static_cast<size_t>(yy) * W + xx] = 1;
                bx0 = std::min(bx0, xx); by0 = std::min(by0, yy); bx1 = std::max(bx1, xx); by1 = std::max(by1, yy);
            }
        }
        if (bx1 < 0) break;
        expand_rigid(L, K, W, H, fr, 4);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) if (fr[static_cast<size_t>(y) * W + x]) { bx0 = std::min(bx0, x); by0 = std::min(by0, y); bx1 = std::max(bx1, x); by1 = std::max(by1, y); }
        bx0 = std::max(0, bx0 - 1); by0 = std::max(0, by0 - 1); bx1 = std::min(W - 1, bx1 + 1); by1 = std::min(H - 1, by1 + 1);
        const int sw = bx1 - bx0 + 1, sh = by1 - by0 + 1;
        if (static_cast<size_t>(sw) * sh * 4 * L.N * 2 > (size_t(200) << 20)) break;
        std::vector<int> sub(static_cast<size_t>(sw) * sh); std::vector<uint8_t> sf(sub.size());
        for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) {
            const size_t gi = static_cast<size_t>(by0 + y) * W + bx0 + x;
            sub[static_cast<size_t>(y) * sw + x] = K[gi]; sf[static_cast<size_t>(y) * sw + x] = fr[gi];
        }
        Repair rp(L, sw, sh); rp.ox = bx0; rp.oy = by0;
        if (rp.solve(sub, sf, rng)) {
            for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) if (sf[static_cast<size_t>(y) * sw + x]) K[static_cast<size_t>(by0 + y) * W + bx0 + x] = sub[static_cast<size_t>(y) * sw + x];
            return count_bad(L, K, W, H, x0, y0, x1, y1, nullptr);
        }
    }
    return nb;
}
// A seam nothing can fix locally: put a fresh piece of a real map over the
// whole spot, the one whose border fits its surroundings best (anchored on
// the surrounding tiles, so textures continue in step).
thread_local const std::vector<uint8_t>* g_lock = nullptr;   // cells the mending must leave alone (a landmark)
bool requilt(const Lib& L, std::vector<int>& K, int W, int H, int x0, int y0, int x1, int y1, std::mt19937& rng, std::vector<uint8_t>* touched) {
    x0 = std::max(0, x0); y0 = std::max(0, y0); x1 = std::min(W - 1, x1); y1 = std::min(H - 1, y1);
    const int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
    const int INF = 1 << 29;
    auto cost = [&](const Grid& g, int sx, int sy) {
        if (sx < 0 || sy < 0 || sx + bw > g.w || sy + bh > g.h) return INF;
        if (g_reg) {   // mixed floor: only a piece of the region planned there
            const int gr = L.grid_region[static_cast<size_t>(&g - L.grids.data())];
            for (int y = 0; y < bh; ++y) for (int x = 0; x < bw; ++x) { const int r = (*g_reg)[static_cast<size_t>(y0 + y) * g_regW + x0 + x]; if (r >= 0 && r != gr) return INF; }
        }
        for (int y = 0; y < bh; ++y) for (int x = 0; x < bw; ++x) if (g.at(sx + x, sy + y) < 0) return INF;
        int c = 0;
        for (int y = 0; y < bh; ++y) {
            if (x0 > 0 && !L.ok(0, K[static_cast<size_t>(y0 + y) * W + x0 - 1], g.at(sx, sy + y))) ++c;
            if (x1 < W - 1 && !L.ok(0, g.at(sx + bw - 1, sy + y), K[static_cast<size_t>(y0 + y) * W + x1 + 1])) ++c;
        }
        for (int x = 0; x < bw; ++x) {
            if (y0 > 0 && !L.ok(2, K[static_cast<size_t>(y0 - 1) * W + x0 + x], g.at(sx + x, sy))) ++c;
            if (y1 < H - 1 && !L.ok(2, g.at(sx + x, sy + bh - 1), K[static_cast<size_t>(y1 + 1) * W + x0 + x])) ++c;
        }
        return c;
    };
    int best = INF, bg = -1, bsx = 0, bsy = 0;
    const int per = 2 * (bw + bh);
    for (int i = 0; i < 4000 && best > 0; ++i) {
        // an outside cell next to the spot, and the inside cell it touches
        int t = static_cast<int>(rng() % static_cast<uint32_t>(per)), ox, oy, ix, iy;
        if (t < bw) { ix = x0 + t; iy = y0; ox = ix; oy = y0 - 1; }
        else if ((t -= bw) < bw) { ix = x0 + t; iy = y1; ox = ix; oy = y1 + 1; }
        else if ((t -= bw) < bh) { ix = x0; iy = y0 + t; ox = x0 - 1; oy = iy; }
        else { t -= bh; ix = x1; iy = y0 + t; ox = x1 + 1; oy = iy; }
        if (ox < 0 || oy < 0 || ox >= W || oy >= H) continue;
        const int k = K[static_cast<size_t>(oy) * W + ox];
        if (k < 0 || L.occ[static_cast<size_t>(k)].empty()) continue;
        const auto& oc = L.occ[static_cast<size_t>(k)]; const int p = oc[rng() % oc.size()];
        const int gi = p >> 20, px = (p & 1023) + (ix - ox), py = ((p >> 10) & 1023) + (iy - oy);
        const int sx = px - (ix - x0), sy = py - (iy - y0);
        const int c = cost(L.grids[static_cast<size_t>(gi)], sx, sy);
        if (c < best) { best = c; bg = gi; bsx = sx; bsy = sy; }
    }
    if (bg < 0) return false;
    if (g_lock) for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) if ((*g_lock)[static_cast<size_t>(y) * W + x]) return false;
    // only if it is better than what is there now
    const int now = count_bad(L, K, W, H, x0 - 1, y0 - 1, x1 + 2, y1 + 2, nullptr);
    if (best >= now) return false;
    const Grid& g = L.grids[static_cast<size_t>(bg)];
    for (int y = 0; y < bh; ++y) for (int x = 0; x < bw; ++x) {
        K[static_cast<size_t>(y0 + y) * W + x0 + x] = g.at(bsx + x, bsy + y);
        (*touched)[static_cast<size_t>(y0 + y) * W + x0 + x] = 1;
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "    requilt %dx%d at %d,%d: border bad %d\n", bw, bh, x0, y0, best);
    return true;
}

// Rigid pieces (a hut, a bridge, a big rock: cells that allow only one or two
// neighbours) cannot be cut: a free region that ends inside one can never be
// solved. Grow the region over every such piece it touches.
void expand_rigid(const Lib& L, const std::vector<int>& K, int W, int H, std::vector<uint8_t>& fr, int maxit) {
    static const int kRigid = getenv("MB_RIGID") ? atoi(getenv("MB_RIGID")) : 3;
    for (int it = 0; it < maxit; ++it) {
        std::vector<int> add;
        for (int c = 0; c < W * H; ++c) {
            if (fr[static_cast<size_t>(c)]) continue;
            const int x = c % W, y = c / W, k = K[static_cast<size_t>(c)];
            if (k < 0) continue;
            // direction from c to the free neighbour: 0 right, 1 left, 2 down, 3 up
            const int nbs[4] = {x + 1 < W ? c + 1 : -1, x > 0 ? c - 1 : -1, y + 1 < H ? c + W : -1, y > 0 ? c - W : -1};
            for (int d = 0; d < 4; ++d) if (nbs[d] >= 0 && fr[static_cast<size_t>(nbs[d])] && L.degree[d][static_cast<size_t>(k)] <= kRigid) { add.push_back(c); break; }
        }
        if (g_lock) add.erase(std::remove_if(add.begin(), add.end(), [](int c) { return (*g_lock)[static_cast<size_t>(c)] != 0; }), add.end());
        if (add.empty()) return;
        for (int c : add) fr[static_cast<size_t>(c)] = 1;
    }
}
// time budget of one build (a floor that takes longer is given up: the area keeps its map)
// Counted in work units, not seconds: two PCs of an online game must give up
// on exactly the same floor (a time limit would depend on the PC's speed).
thread_local std::chrono::steady_clock::time_point g_deadline = std::chrono::steady_clock::time_point::max();
thread_local uint64_t g_work = 0, g_work_max = ~0ull;
thread_local int g_push = 16;   // the final push mends up to this many bad pairs one by one
bool over_time() { return g_work > g_work_max || std::chrono::steady_clock::now() > g_deadline; }
// fix every bad pair: grow a free region around each cluster, solve it in a sub-grid
int repair_all(const Lib& L, std::vector<int>& K, int W, int H, std::mt19937& rng, std::vector<uint8_t>* touched) {
    const int kGrow = getenv("MB_GROW") ? atoi(getenv("MB_GROW")) : 6;
    int last_bad = 1 << 30;
    for (int pass = 0; pass < 5; ++pass) {
        std::vector<uint8_t> mark(static_cast<size_t>(W) * H, 0);
        const int nb0 = count_bad(L, K, W, H, 0, 0, W, H, &mark);
        if (getenv("MB_DEBUG")) fprintf(stderr, "  repair pass %d: %d bad\n", pass, nb0);
        if (nb0 == 0) return 0;
        if (pass > 0 && nb0 >= last_bad) break;   // no progress: on to the final push
        last_bad = nb0;
        const int R = 1 + pass;
        std::vector<uint8_t> fr(mark.size(), 0);
        auto dil = [&](int x, int y, int r) { for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx) { const int xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < W && yy < H && !(g_lock && (*g_lock)[static_cast<size_t>(yy) * W + xx])) fr[static_cast<size_t>(yy) * W + xx] = 1; } };
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) if (mark[static_cast<size_t>(y) * W + x]) dil(x, y, R);
        if (!getenv("MB_NORIGID")) expand_rigid(L, K, W, H, fr, 6);
        if (g_lock) for (size_t c = 0; c < fr.size(); ++c) if ((*g_lock)[c]) fr[c] = 0;
        std::vector<uint8_t> done(mark.size(), 0);
        for (int s0 = 0; s0 < W * H; ++s0) {
            if (!fr[static_cast<size_t>(s0)] || done[static_cast<size_t>(s0)]) continue;
            if (over_time()) return count_bad(L, K, W, H, 0, 0, W, H, nullptr);
            // grow this cluster where the solver gets stuck, up to a limit;
            // if it still cannot be solved, lay a fresh piece over it
            bool solved_it = false; int cx0 = W, cy0 = H, cx1 = -1, cy1 = -1;
            for (int grow = 0; grow < kGrow; ++grow) {
                std::vector<int> q{s0}; std::vector<uint8_t> in(mark.size(), 0); in[static_cast<size_t>(s0)] = 1;
                int x0 = W, y0 = H, x1 = 0, y1 = 0;
                for (size_t h = 0; h < q.size(); ++h) {
                    const int c = q[h], x = c % W, y = c / W;
                    x0 = std::min(x0, x); x1 = std::max(x1, x); y0 = std::min(y0, y); y1 = std::max(y1, y);
                    const int nbs[4] = {x + 1 < W ? c + 1 : -1, x > 0 ? c - 1 : -1, y + 1 < H ? c + W : -1, y > 0 ? c - W : -1};
                    for (int n : nbs) if (n >= 0 && fr[static_cast<size_t>(n)] && !in[static_cast<size_t>(n)]) { in[static_cast<size_t>(n)] = 1; q.push_back(n); }
                }
                for (int c : q) done[static_cast<size_t>(c)] = 1;
                if (grow == 0) { cx0 = x0; cy0 = y0; cx1 = x1; cy1 = y1; }
                const int bx0 = std::max(0, x0 - 1), by0 = std::max(0, y0 - 1), bx1 = std::min(W - 1, x1 + 1), by1 = std::min(H - 1, y1 + 1);
                const int sw = bx1 - bx0 + 1, sh = by1 - by0 + 1;
                if (static_cast<size_t>(sw) * sh * 4 * L.N * 2 > (size_t(300) << 20)) break;
                std::vector<int> sub(static_cast<size_t>(sw) * sh); std::vector<uint8_t> sf(sub.size());
                for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) {
                    const size_t gi = static_cast<size_t>(by0 + y) * W + bx0 + x;
                    sub[static_cast<size_t>(y) * sw + x] = K[gi]; sf[static_cast<size_t>(y) * sw + x] = in[gi];
                }
                Repair rp(L, sw, sh); rp.ox = bx0; rp.oy = by0;
                const auto ts0 = std::chrono::steady_clock::now();
                const bool solved = rp.solve(sub, sf, rng);
                if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '3') { int nf = 0; for (auto v : sf) nf += v; fprintf(stderr, "    solve %dx%d free %d: %s %.0f ms\n", sw, sh, nf, solved ? "ok" : "FAIL", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - ts0).count()); }
                if (solved) {
                    for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) if (sf[static_cast<size_t>(y) * sw + x]) { K[static_cast<size_t>(by0 + y) * W + bx0 + x] = sub[static_cast<size_t>(y) * sw + x]; (*touched)[static_cast<size_t>(by0 + y) * W + bx0 + x] = 1; }
                    solved_it = true;
                    break;
                }
                if (rp.fail_cell < 0) break;
                const int fx = bx0 + rp.fail_cell % sw, fy = by0 + rp.fail_cell / sw;
                dil(fx, fy, 2 + grow / 3);
                if (!fr[static_cast<size_t>(s0)]) break;
            }
            if (!solved_it && cx1 >= 0) requilt(L, K, W, H, cx0 - 2, cy0 - 2, std::max(cx1 + 2, cx0 + 7), std::max(cy1 + 2, cy0 + 7), rng, touched);
            if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '6') fprintf(stderr, "    cluster at %d,%d: %s, now %d bad\n", s0 % W, s0 / W, solved_it ? "solved" : "requilt", count_bad(L, K, W, H, 0, 0, W, H, nullptr));
        }
    }
    // last few bad pairs: re-solve a whole square around each one, growing
    // (every cell of the square free, its border fixed), then a fresh piece
    int left = count_bad(L, K, W, H, 0, 0, W, H, nullptr);
    static const int kPushEnv = getenv("MB_PUSH") ? atoi(getenv("MB_PUSH")) : -1;
    const int kPush = kPushEnv >= 0 ? kPushEnv : g_push;
    if (left > 0 && left <= kPush) {
        for (int round = 0; round < 3 && left > 0; ++round) {
            std::vector<uint8_t> mark(static_cast<size_t>(W) * H, 0);
            count_bad(L, K, W, H, 0, 0, W, H, &mark);
            for (int c0 = 0; c0 < W * H; ++c0) {
                if (!mark[static_cast<size_t>(c0)]) continue;
                if (over_time()) break;
                const int px = c0 % W, py = c0 / W;
                if (count_bad(L, K, W, H, px - 1, py - 1, px + 2, py + 2, nullptr) == 0) continue;   // fixed by a neighbour's square
                bool fixed = false;
                for (int r = 3 + round; r <= 9 + round * 2 && !fixed; r += 2) {
                    std::vector<uint8_t> fm(static_cast<size_t>(W) * H, 0);
                    for (int y = std::max(0, py - r); y <= std::min(H - 1, py + r); ++y) for (int x = std::max(0, px - r); x <= std::min(W - 1, px + r); ++x) fm[static_cast<size_t>(y) * W + x] = 1;
                    if (!getenv("MB_NORIGID")) expand_rigid(L, K, W, H, fm, 10);
                    if (g_lock) for (size_t c = 0; c < fm.size(); ++c) if ((*g_lock)[c]) fm[c] = 0;
                    int fx0 = W, fy0 = H, fx1 = -1, fy1 = -1;
                    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) if (fm[static_cast<size_t>(y) * W + x]) { fx0 = std::min(fx0, x); fx1 = std::max(fx1, x); fy0 = std::min(fy0, y); fy1 = std::max(fy1, y); }
                    const int bx0 = std::max(0, fx0 - 1), by0 = std::max(0, fy0 - 1), bx1 = std::min(W - 1, fx1 + 1), by1 = std::min(H - 1, fy1 + 1);
                    const int sw = bx1 - bx0 + 1, sh = by1 - by0 + 1;
                    if (static_cast<size_t>(sw) * sh * 4 * L.N * 2 > (size_t(300) << 20)) break;
                    std::vector<int> sub(static_cast<size_t>(sw) * sh); std::vector<uint8_t> sf(sub.size(), 0);
                    for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) {
                        sub[static_cast<size_t>(y) * sw + x] = K[static_cast<size_t>(by0 + y) * W + bx0 + x];
                        sf[static_cast<size_t>(y) * sw + x] = fm[static_cast<size_t>(by0 + y) * W + bx0 + x];
                    }
                    Repair rp(L, sw, sh); rp.ox = bx0; rp.oy = by0;
                    const bool okk = rp.solve(sub, sf, rng);
                    if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '4') { int nf = 0; for (auto v : sf) nf += v; fprintf(stderr, "    push at %d,%d r=%d box %dx%d free %d: %s (fail cell %d,%d)\n", px, py, r, sw, sh, nf, okk ? "ok" : "FAIL", rp.fail_cell >= 0 ? bx0 + rp.fail_cell % sw : -1, rp.fail_cell >= 0 ? by0 + rp.fail_cell / sw : -1); }
                    if (okk) {
                        for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) if (sf[static_cast<size_t>(y) * sw + x]) { K[static_cast<size_t>(by0 + y) * W + bx0 + x] = sub[static_cast<size_t>(y) * sw + x]; (*touched)[static_cast<size_t>(by0 + y) * W + bx0 + x] = 1; }
                        fixed = true;
                    }
                }
                if (!fixed) for (int t = 0; t < 4 && !fixed; ++t) { const int r = 4 + t * 2; fixed = requilt(L, K, W, H, px - r, py - r, px + r, py + r, rng, touched) && count_bad(L, K, W, H, px - r - 1, py - r - 1, px + r + 2, py + r + 2, nullptr) == 0; }
            }
            const int now = count_bad(L, K, W, H, 0, 0, W, H, nullptr);
            if (getenv("MB_DEBUG")) fprintf(stderr, "  final push %d: %d -> %d bad\n", round, left, now);
            if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '4')
                for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                    const int ka = K[static_cast<size_t>(y) * W + x];
                    if (x + 1 < W && !L.ok(0, ka, K[static_cast<size_t>(y) * W + x + 1])) fprintf(stderr, "    bad R at %d,%d keys %d(deg %d, walk %d) %d(deg %d)\n", x, y, ka, L.degree[0][ka], L.walk[ka], K[static_cast<size_t>(y) * W + x + 1], L.degree[1][K[static_cast<size_t>(y) * W + x + 1]]);
                    if (y + 1 < H && !L.ok(2, ka, K[static_cast<size_t>(y + 1) * W + x])) fprintf(stderr, "    bad D at %d,%d keys %d(deg %d, walk %d) %d(deg %d)\n", x, y, ka, L.degree[2][ka], L.walk[ka], K[static_cast<size_t>(y + 1) * W + x], L.degree[3][K[static_cast<size_t>(y + 1) * W + x]]);
                }
            left = now;
        }
    }
    return left;
}

// ---------------------------------------------------------------- landmarks
// A real feature of the area's maps (a hut, a pond, a camp, a big rock - a
// piece of solid things standing in open ground) put whole into a clearing,
// so a floor has places you remember, not only a pattern. Its surroundings
// are then re-solved to meet it; the way through stays open (connect below).
struct Landmark { int g, sx, sy, w, h, score; };
std::vector<Landmark> find_landmarks(const Lib& L, int zone) {
    std::vector<Landmark> out;
    static const int kRig = 3;
    static const bool strict = getenv("MB_LMSTRICT") != nullptr;
    static const int kCommon = getenv("MB_LMCOMMON") ? atoi(getenv("MB_LMCOMMON")) : 12;
    static const int kPlain = getenv("MB_LMPLAIN") ? atoi(getenv("MB_LMPLAIN")) : 4;   // a key with this few neighbours on some side is part of something
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        if (gi < L.grid_zone.size() && L.grid_zone[gi] != zone) continue;
        const Grid& g = L.grids[gi];
        {   // a map of the area's usual tiles (not one drawn with a set of its own: nothing else would meet it)
            int n = 0, shared = 0;
            for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
                const int k = g.at(x, y); if (k < 0) continue; ++n;
                for (int p : L.occ[static_cast<size_t>(k)]) if (static_cast<size_t>(p >> 20) != gi) { ++shared; break; }
            }
            static const double kShare = getenv("MB_LMSHARE") ? atof(getenv("MB_LMSHARE")) : 0.6;
            if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '7') fprintf(stderr, "  grid %zu: %dx%d, %.2f of its cells seen elsewhere\n", gi, g.w, g.h, n ? static_cast<double>(shared) / n : 0.0);
            if (!n || shared < n * kShare) continue;
        }
        static const int sizes[5][2] = {{12, 9}, {10, 8}, {14, 10}, {8, 7}, {16, 12}};
        for (const auto& sz : sizes) {
            const int w = sz[0], h = sz[1];
            for (int sy = 0; sy + h <= g.h; sy += 2)
                for (int sx = 0; sx + w <= g.w; sx += 2) {
                    bool ok = true; int solid = 0, rigid = 0, walk_in = 0, edge_block = 0;
                    const int edge_max = (w + h) / 3;   // it stands in open ground (mostly)
                    for (int y = 0; y < h && ok; ++y) for (int x = 0; x < w && ok; ++x) {
                        const int k = g.at(sx + x, sy + y);
                        if (k < 0) { ok = false; break; }
                        const bool edge = x == 0 || y == 0 || x == w - 1 || y == h - 1;
                        const bool edge2 = x <= 1 || y <= 1 || x >= w - 2 || y >= h - 2;
                        const bool wk = L.walk[static_cast<size_t>(k)] != 0;
                        int dm = 1 << 20; for (int d = 0; d < 4; ++d) dm = std::min(dm, static_cast<int>(L.degree[d][static_cast<size_t>(k)]));
                        if (edge && strict && (!wk || dm <= kPlain)) { ok = false; break; }   // wholly inside: nothing of it runs on out of the window
                        if (edge && static_cast<int>(L.occ[static_cast<size_t>(k)].size()) < kCommon) { ok = false; break; }   // its edge is common ground (no layer's picture runs on out of it)
                        (void)edge2;
                        if (edge) { if (!wk && ++edge_block > edge_max) ok = false; continue; }
                        if (!wk) ++solid; else ++walk_in;
                        int dmin = 1 << 20; for (int d = 0; d < 4; ++d) dmin = std::min(dmin, static_cast<int>(L.degree[d][static_cast<size_t>(k)]));
                        if (dmin <= kRig) ++rigid;
                    }
                    if (!ok) continue;
                    const int inner = (w - 2) * (h - 2);
                    if (solid < inner / 6 || solid > inner * 4 / 5 || rigid < 4) continue;
                    out.push_back({static_cast<int>(gi), sx, sy, w, h, rigid + solid / 2});
                }
        }
    }
    std::stable_sort(out.begin(), out.end(), [](const Landmark& a, const Landmark& b) { return a.score > b.score; });
    // one per spot of the source maps (overlapping windows show the same thing)
    std::vector<Landmark> uniq;
    for (const auto& c : out) {
        bool dup = false;
        for (const auto& u : uniq) if (u.g == c.g && std::abs(u.sx - c.sx) < 8 && std::abs(u.sy - c.sy) < 6) { dup = true; break; }
        if (!dup) uniq.push_back(c);
        if (uniq.size() >= 24) break;
    }
    return uniq;
}
void place_landmarks(const Lib& L, std::vector<int>& K, int W, int H, int zone, std::mt19937& rng, std::vector<uint8_t>* touched) {
    if (getenv("MB_NOLANDMARK") || g_rooms.empty()) return;
    static thread_local std::vector<Landmark> cache; static thread_local uint64_t cache_lib = 0;
    if (cache_lib != L.serial) { cache = find_landmarks(L, zone); cache_lib = L.serial; if (getenv("MB_DEBUG")) fprintf(stderr, "  landmarks found: %zu (zone %d, %zu grids)\n", cache.size(), zone, L.grids.size()); }
    if (cache.empty()) return;
    int placed = 0;
    std::vector<uint8_t> have(K.size(), 0);   // landmarks already standing (kept whole by later ones)
    const uint64_t work0 = g_work;   // (the floor's own work budget is not spent on these: they are a bonus)
    int tries = 0;
    std::vector<size_t> order(std::min<size_t>(cache.size(), 16));
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    mb_shuffle(order.begin(), order.end(), rng);
    size_t next = 0;
    for (const Room& r : g_rooms) for (int pick = 0; pick < 3; ++pick) {
        if (placed >= 2 || tries >= 24) break;
        const Landmark& lm = cache[order[next++ % order.size()]];
        const Grid& g = L.grids[static_cast<size_t>(lm.g)];
        bool done = false;
        for (int mg = 3; mg >= 1 && !done; mg -= 2) {
            // a place in the clearing away from the path, where the ground around the
            // feature already meets the floor's ground best (the same tiles in the same
            // phase: then the seam has little to mend)
            int best_x = -1, best_y = -1, best_s = -1;
            const int rcx = (r.x0 + r.x1) / 2, rcy = (r.y0 + r.y1) / 2;
            for (int y0 = rcy - lm.h / 2 - 12; y0 <= rcy - lm.h / 2 + 12; ++y0) for (int x0 = rcx - lm.w / 2 - 14; x0 <= rcx - lm.w / 2 + 14; ++x0) {
                if (x0 - mg < 2 || y0 - mg < 2 || x0 + lm.w + mg > W - 2 || y0 + lm.h + mg > H - 2) continue;
                bool clear = true;
                for (int y = 0; y < lm.h && clear; ++y) for (int x = 0; x < lm.w && clear; ++x) {
                    const size_t i = static_cast<size_t>(y0 + y) * W + x0 + x;
                    if (!g_pathplan.empty() && g_pathW == W && g_pathplan[i] == 2) clear = false;   // not on the path itself
                }
                for (int y = -mg - 2; y < lm.h + mg + 2 && clear; ++y) for (int x = -mg - 2; x < lm.w + mg + 2 && clear; ++x) {
                    const int xx = x0 + x, yy = y0 + y;
                    if (xx >= 0 && yy >= 0 && xx < W && yy < H && have[static_cast<size_t>(yy) * W + xx]) clear = false;   // not onto another one
                }
                if (!clear) continue;
                int sc = 0;
                for (int y = -mg - 1; y < lm.h + mg + 1; ++y) for (int x = -mg - 1; x < lm.w + mg + 1; ++x) {
                    const bool ring = x == -mg - 1 || y == -mg - 1 || x == lm.w + mg || y == lm.h + mg;
                    if (!ring) continue;
                    const int gx = lm.sx + x, gy = lm.sy + y;
                    if (gx < 0 || gy < 0 || gx >= g.w || gy >= g.h) continue;
                    const int k = g.at(gx, gy);
                    if (k >= 0 && k == K[static_cast<size_t>(y0 + y) * W + x0 + x]) sc += 2;
                    else if (k >= 0 && L.walk[static_cast<size_t>(k)] && L.walk[static_cast<size_t>(K[static_cast<size_t>(y0 + y) * W + x0 + x])]) sc += 0;
                    else sc -= 1;
                }
                const int ddx = x0 + lm.w / 2 - rcx, ddy = y0 + lm.h / 2 - rcy;
                sc = sc * 4 - (std::abs(ddx) + std::abs(ddy));   // the ground meeting it counts most; near the clearing next
                if (best_x < 0 || sc > best_s) { best_s = sc; best_x = x0; best_y = y0; }
            }
            if (best_x < 0) { if (getenv("MB_DEBUG")) fprintf(stderr, "  landmark: no free spot in room %d,%d-%d,%d\n", r.x0, r.y0, r.x1, r.y1); continue; }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  landmark spot score %d\n", best_s);
            std::vector<int> K2 = K;
            std::vector<uint8_t> t2 = *touched;
            for (int y = -mg; y < lm.h + mg; ++y) for (int x = -mg; x < lm.w + mg; ++x) {
                const int gx = lm.sx + x, gy = lm.sy + y, fx = best_x + x, fy = best_y + y;
                if (gx < 0 || gy < 0 || gx >= g.w || gy >= g.h || fx < 0 || fy < 0 || fx >= W || fy >= H) continue;
                const int k = g.at(gx, gy); if (k < 0) continue;
                K2[static_cast<size_t>(fy) * W + fx] = k; t2[static_cast<size_t>(fy) * W + fx] = 1;
            }
            std::vector<uint8_t> lock = have;
            static const int lock_mode = getenv("MB_LMLOCK") ? atoi(getenv("MB_LMLOCK")) : 2;
            static const int lm_plain = getenv("MB_LMPLAIN") ? atoi(getenv("MB_LMPLAIN")) : 4;
            for (int y = 1; y < lm.h - 1; ++y) for (int x = 1; x < lm.w - 1; ++x) {
                bool lk = true;
                if (lock_mode == 3) { const int k = g.at(lm.sx + x, lm.sy + y); lk = k >= 0 && !L.walk[static_cast<size_t>(k)]; }   // only its solid things
                else if (lock_mode == 2) {   // its solid things and every piece that belongs to something (few neighbours): plain ground may change
                    const int k = g.at(lm.sx + x, lm.sy + y);
                    int dm = 1 << 20; if (k >= 0) for (int d = 0; d < 4; ++d) dm = std::min(dm, static_cast<int>(L.degree[d][static_cast<size_t>(k)]));
                    lk = k >= 0 && (!L.walk[static_cast<size_t>(k)] || dm <= lm_plain);
                }
                else if (lock_mode == 1) {   // only its solid things and what touches them: the open ground around may change
                    lk = false;
                    for (int dy = -1; dy <= 1 && !lk; ++dy) for (int dx = -1; dx <= 1 && !lk; ++dx) {
                        const int k = g.at(lm.sx + x + dx, lm.sy + y + dy);
                        if (k >= 0 && !L.walk[static_cast<size_t>(k)]) lk = true;
                    }
                }
                if (lk) lock[static_cast<size_t>(best_y + y) * W + best_x + x] = 1;
            }
            const uint64_t w0 = g_work;
            ++tries;
            // first: the whole band around it solved as one piece (its outside fixed)
            static const bool band_on = !getenv("MB_NOBAND");
            for (int b = 2; band_on && b <= 8; b += 3) {
                if (count_bad(L, K2, W, H, 0, 0, W, H, nullptr) == 0) break;
                std::vector<uint8_t> fm(K.size(), 0);
                const int e = mg + b;
                for (int y = -e; y < lm.h + e; ++y) for (int x = -e; x < lm.w + e; ++x) {
                    const int xx = best_x + x, yy = best_y + y;
                    if (xx >= 1 && yy >= 1 && xx < W - 1 && yy < H - 1) fm[static_cast<size_t>(yy) * W + xx] = 1;
                }
                // (the pasted margin stays only where it is part of the feature: everything unlocked may change)
                for (size_t c = 0; c < fm.size(); ++c) if (lock[c]) fm[c] = 0;
                int fx0 = W, fy0 = H, fx1 = -1, fy1 = -1;
                for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) if (fm[static_cast<size_t>(y) * W + x]) { fx0 = std::min(fx0, x); fx1 = std::max(fx1, x); fy0 = std::min(fy0, y); fy1 = std::max(fy1, y); }
                const int bx0 = std::max(0, fx0 - 1), by0 = std::max(0, fy0 - 1), bx1 = std::min(W - 1, fx1 + 1), by1 = std::min(H - 1, fy1 + 1);
                const int sw = bx1 - bx0 + 1, sh = by1 - by0 + 1;
                if (static_cast<size_t>(sw) * sh * 4 * L.N * 2 > (size_t(300) << 20)) break;
                std::vector<int> sub(static_cast<size_t>(sw) * sh); std::vector<uint8_t> sf(sub.size(), 0);
                for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) {
                    sub[static_cast<size_t>(y) * sw + x] = K2[static_cast<size_t>(by0 + y) * W + bx0 + x];
                    sf[static_cast<size_t>(y) * sw + x] = fm[static_cast<size_t>(by0 + y) * W + bx0 + x];
                }
                Repair rp(L, sw, sh); rp.ox = bx0; rp.oy = by0;
                const bool okk = rp.solve(sub, sf, rng);
                if (getenv("MB_DEBUG")) { const int fcx = rp.fail_cell >= 0 ? bx0 + rp.fail_cell % sw - best_x : -99, fcy = rp.fail_cell >= 0 ? by0 + rp.fail_cell / sw - best_y : -99;
                    int inb = count_bad(L, K2, W, H, best_x, best_y, best_x + lm.w, best_y + lm.h, nullptr);
                    fprintf(stderr, "    band %d (%dx%d): %s fail at %d,%d of %dx%d (bad inside %d)\n", b, sw, sh, okk ? "ok" : "FAIL", fcx, fcy, lm.w, lm.h, inb); }
                if (okk) {
                    for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) if (sf[static_cast<size_t>(y) * sw + x]) { K2[static_cast<size_t>(by0 + y) * W + bx0 + x] = sub[static_cast<size_t>(y) * sw + x]; t2[static_cast<size_t>(by0 + y) * W + bx0 + x] = 1; }
                    break;
                }
            }
            g_lock = &lock;
            const int left = count_bad(L, K2, W, H, 0, 0, W, H, nullptr) == 0 ? 0 : (getenv("MB_LMREPAIR") ? repair_all(L, K2, W, H, rng, &t2) : 999);
            g_lock = nullptr;
            // the landmark must still be there (the mending may not have painted over it)
            int kept = 0;
            int solid = 0, solid_kept = 0;
            for (int y = 0; y < lm.h; ++y) for (int x = 0; x < lm.w; ++x) {
                const int k0 = g.at(lm.sx + x, lm.sy + y); const bool same = K2[static_cast<size_t>(best_y + y) * W + best_x + x] == k0;
                kept += same; if (k0 >= 0 && !L.walk[static_cast<size_t>(k0)]) { ++solid; solid_kept += same; }
            }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  landmark %dx%d margin %d: %d bad left, %d of %d cells kept, work %llu\n", lm.w, lm.h, mg, left, kept, lm.w * lm.h, static_cast<unsigned long long>(g_work - w0));
            if (left == 0 && kept * 10 >= lm.w * lm.h * 6 && solid_kept * 10 >= solid * 9) {
                K = K2; *touched = t2; done = true; ++placed;
                for (int y = 1; y < lm.h - 1; ++y) for (int x = 1; x < lm.w - 1; ++x) have[static_cast<size_t>(best_y + y) * W + best_x + x] = 1;
            }
        }
        if (done) break;   // one per clearing
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "  landmarks placed: %d (%d tries, work %llu)\n", placed, tries, static_cast<unsigned long long>(g_work - work0));
    g_work = work0;
    {

    }
}
// Landmarks laid down first: the quilting then seams its pieces onto them (and
// the pieces that continue a landmark's own surroundings fit it best), so the
// feature comes with real ground around it instead of a mended ring.
struct Seeded { int x, y, w, h, g, sx, sy; };
// water (rivers / lakes): windows of the area's real water - its bed, banks and all - one of them
// seeded into the floor; the quilt then carries it on the way the real map does
std::vector<Landmark> find_water_windows(const Lib& L, int zone, int lay) {
    std::vector<Landmark> out;
    if (L.liquid.empty()) return out;
    static const int sizes[3][2] = {{16, 12}, {14, 10}, {18, 13}};
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        if (gi < L.grid_zone.size() && L.grid_zone[gi] != zone) continue;
        const Grid& g = L.grids[gi];
        for (const auto& sz : sizes) {
            const int w = sz[0], h = sz[1];
            for (int sy = 0; sy + h <= g.h; sy += 2) for (int sx = 0; sx + w <= g.w; sx += 2) {
                int lq = 0, eL = 0, eR = 0, eT = 0, eB = 0; bool ok = true;
                for (int y = 0; y < h && ok; ++y) for (int x = 0; x < w; ++x) {
                    const int k = g.at(sx + x, sy + y);
                    if (k < 0) { ok = false; break; }
                    if (!L.liquid[static_cast<size_t>(k)]) continue;
                    ++lq; if (x == 0) ++eL; if (x == w - 1) ++eR; if (y == 0) ++eT; if (y == h - 1) ++eB;
                }
                if (!ok) continue;
                const int area = w * h;
                if (lq * 4 < area || lq * 100 > area * 60) continue;
                const bool cross = (eL && eR) || (eT && eB);
                const int sides = (eL > 0) + (eR > 0) + (eT > 0) + (eB > 0);
                if (lay == 2 && !cross) continue;
                int sc = lq + (lay == 2 ? 0 : (4 - sides) * 40);
                out.push_back({static_cast<int>(gi), sx, sy, w, h, sc});
            }
        }
    }
    std::stable_sort(out.begin(), out.end(), [](const Landmark& a, const Landmark& b) { return a.score > b.score; });
    std::vector<Landmark> uniq;
    for (const auto& c : out) {
        bool dup = false;
        for (const auto& u : uniq) if (u.g == c.g && std::abs(u.sx - c.sx) < 10 && std::abs(u.sy - c.sy) < 8) { dup = true; break; }
        if (!dup) uniq.push_back(c);
        if (uniq.size() >= 16) break;
    }
    return uniq;
}
bool has_water_windows(const Lib& L, int zone, int lay) {   // (cached per library: a land without water of its own just gets an open field)
    static thread_local uint64_t lib = 0; static thread_local int ly = -1; static thread_local bool r = false;
    if (lib != L.serial || ly != lay) { lib = L.serial; ly = lay; r = !find_water_windows(L, zone, lay).empty() || (lay == 3 && !find_water_windows(L, zone, 2).empty()); }
    return r;
}
std::vector<Seeded> seed_landmarks(const Lib& L, int W, int H, int zone, std::mt19937& rng,
                                   std::vector<int>* sk, std::vector<int>* so, std::vector<uint8_t>* lock, int P0, int O0,
                                   const std::vector<uint8_t>& allowed, const std::vector<int>& org0,
                                   const std::vector<Landmark>* water = nullptr, int tcx = -1, int tcy = -1) {
    const int P = getenv("MB_P") ? atoi(getenv("MB_P")) : P0, O = getenv("MB_O") ? atoi(getenv("MB_O")) : O0, step = P - O;
    std::vector<int> ys, xs;   // the quilt's piece corners (as in quilt())
    for (int y = 0; y + P < H; y += step) ys.push_back(y);
    if (ys.empty() || ys.back() != H - P) ys.push_back(H - P);
    for (int x = 0; x + P < W; x += step) xs.push_back(x);
    if (xs.empty() || xs.back() != W - P) xs.push_back(W - P);
    std::vector<Seeded> out;
    sk->assign(static_cast<size_t>(W) * H, -1); so->assign(sk->size(), -1); lock->assign(sk->size(), 0);
    if (!water && (getenv("MB_NOLANDMARK") || g_rooms.empty())) return out;
    static thread_local std::vector<Landmark> lcache; static thread_local uint64_t cache_lib = 0;
    if (!water && cache_lib != L.serial) { lcache = find_landmarks(L, zone); cache_lib = L.serial; if (getenv("MB_DEBUG")) fprintf(stderr, "  landmarks found: %zu (zone %d, %zu grids)\n", lcache.size(), zone, L.grids.size()); }
    const std::vector<Landmark>& cache = water ? *water : lcache;
    if (cache.empty()) return out;
    static const int kMaxL = getenv("MB_LANDMARKS") ? atoi(getenv("MB_LANDMARKS")) : 2;
    const int kMax = water ? 1 : kMaxL;
    std::vector<size_t> order;   // (only from maps drawn like the floor around: the pieces it is made of)
    for (size_t i = 0; i < cache.size() && order.size() < 12; ++i)
        if (water || (static_cast<size_t>(cache[i].g) < allowed.size() && allowed[static_cast<size_t>(cache[i].g)])) order.push_back(i);
    if (getenv("MB_DEBUG")) fprintf(stderr, "  %s: %zu\n", water ? "water windows" : "landmarks of the floor's own look", order.size());
    if (order.empty()) return out;
    mb_shuffle(order.begin(), order.end(), rng);
    std::vector<size_t> rooms(water ? std::min<size_t>(order.size(), 6) : g_rooms.size());   // (water: one spot, a few windows tried there)
    for (size_t i = 0; i < rooms.size(); ++i) rooms[i] = i;
    if (!water) mb_shuffle(rooms.begin(), rooms.end(), rng);
    size_t next = 0;
    for (size_t ri : rooms) {
        if (static_cast<int>(out.size()) >= kMax) break;
        const Landmark& lm = cache[order[next++ % order.size()]];
        const int rcx = water ? tcx : (g_rooms[ri].x0 + g_rooms[ri].x1) / 2, rcy = water ? tcy : (g_rooms[ri].y0 + g_rooms[ri].y1) / 2;
        // the ground's pattern runs in step with the pieces around (a checkered or striped
        // ground a cell out of step meets nothing): the same offset from its map, mod 4
        int phx = -1, phy = -1;
        if (org0.size() == sk->size()) {
            int hist[16] = {0};
            for (int y = std::max(0, rcy - 14); y < std::min(H, rcy + 14); ++y) for (int x = std::max(0, rcx - 16); x < std::min(W, rcx + 16); ++x) {
                const int o = org0[static_cast<size_t>(y) * W + x]; if (o < 0) continue;
                const int ox = (o & 1023) - x, oy = ((o >> 10) & 1023) - y;
                ++hist[((ox % 4 + 4) % 4) * 4 + ((oy % 4 + 4) % 4)];
            }
            int bi = 0; for (int i = 1; i < 16; ++i) if (hist[i] > hist[bi]) bi = i;
            if (hist[bi] > 0) { phx = bi / 4; phy = bi % 4; }
        }
        int bx = -1, by = -1, bs = 1 << 30;
        for (int y0 = rcy - lm.h / 2 - 10; y0 <= rcy - lm.h / 2 + 10; ++y0) for (int x0 = rcx - lm.w / 2 - 12; x0 <= rcx - lm.w / 2 + 12; ++x0) {
            if (x0 < 4 || y0 < 4 || x0 + lm.w > W - 4 || y0 + lm.h > H - 4) continue;
            if (phx >= 0 && (((lm.sx - x0) % 4 + 4) % 4 != phx || ((lm.sy - y0) % 4 + 4) % 4 != phy)) continue;
            bool clear = true;
            for (int y = 0; y < lm.h && clear && !water; ++y) for (int x = 0; x < lm.w && clear; ++x)
                if (!g_pathplan.empty() && g_pathW == W && g_pathplan[static_cast<size_t>(y0 + y) * W + x0 + x] == 2) clear = false;   // not on the path itself (water may: the way fords it)
            for (int y = -4; y < lm.h + 4 && clear; ++y) for (int x = -4; x < lm.w + 4 && clear; ++x) {
                const int xx = x0 + x, yy = y0 + y;
                if (xx >= 0 && yy >= 0 && xx < W && yy < H && (*sk)[static_cast<size_t>(yy) * W + xx] >= 0) clear = false;   // not onto another one
            }
            if (!clear) continue;
            {   // every piece over it must be able to be its own surroundings
                const Grid& g = L.grids[static_cast<size_t>(lm.g)];
                for (int py : ys) for (int px : xs) {
                    if (!clear) break;
                    if (x0 + lm.w <= px || x0 >= px + P || y0 + lm.h <= py || y0 >= py + P) continue;
                    const int sx = lm.sx + (px - x0), sy = lm.sy + (py - y0);
                    if (sx < 0 || sy < 0 || sx + P > g.w || sy + P > g.h) { clear = false; break; }
                    for (int y = 0; y < P && clear; ++y) for (int x = 0; x < P && clear; ++x) if (g.at(sx + x, sy + y) < 0) clear = false;
                }
            }
            if (!clear) continue;
            const int sc = std::abs(x0 + lm.w / 2 - rcx) + std::abs(y0 + lm.h / 2 - rcy) + static_cast<int>(rng() % 3u);
            if (sc < bs) { bs = sc; bx = x0; by = y0; }
        }
        if (bx < 0) continue;
        const Grid& g = L.grids[static_cast<size_t>(lm.g)];
        for (int y = 0; y < lm.h; ++y) for (int x = 0; x < lm.w; ++x) {
            const size_t ci = static_cast<size_t>(by + y) * W + bx + x;
            (*sk)[ci] = g.at(lm.sx + x, lm.sy + y);
            (*so)[ci] = lm.g << 20 | (lm.sy + y) << 10 | (lm.sx + x);
        }
        // kept whole by the mending: its solid things and what touches them
        for (int y = 1; y < lm.h - 1; ++y) for (int x = 1; x < lm.w - 1; ++x) {
            bool lk = false;
            for (int dy = -1; dy <= 1 && !lk; ++dy) for (int dx = -1; dx <= 1 && !lk; ++dx) {
                const int k = g.at(lm.sx + x + dx, lm.sy + y + dy);
                if (k >= 0 && !L.walk[static_cast<size_t>(k)]) lk = true;
            }
            if (lk) (*lock)[static_cast<size_t>(by + y) * W + bx + x] = 1;
        }
        out.push_back({bx, by, lm.w, lm.h, lm.g, lm.sx, lm.sy});
    }
    return out;
}
// ---------------------------------------------------------------- buildings
// Houses, huts, big rocks, lone trees: things standing free in open ground in
// the area's real maps. They are drawn on the object layers (the ground layer
// runs on underneath them), so a whole one can be set down on a new floor's
// open ground layer by layer - nothing around it has to be re-solved.
struct Stamp { int g, x, y, w, h, solid, cells; };
struct StampSet { std::vector<Stamp> st, props; uint8_t ground = 1; std::unordered_map<uint32_t, char> deco; };   // ground: bit l = layer l is ground (runs on everywhere)
StampSet find_stamps(const Lib& L, int zone) {
    StampSet S;
    // which layers are ground: filled nearly everywhere in the area's maps
    long fill[4] = {0, 0, 0, 0}, n = 0;
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        if (gi < L.grid_zone.size() && L.grid_zone[gi] != zone) continue;
        for (int k : L.grids[gi].k) { if (k < 0) continue; ++n; for (int l = 0; l < 4; ++l) fill[l] += (L.keys[static_cast<size_t>(k)].e[l] & 0xFFFF) != 0; }
    }
    if (!n) return S;
    S.ground = 0;
    for (int l = 0; l < 4; ++l) if (fill[l] * 100 >= n * 85) S.ground |= static_cast<uint8_t>(1 << l);
    if (!S.ground) { int b = 0; for (int l = 1; l < 4; ++l) if (fill[l] > fill[b]) b = l; if (fill[b] * 2 >= n) S.ground = static_cast<uint8_t>(1 << b); }   // (the fullest layer)
    if (getenv("MB_DEBUG")) fprintf(stderr, "  layers filled: %.2f %.2f %.2f %.2f (ground mask %d)\n", fill[0] / double(n), fill[1] / double(n), fill[2] / double(n), fill[3] / double(n), S.ground);
    // object-layer tiles that belong to something (seen near walls nearly always), not
    // ground decoration strewn anywhere (flowers, tufts: those count as ground)
    std::unordered_map<uint32_t, std::pair<int, int>> tstat;   // (layer << 16 | tile) -> (seen, seen near a wall)
    std::unordered_map<uint32_t, long> tfill;                  // neighbours with something on the same layer, summed
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        if (gi < L.grid_zone.size() && L.grid_zone[gi] != zone) continue;
        const Grid& g = L.grids[gi];
        for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
            const int k = g.at(x, y); if (k < 0) continue;
            bool near = false;
            for (int dy = -3; dy <= 3 && !near; ++dy) for (int dx = -3; dx <= 3 && !near; ++dx) {
                const int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= g.w || yy >= g.h) continue;
                const int k2 = g.at(xx, yy); near = k2 >= 0 && !L.walk[static_cast<size_t>(k2)];
            }
            for (int l = 0; l < 4; ++l) {
                if ((S.ground >> l) & 1) continue;
                const uint32_t t = L.keys[static_cast<size_t>(k)].e[l] & 0xFFFF; if (!t) continue;
                auto& st = tstat[static_cast<uint32_t>(l) << 16 | t]; ++st.first; st.second += near;
                int filled = 0;   // (a roof or a canopy: its pieces sit among more of it; a flower stands alone)
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                    if (!dx && !dy) continue; const int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= g.w || yy >= g.h) continue;
                    const int k2 = g.at(xx, yy); filled += k2 >= 0 && (L.keys[static_cast<size_t>(k2)].e[l] & 0xFFFF);
                }
                tfill[static_cast<uint32_t>(l) << 16 | t] += filled;
            }
        }
    }
    std::unordered_map<uint32_t, char> deco;
    for (const auto& kv : tstat) if (kv.second.second * 10 < kv.second.first * 8 && tfill[kv.first] < kv.second.first * 3) deco[kv.first] = 1;
    S.deco = deco;
    if (getenv("MB_DEBUG")) fprintf(stderr, "  object-layer tiles: %zu, of them ground decoration: %zu\n", tstat.size(), deco.size());
    // Things, found layer by layer: a piece of something is a run of tiles on ONE object layer (or a
    // run of walls); pieces on different layers of the same cell are one thing. (Taken together, a
    // forest's canopy, the grass overlay and a hut beside them all ran into one huge blob: no area
    // had a single building to give.) Every map the library learned from is looked at, not only
    // the area's own: anything drawn wholly in tiles this area also has can stand here.
    auto content = [&](int k, int l) {
        if (k < 0) return false;
        if (l == 4) return !L.walk[static_cast<size_t>(k)];
        if ((S.ground >> l) & 1) return false;
        const uint32_t t = L.keys[static_cast<size_t>(k)].e[l] & 0xFFFF;
        return t && !deco.count(static_cast<uint32_t>(l) << 16 | t);
    };
    auto any_content = [&](int k) { for (int l = 0; l < 5; ++l) if (content(k, l)) return true; return false; };
    static const int kMaxW = 20, kMaxH = 18;
    std::unordered_map<uint64_t, char> seen;
    int rj[3] = {0, 0, 0};
    for (size_t gi = 0; gi < L.grids.size(); ++gi) {
        const Grid& g = L.grids[gi];
        const int N = g.w * g.h;
        std::vector<int> par(static_cast<size_t>(N) * 5, -1);
        auto node = [&](int c, int l) { return c * 5 + l; };
        std::function<int(int)> find = [&](int x) { while (par[static_cast<size_t>(x)] != x) { par[static_cast<size_t>(x)] = par[static_cast<size_t>(par[static_cast<size_t>(x)])]; x = par[static_cast<size_t>(x)]; } return x; };
        auto unite = [&](int a2, int b2) { a2 = find(a2); b2 = find(b2); if (a2 != b2) par[static_cast<size_t>(a2)] = b2; };
        for (int c = 0; c < N; ++c) for (int l = 0; l < 5; ++l) if (content(g.k[static_cast<size_t>(c)], l)) par[static_cast<size_t>(node(c, l))] = node(c, l);
        for (int y = 0; y < g.h; ++y) for (int x = 0; x < g.w; ++x) {
            const int c = y * g.w + x;
            int first = -1;
            for (int l = 0; l < 5; ++l) {
                if (par[static_cast<size_t>(node(c, l))] < 0) continue;
                if (first < 0) first = node(c, l); else unite(first, node(c, l));
                if (x + 1 < g.w && par[static_cast<size_t>(node(c + 1, l))] >= 0) unite(node(c, l), node(c + 1, l));
                if (y + 1 < g.h && par[static_cast<size_t>(node(c + g.w, l))] >= 0) unite(node(c, l), node(c + g.w, l));
            }
        }
        if (getenv("MB_STAMPDUMP") && gi == static_cast<size_t>(atoi(getenv("MB_STAMPDUMP")))) {
            for (int y = 0; y < g.h; ++y) { for (int x = 0; x < g.w; ++x) { const int k = g.at(x, y); char ch = k < 0 ? ' ' : '.'; if (k >= 0) { int m = 0; for (int l = 0; l < 4; ++l) if (content(k, l)) m |= 1 << l; if (m) ch = static_cast<char>('a' + m - 1); if (content(k, 4)) ch = m ? static_cast<char>('A' + m - 1) : '#'; } fputc(ch, stderr); } fputc('\n', stderr); }
        }
        // each thing: its box, the cells it covers
        std::unordered_map<int, std::array<int, 6>> box;   // root -> x0, y0, x1, y1, cells, solid
        std::vector<int> owner(static_cast<size_t>(N), -1);   // a cell's thing (-2: two things share the cell)
        for (int c = 0; c < N; ++c) {
            int r = -1;
            for (int l = 0; l < 5; ++l) if (par[static_cast<size_t>(node(c, l))] >= 0) { r = find(node(c, l)); break; }
            if (r < 0) continue;
            owner[static_cast<size_t>(c)] = r;
            const int x = c % g.w, y = c / g.w;
            auto it = box.find(r);
            if (it == box.end()) it = box.emplace(r, std::array<int, 6>{x, y, x, y, 0, 0}).first;
            auto& bb = it->second;
            bb[0] = std::min(bb[0], x); bb[1] = std::min(bb[1], y); bb[2] = std::max(bb[2], x); bb[3] = std::max(bb[3], y);
            ++bb[4]; bb[5] += content(g.k[static_cast<size_t>(c)], 4);
        }
        std::vector<std::pair<int, std::array<int, 6>>> boxv(box.begin(), box.end());
        std::stable_sort(boxv.begin(), boxv.end(), [](const auto& a, const auto& b) { return a.first < b.first; });   // (the same order with every C++ library: Windows and Linux make the same floors)
        for (const auto& kv : boxv) {
            const int r = kv.first; const auto& bb = kv.second;
            const int x0 = bb[0], y0 = bb[1], x1 = bb[2], y1 = bb[3], w = x1 - x0 + 1, h = y1 - y0 + 1, cells = bb[4], solid = bb[5];
            if (w > kMaxW || h > kMaxH) { ++rj[0]; continue; }
            const bool prop = w <= 4 && h <= 4;
            if (prop ? (cells < 2 && !solid) : (w < 3 || h < 3 || solid < 2 || cells < 6)) { ++rj[1]; continue; }
            // standing free: a ring of plain open ground round it, nothing else inside its box
            bool ok = x0 - 1 >= 0 && y0 - 1 >= 0 && x1 + 1 < g.w && y1 + 1 < g.h;
            for (int y = y0 - 1; y <= y1 + 1 && ok; ++y) for (int x = x0 - 1; x <= x1 + 1 && ok; ++x) {
                const int c = y * g.w + x, k = g.k[static_cast<size_t>(c)];
                if (k < 0) { ok = false; break; }
                const bool inbox = x >= x0 && x <= x1 && y >= y0 && y <= y1;
                if (inbox) { if (owner[static_cast<size_t>(c)] >= 0 && owner[static_cast<size_t>(c)] != r) ok = false; }
                else if (any_content(k) || !L.walk[static_cast<size_t>(k)]) ok = false;
            }
            if (!ok) { ++rj[2]; continue; }
            uint64_t hsh = 1469598103934665603ull;   // the same thing seen again (a copy, another map): once
            for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) {
                const int k = g.at(x, y); const bool o = owner[static_cast<size_t>(y * g.w + x)] == r;
                for (int l = 0; l < 4; ++l) if (!((S.ground >> l) & 1)) hsh = (hsh ^ (o ? L.keys[static_cast<size_t>(k)].e[l] : 0u)) * 1099511628211ull;
                hsh = (hsh ^ static_cast<uint64_t>(o)) * 1099511628211ull;
            }
            hsh ^= static_cast<uint64_t>(w) << 56 ^ static_cast<uint64_t>(h) << 48;
            if (!seen.emplace(hsh, 1).second) continue;
            (prop ? S.props : S.st).push_back({static_cast<int>(gi), x0, y0, w, h, solid, cells});
        }
    }
    {   // (the same order on every PC whatever the hash map did: by place in the source maps)
        auto by_place = [](const Stamp& a, const Stamp& b) { return std::tie(a.g, a.y, a.x) < std::tie(b.g, b.y, b.x); };
        std::stable_sort(S.st.begin(), S.st.end(), by_place); std::stable_sort(S.props.begin(), S.props.end(), by_place);
    }
    std::stable_sort(S.props.begin(), S.props.end(), [](const Stamp& a, const Stamp& b) { return a.cells > b.cells; });
    if (S.props.size() > 40) S.props.resize(40);
    std::stable_sort(S.st.begin(), S.st.end(), [](const Stamp& a, const Stamp& b) { return a.cells > b.cells; });
    if (S.st.size() > 40) S.st.resize(40);
    if (getenv("MB_DEBUG")) fprintf(stderr, "  things: too big %d, too small %d, not free-standing %d\n", rj[0], rj[1], rj[2]);
    if (getenv("MB_DEBUG")) fprintf(stderr, "  small things (props): %zu\n", S.props.size());
    if (getenv("MB_DEBUG")) { fprintf(stderr, "  buildings found: %zu:", S.st.size()); for (const auto& t : S.st) fprintf(stderr, " %dx%d(g%d %d,%d)", t.w, t.h, t.g, t.x, t.y); fprintf(stderr, "\n"); }
    return S;
}
// ---------------------------------------------------------------- connect
// Make sure the way in reaches the way on: if it does not, take the cheapest
// line between them (fewest blocked cells under the fighter's body box) and
// re-solve a band around it with walkable pieces only along the line.
bool body_fits(const Lib& L, const std::vector<int>& K, int W, int H, int x, int y) {
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) {
        const int xx = x + dx, yy = y + dy;
        if (xx < 0 || yy < 0 || xx >= W || yy >= H || !L.walk[static_cast<size_t>(K[static_cast<size_t>(yy) * W + xx])]) return false;
    }
    return true;
}
Pt inner_point(int side, Pt p, int W, int H, int depth = 0) {   // where the body box fits right at that edge (depth: cells further in)
    switch (side) {
    case 0: return {2 + depth, std::clamp(p.y, 2, H - 3)};
    case 1: return {W - 3 - depth, std::clamp(p.y, 2, H - 3)};
    case 2: return {std::clamp(p.x, 3, W - 4), 1 + depth};
    default: return {std::clamp(p.x, 3, W - 4), H - 2 - depth};
    }
}
constexpr int kMaxDepth = 3;   // an exit may stand a few cells in from the edge (a doorway in a wall) when the edge itself is never open
bool connect(const Lib& L, std::vector<int>& K, int W, int H, Pt* pin_p, Pt* pout_p, int in_side, int out_side, std::mt19937& rng, std::vector<uint8_t>* touched) {
    Pt pin = *pin_p, pout = *pout_p;
    static const bool multi = !getenv("MB_NOMULTI");
    // every point of each side (its middle 80%) may be the way in / on: the cheapest line wins
    auto side_points = [&](int side, Pt p) {
        std::vector<Pt> v{inner_point(side, p, W, H)};
        if (!multi) return v;
        const int len = side < 2 ? H : W;
        for (int dep = 0; dep <= kMaxDepth; ++dep)
            for (int t = len / 5; t < len - len / 5; t += 2) v.push_back(inner_point(side, side < 2 ? Pt{0, t} : Pt{t, 0}, W, H, dep));   // (not near the corners: in and on right next to each other)
        return v;
    };
    static const int kRounds = getenv("MB_CONNECT_ROUNDS") ? atoi(getenv("MB_CONNECT_ROUNDS")) : 6;
    std::vector<int> extra(static_cast<size_t>(W) * H, 0);   // places a line could not be cleared through: dearer next round (another way round)
    for (int round = 0; round < kRounds; ++round) {
        // cost of standing at a cell = blocked cells under the box
        std::vector<int> cost(static_cast<size_t>(W) * H, 0);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            int c = 0;
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) {
                const int xx = x + dx, yy = y + dy;
                if (xx < 0 || yy < 0 || xx >= W || yy >= H) c += 50;
                else if (!L.walk[static_cast<size_t>(K[static_cast<size_t>(yy) * W + xx])]) ++c;
            }
            cost[static_cast<size_t>(y) * W + x] = c + (c ? extra[static_cast<size_t>(y) * W + x] : 0);
        }
        // Dijkstra (small integer costs: bucket queue)
        std::vector<int> dist(cost.size(), 1 << 29), prev(cost.size(), -1);
        std::vector<std::vector<int>> bucket(1);
        const auto As = side_points(in_side, pin), Bs = side_points(out_side, pout);
        // off the planned points costs (the way in and on stay far apart), and so does a doorway further in
        auto pen = [&](int side, const Pt& p, const Pt& planned) {
            const int dep = side == 0 ? p.x - 2 : side == 1 ? W - 3 - p.x : side == 2 ? p.y - 1 : H - 2 - p.y;
            const int dev = side < 2 ? std::abs(p.y - planned.y) : std::abs(p.x - planned.x);
            return dep * 12 + dev * 10;
        };
        const Pt pa = inner_point(in_side, pin, W, H), pb = inner_point(out_side, pout, W, H);
        std::vector<int> gpen(cost.size(), -1);
        for (const Pt& b : Bs) { const int g = b.y * W + b.x, pv = pen(out_side, b, pb); if (gpen[static_cast<size_t>(g)] < 0 || pv < gpen[static_cast<size_t>(g)]) gpen[static_cast<size_t>(g)] = pv; }
        for (size_t i = 0; i < As.size(); ++i) {
            const int s0 = As[i].y * W + As[i].x;
            const int d0 = cost[static_cast<size_t>(s0)] * 8 + pen(in_side, As[i], pa);
            if (d0 >= dist[static_cast<size_t>(s0)]) continue;
            dist[static_cast<size_t>(s0)] = d0;
            if (bucket.size() <= static_cast<size_t>(d0)) bucket.resize(static_cast<size_t>(d0) + 1);
            bucket[static_cast<size_t>(d0)].push_back(s0);
        }
        int goal = -1, goal_tot = 1 << 30;
        for (size_t d = 0; d < bucket.size() && static_cast<int>(d) < goal_tot; ++d)
            for (size_t k = 0; k < bucket[d].size(); ++k) {
                const int c = bucket[d][k];
                if (dist[static_cast<size_t>(c)] != static_cast<int>(d)) continue;
                if (gpen[static_cast<size_t>(c)] >= 0 && static_cast<int>(d) + gpen[static_cast<size_t>(c)] < goal_tot) { goal_tot = static_cast<int>(d) + gpen[static_cast<size_t>(c)]; goal = c; }
                const int x = c % W, y = c / W;
                const int nbs[4] = {x + 1 < W ? c + 1 : -1, x > 0 ? c - 1 : -1, y + 1 < H ? c + W : -1, y > 0 ? c - W : -1};
                for (int n : nbs) {
                    if (n < 0) continue;
                    const int nd = static_cast<int>(d) + 1 + cost[static_cast<size_t>(n)] * 8;
                    if (nd < dist[static_cast<size_t>(n)]) {
                        dist[static_cast<size_t>(n)] = nd; prev[static_cast<size_t>(n)] = c;
                        if (bucket.size() <= static_cast<size_t>(nd)) bucket.resize(static_cast<size_t>(nd) + 1);
                        bucket[static_cast<size_t>(nd)].push_back(n);
                    }
                }
            }
        if (goal < 0) return false;
        std::vector<int> path;
        for (int c = goal; c >= 0; c = prev[static_cast<size_t>(c)]) path.push_back(c);
        {   // the chosen ends become the way in / on
            const int st = path.back();
            *pin_p = Pt{st % W, st / W}; *pout_p = Pt{goal % W, goal / W};
        }
        int blocked = 0;
        for (int c : path) blocked += cost[static_cast<size_t>(c)] > 0;
        if (blocked == 0) return true;
        // must-walk: the body box along the path; free: a band around it
        std::vector<uint8_t> must(cost.size(), 0), fr(cost.size(), 0);
        for (int c : path) {
            const int x = c % W, y = c / W;
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) {
                const int xx = x + dx, yy = y + dy;
                if (xx >= 0 && yy >= 0 && xx < W && yy < H) must[static_cast<size_t>(yy) * W + xx] = 1;
            }
        }
        const int R = 2 + (round & 1);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) if (must[static_cast<size_t>(y) * W + x])
            for (int dy = -R; dy <= R; ++dy) for (int dx = -R; dx <= R; ++dx) {
                const int xx = x + dx, yy = y + dy;
                if (xx >= 0 && yy >= 0 && xx < W && yy < H) fr[static_cast<size_t>(yy) * W + xx] = 1;
            }
        // keep what is already walkable on the line as it is where it fits
        Repair rp(L, W, H);
        std::vector<int> K2 = K;
        if (getenv("MB_DEBUG")) { fprintf(stderr, "  connect round %d: %d blocked cells on the line (from %d,%d to %d,%d):", round, blocked, path.back() % W, path.back() / W, goal % W, goal / W); for (int c : path) if (cost[static_cast<size_t>(c)] > 0) fprintf(stderr, " %d,%d(%d)", c % W, c / W, cost[static_cast<size_t>(c)]); fprintf(stderr, "\n"); }
        {   // memory: only the band around the line takes part (the whole floor counted here made every big floor fail)
            size_t nfr = 0; for (auto v : fr) nfr += v;
            if ((nfr + nfr / 2 + 64) * 4 * static_cast<size_t>(L.N) * 2 > (size_t(300) << 20)) return false;
        }
        bool cleared = false;
        for (int grow = 0; grow < 4 && !cleared; ++grow) {
            K2 = K;
            if (rp.solve(K2, fr, rng, &must)) {
                for (size_t c = 0; c < fr.size(); ++c) if (fr[c]) (*touched)[c] = 1;
                K = K2;
                cleared = true;
                break;
            }
            if (rp.fail_cell < 0) break;
            const int fx = rp.fail_cell % W, fy = rp.fail_cell / W, r2 = 3 + grow;
            for (int dy = -r2; dy <= r2; ++dy) for (int dx = -r2; dx <= r2; ++dx) {
                const int xx = fx + dx, yy = fy + dy;
                if (xx >= 0 && yy >= 0 && xx < W && yy < H) fr[static_cast<size_t>(yy) * W + xx] = 1;
            }
        }
        if (!cleared) for (int c : path) if (cost[static_cast<size_t>(c)] > 0) extra[static_cast<size_t>(c)] += 6;   // this way would not clear: another way round next time
    }
    return false;
}
}  // namespace


// ---------------------------------------------------------------- things from other maps
// The area's own maps hold few things that stand free (a forest has trees and rocks, little else).
// Any map of the game has more: huts, tents, ruins, statues, carts, wells, fountains... All share
// one background palette, so a thing drawn in any map's tiles looks right anywhere - the floor
// just loads those tiles too (a tile list of its own). Things are picked by the ground they stood
// on (grass on grass, sand on sand) and set down on plain open ground, the way through kept open.
namespace {
struct FThing {
    int z, a, w, h, solid; int pri[4]; int ground;   // the source map's layer priorities, its ground layer
    std::vector<uint32_t> e[4];                       // per cell: flags << 16 | game-wide tile number (0 = nothing)
    std::vector<uint16_t> id[4];                      // (the same by look id: for pictures)
    std::vector<uint8_t> wa, wb, obj;                 // walk bits; obj: the thing covers this cell
    float rgb[3];                                     // colour of the ground round it
    bool outdoor = false;                             // its ground is ground of the game's field areas
    bool fringe = false;                              // it draws some of its own ground at its edges (it needs ground like it)
};
std::vector<FThing> g_fthings; std::once_flag g_fthings_once;
void build_fthings(const Rom& rom, const std::vector<BankMap>& bank, const Options& opt) {
    int fr[6] = {0, 0, 0, 0, 0, 0};
    // the ground of the game's field areas (the maps the adventure uses): a thing that stood on it is an outdoor thing
    std::unordered_map<uint32_t, char> field_ground;
    for (const auto& mz : kAdvMaps) {
        const uint16_t* ids = ids_of(bank, mz[0], mz[1]); SrcMap m;
        if (!ids || !load_src(rom, mz[0], mz[1], &m)) continue;
        for (size_t c = 0; c < m.wa.size(); ++c) {
            if (!m.wa[c]) continue;
            int best = -1, bl = -1; for (int l = 0; l < 4; ++l) if (m.tilemap[l] && (m.L[l][c] & 0x3FF)) { const int k = m.pri[l] * 8 + l; if (k > best) { best = k; bl = l; } }
            if (bl < 0) continue;
            const uint16_t id = ids[m.L[bl][c] & 0x3FF]; if (id) field_ground[id] = 1;
        }
    }
    for (const auto& bm : bank) {
        SrcMap m;
        if (!load_src(rom, bm.z, bm.a, &m) || m.tw < 16 || m.th < 16) continue;
        const int N = m.tw * m.th;
        // each cell's ground: the layer drawn at the very back there (whatever else stands on it)
        std::vector<int8_t> back(static_cast<size_t>(N), -1);
        for (int c = 0; c < N; ++c) { int best = -1; for (int l = 0; l < 4; ++l) if (m.tilemap[l] && (m.L[l][static_cast<size_t>(c)] & 0x3FF)) { const int k = m.pri[l] * 8 + l; if (k > best) { best = k; back[static_cast<size_t>(c)] = static_cast<int8_t>(l); } } }
        auto content = [&](int c, int l) {
            if (l == 4) return m.wa[static_cast<size_t>(c)] == 0;
            return m.tilemap[l] && l != back[static_cast<size_t>(c)] && (m.L[l][static_cast<size_t>(c)] & 0x3FF) != 0;
        };
        std::vector<int> par(static_cast<size_t>(N) * 5, -1);
        std::function<int(int)> find = [&](int x) { while (par[static_cast<size_t>(x)] != x) { par[static_cast<size_t>(x)] = par[static_cast<size_t>(par[static_cast<size_t>(x)])]; x = par[static_cast<size_t>(x)]; } return x; };
        auto unite = [&](int a2, int b2) { a2 = find(a2); b2 = find(b2); if (a2 != b2) par[static_cast<size_t>(a2)] = b2; };
        for (int c = 0; c < N; ++c) for (int l = 0; l < 5; ++l) if (content(c, l)) par[static_cast<size_t>(c * 5 + l)] = c * 5 + l;
        for (int y = 0; y < m.th; ++y) for (int x = 0; x < m.tw; ++x) {
            const int c = y * m.tw + x; int first = -1;
            for (int l = 0; l < 5; ++l) {
                if (par[static_cast<size_t>(c * 5 + l)] < 0) continue;
                if (first < 0) first = c * 5 + l; else unite(first, c * 5 + l);
                if (x + 1 < m.tw && par[static_cast<size_t>((c + 1) * 5 + l)] >= 0) unite(c * 5 + l, (c + 1) * 5 + l);
                if (y + 1 < m.th && par[static_cast<size_t>((c + m.tw) * 5 + l)] >= 0) unite(c * 5 + l, (c + m.tw) * 5 + l);
            }
        }
        std::vector<int> owner(static_cast<size_t>(N), -1);
        std::vector<std::array<int, 6>> boxes; std::unordered_map<int, int> bi;
        for (int c = 0; c < N; ++c) {
            int r = -1; for (int l = 0; l < 5; ++l) if (par[static_cast<size_t>(c * 5 + l)] >= 0) { r = find(c * 5 + l); break; }
            if (r < 0) continue;
            owner[static_cast<size_t>(c)] = r;
            const int x = c % m.tw, y = c / m.tw;
            auto it = bi.find(r);
            if (it == bi.end()) { it = bi.emplace(r, static_cast<int>(boxes.size())).first; boxes.push_back({x, y, x, y, r, 0}); }
            auto& b = boxes[static_cast<size_t>(it->second)];
            b[0] = std::min(b[0], x); b[1] = std::min(b[1], y); b[2] = std::max(b[2], x); b[3] = std::max(b[3], y); b[5] += content(c, 4);
        }
        // things, and groups of things standing close together (a house with its fence and well, a
        // ruin's pieces, a camp): each nearby pair (2 cells apart or less) belongs to one group
        struct FC { int x0, y0, x1, y1, solid; std::vector<int> roots; };
        std::vector<FC> fcs;
        for (const auto& b : boxes) fcs.push_back({b[0], b[1], b[2], b[3], b[5], {b[4]}});
        {
            std::vector<int> gp(boxes.size()); for (size_t i = 0; i < gp.size(); ++i) gp[i] = static_cast<int>(i);
            std::function<int(int)> gf = [&](int x) { while (gp[static_cast<size_t>(x)] != x) x = gp[static_cast<size_t>(x)] = gp[static_cast<size_t>(gp[static_cast<size_t>(x)])]; return x; };
            auto small = [&](const std::array<int, 6>& b) { return b[2] - b[0] < 24 && b[3] - b[1] < 20; };
            for (size_t i = 0; i < boxes.size(); ++i) for (size_t j = i + 1; j < boxes.size(); ++j) {
                const auto& A = boxes[i]; const auto& B = boxes[j];
                if (!small(A) || !small(B)) continue;
                if (A[0] - 2 <= B[2] && B[0] - 2 <= A[2] && A[1] - 2 <= B[3] && B[1] - 2 <= A[3]) gp[static_cast<size_t>(gf(static_cast<int>(i)))] = gf(static_cast<int>(j));
            }
            std::unordered_map<int, FC> groups;
            for (size_t i = 0; i < boxes.size(); ++i) {
                if (!small(boxes[i])) continue;
                const int g = gf(static_cast<int>(i)); const auto& b = boxes[i];
                auto it = groups.find(g);
                if (it == groups.end()) groups.emplace(g, FC{b[0], b[1], b[2], b[3], b[5], {b[4]}});
                else { FC& c = it->second; c.x0 = std::min(c.x0, b[0]); c.y0 = std::min(c.y0, b[1]); c.x1 = std::max(c.x1, b[2]); c.y1 = std::max(c.y1, b[3]); c.solid += b[5]; c.roots.push_back(b[4]); }
            }
            std::vector<std::pair<int, FC>> gl2(groups.begin(), groups.end());
            std::stable_sort(gl2.begin(), gl2.end(), [](const auto& a2, const auto& b2) { return a2.first < b2.first; });   // (the same order everywhere)
            for (auto& kv : gl2) if (kv.second.roots.size() >= 2 && kv.second.x1 - kv.second.x0 < 28 && kv.second.y1 - kv.second.y0 < 24) fcs.push_back(std::move(kv.second));
        }
        for (const auto& b : fcs) {
            const int x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, w = x1 - x0 + 1, h = y1 - y0 + 1, solid = b.solid;
            auto mine = [&](int rr) { return std::find(b.roots.begin(), b.roots.end(), rr) != b.roots.end(); };
            const bool grp = b.roots.size() >= 2;
            ++fr[0]; if (w < 3 || h < 3 || w > (grp ? 28 : 24) || h > (grp ? 24 : 20) || solid < 2) { ++fr[1]; continue; }
            if (x0 < 1 || y0 < 1 || x1 + 1 >= m.tw || y1 + 1 >= m.th) continue;
            bool used_l[5] = {false, false, false, false, false};   // the layers it is drawn on (a piece touching it on one of those is part of something bigger)
            for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) { const int c = y * m.tw + x; if (owner[static_cast<size_t>(c)] >= 0 && mine(owner[static_cast<size_t>(c)])) for (int l = 0; l < 5; ++l) used_l[l] |= content(c, l); }
            bool ok = true; float acc[3] = {0, 0, 0}; int na = 0; int gvote[4] = {0, 0, 0, 0}; int nring = 0, nfield = 0;
            for (int y = y0 - 1; y <= y1 + 1 && ok; ++y) for (int x = x0 - 1; x <= x1 + 1 && ok; ++x) {
                const int c = y * m.tw + x;
                const bool inbox = x >= x0 && x <= x1 && y >= y0 && y <= y1;
                if (inbox) { if (owner[static_cast<size_t>(c)] >= 0 && !mine(owner[static_cast<size_t>(c)])) ok = false; continue; }
                static const bool kStrictRing = getenv("MB_FSTRICT") != nullptr;
                if ((kStrictRing && owner[static_cast<size_t>(c)] >= 0) || !m.wa[static_cast<size_t>(c)] || back[static_cast<size_t>(c)] < 0) { ok = false; break; }
                for (int l = 0; l < 4; ++l) if (used_l[l] && content(c, l)) { ok = false; break; }   // (a cut-off piece of a bigger thing)
                if (!ok) break;
                ++gvote[back[static_cast<size_t>(c)]];
                { const uint16_t t2 = m.L[back[static_cast<size_t>(c)]][static_cast<size_t>(c)] & 0x3FF; ++nring; if (t2 && field_ground.count(bm.ids[t2])) ++nfield; }
                const uint16_t t = m.L[back[static_cast<size_t>(c)]][static_cast<size_t>(c)] & 0x3FF;   // the ground round it: its colour
                const uint16_t id = t ? bm.ids[t] : 0;
                const uint8_t* px = (id && id < 0xC000 && opt.tile_pixels) ? opt.tile_pixels(id) : nullptr;
                if (px && opt.palette) for (int i = 0; i < 64; ++i) if (px[i]) { for (int q = 0; q < 3; ++q) acc[q] += opt.palette[px[i] * 3 + q]; ++na; }
            }
            if (!ok) { ++fr[2]; continue; } if (na < 32) { ++fr[3]; continue; }
            int ground = 0; for (int l = 1; l < 4; ++l) if (gvote[l] > gvote[ground]) ground = l;
            FThing f; f.z = m.z; f.a = m.a; f.w = w; f.h = h; f.solid = solid; f.ground = ground;
            for (int l = 0; l < 4; ++l) { f.pri[l] = m.pri[l]; f.e[l].assign(static_cast<size_t>(w) * h, 0); f.id[l].assign(static_cast<size_t>(w) * h, 0); }
            f.wa.assign(static_cast<size_t>(w) * h, 1); f.wb.assign(static_cast<size_t>(w) * h, 1); f.obj.assign(static_cast<size_t>(w) * h, 0);
            for (int q = 0; q < 3; ++q) f.rgb[q] = acc[q] / na;
            f.outdoor = nfield * 10 >= nring * 6;
            for (int y = 0; y < h && ok; ++y) for (int x = 0; x < w && ok; ++x) {
                const int c = (y0 + y) * m.tw + x0 + x; const size_t i = static_cast<size_t>(y) * w + x;
                if (owner[static_cast<size_t>(c)] < 0 || !mine(owner[static_cast<size_t>(c)])) continue;
                f.obj[i] = 1; f.wa[i] = m.wa[static_cast<size_t>(c)]; f.wb[i] = m.wb[static_cast<size_t>(c)];
                const int bk = back[static_cast<size_t>(c)];
                bool above = false; for (int l = 0; l < 4; ++l) if (l != bk && m.tilemap[l] && (m.L[l][static_cast<size_t>(c)] & 0x3FF)) above = true;
                for (int l = 0; l < 4; ++l) {
                    if (!m.tilemap[l]) continue;
                    if (l == bk && (above || m.wa[static_cast<size_t>(c)])) continue;   // (its ground stays the floor's - unless a wall is drawn on it)
                    if (l == bk && l != ground) continue;   // (a wall on a layer that is not its map's ground: no place for it)
                    const uint16_t e = m.L[l][static_cast<size_t>(c)], t = e & 0x3FF;
                    if (!t) continue;
                    const uint16_t id = bm.ids[t];
                    if (!id || id >= 0xC000 || !opt.id_global || id >= opt.id_global->size() || !(*opt.id_global)[id]) { ok = false; break; }   // (animated, or not a plain tile)
                    f.e[l][i] = static_cast<uint32_t>(e & 0xFC00) << 16 | (*opt.id_global)[id]; f.id[l][i] = id;
                }
            }
            if (!ok) { ++fr[4]; continue; }
            {   // its edge cells: how much of what they draw is ground-coloured (grass round a rock drawn into its tiles)
                int nop = 0, ng = 0;
                for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                    const size_t i = static_cast<size_t>(y) * w + x; if (!f.obj[i]) continue;
                    bool edge = false; for (int d = 0; d < 4; ++d) { const int xx = x + (d == 0) - (d == 1), yy = y + (d == 2) - (d == 3); if (xx < 0 || yy < 0 || xx >= w || yy >= h || !f.obj[static_cast<size_t>(yy) * w + xx]) edge = true; }
                    if (!edge) continue;
                    for (int l = 0; l < 4; ++l) { const uint16_t id = f.id[l][i]; const uint8_t* px = id ? opt.tile_pixels(id) : nullptr; if (!px) continue;
                        for (int q = 0; q < 64; ++q) if (px[q]) { ++nop; float d2 = 0; for (int c3 = 0; c3 < 3; ++c3) { const float dv = opt.palette[px[q] * 3 + c3] - f.rgb[c3]; d2 += dv * dv; } ng += d2 < 40.0f * 40.0f; } }
                }
                f.fringe = nop && ng * 100 >= nop * 5;
            }
            {   // something to see: a few tiles' worth drawn (not a stump or a tuft), and not the landing ship (Capsule Corp's own maps)
                int op = 0, dark = 0; for (int l = 0; l < 4; ++l) for (size_t i = 0; i < f.id[l].size(); ++i) if (const uint16_t id = f.id[l][i]) if (const uint8_t* px = opt.tile_pixels(id)) for (int q = 0; q < 64; ++q) if (px[q]) { ++op; dark += opt.palette[px[q] * 3] + opt.palette[px[q] * 3 + 1] + opt.palette[px[q] * 3 + 2] < 60; }
                // (mostly black: a doorway into the dark, a shadow - a black hole on a field)
                if (op < 320 || dark * 10 > op * 4 || (m.z == 6 && (m.a == 22 || m.a == 23 || (m.a == 60 && w >= 14)))) { ++fr[5]; continue; }
            }
            bool dup = false;   // the same thing in another map: once
            for (const auto& o : g_fthings) if (o.w == w && o.h == h && o.e[0] == f.e[0] && o.e[1] == f.e[1] && o.e[2] == f.e[2] && o.e[3] == f.e[3]) { dup = true; break; }
            if (!dup) g_fthings.push_back(std::move(f));
        }
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "  things from other maps: %zu (of %d: size %d, not free %d, no ground %d, tiles %d)\n", g_fthings.size(), fr[0], fr[1], fr[2], fr[3], fr[4]);
    if (const char* dp = getenv("MB_FDUMP")) {   // (dev) every thing as a picture: a PPM sheet, 8 across, cells of 160 x 144
        std::vector<size_t> show; for (size_t n = 0; n < g_fthings.size(); ++n) if (g_fthings[n].outdoor || !getenv("MB_FDUMPOUT")) show.push_back(n);
        const int CW = 200, CH = 168, cols = 8, rows = (static_cast<int>(show.size()) + cols - 1) / cols;
        std::vector<uint8_t> img(static_cast<size_t>(CW * cols) * CH * rows * 3, 40);
        for (size_t si = 0; si < show.size(); ++si) {
            const size_t n = show[si];
            const FThing& f = g_fthings[n]; const int ox = static_cast<int>(si % cols) * CW, oy = static_cast<int>(si / cols) * CH;
            if (f.fringe) for (int q = 0; q < 6; ++q) for (int r2 = 0; r2 < 6; ++r2) { const size_t o = (static_cast<size_t>(oy + CH - 8 + r2 / 3) * CW * cols + ox + q) * 3; img[o] = 255; img[o + 1] = 0; img[o + 2] = 0; }
            int ord[4] = {0, 1, 2, 3}; std::stable_sort(ord, ord + 4, [&](int a2, int b2) { return f.pri[a2] != f.pri[b2] ? f.pri[a2] > f.pri[b2] : a2 > b2; });
            for (int y = 0; y < f.h && y * 8 < CH - 8; ++y) for (int x = 0; x < f.w && x * 8 < CW; ++x) for (int li = 0; li < 4; ++li) {
                const int l = ord[li]; const size_t i = static_cast<size_t>(y) * f.w + x; const uint16_t id = f.id[l][i]; if (!id) continue;
                const uint8_t* px = opt.tile_pixels(id); if (!px) continue; const uint32_t fl = f.e[l][i] >> 16;
                for (int py = 0; py < 8; ++py) for (int pxx = 0; pxx < 8; ++pxx) {
                    const int sx2 = (fl & 0x400) ? 7 - pxx : pxx, sy2 = (fl & 0x800) ? 7 - py : py; const uint8_t v = px[sy2 * 8 + sx2]; if (!v) continue;
                    const size_t o = (static_cast<size_t>(oy + y * 8 + py) * CW * cols + ox + x * 8 + pxx) * 3;
                    for (int q = 0; q < 3; ++q) img[o + q] = opt.palette[v * 3 + q];
                }
            }
        }
        if (FILE* fo = fopen(dp, "wb")) { fprintf(fo, "P6 %d %d 255\n", CW * cols, CH * rows); fwrite(img.data(), 1, img.size(), fo); fclose(fo); }
        for (size_t n = 0; n < g_fthings.size(); ++n) fprintf(stderr, "  thing %zu: %d/%d %dx%d ground %.0f,%.0f,%.0f%s%s\n", n, g_fthings[n].z, g_fthings[n].a, g_fthings[n].w, g_fthings[n].h, g_fthings[n].rgb[0], g_fthings[n].rgb[1], g_fthings[n].rgb[2], g_fthings[n].outdoor ? " outdoor" : " INDOOR", g_fthings[n].fringe ? " fringe" : "");
    }
}
// Set down up to opt.foreign things from other maps. The floor's layer entries become slots of a
// tile list of its own; nothing changes when no thing fits (or the tiles would not all fit).
void place_water(const Rom& rom, int bz, int ba, const std::vector<BankMap>& bank, uint32_t seed, const Options& opt, Out* out);
void place_foreign(const Rom& rom, int bz, int ba, const std::vector<BankMap>& bank, uint32_t seed, const Options& opt, Out* out) {
    if (opt.foreign <= 0 || !opt.id_global || !opt.tile_pixels || !opt.palette || !out->tile_list.empty()) return;
    std::call_once(g_fthings_once, [&] { build_fthings(rom, bank, opt); });
    if (g_fthings.empty()) return;
    const uint16_t* base = ids_of(bank, bz, ba);
    SrcMap bm; if (!base || !load_src(rom, bz, ba, &bm)) return;
    const int W = out->tw, H = out->th, N = W * H;
    // the floor in game-wide tile numbers (animated tiles keep their slot: bit 31)
    std::vector<uint32_t> G[4];
    int first_anim = 896;
    for (int l = 0; l < 4; ++l) {
        G[l].assign(static_cast<size_t>(N), 0);
        for (int c = 0; c < N; ++c) {
            const uint16_t e = out->L[l][static_cast<size_t>(c)], t = e & 0x3FF;
            if (!t) { G[l][static_cast<size_t>(c)] = static_cast<uint32_t>(e & 0xFC00) << 16; continue; }
            const uint16_t id = base[t];
            if (id >= 0xC000) { first_anim = std::min(first_anim, static_cast<int>(t)); G[l][static_cast<size_t>(c)] = static_cast<uint32_t>(e & 0xFC00) << 16 | 0x10000u | t; continue; }
            const uint32_t gn = (id && id < opt.id_global->size()) ? (*opt.id_global)[id] : 0;
            if (!gn) return;   // (a tile the list could not name: leave the floor as it is)
            G[l][static_cast<size_t>(c)] = static_cast<uint32_t>(e & 0xFC00) << 16 | gn;
        }
    }
    // the floor's ground: layers filled nearly everywhere; its plain look (the commonest ground tiles)
    uint8_t gmask = 0;
    for (int l = 0; l < 4; ++l) { int n = 0; for (int c = 0; c < N; ++c) n += (G[l][static_cast<size_t>(c)] & 0xFFFF) != 0; if (bm.tilemap[l] && n * 100 >= N * 85) gmask |= static_cast<uint8_t>(1 << l); }
    if (!gmask) return;
    int gl = -1; for (int l = 0; l < 4; ++l) if (((gmask >> l) & 1) && (gl < 0 || bm.pri[l] > bm.pri[gl])) gl = l;
    std::unordered_map<uint32_t, int> gcount;
    for (int c = 0; c < N; ++c) if (out->wa[static_cast<size_t>(c)]) ++gcount[G[gl][static_cast<size_t>(c)] & 0x7FFFFFFFu];
    std::vector<std::pair<int, uint32_t>> gs; for (const auto& kv : gcount) gs.push_back({kv.second, kv.first});
    std::stable_sort(gs.begin(), gs.end(), std::greater<>());
    std::unordered_map<uint32_t, char> plain_ground; int covered = 0, wn = 0; for (const auto& kv : gcount) wn += kv.second;
    for (const auto& g2 : gs) { if (covered * 10 >= wn * 9) break; plain_ground[g2.second] = 1; covered += g2.first; }   // (90% of the walkable ground: grass, not the rarer dirt track)
    float frgb[3] = {0, 0, 0}; int fn = 0;
    for (const auto& kv : plain_ground) {
        const uint32_t gn = kv.first & 0xFFFF;   // (game-wide numbers: the picture via the id that has it)
        (void)gn;
    }
    for (int c = 0; c < N && fn < 200000; c += 7) {   // colour of the plain ground, from the area's own tiles
        const uint16_t t = out->L[gl][static_cast<size_t>(c)] & 0x3FF; if (!t || !out->wa[static_cast<size_t>(c)]) continue;
        if (!plain_ground.count(G[gl][static_cast<size_t>(c)] & 0x7FFFFFFFu)) continue;
        const uint16_t id = base[t]; const uint8_t* px = (id && id < 0xC000) ? opt.tile_pixels(id) : nullptr;
        if (px) for (int i = 0; i < 64; ++i) if (px[i]) { for (int q = 0; q < 3; ++q) frgb[q] += opt.palette[px[i] * 3 + q]; ++fn; }
    }
    if (fn < 64) return;
    for (float& v : frgb) v /= fn;
    {   // every ground tile of a colour near the plain ground's counts as plain (grass variants), the rest not (a dirt track)
        std::unordered_map<uint32_t, uint16_t> look;   // ground tile -> an id that draws it
        for (int c = 0; c < N; ++c) { const uint16_t t = out->L[gl][static_cast<size_t>(c)] & 0x3FF; if (t) look[G[gl][static_cast<size_t>(c)] & 0x7FFFFFFFu] = base[t]; }
        for (const auto& kv : gcount) {
            if (plain_ground.count(kv.first)) continue;
            auto it = look.find(kv.first); if (it == look.end() || it->second >= 0xC000) continue;
            const uint8_t* px = opt.tile_pixels(it->second); if (!px) continue;
            float m3[3] = {0, 0, 0}; int nn = 0;
            for (int i = 0; i < 64; ++i) if (px[i]) { for (int q = 0; q < 3; ++q) m3[q] += opt.palette[px[i] * 3 + q]; ++nn; }
            if (nn < 32) continue;
            float d = 0; for (int q = 0; q < 3; ++q) { const float dv = m3[q] / nn - frgb[q]; d += dv * dv; }
            if (d < 30.0f * 30.0f) plain_ground[kv.first] = 1;
        }
    }
    // a layer drawn over most of the walkable ground (a grass overlay): its commonest tiles count as plain too
    std::unordered_map<uint32_t, char> overlay[4];
    for (int l = 0; l < 4; ++l) {
        if ((gmask >> l) & 1) continue;
        std::unordered_map<uint32_t, int> cnt; int n = 0;
        for (int c = 0; c < N; ++c) if (out->wa[static_cast<size_t>(c)]) { ++n; const uint32_t v = G[l][static_cast<size_t>(c)] & 0x7FFFFFFFu; if (v & 0xFFFF) ++cnt[v]; }
        std::vector<std::pair<int, uint32_t>> v2; int tot = 0; for (const auto& kv : cnt) { v2.push_back({kv.second, kv.first}); tot += kv.second; }
        if (tot * 2 < n) continue;   // (only a layer over half the walkable ground or more)
        std::stable_sort(v2.begin(), v2.end(), std::greater<>());
        int cov = 0; for (const auto& p2 : v2) { if (cov * 10 >= tot * 7) break; overlay[l][p2.second] = 1; cov += p2.first; }
    }
    // ground decoration (a tuft, a flower: a lone tile on walkable ground) counts as plain too
    for (int l = 0; l < 4; ++l) {
        if ((gmask >> l) & 1) continue;
        std::unordered_map<uint32_t, std::pair<int, int>> st2;   // tile -> (seen, seen alone on walkable ground)
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            const size_t c = static_cast<size_t>(y) * W + x; const uint32_t v = G[l][c] & 0x7FFFFFFFu; if (!(v & 0xFFFF)) continue;
            int nb = 0; const int d4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (auto& d : d4) { const int xx = x + d[0], yy = y + d[1]; if (xx >= 0 && yy >= 0 && xx < W && yy < H && (G[l][static_cast<size_t>(yy) * W + xx] & 0xFFFF)) ++nb; }
            auto& e2 = st2[v]; ++e2.first; e2.second += nb <= 1 && out->wa[c];
        }
        for (const auto& kv : st2) if (kv.second.second * 10 >= kv.second.first * 8) overlay[l][kv.first] = 1;
    }
    // where a thing may stand: plain walkable ground, nothing else standing there
    auto plain = [&](int x, int y) {
        if (x < 0 || y < 0 || x >= W || y >= H) return false;
        const size_t c = static_cast<size_t>(y) * W + x;
        if (!out->wa[c] || !plain_ground.count(G[gl][c] & 0x7FFFFFFFu)) return false;
        for (int l = 0; l < 4; ++l) if (!((gmask >> l) & 1) && (G[l][c] & 0xFFFF) && !overlay[l].count(G[l][c] & 0x7FFFFFFFu)) return false;
        return true;
    };
    if (getenv("MB_DEBUG")) { int np = 0, nw = 0, ng = 0; for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) { const size_t c = static_cast<size_t>(y) * W + x; nw += out->wa[c] != 0; ng += out->wa[c] && plain_ground.count(G[gl][c] & 0x7FFFFFFFu); np += plain(x, y); } fprintf(stderr, "  plain cells %d (walkable %d, plain ground %d; ground tiles %zu, overlay %zu %zu %zu %zu)\n", np, nw, ng, plain_ground.size(), overlay[0].size(), overlay[1].size(), overlay[2].size(), overlay[3].size()); }
    if (const char* pd = getenv("MB_PLAINDUMP")) if (FILE* fp = fopen(pd, "w")) { for (int y = 0; y < H; ++y) { for (int x = 0; x < W; ++x) { const size_t c = static_cast<size_t>(y) * W + x; fputc(plain(x, y) ? '.' : (!out->wa[c] ? '#' : (!plain_ground.count(G[gl][c] & 0x7FFFFFFFu) ? 'g' : 'o')), fp); } fputc('\n', fp); } fclose(fp); }
    // things whose ground looks like this floor's, nearest first, a few of the best in seed order
    std::vector<std::pair<float, int>> cand;
    for (size_t i = 0; i < g_fthings.size(); ++i) {
        const FThing& f = g_fthings[i];
        if (f.z == bz || !f.outdoor) continue;   // (the area's own things are the builder's already; nothing from indoors)
        float d = 0; for (int q = 0; q < 3; ++q) d += (f.rgb[q] - frgb[q]) * (f.rgb[q] - frgb[q]);
        d = std::sqrt(d);
        static const float kNear = getenv("MB_FNEAR") ? static_cast<float>(atof(getenv("MB_FNEAR"))) : 36.0f;
        if (f.fringe && d >= kNear) continue;   // (it brings some of its own ground: only onto ground like it)
        cand.push_back({d, static_cast<int>(i)});   // (nearest ground first: what stood on grass like this - palms on jungle grass, not in a pine forest)
    }
    if (cand.empty()) { if (getenv("MB_DEBUG")) fprintf(stderr, "  no thing from another map stood on ground like this (%.0f,%.0f,%.0f)\n", frgb[0], frgb[1], frgb[2]); return; }
    std::stable_sort(cand.begin(), cand.end());
    {   // what stood on ground like this floor's; only if hardly anything did, the nearest few anyway
        static const float kTheme = getenv("MB_FTHEME") ? static_cast<float>(atof(getenv("MB_FTHEME"))) : 30.0f;
        size_t near = 0; while (near < cand.size() && cand[near].first < kTheme) ++near;
        cand.resize(std::min(cand.size(), std::max<size_t>(near, 6)));
    }
    if (getenv("MB_DEBUG")) { fprintf(stderr, "  floor ground %.0f,%.0f,%.0f gmask %d gl %d pri %d%d%d%d tm %d%d%d%d; candidates %zu:", frgb[0], frgb[1], frgb[2], gmask, gl, bm.pri[0], bm.pri[1], bm.pri[2], bm.pri[3], bm.tilemap[0], bm.tilemap[1], bm.tilemap[2], bm.tilemap[3], cand.size()); for (auto& c : cand) fprintf(stderr, " %d/%d %dx%d(%.0f)", g_fthings[c.second].z, g_fthings[c.second].a, g_fthings[c.second].w, g_fthings[c.second].h, c.first); fprintf(stderr, "\n"); }
    std::mt19937 rng(seed * 2246822519u + 0x9E3779B9u);
    if (cand.size() > 28) cand.resize(28);
    mb_shuffle(cand.begin(), cand.end(), rng);
    std::stable_sort(cand.begin(), cand.end(), [&](const auto& a2, const auto& b2) { const FThing& fa = g_fthings[static_cast<size_t>(a2.second)]; const FThing& fb = g_fthings[static_cast<size_t>(b2.second)]; return (fa.w * fa.h >= 60) > (fb.w * fb.h >= 60); });   // (a big one or two first, while there is room)
    // the body test and the way through (from the arrival spot to every exit)
    auto body_ok = [&](int x, int y) { for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H || !out->wa[static_cast<size_t>(yy) * W + xx]) return false; } return true; };
    auto ways_open = [&]() {
        const int sx = out->spawn_x / 8, sy = out->spawn_y / 8;
        std::vector<uint8_t> vis(static_cast<size_t>(N), 0); std::vector<int> q;
        for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int x = sx + dx, y = sy + dy; if (body_ok(x, y) && !vis[static_cast<size_t>(y) * W + x]) { vis[static_cast<size_t>(y) * W + x] = 1; q.push_back(y * W + x); } }
        for (size_t h = 0; h < q.size(); ++h) {
            const int c = q[h], x = c % W, y = c / W;
            const int nb[4][2] = {{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}};
            for (auto& v : nb) { if (!body_ok(v[0], v[1])) continue; const size_t c2 = static_cast<size_t>(v[1]) * W + v[0]; if (!vis[c2]) { vis[c2] = 1; q.push_back(static_cast<int>(c2)); } }
        }
        for (const Rect& r : out->exits) {
            bool hit = false;
            for (int y = r.y0 / 8 - 2; y <= r.y1 / 8 + 2 && !hit; ++y) for (int x = r.x0 / 8 - 2; x <= r.x1 / 8 + 2 && !hit; ++x)
                if (x >= 0 && y >= 0 && x < W && y < H && vis[static_cast<size_t>(y) * W + x]) hit = true;
            if (!hit) return false;
        }
        return !q.empty();
    };
    // a layer of the floor for each of the thing's layers: the same drawing priority (in front of /
    // behind the fighters as it was), never the floor's ground (the thing's own ground is not taken)
    int placed = 0;
    std::vector<std::array<int, 4>> taken;
    for (const auto& cd : cand) {
        if (placed >= opt.foreign) break;
        const FThing& f = g_fthings[static_cast<size_t>(cd.second)];
        int lmap[4] = {-1, -1, -1, -1}; bool okl = true;
        for (int l = 0; l < 4 && okl; ++l) {
            bool used = false; for (uint32_t v : f.e[l]) if (v & 0xFFFF) { used = true; break; }
            if (!used) continue;
            if (l == f.ground) { lmap[l] = gl; continue; }   // (a wall drawn on its ground: onto the floor's ground)
            int best = -1, bd = 99;
            for (int t = 0; t < 4; ++t) {
                if (!bm.tilemap[t] || ((gmask >> t) & 1)) continue;
                const int d = std::abs(bm.pri[t] - f.pri[l]) * 4 + (t != l);
                if (d < bd) { bd = d; best = t; }
            }
            if (best < 0 || bd >= 4) okl = false; else lmap[l] = best;   // (only the same priority)
        }
        if (!okl) { if (getenv("MB_DEBUG")) fprintf(stderr, "  %d/%d: no layer of the same priority (pri %d%d%d%d ground %d)\n", f.z, f.a, f.pri[0], f.pri[1], f.pri[2], f.pri[3], f.ground); continue; }
        // its layers must not share a floor layer
        { bool clash = false; for (int a2 = 0; a2 < 4; ++a2) for (int b2 = a2 + 1; b2 < 4; ++b2) if (lmap[a2] >= 0 && lmap[a2] == lmap[b2]) clash = true; if (clash) continue; }
        bool done = false; int why[4] = {0, 0, 0, 0};
        // every spot, in an order of its own (seeded): the first that fits
        std::vector<int> spots;
        for (int y0 = 4; y0 + f.h <= H - 4; ++y0) for (int x0 = 4; x0 + f.w <= W - 4; ++x0) spots.push_back(y0 * W + x0);
        mb_shuffle(spots.begin(), spots.end(), rng);
        if (placed == 0 && out->keep_x >= 0 && f.w * f.h >= 40) {   // (the first big one: the clearing kept for it first)
            const int kcx = out->keep_x + out->keep_w / 2, kcy = out->keep_y + out->keep_h / 2;
            std::stable_sort(spots.begin(), spots.end(), [&](int a2, int b2) {
                const int da = std::abs(a2 % W + f.w / 2 - kcx) + std::abs(a2 / W + f.h / 2 - kcy), db = std::abs(b2 % W + f.w / 2 - kcx) + std::abs(b2 / W + f.h / 2 - kcy);
                return std::min(da, 12) < std::min(db, 12); });
        }
        for (size_t tries = 0; tries < spots.size() && !done; ++tries) {
            const int x0 = spots[tries] % W, y0 = spots[tries] / W;
            bool ok = true;
            // what it covers, and one cell round that, is plain ground (the rest of its box may hold anything)
            for (int y = -1; y < f.h + 1 && ok; ++y) for (int x = -1; x < f.w + 1 && ok; ++x) {
                bool near = false;
                for (int dy = -1; dy <= 1 && !near; ++dy) for (int dx = -1; dx <= 1 && !near; ++dx) { const int xx = x + dx, yy = y + dy; near = xx >= 0 && yy >= 0 && xx < f.w && yy < f.h && f.obj[static_cast<size_t>(yy) * f.w + xx]; }
                if (near && !plain(x0 + x, y0 + y)) ok = false;
            }
            if (!ok) { ++why[0]; continue; }
            for (const auto& t : taken) if (x0 < t[2] + 6 && t[0] < x0 + f.w + 6 && y0 < t[3] + 6 && t[1] < y0 + f.h + 6) ok = false;
            const int cx = x0 + f.w / 2, cy = y0 + f.h / 2;
            if (std::abs(cx - out->spawn_x / 8) + std::abs(cy - out->spawn_y / 8) < 12) ok = false;
            for (const Rect& r : out->exits) if (std::abs(cx - (r.x0 + r.x1) / 16) + std::abs(cy - (r.y0 + r.y1) / 16) < 14) ok = false;
            if (!ok) { ++why[1]; continue; }
            std::vector<uint32_t> kG[4]; for (int l = 0; l < 4; ++l) kG[l] = G[l];
            const std::vector<uint8_t> kwa = out->wa, kwb = out->wb;
            for (int y = 0; y < f.h; ++y) for (int x = 0; x < f.w; ++x) {
                const size_t i = static_cast<size_t>(y) * f.w + x;
                if (!f.obj[i]) continue;
                const size_t c = static_cast<size_t>(y0 + y) * W + x0 + x;
                for (int l = 0; l < 4; ++l) {
                    if (lmap[l] < 0 || !(f.e[l][i] & 0xFFFF)) continue;
                    if (lmap[l] == gl) {   // (onto the floor's ground only a tile that covers it: a see-through one left a black hole)
                        const uint8_t* px = f.id[l][i] ? opt.tile_pixels(f.id[l][i]) : nullptr; int op = 0;
                        if (px) for (int q = 0; q < 64; ++q) op += px[q] != 0;
                        if (op < 60) continue;
                    }
                    G[lmap[l]][c] = f.e[l][i];
                }
                out->wa[c] = f.wa[i]; out->wb[c] = f.wb[i];
            }
            if (!ways_open()) { ++why[2]; for (int l = 0; l < 4; ++l) G[l] = kG[l]; out->wa = kwa; out->wb = kwb; continue; }
            taken.push_back({x0, y0, x0 + f.w, y0 + f.h}); ++placed; done = true;
            if (getenv("MB_DEBUG")) fprintf(stderr, "  thing %dx%d from map %d/%d set down at %d,%d (ground %.0f apart)\n", f.w, f.h, f.z, f.a, x0, y0, cd.first);
        }
        if (!done && getenv("MB_DEBUG")) fprintf(stderr, "  %d/%d %dx%d: no room (not plain %d, near a way %d, would close it %d)\n", f.z, f.a, f.w, f.h, why[0], why[1], why[2]);
    }
    if (!placed) return;
    // the tile list: slot 0 empty, then every tile by game-wide number (rising); animated tiles keep theirs
    std::vector<uint32_t> used;
    { std::unordered_map<uint32_t, char> seen; for (int l = 0; l < 4; ++l) for (uint32_t v : G[l]) { const uint32_t t = v & 0xFFFF; if (t && !(v & 0x10000u) && seen.emplace(t, 1).second) used.push_back(t); } }
    std::stable_sort(used.begin(), used.end());
    if (static_cast<int>(used.size()) + 1 > first_anim) { if (getenv("MB_DEBUG")) fprintf(stderr, "  things from other maps: %zu tiles, room for %d - left out\n", used.size() + 1, first_anim); return; }
    std::unordered_map<uint32_t, uint16_t> slot;
    out->tile_list.assign(1, 0);
    for (uint32_t t : used) { slot[t] = static_cast<uint16_t>(out->tile_list.size()); out->tile_list.push_back(t); }
    for (int l = 0; l < 4; ++l) for (int c = 0; c < N; ++c) {
        const uint32_t v = G[l][static_cast<size_t>(c)], t = v & 0xFFFF;   // (bit 16: an animated tile, by its slot)
        const uint16_t s2 = !t ? 0 : ((v & 0x10000u) ? static_cast<uint16_t>(t & 0x3FF) : slot[t]);
        out->L[l][static_cast<size_t>(c)] = static_cast<uint16_t>(((v >> 16) & 0xFC00u) | s2);
    }
    out->foreign = placed;
    if (getenv("MB_DEBUG")) fprintf(stderr, "  floor tile list: %zu tiles\n", out->tile_list.size());
}
}  // namespace
bool build(const Rom& rom, int bz, int ba, const std::vector<BankMap>& bank,
           const std::vector<std::pair<int, int>>& sources, uint32_t seed,
           const Options& opt, Out* out) {
    Lib L;
    auto tl0 = std::chrono::steady_clock::now();
    if (!build_lib(rom, bz, ba, bank, sources, &L, opt)) return false;
    { static std::atomic<uint64_t> serials{0}; L.serial = ++serials; }
    find_paths(L, opt, ids_of(bank, bz, ba));
    {   // water: a solid cell drawn with an animated tile (the area's own: borrowed ones are never taken)
        const uint16_t* base = ids_of(bank, bz, ba);
        L.liquid.assign(static_cast<size_t>(L.N), 0); L.liquid_n = 0;
        for (int k = 0; k < L.N && base; ++k) {
            if (L.walk[static_cast<size_t>(k)]) continue;
            for (int l = 0; l < 4; ++l) { const uint32_t id = L.keys[static_cast<size_t>(k)].e[l] & 0xFFFF; const uint32_t g = L.global ? id : (id && id < 1024 ? base[id] : 0); if (g >= 0xC000) { L.liquid[static_cast<size_t>(k)] = 1; ++L.liquid_n; break; } }
        }
        if (getenv("MB_DEBUG")) fprintf(stderr, "water cells: %d\n", L.liquid_n);
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "time lib %.0f ms\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tl0).count());
    out->cells = L.N;
    std::mt19937 rng(seed);
    const int kStamps = opt.stamps >= 0 ? opt.stamps : (getenv("MB_STAMPS") ? atoi(getenv("MB_STAMPS")) : 2);
    StampSet SS; std::vector<uint8_t> keyobj;   // buildings of the area; which cells have something standing on them
    if (kStamps > 0 && !L.global) {
        SS = find_stamps(L, bz);
        keyobj.assign(static_cast<size_t>(L.N), 0);
        for (int k = 0; k < L.N; ++k) {
            const Key& key = L.keys[static_cast<size_t>(k)];
            bool o = !L.walk[static_cast<size_t>(k)];
            for (int l = 0; l < 4 && !o; ++l) if (!((SS.ground >> l) & 1) && (key.e[l] & 0x3FF) && !SS.deco.count(static_cast<uint32_t>(l) << 16 | (key.e[l] & 0x3FF))) o = true;
            keyobj[static_cast<size_t>(k)] = o;
        }
    }
    if (getenv("MB_STAMPSCAN")) { printf("area %d/%d grids %zu buildings %zu:", bz, ba, L.grids.size(), SS.st.size()); for (const auto& t : SS.st) printf(" %dx%d", t.w, t.h); printf("\n"); return false; }
    g_lm_pull.clear();
    if (getenv("MB_LMPULL") && !(L.global && opt.regions.size() >= 2)) {   // (experimental: landmarks are off in the game for now)
        for (const auto& lm : find_landmarks(L, bz)) g_lm_pull.push_back({lm.g, lm.sx, lm.sy, lm.w, lm.h});
        if (getenv("MB_DEBUG")) fprintf(stderr, "  landmarks to pull in: %zu\n", g_lm_pull.size());
    }
    const int W0 = opt.tw, H0 = opt.th;
    // piece sizes per try: big pieces first (few seams), then smaller (more ways to fit)
    static const int kPiece[10][2] = {{30, 12}, {18, 8}, {26, 10}, {22, 9}, {30, 12}, {18, 8}, {26, 10}, {22, 9}, {30, 12}, {18, 8}};
    // budget: work units (same on every PC); MB_BUDGET = extra time limit in ms (dev tools only)
    const uint64_t work_total = getenv("MB_WORK") ? strtoull(getenv("MB_WORK"), nullptr, 10) : (opt.work_max > 0 ? opt.work_max : 900000ull);   // (a floor that has not come together by then rarely does)
    const auto deadline = getenv("MB_BUDGET") ? std::chrono::steady_clock::now() + std::chrono::milliseconds(atoi(getenv("MB_BUDGET"))) : std::chrono::steady_clock::time_point::max();
    static const int kTriesEnv = getenv("MB_TRIES") ? atoi(getenv("MB_TRIES")) : 12;
    const int kTries = (opt.shrink_early || getenv("MB_SHRINK_EARLY")) ? 8 : kTriesEnv;
    // Each try is a floor of its own (its own dice, its own share of the work) - so several can
    // be built at once on a PC with cores to spare, and the result is the same on every PC: the
    // first try (in order) that comes together, within the work allowed.
    const uint64_t work_try = std::max<uint64_t>(300000ull, work_total / 3);
    const std::vector<LmWin> lm_pull = g_lm_pull;
    // a floor that will not come together at full size is tried smaller (fewer seams to mend);
    // a big floor: two tries at each size, each smaller try allowed less work
    static const bool shrink = !getenv("MB_NOSHRINK");
    static const bool early_env = getenv("MB_SHRINK_EARLY") != nullptr;
    const bool early = early_env || opt.shrink_early;
    auto try_scale = [&](int tryn) -> double {
        if (!shrink) return 1.0;
        if (early) { static const double k[8] = {1.0, 1.0, 0.87, 0.87, 0.77, 0.77, 0.68, 0.68}; return k[std::min(tryn, 7)]; }
        return tryn < 5 ? 1.0 : (tryn < 8 ? 0.85 : 0.72);
    };
    auto attempt = [&](const int T, Out* out) -> bool {
    g_work = 0; g_work_max = early ? static_cast<uint64_t>(work_try * try_scale(T) * try_scale(T)) : work_try; g_deadline = deadline; g_lm_pull = lm_pull; g_push = opt.push;
    std::mt19937 rng(seed + static_cast<uint32_t>(T) * 0x9E3779B9u);
    for (int tryn = T; tryn < T + 1; ++tryn) {
        if (over_time()) break;
        ++out->attempts;
        // a floor that will not come together at full size is tried smaller (fewer seams to mend)
        const double sc = try_scale(tryn);
        const int wmin = early ? std::min(W0, 64) : 32, hmin = early ? std::min(H0, 48) : 24;   // (a big floor never ends up smaller than a normal one)
        const int W = std::max(wmin, static_cast<int>(W0 * sc + 0.5)), H = std::max(hmin, static_cast<int>(H0 * sc + 0.5));
        Pt pin{0, 0}, pout{0, 0};
        make_plan(W, H, opt, rng, &out->mask, &pin, &pout, getenv("MB_WATERPLAN") && L.liquid_n >= 12);   // (rivers / lakes: real water seeded below - a planned shape never came out)
        struct Resv { int si, x, y; };
        std::vector<Resv> resv; std::vector<uint8_t> reserve;
        std::mt19937 srng(seed * 2654435761u + static_cast<uint32_t>(tryn) * 97u + 12345u);   // (buildings: their own dice, the floor itself is built as without them)
        // room for the buildings, kept before the quilt: the quilt keeps things off those spots
        // (plain ground of the kind the building stood on); set down there once the floor stands
        std::vector<Resv> qresv; std::vector<uint8_t> qreserve;
        static const int kQRes = getenv("MB_QRES") ? atoi(getenv("MB_QRES")) : 0;   // tries that keep room (tried: a few more buildings, a floor lost here and there - off)
        g_res_ground.clear(); g_ground_mask = SS.ground;
        if (tryn < kQRes && !keyobj.empty() && !SS.st.empty() && !(L.global && opt.regions.size() >= 2) && !g_rooms.empty()) {
            qreserve.assign(static_cast<size_t>(W) * H, 0);
            std::vector<size_t> rooms(g_rooms.size()); for (size_t i = 0; i < rooms.size(); ++i) rooms[i] = i;
            mb_shuffle(rooms.begin(), rooms.end(), srng);
            std::vector<int> taken;
            for (size_t ri : rooms) {
                if (static_cast<int>(qresv.size()) >= kStamps) break;
                const Room& r = g_rooms[ri];
                const int rcx = (r.x0 + r.x1) / 2, rcy = (r.y0 + r.y1) / 2;
                std::vector<int> order;   // the big ones first
                for (size_t i = 0; i < std::min<size_t>(SS.st.size(), 16); ++i) order.push_back(static_cast<int>(i));
                for (size_t i = 0; i + 1 < order.size(); ++i) { const size_t j = i + srng() % std::min<size_t>(3, order.size() - i); std::swap(order[i], order[j]); }
                bool done = false;
                for (size_t pk = 0; pk < order.size() && pk < 6 && !done; ++pk) {
                    const int si = order[pk];
                    if (std::find(taken.begin(), taken.end(), si) != taken.end()) continue;
                    const Stamp& t = SS.st[static_cast<size_t>(si)];
                    int bx = -1, by = -1, bs = 1 << 30;
                    for (int y0 = rcy - t.h / 2 - 8; y0 <= rcy - t.h / 2 + 8; ++y0) for (int x0 = rcx - t.w / 2 - 10; x0 <= rcx - t.w / 2 + 10; ++x0) {
                        if (x0 < 6 || y0 < 6 || x0 + t.w > W - 6 || y0 + t.h > H - 6) continue;
                        const int ccx = x0 + t.w / 2, ccy = y0 + t.h / 2;
                        if (std::abs(ccx - pin.x) + std::abs(ccy - pin.y) < 12 || std::abs(ccx - pout.x) + std::abs(ccy - pout.y) < 12) continue;
                        bool clear = true;
                        for (int y = -2; y < t.h + 2 && clear; ++y) for (int x = -2; x < t.w + 2 && clear; ++x) {
                            const size_t c = static_cast<size_t>(y0 + y) * W + x0 + x;
                            if (qreserve[c] || (!g_pathplan.empty() && g_pathW == W && g_pathplan[c] == 2)) clear = false;
                        }
                        if (!clear) continue;
                        const int sc = std::abs(ccx - rcx) + std::abs(ccy - rcy);
                        if (sc < bs) { bs = sc; bx = x0; by = y0; }
                    }
                    if (bx < 0) continue;
                    for (int y = -1; y < t.h + 1; ++y) for (int x = -1; x < t.w + 1; ++x) qreserve[static_cast<size_t>(by + y) * W + bx + x] = static_cast<uint8_t>(qresv.size() + 1);
                    {   std::unordered_map<uint32_t, char> gs; const Grid& g = L.grids[static_cast<size_t>(t.g)];
                        for (int y = -2; y < t.h + 2; ++y) for (int x = -2; x < t.w + 2; ++x) {
                            if (x >= 0 && y >= 0 && x < t.w && y < t.h) continue;
                            const Key& key = L.keys[static_cast<size_t>(g.at(t.x + x, t.y + y))];
                            for (int l = 0; l < 4; ++l) if ((SS.ground >> l) & 1) gs[static_cast<uint32_t>(l) << 16 | (key.e[l] & 0x3FF)] = 1;
                        }
                        g_res_ground.push_back(gs); }
                    qresv.push_back({si, bx, by}); taken.push_back(si); done = true;
                    if (getenv("MB_DEBUG")) fprintf(stderr, "  room kept (quilt) for building %dx%d at %d,%d\n", t.w, t.h, bx, by);
                }
            }
        }
        bool kept_clearing = false;
        const int kFResTries = getenv("MB_FRES") ? atoi(getenv("MB_FRES")) : (opt.keep_clearing ? 1 : 0);
        if (opt.foreign > 0 && tryn < kFResTries && !keyobj.empty() && !g_rooms.empty() && !L.global) {
            // a clearing kept for one big thing from another map (set down once the floor stands): the
            // quilt keeps plain ground there - the area's commonest open ground
            if (qreserve.empty()) qreserve.assign(static_cast<size_t>(W) * H, 0);
            std::unordered_map<uint32_t, double> gf; double tot = 0;
            for (int k = 0; k < L.N; ++k) {
                if (!L.walk[static_cast<size_t>(k)] || keyobj[static_cast<size_t>(k)]) continue;
                for (int l = 0; l < 4; ++l) if ((SS.ground >> l) & 1) { gf[static_cast<uint32_t>(l) << 16 | (L.keys[static_cast<size_t>(k)].e[l] & 0x3FF)] += L.freq[static_cast<size_t>(k)]; tot += L.freq[static_cast<size_t>(k)]; }
            }
            std::vector<std::pair<double, uint32_t>> gv; for (const auto& kv : gf) gv.push_back({kv.second, kv.first});
            std::stable_sort(gv.begin(), gv.end(), std::greater<>());
            std::unordered_map<uint32_t, char> gs; double cov = 0;
            for (const auto& g2 : gv) { if (cov >= tot * 0.85) break; gs[g2.second] = 1; cov += g2.first; }
            // the roomiest clearing of the plan, off the track, away from the ways in and on
            const int cw = 14 + static_cast<int>(srng() % 4u), ch = 12 + static_cast<int>(srng() % 3u);
            int bx = -1, by = -1; long bs = -(1L << 40);
            for (const Room& r : g_rooms) {
                const int rcx = (r.x0 + r.x1) / 2, rcy = (r.y0 + r.y1) / 2;
                for (int y0 = rcy - ch / 2 - 4; y0 <= rcy - ch / 2 + 4; ++y0) for (int x0 = rcx - cw / 2 - 5; x0 <= rcx - cw / 2 + 5; ++x0) {
                    if (x0 < 5 || y0 < 5 || x0 + cw > W - 5 || y0 + ch > H - 5) continue;
                    const int ccx = x0 + cw / 2, ccy = y0 + ch / 2;
                    if (std::abs(ccx - pin.x) + std::abs(ccy - pin.y) < 16 || std::abs(ccx - pout.x) + std::abs(ccy - pout.y) < 16) continue;
                    long sc = 0;
                    for (int y = 0; y < ch; ++y) for (int x = 0; x < cw; ++x) {
                        const size_t c = static_cast<size_t>(y0 + y) * W + x0 + x;
                        if (qreserve[c] || (!g_pathplan.empty() && g_pathW == W && g_pathplan[c] == 2)) sc -= 100;
                        if (out->mask.size() == static_cast<size_t>(W) * H && out->mask[c] == 1) sc += 1;   // (open in the plan)
                    }
                    sc = sc * 4 - (std::abs(ccx - (r.x0 + r.x1) / 2) + std::abs(ccy - (r.y0 + r.y1) / 2));
                    if (sc > bs) { bs = sc; bx = x0; by = y0; }
                }
            }
            if (getenv("MB_DEBUG") && bx < 0) fprintf(stderr, "  no clearing kept (%zu rooms)\n", g_rooms.size());
            if (bx >= 0) {
                g_res_ground.push_back(gs);
                const uint8_t id = static_cast<uint8_t>(g_res_ground.size());
                for (int y = 0; y < ch; ++y) for (int x = 0; x < cw; ++x) qreserve[static_cast<size_t>(by + y) * W + bx + x] = id;
                kept_clearing = true; out->keep_x = bx; out->keep_y = by; out->keep_w = cw; out->keep_h = ch;
                if (getenv("MB_DEBUG")) fprintf(stderr, "  clearing kept for a thing from another map: %dx%d at %d,%d\n", cw, ch, bx, by);
            }
        }
        g_reserve = (qresv.empty() && !kept_clearing) ? nullptr : &qreserve; g_keyobj = &keyobj;
        const bool mix = L.global && opt.regions.size() >= 2;
        if (mix) {
            // regions: the way in's region near it, the way on's near that; a
            // wavy border band between them where either may stand (the builder
            // finds real pieces there that join the two)
            const int nr = static_cast<int>(opt.regions.size());
            const double ph1 = (rng() % 1000) * 0.00628, ph2 = (rng() % 1000) * 0.00628;
            out->region.assign(static_cast<size_t>(W) * H, -1);
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                const double di = std::hypot(x - pin.x, y - pin.y), dout = std::hypot(x - pout.x, y - pout.y);
                const double f = (di - dout) / (di + dout + 1e-6) + 0.08 * std::sin(x * 0.21 + ph1) + 0.08 * std::sin(y * 0.17 + ph2);   // -1 .. 1
                const double u = (f + 1.0) * 0.5 * nr;   // 0 .. nr
                const int r = std::clamp(static_cast<int>(u), 0, nr - 1);
                const double edge = u - std::floor(u);
                static const double kBand = getenv("MB_BAND") ? atof(getenv("MB_BAND")) : 0.2;
                const bool band = (edge < kBand && r > 0) || (edge > 1.0 - kBand && r < nr - 1);
                out->region[static_cast<size_t>(y) * W + x] = static_cast<int8_t>(band ? -1 : r);
            }
        }
        // repairs keep each land to its own pieces only deep inside it: near the
        // border band either land (or pieces seen in both) may stand, so the
        // builder has room to find a way from one to the other
        std::vector<int8_t> reg_core;
        if (mix) {
            static const int kSoft = getenv("MB_SOFT") ? atoi(getenv("MB_SOFT")) : 0;
            reg_core = out->region;
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                if (out->region[static_cast<size_t>(y) * W + x] < 0) continue;
                bool near = false;
                for (int dy = -kSoft; dy <= kSoft && !near; ++dy) for (int dx = -kSoft; dx <= kSoft && !near; ++dx) {
                    const int xx = x + dx, yy = y + dy;
                    near = xx >= 0 && yy >= 0 && xx < W && yy < H && out->region[static_cast<size_t>(yy) * W + xx] < 0;
                }
                if (near) reg_core[static_cast<size_t>(y) * W + x] = -1;
            }
        }
        g_reg = mix ? &reg_core : nullptr; g_regW = W;
        std::vector<int> K; int sb = 0;
        auto tq0 = std::chrono::steady_clock::now();
        std::vector<int> seed_k, seed_org; std::vector<uint8_t> lm_lock; std::vector<Seeded> seeds; bool water_seeded = false;
        static const bool lm_on = getenv("MB_LMSEED") != nullptr;   // (laid down before the quilt: tried, costs floors; the pull below does it gently)
        static const int lm_tries = getenv("MB_LMTRIES") ? atoi(getenv("MB_LMTRIES")) : 2;   // (later tries without: the floor matters more)
        out->landmarks = 0;
        if (!mix && lm_on && tryn < lm_tries) {
            // a quilt without them first: which maps the floor is made of here (a landmark from another
            // map family would meet nothing around it)
            std::vector<int> K0, org0; int sb0 = 0;
            g_quilt_org = &org0;
            std::mt19937 r0 = rng;
            const bool q0 = quilt(L, out->mask, W, H, r0, &K0, &sb0, kPiece[tryn % 10][0], kPiece[tryn % 10][1], nullptr);
            g_quilt_org = nullptr;
            std::vector<uint8_t> allowed(L.grids.size(), 0);
            if (q0) {
                std::vector<int> use(L.grids.size(), 0);
                for (int o : org0) if (o >= 0 && static_cast<size_t>(o >> 20) < use.size()) ++use[static_cast<size_t>(o >> 20)];
                for (size_t gi = 0; gi < use.size(); ++gi) allowed[gi] = use[gi] * 8 >= W * H;   // an eighth of the floor or more
                if (getenv("MB_DEBUG")) { fprintf(stderr, "  floor made of:"); for (size_t gi = 0; gi < use.size(); ++gi) if (use[gi]) fprintf(stderr, " g%zu=%d", gi, use[gi]); fprintf(stderr, "\n"); }
            }
            seeds = seed_landmarks(L, W, H, bz, rng, &seed_k, &seed_org, &lm_lock, kPiece[tryn % 10][0], kPiece[tryn % 10][1], allowed, org0);
        }
        if (!mix && seeds.empty() && (opt.layout == 2 || opt.layout == 3) && L.liquid_n >= 12) {   // a river / a lake: real water seeded, carried on by the quilt
            static thread_local std::vector<Landmark> wcache; static thread_local uint64_t wlib = 0; static thread_local int wlay = -1;
            if (wlib != L.serial || wlay != opt.layout) { wcache = find_water_windows(L, bz, opt.layout); if (wcache.empty() && opt.layout == 3) wcache = find_water_windows(L, bz, 2); wlib = L.serial; wlay = opt.layout; if (getenv("MB_DEBUG")) fprintf(stderr, "  water windows found: %zu\n", wcache.size()); }
            const int tcx = W / 2 + static_cast<int>(rng() % 9u) - 4, tcy = H / 2 + static_cast<int>(rng() % 7u) - 3;
            std::vector<int> no_org; std::vector<uint8_t> no_allow;
            seeds = seed_landmarks(L, W, H, bz, rng, &seed_k, &seed_org, &lm_lock, kPiece[tryn % 10][0], kPiece[tryn % 10][1], no_allow, no_org, &wcache, tcx, tcy);
            if (getenv("MB_DEBUG")) fprintf(stderr, "  water seeded: %zu\n", seeds.size());
            water_seeded = !seeds.empty();
        }
        if (!seeds.empty()) { g_seed_k = &seed_k; g_seed_org = &seed_org; g_seed_src.clear(); for (const auto& sd : seeds) g_seed_src.push_back({sd.x, sd.y, sd.w, sd.h, sd.g, sd.sx, sd.sy}); }
        const bool qok = quilt(L, out->mask, W, H, rng, &K, &sb, kPiece[tryn % 10][0], kPiece[tryn % 10][1], mix ? &out->region : nullptr);
        g_seed_k = g_seed_org = nullptr; g_reserve = nullptr;
        if (!qok) continue;
        auto tq1 = std::chrono::steady_clock::now();
        out->seam_bad = sb;
        std::vector<uint8_t> touched_band(static_cast<size_t>(W) * H, 0);
        auto region_report = [&](const char* when) {
            if (!mix || !getenv("MB_DEBUG")) return;
            for (size_t r = 0; r < opt.regions.size(); ++r) { int plan = 0, have = 0; for (int c = 0; c < W * H; ++c) if (out->region[static_cast<size_t>(c)] == static_cast<int>(r)) { ++plan; have += (L.key_regions[static_cast<size_t>(K[static_cast<size_t>(c)])] >> r) & 1; } fprintf(stderr, "  %s: region %zu %d/%d\n", when, r, have, plan); }
        };
        region_report("after quilt");
        if (mix && !getenv("MB_NOBAND")) {   // the border band as a whole: the two lands meet here, solved in one go
            std::vector<uint8_t> fb(static_cast<size_t>(W) * H, 0);
            static const int kBandGrow = getenv("MB_BANDGROW") ? atoi(getenv("MB_BANDGROW")) : 3;
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {   // the band and a few cells into each land (each keeps to its own there)
                bool near = false;
                for (int dy = -kBandGrow; dy <= kBandGrow && !near; ++dy) for (int dx = -kBandGrow; dx <= kBandGrow && !near; ++dx) {
                    const int xx = x + dx, yy = y + dy;
                    near = xx >= 0 && yy >= 0 && xx < W && yy < H && out->region[static_cast<size_t>(yy) * W + xx] < 0;
                }
                if (near) fb[static_cast<size_t>(y) * W + x] = 1;
            }
            expand_rigid(L, K, W, H, fb, 6);
            Repair rb(L, W, H);
            std::vector<int> K2 = K;
            const bool okb = rb.solve(K2, fb, rng);
            if (okb) { K = K2; for (int c = 0; c < W * H; ++c) if (fb[static_cast<size_t>(c)]) touched_band[static_cast<size_t>(c)] = 1; }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  border band solve: %s (fail cell %d,%d region %d)\n", okb ? "ok" : "no way to join here", rb.fail_cell % W, rb.fail_cell / W, rb.fail_cell >= 0 ? out->region[static_cast<size_t>(rb.fail_cell)] : 9);
            // (if it cannot be solved in one go, the usual repairs below still try, spot by spot)
        }
        std::vector<uint8_t> touched = touched_band;
        // a few pairs the joint rule rejects are kept when every layer on its own
        // meets as in a real map (hardly visible; the floor is not thrown away)
        static const int kLooseMax = getenv("MB_LOOSEMAX") ? atoi(getenv("MB_LOOSEMAX")) : 8;
        static const int kAcceptEnv = getenv("MB_ACCEPTBAD") ? atoi(getenv("MB_ACCEPTBAD")) : -1;
        const int accept_bad = kAcceptEnv >= 0 ? kAcceptEnv : opt.accept_bad;
        auto loose_accept = [&](int nbad) {
            if (nbad > 0 && nbad <= accept_bad) {   // a big floor: a few seams left are better than no floor
                if (getenv("MB_DEBUG")) fprintf(stderr, "  %d seams left - accepted\n", nbad);
                out->loose = nbad; return 0;
            }
            if (nbad <= 0 || nbad > kLooseMax) return nbad;
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                const int a = K[static_cast<size_t>(y) * W + x];
                if (x + 1 < W) { const int b = K[static_cast<size_t>(y) * W + x + 1]; if (!L.ok(0, a, b) && !L.loose_ok(0, a, b)) return nbad; }
                if (y + 1 < H) { const int b = K[static_cast<size_t>(y + 1) * W + x]; if (!L.ok(2, a, b) && !L.loose_ok(2, a, b)) return nbad; }
            }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  %d pairs kept (each layer fits)\n", nbad);
            out->loose = nbad;
            return 0;
        };
        out->loose = 0;
        if (!seeds.empty() && getenv("MB_DEBUG")) {
            int all = count_bad(L, K, W, H, 0, 0, W, H, nullptr), near = 0;
            for (const auto& sd : seeds) near += count_bad(L, K, W, H, sd.x - 1, sd.y - 1, sd.x + sd.w + 1, sd.y + sd.h + 1, nullptr);
            fprintf(stderr, "  after quilt: %d bad, %d at the landmarks' edges\n", all, near);
        }
        if (!seeds.empty()) {   // the landmarks stay whole if the mending can manage; if not, they give way
            // (locked during the mending they only block it: the usual mending keeps most of them anyway)
            static const bool lm_lockrep = getenv("MB_LMLOCKREP") != nullptr;
            int left;
            if (lm_lockrep || water_seeded) { g_lock = &lm_lock; left = repair_all(L, K, W, H, rng, &touched); g_lock = nullptr; if (left > 0 && !over_time()) left = repair_all(L, K, W, H, rng, &touched); }
            else left = repair_all(L, K, W, H, rng, &touched);
            if (left > 0 && getenv("MB_DEBUG")) {
                std::vector<uint8_t> mk(K.size(), 0); count_bad(L, K, W, H, 0, 0, W, H, &mk);
                fprintf(stderr, "  bad cells:"); for (int c = 0; c < W * H; ++c) if (mk[static_cast<size_t>(c)]) fprintf(stderr, " %d,%d", c % W, c / W); fprintf(stderr, "\n");
            }
            out->landmarks = 0;
            for (const auto& sd : seeds) {
                const Grid& g = L.grids[static_cast<size_t>(sd.g)]; int kept = 0;
                for (int y = 0; y < sd.h; ++y) for (int x = 0; x < sd.w; ++x) kept += K[static_cast<size_t>(sd.y + y) * W + sd.x + x] == g.at(sd.sx + x, sd.sy + y);
                if (kept * 10 >= sd.w * sd.h * 7) ++out->landmarks;
                if (getenv("MB_DEBUG")) fprintf(stderr, "  landmark %dx%d at %d,%d (grid %d at %d,%d): %d of %d cells kept\n", sd.w, sd.h, sd.x, sd.y, sd.g, sd.sx, sd.sy, kept, sd.w * sd.h);
            }
            out->bad_pairs = loose_accept(left);
        }
        else out->bad_pairs = loose_accept(repair_all(L, K, W, H, rng, &touched));
        region_report("after repair");
        if (mix && getenv("MB_DEBUG")) {   // where the bad pairs are: border band / region 0 / region 1 / across
            int where[4] = {0, 0, 0, 0};
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                const int a = K[static_cast<size_t>(y) * W + x], ra = out->region[static_cast<size_t>(y) * W + x];
                for (int d = 0; d < 2; ++d) {
                    const int nx = x + (d == 0), ny = y + (d == 1); if (nx >= W || ny >= H) continue;
                    const int b = K[static_cast<size_t>(ny) * W + nx], rb = out->region[static_cast<size_t>(ny) * W + nx];
                    if (L.ok(d == 0 ? 0 : 2, a, b)) continue;
                    where[(ra < 0 || rb < 0) ? 0 : (ra != rb ? 3 : 1 + ra)]++;
                }
            }
            fprintf(stderr, "  bad pairs: band %d, region0 %d, region1 %d, across %d\n", where[0], where[1], where[2], where[3]);
        }
        if (!out->bad_pairs && !mix && getenv("MB_LMPASTE")) place_landmarks(L, K, W, H, bz, rng, &touched);
        if (!out->bad_pairs) {
            const int is = opt.in_side >= 0 ? opt.in_side : 3;
            int os = opt.out_side >= 0 ? opt.out_side : (is ^ 1);
            if (os == is) os = is ^ 1;
            connect(L, K, W, H, &pin, &pout, is, os, rng, &touched);
            if (opt.side_side >= 0 && opt.side_side != is && opt.side_side != os) {   // the side way: from the way in to the middle of its side
                Pt pin2 = pin;
                Pt pside = opt.side_side < 2 ? Pt{opt.side_side == 0 ? 0 : W - 1, H / 2} : Pt{W / 2, opt.side_side == 2 ? 0 : H - 1};
                connect(L, K, W, H, &pin2, &pside, is, opt.side_side, rng, &touched);
            }
            out->bad_pairs = loose_accept(count_bad(L, K, W, H, 0, 0, W, H, nullptr));
        }
        // room for the buildings: a clearing kept open for each (the quilt keeps things
        // off it; the building is set down there once the floor stands)
        static const int kResTries = getenv("MB_KEYPLACE") ? 99 : 0;   // (set into the floor cell by cell: tried; the ground around often shows a lighter box - off)   // (later tries without: the floor matters more)
        if (kResTries > 0) { g_res_ground.clear(); g_ground_mask = SS.ground; }
        if (tryn < kResTries && !out->bad_pairs && !keyobj.empty() && !SS.st.empty() && !(L.global && opt.regions.size() >= 2) && !g_rooms.empty()) {
            reserve.assign(static_cast<size_t>(W) * H, 0);
            std::vector<size_t> rooms(g_rooms.size()); for (size_t i = 0; i < rooms.size(); ++i) rooms[i] = i;
            mb_shuffle(rooms.begin(), rooms.end(), srng);
            std::vector<int> taken;
            for (size_t ri : rooms) {
                if (static_cast<int>(resv.size()) >= kStamps) break;
                const Room& r = g_rooms[ri];
                const int rcx = (r.x0 + r.x1) / 2, rcy = (r.y0 + r.y1) / 2;
                std::vector<int> order;   // the big ones first
                for (size_t i = 0; i < std::min<size_t>(SS.st.size(), 16); ++i) order.push_back(static_cast<int>(i));
                for (size_t i = 0; i + 1 < order.size(); ++i) { const size_t j = i + srng() % std::min<size_t>(3, order.size() - i); std::swap(order[i], order[j]); }
                bool done = false;
                for (size_t pk = 0; pk < order.size() && pk < 6 && !done; ++pk) {
                    const int si = order[pk];
                    if (std::find(taken.begin(), taken.end(), si) != taken.end()) continue;
                    const Stamp& t = SS.st[static_cast<size_t>(si)];
                    int bx = -1, by = -1, bs = 1 << 30;
                    for (int y0 = rcy - t.h / 2 - 10; y0 <= rcy - t.h / 2 + 10; ++y0) for (int x0 = rcx - t.w / 2 - 12; x0 <= rcx - t.w / 2 + 12; ++x0) {
                        if (x0 < 6 || y0 < 6 || x0 + t.w > W - 6 || y0 + t.h > H - 6) continue;
                        const int ccx = x0 + t.w / 2, ccy = y0 + t.h / 2;
                        if (std::abs(ccx - pin.x) + std::abs(ccy - pin.y) < 12 || std::abs(ccx - pout.x) + std::abs(ccy - pout.y) < 12) continue;
                        bool clear = true;
                        for (int y = -2; y < t.h + 2 && clear; ++y) for (int x = -2; x < t.w + 2 && clear; ++x) {
                            const size_t c = static_cast<size_t>(y0 + y) * W + x0 + x;
                            if (reserve[c] || (!g_pathplan.empty() && g_pathW == W && g_pathplan[c] == 2)) clear = false;
                        }
                        if (!clear) continue;
                        int nobj = 0;   // (where the least stands already: the easiest to clear)
                        for (int y = -1; y < t.h + 1; ++y) for (int x = -1; x < t.w + 1; ++x) nobj += keyobj[static_cast<size_t>(K[static_cast<size_t>(y0 + y) * W + x0 + x])];
                        int phase = 0;   // the ground's pattern in step with the building's own ground (a patterned ground cannot shift its step)
                        {   const Grid& g = L.grids[static_cast<size_t>(t.g)];
                            for (int y = -2; y < t.h + 2; ++y) for (int x = -2; x < t.w + 2; ++x) {
                                if (x >= 0 && y >= 0 && x < t.w && y < t.h) continue;
                                const Key& a = L.keys[static_cast<size_t>(g.at(t.x + x, t.y + y))];
                                const Key& b = L.keys[static_cast<size_t>(K[static_cast<size_t>(y0 + y) * W + x0 + x])];
                                for (int l = 0; l < 4; ++l) if ((SS.ground >> l) & 1) phase += a.e[l] == b.e[l];
                            } }
                        const int sc = nobj * 6 - phase * 4 + std::abs(ccx - rcx) + std::abs(ccy - rcy);
                        if (sc < bs) { bs = sc; bx = x0; by = y0; }
                    }
                    if (bx < 0) continue;
                    for (int y = -1; y < t.h + 1; ++y) for (int x = -1; x < t.w + 1; ++x) reserve[static_cast<size_t>(by + y) * W + bx + x] = static_cast<uint8_t>(resv.size() + 1);
                    {   // the ground it stood on
                        std::unordered_map<uint32_t, char> gs; const Grid& g = L.grids[static_cast<size_t>(t.g)];
                        for (int y = -2; y < t.h + 2; ++y) for (int x = -2; x < t.w + 2; ++x) {
                            if (x >= 0 && y >= 0 && x < t.w && y < t.h) continue;
                            const Key& key = L.keys[static_cast<size_t>(g.at(t.x + x, t.y + y))];
                            for (int l = 0; l < 4; ++l) if ((SS.ground >> l) & 1) gs[static_cast<uint32_t>(l) << 16 | (key.e[l] & 0x3FF)] = 1;
                        }
                        g_res_ground.push_back(gs);
                    }
                    resv.push_back({si, bx, by}); taken.push_back(si); done = true;
                    if (getenv("MB_DEBUG")) fprintf(stderr, "  room kept for building %dx%d at %d,%d (score %d)\n", t.w, t.h, bx, by, bs);
                }
            }
        }
        // each building set down whole where room was kept: its own open ground around it
        // comes along (a ring of plain ground, as in its map), and the ground between
        // that and the floor is re-solved; the building itself stays as it is
        std::vector<int> placed_si;
        if (!out->bad_pairs && !resv.empty()) {
            const uint64_t work_before = g_work;   // (not charged to the floor's budget)
            struct WorkBack { uint64_t w; ~WorkBack() { g_work = w; } } work_back{work_before};
            auto way_open_k = [&](const std::vector<int>& KK) {
                auto wk = [&](int x, int y) { return x >= 0 && y >= 0 && x < W && y < H && L.walk[static_cast<size_t>(KK[static_cast<size_t>(y) * W + x])]; };
                auto body = [&](int x, int y) { for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) if (!wk(x + dx, y + dy)) return false; return true; };
                std::vector<uint8_t> vis(static_cast<size_t>(W) * H, 0); std::vector<int> q, s1;
                for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) {
                    if (body(pin.x + dx, pin.y + dy)) { const int c = (pin.y + dy) * W + pin.x + dx; if (!vis[static_cast<size_t>(c)]) { vis[static_cast<size_t>(c)] = 1; q.push_back(c); } }
                    if (body(pout.x + dx, pout.y + dy)) s1.push_back((pout.y + dy) * W + pout.x + dx);
                }
                if (q.empty() || s1.empty()) return false;
                for (size_t h = 0; h < q.size(); ++h) {
                    const int c = q[h], x = c % W, y = c / W;
                    const int nb[4][2] = {{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}};
                    for (auto& v : nb) { if (!body(v[0], v[1])) continue; const int c2 = v[1] * W + v[0]; if (!vis[static_cast<size_t>(c2)]) { vis[static_cast<size_t>(c2)] = 1; q.push_back(c2); } }
                }
                for (int c : s1) if (vis[static_cast<size_t>(c)]) return true;
                return false;
            };
            for (size_t ri = 0; ri < resv.size(); ++ri) {
                const Resv& rv = resv[ri]; const Stamp& t = SS.st[static_cast<size_t>(rv.si)];
                const Grid& g = L.grids[static_cast<size_t>(t.g)];
                bool done = false;
                for (int band = 2; band <= 4 && !done; band += 2) {
                    std::vector<int> K2 = K;
                    for (int y = -2; y < t.h + 2; ++y) for (int x = -2; x < t.w + 2; ++x) K2[static_cast<size_t>(rv.y + y) * W + rv.x + x] = g.at(t.x + x, t.y + y);
                    const int e = 2 + band;
                    const int bx0 = std::max(0, rv.x - e - 1), by0 = std::max(0, rv.y - e - 1), bx1 = std::min(W - 1, rv.x + t.w + e), by1 = std::min(H - 1, rv.y + t.h + e);
                    const int sw = bx1 - bx0 + 1, sh = by1 - by0 + 1;
                    std::vector<int> sub(static_cast<size_t>(sw) * sh); std::vector<uint8_t> sf(sub.size(), 0);
                    for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) {
                        const int fx = bx0 + x, fy = by0 + y; const size_t i = static_cast<size_t>(y) * sw + x;
                        sub[i] = K2[static_cast<size_t>(fy) * W + fx];
                        const bool in_box = fx >= rv.x && fx < rv.x + t.w && fy >= rv.y && fy < rv.y + t.h;
                        const bool in_band = fx >= rv.x - e && fx < rv.x + t.w + e && fy >= rv.y - e && fy < rv.y + t.h + e && fx > 0 && fy > 0 && fx < W - 1 && fy < H - 1;
                        sf[i] = in_band && !in_box;
                    }
                    Repair rp(L, sw, sh); rp.ox = bx0; rp.oy = by0;
                    const bool okk = rp.solve(sub, sf, srng);
                    if (getenv("MB_DEBUG")) fprintf(stderr, "  building %dx%d into kept room %d,%d (band %d): %s\n", t.w, t.h, rv.x, rv.y, band, okk ? "fits" : "no");
                    if (!okk) continue;
                    for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x) if (sf[static_cast<size_t>(y) * sw + x]) K2[static_cast<size_t>(by0 + y) * W + bx0 + x] = sub[static_cast<size_t>(y) * sw + x];
                    if (count_bad(L, K2, W, H, bx0 - 1, by0 - 1, bx1 + 2, by1 + 2, nullptr) > 0) continue;
                    if (!way_open_k(K2)) { if (getenv("MB_DEBUG")) fprintf(stderr, "  (it would close the way)\n"); break; }
                    for (int y = by0; y <= by1; ++y) for (int x = bx0; x <= bx1; ++x) { const size_t c = static_cast<size_t>(y) * W + x; if (K2[c] != K[c]) touched[c] = 0; }
                    K = K2; done = true; placed_si.push_back(rv.si);
                }
            }
        }
        if (!g_lm_pull.empty() && !out->bad_pairs) {   // landmarks standing whole in a clearing
            int n = 0; std::vector<uint8_t> used(K.size(), 0);
            for (const auto& lw : g_lm_pull) {
                const Grid& g = L.grids[static_cast<size_t>(lw.g)];
                const int k00 = g.at(lw.sx, lw.sy);
                for (int y = 0; y + lw.h <= H; ++y) for (int x = 0; x + lw.w <= W; ++x) {
                    if (K[static_cast<size_t>(y) * W + x] != k00 || used[static_cast<size_t>(y) * W + x]) continue;
                    bool same = true;
                    for (int yy = 0; yy < lw.h && same; ++yy) for (int xx = 0; xx < lw.w && same; ++xx) same = K[static_cast<size_t>(y + yy) * W + x + xx] == g.at(lw.sx + xx, lw.sy + yy);
                    if (!same) continue;
                    const int cx = x + lw.w / 2, cy = y + lw.h / 2; bool in_room = false;
                    for (const auto& r : g_rooms) if (cx >= r.x0 - 3 && cx <= r.x1 + 3 && cy >= r.y0 - 3 && cy <= r.y1 + 3) { in_room = true; break; }
                    if (!in_room) continue;
                    ++n; for (int yy = 0; yy < lw.h; ++yy) for (int xx = 0; xx < lw.w; ++xx) used[static_cast<size_t>(y + yy) * W + x + xx] = 1;
                    if (getenv("MB_DEBUG")) fprintf(stderr, "  landmark %dx%d standing at %d,%d\n", lw.w, lw.h, x, y);
                }
            }
            out->landmarks = n;
        }
        if (getenv("MB_DEBUG")) fprintf(stderr, "time quilt %.0f ms repair %.0f ms\n", std::chrono::duration<double, std::milli>(tq1 - tq0).count(), std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tq1).count());
        out->tw = W; out->th = H;
        for (auto& l : out->L) l.assign(static_cast<size_t>(W) * H, 0);
        out->wa.assign(static_cast<size_t>(W) * H, 0); out->wb.assign(static_cast<size_t>(W) * H, 0);
        // tiles -> slots: the area's own slots, or (mixed floor) a tile list of its own:
        // slot 0 = the empty tile, then every tile used, by game-wide number (the
        // game's list is delta coded, so rising); animated tiles keep their slot
        std::unordered_map<uint32_t, uint16_t> slot_of;
        out->tile_list.clear();
        bool too_many = false;
        if (L.global) {
            std::vector<std::pair<uint32_t, uint32_t>> used;   // game-wide number, id
            int first_anim = 896;                               // tile maps live from slot 896 on
            std::unordered_map<uint32_t, char> seen;
            for (int c = 0; c < W * H; ++c) for (int l = 0; l < 4; ++l) {
                const uint32_t id = L.keys[static_cast<size_t>(K[static_cast<size_t>(c)])].e[l] & 0xFFFF;
                if (!id || !seen.emplace(id, 1).second) continue;
                if (id >= 0xC000) { first_anim = std::min(first_anim, static_cast<int>(id & 0x3FF)); slot_of[id] = static_cast<uint16_t>(id & 0x3FF); continue; }
                const uint32_t gnum = (opt.id_global && id < opt.id_global->size()) ? (*opt.id_global)[id] : 0;
                if (!gnum) { too_many = true; continue; }
                used.push_back({gnum, id});
            }
            std::stable_sort(used.begin(), used.end());
            out->tile_list.push_back(0);
            for (const auto& u : used) { slot_of[u.second] = static_cast<uint16_t>(out->tile_list.size()); out->tile_list.push_back(u.first); }
            if (static_cast<int>(out->tile_list.size()) > first_anim) too_many = true;   // would overwrite animated tiles / tile maps
            if (getenv("MB_DEBUG")) fprintf(stderr, "  mixed floor: %zu tiles (room for %d)%s\n", out->tile_list.size(), first_anim, too_many ? " - TOO MANY" : "");
        }
        for (int c = 0; c < W * H; ++c) {
            const Key& k = L.keys[static_cast<size_t>(K[static_cast<size_t>(c)])];
            for (int l = 0; l < 4; ++l) {
                const uint32_t e = k.e[l], tile = e & 0xFFFF;
                const uint16_t slot = L.global ? (tile ? slot_of[tile] : 0) : static_cast<uint16_t>(tile);
                out->L[l][static_cast<size_t>(c)] = static_cast<uint16_t>((e >> 16) | slot);
            }
            out->wa[static_cast<size_t>(c)] = k.wa; out->wb[static_cast<size_t>(c)] = k.wb;
        }
        if (opt.tile_pixels && !L.global && !getenv("MB_NOHOLES")) {
            // no see-through holes: where no layer draws a pixel the backdrop shows (a black
            // square in the field) - such a cell takes the ground of a neighbour on an empty layer
            const uint16_t* base = ids_of(bank, bz, ba);
            auto pix = [&](uint16_t v) -> const uint8_t* {
                const uint32_t t = v & 0x3FF; if (!t || !base) return nullptr;
                const uint32_t id = base[t]; if (!id || id >= 0xC000) return nullptr;
                return opt.tile_pixels(static_cast<uint16_t>(id));
            };
            auto full = [&](uint16_t v) { if ((v & 0x3FF) && base && base[v & 0x3FF] >= 0xC000) return true; const uint8_t* tp = pix(v); if (!tp) return false; for (int i = 0; i < 64; ++i) if (!tp[i]) return false; return true; };
            int filled = 0;
            int lord[4] = {0, 1, 2, 3}; long lcnt[4] = {0, 0, 0, 0};   // the ground layer first: the one most often fully drawn
            for (int c = 0; c < W * H; c += 3) for (int l = 0; l < 4; ++l) if (full(out->L[l][static_cast<size_t>(c)])) ++lcnt[l];
            std::stable_sort(lord, lord + 4, [&](int a2, int b2) { return lcnt[a2] > lcnt[b2]; });
            for (int c = 0; c < W * H; ++c) {
                bool cov[64] = {}; int n = 0; bool anim = false;
                for (int l = 0; l < 4; ++l) {
                    const uint16_t v = out->L[l][static_cast<size_t>(c)];
                    if ((v & 0x3FF) && base && base[v & 0x3FF] >= 0xC000) { anim = true; break; }
                    const uint8_t* tp = pix(v); if (!tp) continue;
                    for (int i = 0; i < 64; ++i) if (tp[i] && !cov[i]) { cov[i] = true; ++n; }
                }
                if (anim || n == 64) continue;
                const int cx = c % W, cy = c / W; bool done = false;
                for (int r = 1; r <= 4 && !done; ++r)
                    for (int dy = -r; dy <= r && !done; ++dy) for (int dx = -r; dx <= r && !done; ++dx) {
                        if (std::max(std::abs(dx), std::abs(dy)) != r) continue;
                        const int nx = cx + dx, ny = cy + dy; if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
                        const size_t nc = static_cast<size_t>(ny) * W + nx;
                        for (int li = 0; li < 4 && !done; ++li) {
                            const int l = lord[li];
                            if (lcnt[l] == 0) break;
                            const uint16_t v = out->L[l][nc];
                            if (!full(v) || (out->L[l][static_cast<size_t>(c)] & 0x3FF)) continue;
                            out->L[l][static_cast<size_t>(c)] = v; done = true; ++filled;
                        }
                    }
            }
            if (getenv("MB_DEBUG") || getenv("LOG2_WORLD_LOG")) if (filled) fprintf(stderr, "  %d see-through cells filled\n", filled);
        }
        if (too_many) { out->bad_pairs = 1; continue; }
        if (mix && !out->bad_pairs) {
            // a mixed floor must really show every region where it was planned
            // (not one region everywhere because the two would not join)
            bool mixed_ok = true;
            for (size_t r = 0; r < opt.regions.size(); ++r) {
                int plan = 0, have = 0;
                for (int c = 0; c < W * H; ++c) if (out->region[static_cast<size_t>(c)] == static_cast<int>(r)) { ++plan; have += (L.key_regions[static_cast<size_t>(K[static_cast<size_t>(c)])] >> r) & 1; }
                static const double kMixMin = getenv("MB_MIXMIN") ? atof(getenv("MB_MIXMIN")) : 0.6;
                if (getenv("MB_DEBUG")) fprintf(stderr, "  region %zu: %d of %d planned cells show it\n", r, have, plan);
                if (plan && have < plan * kMixMin) mixed_ok = false;
            }
            if (!mixed_ok) { out->bad_pairs = 1; continue; }
        }
        if (out->bad_pairs) continue;
        // repaired cells take the walk bits of their surroundings when they stand alone
        for (int pass = 0; pass < 2; ++pass)
            for (int c = 0; c < W * H; ++c) {
                if (!touched[static_cast<size_t>(c)]) continue;
                const int x = c % W, y = c / W; int same = 0, n = 0, sa = 0;
                const int nbs[4] = {x + 1 < W ? c + 1 : -1, x > 0 ? c - 1 : -1, y + 1 < H ? c + W : -1, y > 0 ? c - W : -1};
                for (int q : nbs) if (q >= 0) { ++n; sa += out->wa[static_cast<size_t>(q)]; same += out->wa[static_cast<size_t>(q)] == out->wa[static_cast<size_t>(c)]; }
                (void)same; (void)sa;   // (walk bits stay the cell's own: what you see is what blocks - no invisible walls)
            }
        // buildings set down whole in the clearings (on open ground, off the track;
        // never closing the way through)
        out->landmarks = static_cast<int>(placed_si.size());
        if (kStamps > 0 && !L.global && !mix && !g_rooms.empty()) {
            auto floor_obj = [&](int c) {
                // (the floor's layer entries: tile = low 10 bits; ground decoration does not count)
                for (int l = 0; l < 4; ++l) {
                    if ((SS.ground >> l) & 1) continue;
                    const uint32_t t = out->L[l][static_cast<size_t>(c)] & 0x3FF;
                    if (t && !SS.deco.count(static_cast<uint32_t>(l) << 16 | t)) return true;
                }
                return !out->wa[static_cast<size_t>(c)];
            };
            auto body_ok = [&](int x, int y) {
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H || !out->wa[static_cast<size_t>(yy) * W + xx]) return false; }
                return true;
            };
            auto way_open = [&]() {   // the fighter's body still gets from the way in to the way on
                std::vector<uint8_t> vis(static_cast<size_t>(W) * H, 0); std::vector<int> q;
                auto near_ok = [&](Pt p, std::vector<int>* seeds) { for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int x = p.x + dx, y = p.y + dy; if (body_ok(x, y)) seeds->push_back(y * W + x); } };
                std::vector<int> s0, s1; near_ok(pin, &s0); near_ok(pout, &s1);
                if (s0.empty() || s1.empty()) return false;
                for (int c : s0) { vis[static_cast<size_t>(c)] = 1; q.push_back(c); }
                for (size_t h = 0; h < q.size(); ++h) {
                    const int c = q[h], x = c % W, y = c / W;
                    const int nb[4][2] = {{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}};
                    for (auto& v : nb) { if (v[0] < 0 || v[1] < 0 || v[0] >= W || v[1] >= H) continue; const int c2 = v[1] * W + v[0]; if (!vis[static_cast<size_t>(c2)] && body_ok(v[0], v[1])) { vis[static_cast<size_t>(c2)] = 1; q.push_back(c2); } }
                }
                for (int c : s1) if (vis[static_cast<size_t>(c)]) return true;
                return false;
            };
            std::vector<int> used_st = placed_si;
            // where one can walk to from the way in (the top of a roof is "walkable" in the
            // collision map but nobody gets there: nothing is set down on it)
            std::vector<uint8_t> reach(static_cast<size_t>(W) * H, 0);
            {   // (cells the fighter's body covers somewhere on its way from the way in)
                std::vector<uint8_t> vis(static_cast<size_t>(W) * H, 0); std::vector<int> q;
                for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int x = pin.x + dx, y = pin.y + dy; if (body_ok(x, y) && !vis[static_cast<size_t>(y) * W + x]) { vis[static_cast<size_t>(y) * W + x] = 1; q.push_back(y * W + x); } }
                for (size_t h = 0; h < q.size(); ++h) {
                    const int c = q[h], x = c % W, y = c / W;
                    for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) reach[static_cast<size_t>(y + dy) * W + x + dx] = 1;
                    const int nb[4][2] = {{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}};
                    for (auto& v : nb) { if (!body_ok(v[0], v[1])) continue; const size_t c2 = static_cast<size_t>(v[1]) * W + v[0]; if (!vis[c2]) { vis[c2] = 1; q.push_back(static_cast<int>(c2)); } }
                }
            }
            // set building si down near (cx, cy) (its top-left within rx / ry of it): on free
            // ground of its own kind, off the track, the way through kept open
            auto try_place = [&](int si, int cx0, int cy0, int rx, int ry, bool near_centre, bool kept = false) {
                const Stamp& t = SS.st[static_cast<size_t>(si)];
                const Grid& g = L.grids[static_cast<size_t>(t.g)];
                int bx = -1, by = -1; double bs = -1e9; int why[4] = {0, 0, 0, 0};
                for (int y0 = cy0 - ry; y0 <= cy0 + ry; ++y0) for (int x0 = cx0 - rx; x0 <= cx0 + rx; ++x0) {
                    if (x0 < 5 || y0 < 5 || x0 + t.w > W - 5 || y0 + t.h > H - 5) continue;
                    const int ccx = x0 + t.w / 2, ccy = y0 + t.h / 2;
                    if (std::abs(ccx - pin.x) + std::abs(ccy - pin.y) < 10 || std::abs(ccx - pout.x) + std::abs(ccy - pout.y) < 10) continue;
                    bool clear = true; int match = 0;
                    for (int y = -1; y < t.h + 1 && clear; ++y) for (int x = -1; x < t.w + 1 && clear; ++x) {
                        const int c = (y0 + y) * W + x0 + x;
                        if (floor_obj(c) || !reach[static_cast<size_t>(c)]) { clear = false; ++why[0]; }
                        else if (!g_pathplan.empty() && g_pathW == W && g_pathplan[static_cast<size_t>(c)] == 2) { clear = false; ++why[1]; }
                        else {   // the ground under and around it in step with its own (the same ground tiles)
                            const Key& sk = L.keys[static_cast<size_t>(g.at(t.x + x, t.y + y))];
                            for (int l = 0; l < 4; ++l) if ((SS.ground >> l) & 1) match += out->L[l][static_cast<size_t>(c)] == static_cast<uint16_t>((sk.e[l] >> 16) | (sk.e[l] & 0xFFFF));
                        }
                    }
                    if (!clear) continue;
                    if (true || !kept) {   // it stood on the same kind of ground as this (grass on grass, paving on paving)
                        std::unordered_map<uint32_t, char> here;
                        for (int y = -4; y < t.h + 4; ++y) for (int x = -4; x < t.w + 4; ++x) {
                            const int xx = x0 + x, yy = y0 + y; if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
                            for (int l = 0; l < 4; ++l) here[static_cast<uint32_t>(l) << 16 | (out->L[l][static_cast<size_t>(yy) * W + xx] & 0x3FF)] = 1;
                        }
                        int ring = 0, same = 0;
                        for (int y = -1; y <= t.h; ++y) for (int x = -1; x <= t.w; ++x) {
                            if (x >= 0 && y >= 0 && x < t.w && y < t.h) continue;
                            const Key& sk = L.keys[static_cast<size_t>(g.at(t.x + x, t.y + y))];
                            for (int l = 0; l < 4; ++l) { if (!(sk.e[l] & 0x3FF)) continue; ++ring; same += here.count(static_cast<uint32_t>(l) << 16 | (sk.e[l] & 0x3FF)) != 0; }   // (every layer: some areas lay their ground on two)
                        }
                        if (same * 10 < ring * 7) { ++why[2]; continue; }
                    }
                    const double sc = match * 3.0 - (near_centre ? std::abs(ccx - cx0 - t.w / 2) + std::abs(ccy - cy0 - t.h / 2) : 0) + (srng() % 100) * 0.01;
                    if (sc > bs) { bs = sc; bx = x0; by = y0; }
                }
                if (bx < 0) { if (getenv("MB_DEBUG") && getenv("MB_DEBUG")[0] == '9') fprintf(stderr, "    %dx%d near %d,%d: blocked %d, track %d, other ground %d\n", t.w, t.h, cx0, cy0, why[0], why[1], why[2]); return false; }
                // set it down: its object layers (and walls) and walk bits; the floor's own ground stays
                std::vector<uint16_t> keepL[4]; for (int l = 0; l < 4; ++l) keepL[l] = out->L[l];
                std::vector<uint8_t> kwa = out->wa, kwb = out->wb;
                for (int y = 0; y < t.h; ++y) for (int x = 0; x < t.w; ++x) {
                    const int k = g.at(t.x + x, t.y + y);
                    const Key& sk = L.keys[static_cast<size_t>(k)];
                    const bool solid = !L.walk[static_cast<size_t>(k)];
                    bool obj = solid; for (int l = 0; l < 4; ++l) if (!((SS.ground >> l) & 1) && (sk.e[l] & 0xFFFF)) obj = true;
                    if (!obj) continue;
                    const size_t c = static_cast<size_t>(by + y) * W + bx + x;
                    bool drawn_above = false;   // (a wall drawn on the object layers keeps the floor's ground under it)
                    for (int l = 0; l < 4; ++l) if (!((SS.ground >> l) & 1) && (sk.e[l] & 0xFFFF)) drawn_above = true;
                    for (int l = 0; l < 4; ++l) {
                        const bool ground = (SS.ground >> l) & 1;
                        if (ground && (!solid || drawn_above)) continue;
                        out->L[l][c] = static_cast<uint16_t>((sk.e[l] >> 16) | (sk.e[l] & 0xFFFF));
                    }
                    out->wa[c] = sk.wa; out->wb[c] = sk.wb;
                }
                if (!way_open()) {
                    for (int l = 0; l < 4; ++l) out->L[l] = keepL[l];
                    out->wa = kwa; out->wb = kwb;
                    if (getenv("MB_DEBUG")) fprintf(stderr, "  building %dx%d at %d,%d would close the way\n", t.w, t.h, bx, by);
                    return false;
                }
                used_st.push_back(si); ++out->landmarks;
                if (getenv("MB_DEBUG")) fprintf(stderr, "  building %dx%d (grid %d at %d,%d) set down at %d,%d (ground match %.0f)\n", t.w, t.h, t.g, t.x, t.y, bx, by, bs);
                return true;
            };
            if (!SS.st.empty() && way_open()) {
                // first where the quilt kept room for one
                for (const auto& rv : qresv) {
                    if (out->landmarks >= kStamps) break;
                    if (std::find(used_st.begin(), used_st.end(), rv.si) != used_st.end()) continue;
                    if (!try_place(rv.si, rv.x, rv.y, 3, 3, true) && getenv("MB_DEBUG")) fprintf(stderr, "  kept room at %d,%d: building would not fit\n", rv.x, rv.y);
                }
                // then any clearing with free ground
                std::vector<size_t> rooms(g_rooms.size()); for (size_t i = 0; i < rooms.size(); ++i) rooms[i] = i;
                mb_shuffle(rooms.begin(), rooms.end(), srng);
                for (size_t ri : rooms) {
                    if (out->landmarks >= kStamps) break;
                    const Room& r = g_rooms[ri];
                    const int rcx = (r.x0 + r.x1) / 2, rcy = (r.y0 + r.y1) / 2;
                    std::vector<int> order;   // the big ones first (houses before rocks), shuffled among similar sizes
                    for (size_t i = 0; i < std::min<size_t>(SS.st.size(), 16); ++i) order.push_back(static_cast<int>(i));
                    for (size_t i = 0; i + 1 < order.size(); ++i) { const size_t j = i + srng() % std::min<size_t>(3, order.size() - i); std::swap(order[i], order[j]); }
                    for (size_t pick = 0; pick < order.size() && pick < 8; ++pick) {
                        const int si = order[pick];
                        if (std::find(used_st.begin(), used_st.end(), si) != used_st.end()) continue;   // (not the same one twice)
                        const Stamp& t = SS.st[static_cast<size_t>(si)];
                        if (try_place(si, rcx - t.w / 2, rcy - t.h / 2, 14, 12, true)) break;
                    }
                }
                // still room for one: any free open ground of the floor (off the track)
                for (size_t si = 0; si < std::min<size_t>(SS.st.size(), 16) && out->landmarks < kStamps; ++si) {
                    if (std::find(used_st.begin(), used_st.end(), static_cast<int>(si)) != used_st.end()) continue;
                    try_place(static_cast<int>(si), W / 2, H / 2, W / 2, H / 2, false);
                }
            }
        }
        // exits: walkable spots on the map edges (3 cells wide); way in preferably
        // at the bottom near the plan's, way on the connected spot farthest away
        auto walk1 = [&](int x, int y) { return x >= 0 && y >= 0 && x < W && y < H && out->wa[static_cast<size_t>(y) * W + x] != 0; };
        // a fighter needs room: its body box (x-15..x+17, y-10..y+8 px) touches
        // 5 x 3 cells; cell (x, y) here = the box centred on that cell
        auto walk = [&](int x, int y) {
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -2; dx <= 2; ++dx) if (!walk1(x + dx, y + dy)) return false;
            return true;
        };
        std::vector<uint8_t> pass(static_cast<size_t>(W) * H, 0);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) pass[static_cast<size_t>(y) * W + x] = walk(x, y);
        struct Spot { int x, y, side, depth; };   // side 0 bottom, 1 top, 2 left, 3 right
        std::vector<Spot> spots;
        // exit spots: the box fits right at the edge (centre 1 cell in from a top /
        // bottom edge, 2 cells in from a left / right edge) - or, on a side with no
        // opening at all, a few cells in (a doorway)
        int have_side[4] = {0, 0, 0, 0};
        for (int dep = 0; dep <= kMaxDepth; ++dep) {
            for (int x = 4; x < W - 4; ++x) {
                if (!have_side[0] || have_side[0] > dep) if (walk(x - 1, H - 2 - dep) && walk(x, H - 2 - dep) && walk(x + 1, H - 2 - dep)) { spots.push_back({x, H - 2 - dep, 0, dep}); if (!have_side[0]) have_side[0] = dep + 1; }
                if (!have_side[1] || have_side[1] > dep) if (walk(x - 1, 1 + dep) && walk(x, 1 + dep) && walk(x + 1, 1 + dep)) { spots.push_back({x, 1 + dep, 1, dep}); if (!have_side[1]) have_side[1] = dep + 1; }
            }
            for (int y = 3; y < H - 3; ++y) {
                if (!have_side[2] || have_side[2] > dep) if (walk(2 + dep, y - 1) && walk(2 + dep, y) && walk(2 + dep, y + 1)) { spots.push_back({2 + dep, y, 2, dep}); if (!have_side[2]) have_side[2] = dep + 1; }
                if (!have_side[3] || have_side[3] > dep) if (walk(W - 3 - dep, y - 1) && walk(W - 3 - dep, y) && walk(W - 3 - dep, y + 1)) { spots.push_back({W - 3 - dep, y, 3, dep}); if (!have_side[3]) have_side[3] = dep + 1; }
            }
        }
        static const int kWorld[4] = {3, 2, 0, 1};   // spot side -> 0 left, 1 right, 2 top, 3 bottom
        const int want_in = opt.in_side >= 0 ? opt.in_side : 3;
        int si = -1, sbest = 1 << 30;
        for (size_t i = 0; i < spots.size(); ++i) {
            const int c = (kWorld[spots[i].side] == want_in ? 0 : (opt.in_side >= 0 ? 1 << 20 : 1000)) + std::abs(spots[i].x - pin.x) + std::abs(spots[i].y - pin.y);
            if (c < sbest) { sbest = c; si = static_cast<int>(i); }
        }
        if (si < 0 || sbest >= (1 << 20)) continue;
        const Spot in = spots[static_cast<size_t>(si)];
        std::vector<int> dist(static_cast<size_t>(W) * H, -1); std::vector<int> q{in.y * W + in.x}; dist[static_cast<size_t>(q[0])] = 0;
        for (size_t h = 0; h < q.size(); ++h) {
            const int c = q[h], x = c % W, y = c / W;
            const int nbs[4] = {x + 1 < W ? c + 1 : -1, x > 0 ? c - 1 : -1, y + 1 < H ? c + W : -1, y > 0 ? c - W : -1};
            for (int n : nbs) if (n >= 0 && dist[static_cast<size_t>(n)] < 0 && pass[static_cast<size_t>(n)]) { dist[static_cast<size_t>(n)] = dist[static_cast<size_t>(c)] + 1; q.push_back(n); }
        }
        int oi = -1; long long obest = -(1LL << 40);
        for (size_t i = 0; i < spots.size(); ++i) {
            const auto& sp = spots[i]; const int d = dist[static_cast<size_t>(sp.y * W + sp.x)];
            if (sp.side == in.side || d < 0) continue;
            if (opt.out_side >= 0 && kWorld[sp.side] != opt.out_side) continue;
            const long long sc = (opt.out_side >= 0 ? -(std::abs(sp.x - pout.x) + std::abs(sp.y - pout.y)) : d);
            if (sc > obest) { obest = sc; oi = static_cast<int>(i); }
        }
        out->connected = oi >= 0;
        if (getenv("MB_DEBUG")) fprintf(stderr, "  connected=%d\n", (int)out->connected);
        if (!out->connected) continue;
        const Spot on = spots[static_cast<size_t>(oi)];
        if (std::abs(on.x - in.x) + std::abs(on.y - in.y) < (W + H) / 4) { out->connected = false; if (getenv("MB_DEBUG")) fprintf(stderr, "  way in and way on too close\n"); continue; }   // a floor worth walking through
        // the exit covers the whole opening in that edge (every walkable edge cell next to the spot)
        auto rect = [&](const Spot& sp) {
            const bool horiz = sp.side < 2;
            const int ey = sp.side == 0 ? H - 1 - sp.depth : sp.depth, ex = sp.side == 3 ? W - 1 - sp.depth : sp.depth;
            auto open_at = [&](int t) { return horiz ? walk1(t, ey) : walk1(ex, t); };
            int lo = horiz ? sp.x : sp.y, hi = lo + 1;
            while (lo > 0 && open_at(lo - 1)) --lo;
            while (hi < (horiz ? W : H) - 1 && open_at(hi + 1)) ++hi;
            const uint16_t a0 = static_cast<uint16_t>(lo * 8), a1 = static_cast<uint16_t>(hi * 8 + 8);
            switch (sp.side) {
            // deep enough for the fighter's position (its body box keeps it 10 px from
            // the top edge, 8 from the bottom, 15 from the left, 17 from the right)
            case 0: return Rect{a0, static_cast<uint16_t>(H * 8 - 20 - sp.depth * 8), a1, static_cast<uint16_t>(H * 8)};
            case 1: return Rect{a0, 0, a1, static_cast<uint16_t>(20 + sp.depth * 8)};
            case 2: return Rect{0, a0, static_cast<uint16_t>(26 + sp.depth * 8), a1};
            default: return Rect{static_cast<uint16_t>(W * 8 - 26 - sp.depth * 8), a0, static_cast<uint16_t>(W * 8), a1};
            }
        };
        out->exits.clear(); out->exits.push_back(rect(in)); out->exits.push_back(rect(on));
        out->exit_side[0] = kWorld[in.side]; out->exit_side[1] = kWorld[on.side]; out->exit_side[2] = -1;
        if (opt.side_side >= 0) {   // the side way: a reachable opening on its side, well away from the other two
            int bi = -1; long bsc = -1;
            for (size_t i = 0; i < spots.size(); ++i) {
                const auto& sp = spots[i];
                if (kWorld[sp.side] != opt.side_side || sp.side == in.side || sp.side == on.side || dist[static_cast<size_t>(sp.y * W + sp.x)] < 0) continue;
                const long d = std::min(std::abs(sp.x - in.x) + std::abs(sp.y - in.y), std::abs(sp.x - on.x) + std::abs(sp.y - on.y));
                if (d < (W + H) / 6) continue;
                if (d > bsc) { bsc = d; bi = static_cast<int>(i); }
            }
            if (bi >= 0) {   // (an opening shared with another exit - a corner: only the part away from it)
                Rect r = rect(spots[static_cast<size_t>(bi)]);
                const bool vert = opt.side_side < 2;   // along y (left / right edge)
                const int c = vert ? spots[static_cast<size_t>(bi)].y * 8 + 4 : spots[static_cast<size_t>(bi)].x * 8 + 4;
                for (int k = 0; k < 2; ++k) {
                    const Rect& o = out->exits[static_cast<size_t>(k)];
                    const bool cross = vert ? (o.x0 < r.x1 && o.x1 > r.x0) : (o.y0 < r.y1 && o.y1 > r.y0);
                    if (!cross) continue;
                    if (vert) { if (o.y1 <= c) r.y0 = std::max<int>(r.y0, o.y1 + 16); else if (o.y0 >= c) r.y1 = std::min<int>(r.y1, o.y0 - 16); else r.y1 = r.y0; }
                    else { if (o.x1 <= c) r.x0 = std::max<int>(r.x0, o.x1 + 16); else if (o.x0 >= c) r.x1 = std::min<int>(r.x1, o.x0 - 16); else r.x1 = r.x0; }
                }
                if ((vert ? r.y1 - r.y0 : r.x1 - r.x0) >= 32) { out->exits.push_back(r); out->exit_side[2] = opt.side_side; }
                else bi = -1;
            }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  side way on side %d: %s\n", opt.side_side, bi >= 0 ? "yes" : "no");
        }
        if (opt.dead_end) { out->exits.resize(1); out->exit_side[1] = -1; out->exit_side[2] = -1; }   // a side place: the way in is the only way out
        // spawn: a reachable cell ~6 tiles in from the way in
        const int ix = in.side == 2 ? 1 : (in.side == 3 ? -1 : 0), iy = in.side == 0 ? -1 : (in.side == 1 ? 1 : 0);
        // (spawn at the footprint's centre: +8 px)
        int bx = in.x, by = in.y;
        for (int d = 1; d < 12; ++d) { const int x = in.x + ix * d, y = in.y + iy * d; if (!walk(x, y) || dist[static_cast<size_t>(y * W + x)] < 0) break; bx = x; by = y; if (d >= 6) break; }
        {   // arrive clear of the way in (40 px) and of every other way out (16 px), even when the
            // passage bends at once - straight in could stop next to the exit and send you back
            const int tx = in.x + ix * 6, ty = in.y + iy * 6;
            auto trig = [](int px, int py, const Rect& r) {
                const int dx = std::max({static_cast<int>(r.x0) - px, 0, px - static_cast<int>(r.x1) + 1});
                const int dy = std::max({static_cast<int>(r.y0) - py, 0, py - static_cast<int>(r.y1) + 1});
                return std::max(dx, dy);
            };
            int best = 1 << 30, cx = -1, cy = -1;
            if (!out->exits.empty())
                for (int c : q) {
                    const int x = c % W, y = c / W, px = x * 8 + 4, py = y * 8 + 4;
                    if (trig(px, py, out->exits[0]) < 40) continue;
                    bool away = true;
                    for (size_t e = 1; e < out->exits.size(); ++e) if (trig(px, py, out->exits[e]) < 16) { away = false; break; }
                    if (!away) continue;
                    const int sc = std::abs(dist[static_cast<size_t>(c)] - 6) * 16 + std::abs(x - tx) + std::abs(y - ty);
                    if (sc < best) { best = sc; cx = x; cy = y; }
                }
            if (cx >= 0) { bx = cx; by = cy; }
        }
        out->spawn_x = static_cast<uint16_t>(bx * 8 + 4); out->spawn_y = static_cast<uint16_t>(by * 8 + 4);
        out->work = g_work;
        if ((opt.layout == 2 || opt.layout == 3) && L.liquid_n >= 12 && has_water_windows(L, bz, opt.layout)) {   // a river / a lake asked for (and its land has water): it really has one (else another try)
            const uint16_t* bids = ids_of(bank, bz, ba);
            int wn = 0;
            for (int c = 0; c < W * H && bids; ++c) {
                if (out->wa[static_cast<size_t>(c)]) continue;
                for (int l = 0; l < 4; ++l) { const int t = out->L[l][static_cast<size_t>(c)] & 0x3FF; if (t && bids[t] >= 0xC000) { ++wn; break; } }
            }
            if (getenv("MB_DEBUG")) fprintf(stderr, "  water in the floor: %d cells\n", wn);
            if (wn < (opt.layout == 2 ? 90 : 60)) return false;
        }
        return true;
    }
    out->work = g_work;
    return false;
    };
    const int threads = std::max(1, std::min(kTries, getenv("MB_THREADS") ? atoi(getenv("MB_THREADS")) : opt.threads));
    std::vector<Out> outs(static_cast<size_t>(kTries));
    std::vector<char> ok(static_cast<size_t>(kTries), 0), ran(static_cast<size_t>(kTries), 0);
    uint64_t used = 0;
    int attempts = 0;
    for (int b0 = 0; b0 < kTries; b0 += threads) {
        const int b1 = std::min(kTries, b0 + threads);
        if (b1 - b0 == 1) { ok[static_cast<size_t>(b0)] = attempt(b0, &outs[static_cast<size_t>(b0)]); }
        else {
            std::vector<std::thread> th;
            for (int t = b0 + 1; t < b1; ++t) th.emplace_back([&, t] { if (opt.thread_init) opt.thread_init(); ok[static_cast<size_t>(t)] = attempt(t, &outs[static_cast<size_t>(t)]); });
            ok[static_cast<size_t>(b0)] = attempt(b0, &outs[static_cast<size_t>(b0)]);
            for (auto& x : th) x.join();
        }
        for (int t = b0; t < b1; ++t) {   // in order: the first that came together while work was left
            ++attempts;
            if (ok[static_cast<size_t>(t)]) {
                *out = std::move(outs[static_cast<size_t>(t)]);
                out->attempts = attempts; out->work = used + out->work; out->cells = L.N;
                if (!L.global) place_foreign(rom, bz, ba, bank, seed, opt, out);
                if ((opt.layout == 2 || opt.layout == 3) && getenv("MB_WATERPAINT")) place_water(rom, bz, ba, bank, seed, opt, out);   // (flat painted water: looked pasted on - kept for tests)
                if (getenv("MB_DEBUG")) fprintf(stderr, "  try %d came together\n", t);
                return true;
            }
            used += outs[static_cast<size_t>(t)].work;
            if (used >= work_total && !early) { *out = std::move(outs[static_cast<size_t>(t)]); out->attempts = attempts; out->work = used; return false; }
        }
    }
    *out = std::move(outs.back()); out->attempts = attempts; out->work = used;
    return false;
}


namespace {
// ---------------------------------------------------------------- water
// A river or a lake painted into a floor that stands: the area's own water (its water layer's tiles,
// animated ripples and all, copied from a patch of its real map), on plain open ground only, never on
// the way between the ways in and out (a ford is kept where the way crosses a river).
void place_water(const Rom& rom, int bz, int ba, const std::vector<BankMap>& bank, uint32_t seed, const Options& opt, Out* out) {
    const uint16_t* base = ids_of(bank, bz, ba);
    SrcMap bm; if (!base || !load_src(rom, bz, ba, &bm)) return;
    const int W = out->tw, H = out->th, N = W * H;
    if (W < 24 || H < 20 || static_cast<int>(out->wa.size()) != N) return;
    // the water layer: the one with the most animated tiles
    int kw = -1, best = 0;
    for (int l = 0; l < 4; ++l) {
        int n = 0;
        for (uint16_t e : bm.L[l]) { const int t = e & 0x3FF; if (t && base[t] >= 0xC000) ++n; }
        if (n > best) { best = n; kw = l; }
    }
    if (kw < 0 || best < 120) { if (getenv("MB_DEBUG")) fprintf(stderr, "  water: %d/%d has no water of its own\n", bz, ba); return; }
    // a patch of open water in the real map (every tile water, ripples among it)
    const int P = 8;
    int mode = 0;   // (the plain water tile: the commonest still tile of the water layer)
    { std::unordered_map<int, int> cnt; int mc = 0; for (uint16_t e : bm.L[kw]) { const int t = e & 0x3FF; if (t && base[t] < 0xC000 && ++cnt[t] > mc) { mc = cnt[t]; mode = t; } } }
    int px0 = -1, py0 = -1, pbest = -1;
    for (int y = 0; y + P <= bm.th; ++y) for (int x = 0; x + P <= bm.tw; ++x) {
        int an = 0, mn = 0; bool full = true;
        for (int yy = 0; yy < P && full; ++yy) for (int xx = 0; xx < P; ++xx) {
            const uint16_t e = bm.L[kw][static_cast<size_t>(y + yy) * bm.tw + x + xx]; const int t = e & 0x3FF;
            if (!t) { full = false; break; }
            if (base[t] >= 0xC000) ++an; else if (t == mode) ++mn;
        }
        if (!full || an < P * P / 10 || mn < P * P / 4) continue;   // open water: plain water with ripples among it
        const int sc = std::min(an, P * P / 3) + mn;
        if (sc > pbest) { pbest = sc; px0 = x; py0 = y; }
    }
    if (px0 < 0) { if (getenv("MB_DEBUG")) fprintf(stderr, "  water: no open water patch in %d/%d\n", bz, ba); return; }
    // the water's own collision (the second layer, as in the real map); its middle is never walked on
    int wbn = 0; for (int yy = 0; yy < P; ++yy) for (int xx = 0; xx < P; ++xx) wbn += bm.wb[static_cast<size_t>(py0 + yy) * bm.tw + px0 + xx];
    const uint8_t wbv = wbn * 2 >= P * P ? 1 : 0;
    // plain open ground: walkable, nothing on the layers above the ground
    int kg = 0, gn = -1;   // (the ground layer: filled nearly everywhere)
    for (int l = 0; l < 4; ++l) { int n = 0; for (int c = 0; c < N; ++c) if (out->L[l][static_cast<size_t>(c)] & 0x3FF) ++n; if (n > gn) { gn = n; kg = l; } }
    std::vector<uint8_t> plain(static_cast<size_t>(N), 0);
    for (int c = 0; c < N; ++c) {
        if (!out->wa[static_cast<size_t>(c)]) continue;
        bool empty = true; for (int l = 0; l < 4; ++l) if (l != kg && (out->L[l][static_cast<size_t>(c)] & 0x3FF)) empty = false;
        plain[static_cast<size_t>(c)] = empty ? 1 : 0;
    }
    // kept dry: the way between the ways in / out / the side way and the arrival spot (2 tiles round it), and near them
    std::vector<uint8_t> keep(static_cast<size_t>(N), 0);
    std::vector<int> ends;
    for (const Rect& r : out->exits) ends.push_back(std::clamp((r.y0 + r.y1) / 16, 0, H - 1) * W + std::clamp((r.x0 + r.x1) / 16, 0, W - 1));
    ends.push_back(std::clamp(out->spawn_y / 8, 0, H - 1) * W + std::clamp(out->spawn_x / 8, 0, W - 1));
    auto bfs_from = [&](int s, const std::vector<uint8_t>& ok, std::vector<int>* prev) {
        prev->assign(static_cast<size_t>(N), -2); if (s < 0 || s >= N) return; (*prev)[static_cast<size_t>(s)] = -1;
        std::vector<int> q{s};
        for (size_t h = 0; h < q.size(); ++h) { const int c = q[h], x = c % W, y = c / W;
            const int nb[4] = {x > 0 ? c - 1 : -1, x + 1 < W ? c + 1 : -1, y > 0 ? c - W : -1, y + 1 < H ? c + W : -1};
            for (int d : nb) if (d >= 0 && ok[static_cast<size_t>(d)] && (*prev)[static_cast<size_t>(d)] == -2) { (*prev)[static_cast<size_t>(d)] = c; q.push_back(d); } }
    };
    std::vector<uint8_t> walk0(out->wa.begin(), out->wa.end());
    for (int e : ends) walk0[static_cast<size_t>(e)] = 1;
    std::vector<int> prev;
    if (!ends.empty()) {
        bfs_from(ends[0], walk0, &prev);
        for (size_t i = 1; i < ends.size(); ++i) {
            for (int c = ends[i]; c >= 0 && prev[static_cast<size_t>(c)] != -2; c = prev[static_cast<size_t>(c)]) {
                const int x = c % W, y = c / W;
                for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) { const int xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < W && yy < H) keep[static_cast<size_t>(yy) * W + xx] = 1; }
                if (prev[static_cast<size_t>(c)] == -1) break;
            }
        }
    }
    for (int e : ends) { const int x = e % W, y = e / W; for (int dy = -5; dy <= 5; ++dy) for (int dx = -5; dx <= 5; ++dx) { const int xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < W && yy < H) keep[static_cast<size_t>(yy) * W + xx] = 1; } }
    // the shape
    std::mt19937 rng(seed * 2246822519u + 0x3A7Eu);
    auto rnd = [&](int a, int b) { return a + static_cast<int>(rng() % static_cast<uint32_t>(b - a + 1)); };
    std::vector<uint8_t> Wt(static_cast<size_t>(N), 0);
    if (opt.layout == 2) {   // a river: a wavy band from one edge to the other, across the way
        const bool across_x = W >= H;   // (runs along the longer side)
        const int len = across_x ? W : H, span = across_x ? H : W;
        const int mid = span / 2 + rnd(-span / 6, span / 6), wdt = rnd(3, 5);
        const double ph = (rng() % 1000) * 0.00628, amp = 2.0 + (rng() % 300) * 0.01;
        for (int u = 0; u < len; ++u) {
            const int c = mid + static_cast<int>(std::lround(amp * std::sin(u * 0.11 + ph) + 1.2 * std::sin(u * 0.29 + ph * 2)));
            for (int v = c - wdt / 2; v <= c + (wdt - 1) / 2; ++v) { const int x = across_x ? u : v, y = across_x ? v : u; if (x >= 0 && y >= 0 && x < W && y < H) Wt[static_cast<size_t>(y) * W + x] = 1; }
        }
    } else {   // a lake (two or three ponds on a big floor): in the roomiest open ground off the way
        const int nl = W * H > 4500 ? rnd(2, 3) : 1;
        for (int li = 0; li < nl; ++li) {
            const int rx = li == 0 ? rnd(5, 8) : rnd(3, 5), ry = li == 0 ? rnd(4, 6) : rnd(3, 4);
            int bx = -1, by = -1, bs = -1;
            for (int cy = ry + 2; cy < H - ry - 2; ++cy) for (int cx = rx + 2; cx < W - rx - 2; ++cx) {
                int sc = 0; bool bad = false;
                for (int y = cy - ry; y <= cy + ry && !bad; ++y) for (int x = cx - rx; x <= cx + rx; ++x) {
                    const size_t c = static_cast<size_t>(y) * W + x;
                    if (keep[c] || Wt[c]) { bad = true; break; }
                    sc += plain[c];
                }
                if (bad) continue;
                sc = sc * 8 + static_cast<int>(rng() % 8u);
                if (sc > bs) { bs = sc; bx = cx; by = cy; }
            }
            if (bx < 0 || bs < (2 * rx + 1) * (2 * ry + 1) * 8 / 2) continue;
            const double ph = (rng() % 1000) * 0.00628;
            for (int y = by - ry; y <= by + ry; ++y) for (int x = bx - rx; x <= bx + rx; ++x) {
                const double a = std::atan2(y - by, x - bx), wob = 1.0 + 0.2 * std::sin(a * 3 + ph) + 0.1 * std::sin(a * 5 + ph * 2);
                const double dx = (x - bx) / (rx * wob + 0.5), dy = (y - by) / (ry * wob + 0.5);
                if (dx * dx + dy * dy <= 1.0) Wt[static_cast<size_t>(y) * W + x] = 1;
            }
        }
    }
    // only on plain ground, never where the way must stay dry
    for (int c = 0; c < N; ++c) if (Wt[static_cast<size_t>(c)] && (keep[static_cast<size_t>(c)] || !plain[static_cast<size_t>(c)])) Wt[static_cast<size_t>(c)] = 0;
    // no specks: water cells with fewer than 3 water neighbours go
    for (int pass = 0; pass < 2; ++pass) {
        std::vector<uint8_t> w2 = Wt;
        for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
            if (!Wt[static_cast<size_t>(y) * W + x]) continue;
            int n = 0; for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) { const int xx = x + dx, yy = y + dy; if ((dx || dy) && xx >= 0 && yy >= 0 && xx < W && yy < H && Wt[static_cast<size_t>(yy) * W + xx]) ++n; }
            if (n < 3) w2[static_cast<size_t>(y) * W + x] = 0;
        }
        Wt.swap(w2);
    }
    int nw = 0; for (uint8_t v : Wt) nw += v;
    if (nw < 20) { if (getenv("MB_DEBUG")) fprintf(stderr, "  water: no room (%d cells)\n", nw); return; }
    // paint: its edge stays walkable (the shallows), its middle does not
    std::vector<uint8_t> wa2(out->wa.begin(), out->wa.end());
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        const size_t c = static_cast<size_t>(y) * W + x;
        if (!Wt[c]) continue;
        bool inner = true; for (int dy = -1; dy <= 1 && inner; ++dy) for (int dx = -1; dx <= 1 && inner; ++dx) { const int xx = x + dx, yy = y + dy; inner = xx >= 0 && yy >= 0 && xx < W && yy < H && Wt[static_cast<size_t>(yy) * W + xx]; }
        if (inner) wa2[c] = 0;
    }
    // the way must still go through
    {
        std::vector<int> pv; bfs_from(ends.empty() ? -1 : ends[0], wa2, &pv);
        for (int e : ends) if (pv.empty() || pv[static_cast<size_t>(e)] == -2) { if (getenv("MB_DEBUG")) fprintf(stderr, "  water: it would cut the way - left out\n"); return; }
    }
    // a floor with its own tile list (things from other maps): the water's tiles named in that list
    bool remap_ok = true;
    int first_anim = 896; for (int t = 1; t < 1024; ++t) if (base[t] >= 0xC000) { first_anim = t; break; }
    auto remap = [&](uint16_t e) -> uint16_t {
        const int t = e & 0x3FF;
        if (!t || out->tile_list.empty() || base[t] >= 0xC000) return e;   // (animated tiles keep their slot)
        const uint32_t gn = (opt.id_global && base[t] < opt.id_global->size()) ? (*opt.id_global)[base[t]] : 0;
        if (!gn) { remap_ok = false; return e; }
        for (size_t i = 1; i < out->tile_list.size(); ++i) if (out->tile_list[i] == gn) return static_cast<uint16_t>((e & 0xFC00) | i);
        if (static_cast<int>(out->tile_list.size()) + 1 > first_anim) { remap_ok = false; return e; }
        out->tile_list.push_back(gn);
        return static_cast<uint16_t>((e & 0xFC00) | (out->tile_list.size() - 1));
    };
    {   // (the list has room for them: checked before anything is painted)
        const std::vector<uint32_t> keep_list = out->tile_list;
        for (int yy = 0; yy < P; ++yy) for (int xx = 0; xx < P; ++xx) remap(bm.L[kw][static_cast<size_t>(py0 + yy) * bm.tw + px0 + xx]);
        if (!remap_ok) { out->tile_list = keep_list; if (getenv("MB_DEBUG")) fprintf(stderr, "  water: no room in the tile list\n"); return; }
    }
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        const size_t c = static_cast<size_t>(y) * W + x;
        if (!Wt[c]) continue;
        out->L[kw][c] = remap(bm.L[kw][static_cast<size_t>(py0 + y % P) * bm.tw + px0 + x % P]);
        out->wa[c] = wa2[c];
        out->wb[c] = wbv;
    }
    if (getenv("MB_DEBUG")) fprintf(stderr, "  water: %s of %d cells (layer %d, patch at %d,%d of %d/%d)\n", opt.layout == 2 ? "a river" : "a lake", nw, kw, px0, py0, bz, ba);
}

}  // namespace
// dev: save a floor in the .gen test format (loader LOG2_GEN_FILE, tools/render_gen.py)
bool write_gen(const char* path, int z, int a, const Out& out) {
    FILE* f = fopen(path, "wb");
    if (!f) return false;
    const int tw = out.tw, th = out.th, cols = (tw + 31) / 32, rows = (th + 31) / 32;
    uint8_t hdr[10] = {static_cast<uint8_t>(z), static_cast<uint8_t>(a)};
    const uint16_t v[4] = {static_cast<uint16_t>(tw * 8), static_cast<uint16_t>(th * 8), out.spawn_x, out.spawn_y};
    std::memcpy(hdr + 2, v, 8); fwrite(hdr, 1, 10, f);
    for (int k = 0; k < 4; ++k) {
        bool any = false; for (auto e : out.L[k]) any |= e != 0;
        if (!any) { const uint8_t z2[2] = {0, 0}; fwrite(z2, 1, 2, f); continue; }
        const uint8_t cr[2] = {static_cast<uint8_t>(cols), static_cast<uint8_t>(rows)}; fwrite(cr, 1, 2, f);
        for (int cy = 0; cy < rows; ++cy) for (int cx = 0; cx < cols; ++cx)
            for (int y = 0; y < 32; ++y) for (int x = 0; x < 32; ++x) {
                const int wx = cx * 32 + x, wy = cy * 32 + y;
                const uint16_t e = (wx < tw && wy < th) ? out.L[k][static_cast<size_t>(wy) * tw + wx] : 0;
                fwrite(&e, 2, 1, f);
            }
    }
    for (int k = 0; k < 2; ++k) {
        std::vector<uint8_t> B(8192, 0); const auto& W = k ? out.wb : out.wa;
        for (int y = 0; y < th && y < 256; ++y) for (int x = 0; x < tw && x < 256; ++x) if (W[static_cast<size_t>(y) * tw + x]) B[static_cast<size_t>(y) * 32 + (x >> 3)] |= static_cast<uint8_t>(1u << (x & 7));
        fwrite(B.data(), 1, 8192, f);
    }
    const uint8_t ne = static_cast<uint8_t>(out.exits.size()); fwrite(&ne, 1, 1, f);
    for (const auto& r : out.exits) fwrite(&r, 8, 1, f);
    fclose(f);
    return true;
}

}  // namespace mapbuild
