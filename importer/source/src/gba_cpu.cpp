#include "gba_cpu.h"
#include <cstdio>

namespace gbacpu {

static constexpr uint32_t N = 1u << 31, Z = 1u << 30, C = 1u << 29, V = 1u << 28, T = 1u << 5;

Machine::Machine(std::vector<uint8_t> game)
    : rom(std::move(game)), ewram(0x40000), iwram(0x8000), io(0x400), vram(0x18000), pal(0x400), oam(0x400) {
    bank_sp[0] = 0x03007F00u; bank_sp[1] = 0x03007FA0u; bank_sp[2] = 0x03007FE0u;
    r[13] = bank_sp[0];
}

static int bank_of(uint32_t mode) {
    switch (mode & 0x1F) {
        case 0x12: return 1;
        case 0x13: return 2;
        case 0x17: return 3;
        case 0x1B: return 4;
        case 0x11: return 5;
        default: return 0;
    }
}

void Machine::set_mode(uint32_t mode) {
    const int a = bank_of(cpsr), b = bank_of(mode);
    if (a != b) {
        bank_sp[a] = r[13]; bank_lr[a] = r[14];
        r[13] = bank_sp[b]; r[14] = bank_lr[b];
    }
    cpsr = (cpsr & ~0x1Fu) | (mode & 0x1F);
}

uint8_t* Machine::at(uint32_t a, bool write) {
    switch (a >> 24) {
        case 0x02: return &ewram[a & 0x3FFFF];
        case 0x03: return &iwram[a & 0x7FFF];
        case 0x04: return (a & 0xFFFFFF) < 0x400 ? &io[a & 0x3FF] : nullptr;
        case 0x05: return &pal[a & 0x3FF];
        case 0x06: { uint32_t o = a & 0x1FFFF; if (o >= 0x18000) o -= 0x8000; return &vram[o]; }
        case 0x07: return &oam[a & 0x3FF];
        case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: {
            if (write) return nullptr;
            const uint32_t o = a & 0x1FFFFFF;
            return o < rom.size() ? &rom[o] : nullptr;
        }
        default: return nullptr;
    }
}

uint8_t Machine::r8(uint32_t a) {
    if ((a >> 24) == 0x04 && (a & 0x3FF) == 0x06) return static_cast<uint8_t>((steps / 64) % 228);   // VCOUNT moves on
    const uint8_t* p = at(a, false);
    return p ? *p : 0;
}
uint16_t Machine::r16(uint32_t a) { a &= ~1u; return static_cast<uint16_t>(r8(a) | (r8(a + 1) << 8)); }
uint32_t Machine::r32(uint32_t a) { a &= ~3u; return static_cast<uint32_t>(r16(a) | (static_cast<uint32_t>(r16(a + 2)) << 16)); }

void Machine::w8(uint32_t a, uint8_t v) {
    if (uint8_t* p = at(a, true)) {
        *p = v;
        if (on_write && (a >> 24) != 0x04) on_write(a, v, 1);
        if ((a >> 24) == 0x04) io_written(a & 0x3FF);
    }
}
void Machine::w16(uint32_t a, uint16_t v) {
    a &= ~1u;
    if (uint8_t* p = at(a, true)) {
        p[0] = static_cast<uint8_t>(v); p[1] = static_cast<uint8_t>(v >> 8);
        if (on_write && (a >> 24) != 0x04) on_write(a, v, 2);
        if ((a >> 24) == 0x04) io_written((a & 0x3FF) + 1);
    }
}
void Machine::w32(uint32_t a, uint32_t v) {
    a &= ~3u;
    if (uint8_t* p = at(a, true)) {
        p[0] = static_cast<uint8_t>(v); p[1] = static_cast<uint8_t>(v >> 8); p[2] = static_cast<uint8_t>(v >> 16); p[3] = static_cast<uint8_t>(v >> 24);
        if (on_write && (a >> 24) != 0x04) on_write(a, v, 4);
        if ((a >> 24) == 0x04) io_written((a & 0x3FF) + 3);
    }
}

// DMA 3 (the game copies and fills memory with it): started at once when its control is written with "enable"
void Machine::io_written(uint32_t o) {
    if (o < 0xDE || o > 0xDF) return;
    const uint16_t ctl = static_cast<uint16_t>(io[0xDE] | (io[0xDF] << 8));
    if (!(ctl & 0x8000)) return;
    if ((ctl >> 12) & 3) { io[0xDF] &= 0x7F; return; }       // (timed copies are not needed here)
    uint32_t src = io[0xD4] | (io[0xD5] << 8) | (io[0xD6] << 16) | (static_cast<uint32_t>(io[0xD7]) << 24);
    uint32_t dst = io[0xD8] | (io[0xD9] << 8) | (io[0xDA] << 16) | (static_cast<uint32_t>(io[0xDB]) << 24);
    uint32_t n = static_cast<uint32_t>(io[0xDC] | (io[0xDD] << 8));
    if (n == 0) n = 0x10000;
    const bool word = ctl & 0x400;
    const int sz = word ? 4 : 2;
    const int sd = (ctl >> 7) & 3, dd = (ctl >> 5) & 3;
    io[0xDF] &= 0x7F;
    for (uint32_t i = 0; i < n; ++i) {
        if (word) w32(dst, r32(src)); else w16(dst, r16(src));
        if (sd == 0) src += sz; else if (sd == 1) src -= sz;
        if (dd == 0 || dd == 3) dst += sz; else if (dd == 1) dst -= sz;
    }
}

bool Machine::cond(uint32_t c) const {
    const bool n = cpsr & N, z = cpsr & Z, cc = cpsr & C, v = cpsr & V;
    switch (c) {
        case 0: return z; case 1: return !z; case 2: return cc; case 3: return !cc;
        case 4: return n; case 5: return !n; case 6: return v; case 7: return !v;
        case 8: return cc && !z; case 9: return !cc || z; case 10: return n == v; case 11: return n != v;
        case 12: return !z && n == v; case 13: return z || n != v; case 14: return true;
        default: return false;
    }
}

void Machine::set_nz(uint32_t v) { cpsr = (cpsr & ~(N | Z)) | (v & N) | (v == 0 ? Z : 0); }

uint32_t Machine::add(uint32_t a, uint32_t b, uint32_t c, bool s) {
    const uint64_t w = static_cast<uint64_t>(a) + b + c;
    const uint32_t res = static_cast<uint32_t>(w);
    if (s) {
        set_nz(res);
        cpsr = (cpsr & ~(C | V)) | ((w >> 32) ? C : 0) | ((((a ^ res) & (b ^ res)) >> 31) ? V : 0);
    }
    return res;
}
uint32_t Machine::sub(uint32_t a, uint32_t b, uint32_t c, bool s) {
    return add(a, ~b, c, s);      // a - b - !c
}

uint32_t Machine::shift(uint32_t v, uint32_t type, uint32_t amt, bool reg, bool& carry) {
    switch (type) {
        case 0:      // LSL
            if (amt == 0) return v;
            if (amt < 32) { carry = (v >> (32 - amt)) & 1; return v << amt; }
            carry = amt == 32 ? (v & 1) : false; return 0;
        case 1:      // LSR
            if (amt == 0) { if (reg) return v; amt = 32; }
            if (amt < 32) { carry = (v >> (amt - 1)) & 1; return v >> amt; }
            carry = amt == 32 ? (v >> 31) : false; return 0;
        case 2:      // ASR
            if (amt == 0) { if (reg) return v; amt = 32; }
            if (amt < 32) { carry = (v >> (amt - 1)) & 1; return static_cast<uint32_t>(static_cast<int32_t>(v) >> amt); }
            carry = v >> 31; return (v >> 31) ? 0xFFFFFFFFu : 0;
        default:     // ROR (immediate 0: RRX)
            if (amt == 0) {
                if (reg) return v;
                const bool old = cpsr & C; carry = v & 1; return (v >> 1) | (old ? 0x80000000u : 0);
            }
            amt &= 31;
            if (amt == 0) { carry = v >> 31; return v; }
            carry = (v >> (amt - 1)) & 1; return (v >> amt) | (v << (32 - amt));
    }
}

uint32_t Machine::ld32(uint32_t a) {
    const uint32_t v = r32(a), rot = (a & 3) * 8;
    return rot ? (v >> rot) | (v << (32 - rot)) : v;
}

void Machine::set_pc(uint32_t v, bool exchange) {
    if (exchange) {
        thumb = v & 1;
        if (thumb) cpsr |= T; else cpsr &= ~T;
    }
    next_ = thumb ? (v & ~1u) : (v & ~3u);
}

void Machine::swi(uint32_t n) {
    switch (n) {
        case 0x06: case 0x07: {      // Div (r0 / r1) and DivArm (r1 / r0)
            int32_t a = static_cast<int32_t>(r[0]), b = static_cast<int32_t>(r[1]);
            if (n == 7) std::swap(a, b);
            if (b == 0) { r[0] = 0; r[1] = 0; r[3] = 0; break; }
            const int32_t q = a / b;
            r[0] = static_cast<uint32_t>(q); r[1] = static_cast<uint32_t>(a % b); r[3] = static_cast<uint32_t>(q < 0 ? -q : q);
            break;
        }
        case 0x08: {                 // Sqrt
            uint32_t x = r[0], y = 0;
            for (uint32_t bit = 1u << 30; bit; bit >>= 2) { if (x >= y + bit) { x -= y + bit; y = (y >> 1) + bit; } else y >>= 1; }
            r[0] = y; break;
        }
        case 0x0B: case 0x0C: {      // CpuSet / CpuFastSet
            uint32_t src = r[0], dst = r[1];
            const uint32_t ctl = r[2], cnt = ctl & 0x1FFFFF;
            const bool fill = ctl & (1u << 24), word = n == 0x0C || (ctl & (1u << 26));
            const uint32_t total = n == 0x0C ? ((cnt + 7) & ~7u) : cnt;
            const uint32_t fv = word ? r32(src) : r16(src);
            for (uint32_t i = 0; i < total; ++i) {
                if (word) { w32(dst, fill ? fv : r32(src)); dst += 4; if (!fill) src += 4; }
                else { w16(dst, static_cast<uint16_t>(fill ? fv : r16(src))); dst += 2; if (!fill) src += 2; }
            }
            break;
        }
        default: break;              // (waiting, sound bias, reset...: nothing to do here)
    }
}

void Machine::step() {
    ++steps;
    const uint32_t pc = r[15];
    if (thumb) {
        const uint16_t ins = r16(pc);
        next_ = pc + 2;
        r[15] = pc + 4;
        thm(ins);
    } else {
        const uint32_t ins = r32(pc);
        next_ = pc + 4;
        r[15] = pc + 8;
        if (cond(ins >> 28)) arm(ins);
    }
    r[15] = next_;
}

void Machine::arm(uint32_t ins) {
    if ((ins & 0x0FFFFFF0u) == 0x012FFF10u) { set_pc(r[ins & 15], true); return; }          // BX
    if ((ins & 0x0F000000u) == 0x0F000000u) { swi((ins >> 16) & 0xFF); return; }              // SWI
    if ((ins & 0x0E000000u) == 0x0A000000u) {                                                  // B, BL
        int32_t off = static_cast<int32_t>(ins << 8) >> 6;
        if (ins & (1u << 24)) r[14] = r[15] - 4;
        set_pc(r[15] + static_cast<uint32_t>(off), false);
        return;
    }
    if ((ins & 0x0FC000F0u) == 0x00000090u) {                                                  // MUL, MLA
        const uint32_t rd = (ins >> 16) & 15, rn = (ins >> 12) & 15, rs = (ins >> 8) & 15, rm = ins & 15;
        uint32_t v = r[rm] * r[rs];
        if (ins & (1u << 21)) v += r[rn];
        r[rd] = v;
        if (ins & (1u << 20)) set_nz(v);
        return;
    }
    if ((ins & 0x0F8000F0u) == 0x00800090u) {                                                  // UMULL, SMULL...
        const uint32_t hi = (ins >> 16) & 15, lo = (ins >> 12) & 15, rs = (ins >> 8) & 15, rm = ins & 15;
        uint64_t v;
        if (ins & (1u << 22)) v = static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(r[rm])) * static_cast<int32_t>(r[rs]));
        else v = static_cast<uint64_t>(r[rm]) * r[rs];
        if (ins & (1u << 21)) v += (static_cast<uint64_t>(r[hi]) << 32) | r[lo];
        r[lo] = static_cast<uint32_t>(v); r[hi] = static_cast<uint32_t>(v >> 32);
        if (ins & (1u << 20)) cpsr = (cpsr & ~(N | Z)) | ((v >> 63) ? N : 0) | (v == 0 ? Z : 0);
        return;
    }
    if ((ins & 0x0FB00FF0u) == 0x01000090u) {                                                  // SWP
        const uint32_t rn = (ins >> 16) & 15, rd = (ins >> 12) & 15, rm = ins & 15;
        const uint32_t a = r[rn];
        if (ins & (1u << 22)) { const uint8_t t = r8(a); w8(a, static_cast<uint8_t>(r[rm])); r[rd] = t; }
        else { const uint32_t t = ld32(a); w32(a, r[rm]); r[rd] = t; }
        return;
    }
    if ((ins & 0x0E000090u) == 0x00000090u && (ins & 0x60)) {                                  // LDRH, STRH, LDRSB, LDRSH
        const bool p = ins & (1u << 24), u = ins & (1u << 23), w = ins & (1u << 21), l = ins & (1u << 20);
        const uint32_t rn = (ins >> 16) & 15, rd = (ins >> 12) & 15;
        const uint32_t off = (ins & (1u << 22)) ? (((ins >> 4) & 0xF0) | (ins & 15)) : r[ins & 15];
        const uint32_t base = r[rn];
        const uint32_t moved = u ? base + off : base - off;
        const uint32_t a = p ? moved : base;
        const uint32_t sh = (ins >> 5) & 3;
        uint32_t val = 0;
        if (l) {
            if (sh == 1) val = r16(a);
            else if (sh == 2) val = static_cast<uint32_t>(static_cast<int8_t>(r8(a)));
            else val = static_cast<uint32_t>(static_cast<int16_t>(r16(a)));
        } else w16(a, static_cast<uint16_t>(rd == 15 ? r[15] + 4 : r[rd]));
        if (!p || w) r[rn] = moved;
        if (l) { if (rd == 15) set_pc(val, false); else r[rd] = val; }
        return;
    }
    if ((ins & 0x0FBF0FFFu) == 0x010F0000u) { r[(ins >> 12) & 15] = cpsr; return; }        // MRS
    if ((ins & 0x0DB0F000u) == 0x0120F000u) {                                                  // MSR
        uint32_t v;
        if (ins & (1u << 25)) { const uint32_t rot = ((ins >> 8) & 15) * 2, im = ins & 0xFF; v = rot ? (im >> rot) | (im << (32 - rot)) : im; }
        else v = r[ins & 15];
        if (ins & (1u << 22)) return;          // (the saved status: not kept)
        if (ins & (1u << 19)) cpsr = (cpsr & 0x00FFFFFFu) | (v & 0xFF000000u);
        if (ins & (1u << 16)) set_mode(v & 0x1F);
        return;
    }
    if ((ins & 0x0C000000u) == 0x00000000u) {                                                  // data processing
        const uint32_t op = (ins >> 21) & 15, rn = (ins >> 16) & 15, rd = (ins >> 12) & 15;
        const bool s = ins & (1u << 20);
        bool carry = cpsr & C;
        uint32_t b;
        if (ins & (1u << 25)) {
            const uint32_t rot = ((ins >> 8) & 15) * 2, im = ins & 0xFF;
            b = rot ? (im >> rot) | (im << (32 - rot)) : im;
            if (rot) carry = b >> 31;
        } else {
            const uint32_t rm = ins & 15, type = (ins >> 5) & 3;
            if (ins & 0x10) {
                const uint32_t amt = r[(ins >> 8) & 15] & 0xFF;
                const uint32_t mv = rm == 15 ? r[15] + 4 : r[rm];
                b = shift(mv, type, amt, true, carry);
            } else b = shift(r[rm], type, (ins >> 7) & 31, false, carry);
        }
        const uint32_t a = (rn == 15 && !(ins & (1u << 25)) && (ins & 0x10)) ? r[15] + 4 : r[rn];
        const uint32_t cin = (cpsr & C) ? 1 : 0;
        uint32_t res = 0;
        bool write = true, logic = false;
        switch (op) {
            case 0: res = a & b; logic = true; break;
            case 1: res = a ^ b; logic = true; break;
            case 2: res = sub(a, b, 1, s); break;
            case 3: res = sub(b, a, 1, s); break;
            case 4: res = add(a, b, 0, s); break;
            case 5: res = add(a, b, cin, s); break;
            case 6: res = sub(a, b, cin, s); break;
            case 7: res = sub(b, a, cin, s); break;
            case 8: res = a & b; logic = true; write = false; break;
            case 9: res = a ^ b; logic = true; write = false; break;
            case 10: sub(a, b, 1, true); write = false; break;
            case 11: add(a, b, 0, true); write = false; break;
            case 12: res = a | b; logic = true; break;
            case 13: res = b; logic = true; break;
            case 14: res = a & ~b; logic = true; break;
            default: res = ~b; logic = true; break;
        }
        if (logic && (s || !write)) { set_nz(res); cpsr = (cpsr & ~C) | (carry ? C : 0); }
        if (write) { if (rd == 15) set_pc(res, false); else r[rd] = res; }
        return;
    }
    if ((ins & 0x0C000000u) == 0x04000000u) {                                                  // LDR, STR
        const bool p = ins & (1u << 24), u = ins & (1u << 23), byte = ins & (1u << 22), w = ins & (1u << 21), l = ins & (1u << 20);
        const uint32_t rn = (ins >> 16) & 15, rd = (ins >> 12) & 15;
        uint32_t off;
        if (ins & (1u << 25)) { bool c = cpsr & C; off = shift(r[ins & 15], (ins >> 5) & 3, (ins >> 7) & 31, false, c); }
        else off = ins & 0xFFF;
        const uint32_t base = r[rn];
        const uint32_t moved = u ? base + off : base - off;
        const uint32_t a = p ? moved : base;
        uint32_t val = 0;
        if (l) val = byte ? r8(a) : ld32(a);
        else { const uint32_t sv = rd == 15 ? r[15] + 4 : r[rd]; if (byte) w8(a, static_cast<uint8_t>(sv)); else w32(a, sv); }
        if (!p || w) r[rn] = moved;
        if (l) { if (rd == 15) set_pc(val, false); else r[rd] = val; }
        return;
    }
    if ((ins & 0x0E000000u) == 0x08000000u) {                                                  // LDM, STM
        const bool p = ins & (1u << 24), u = ins & (1u << 23), w = ins & (1u << 21), l = ins & (1u << 20);
        const uint32_t rn = ins >> 16 & 15, list = ins & 0xFFFF;
        int cnt = 0;
        for (int i = 0; i < 16; ++i) if (list >> i & 1) ++cnt;
        if (!cnt) return;
        const uint32_t base = r[rn];
        uint32_t a = u ? base : base - 4u * cnt;
        if (p == u) a += 4;
        const uint32_t end = u ? base + 4u * cnt : base - 4u * cnt;
        bool pc_loaded = false; uint32_t pcv = 0;
        for (int i = 0; i < 16; ++i) {
            if (!(list >> i & 1)) continue;
            if (l) { const uint32_t v = r32(a); if (i == 15) { pc_loaded = true; pcv = v; } else r[i] = v; }
            else w32(a, i == 15 ? r[15] + 4 : r[i]);
            a += 4;
        }
        if (w && !(l && (list >> rn & 1))) r[rn] = end;
        if (pc_loaded) set_pc(pcv, false);
        return;
    }
    // coprocessor and the rest: nothing on a GBA
}

void Machine::thm(uint16_t ins) {
    const uint32_t top = ins >> 13;
    if (top == 0) {
        if (((ins >> 11) & 3) != 3) {                                       // LSL, LSR, ASR (immediate)
            const uint32_t rd = ins & 7, rs = (ins >> 3) & 7, amt = (ins >> 6) & 31, type = (ins >> 11) & 3;
            bool carry = cpsr & C;
            const uint32_t v = shift(r[rs], type, amt, false, carry);
            r[rd] = v; set_nz(v); cpsr = (cpsr & ~C) | (carry ? C : 0);
        } else {                                                            // ADD, SUB (register or 3-bit immediate)
            const uint32_t rd = ins & 7, rs = (ins >> 3) & 7, rn = (ins >> 6) & 7;
            const uint32_t b = (ins & 0x400) ? rn : r[rn];
            r[rd] = (ins & 0x200) ? sub(r[rs], b, 1, true) : add(r[rs], b, 0, true);
        }
        return;
    }
    if (top == 1) {                                                         // MOV, CMP, ADD, SUB (8-bit immediate)
        const uint32_t rd = (ins >> 8) & 7, im = ins & 0xFF;
        switch ((ins >> 11) & 3) {
            case 0: r[rd] = im; set_nz(im); break;
            case 1: sub(r[rd], im, 1, true); break;
            case 2: r[rd] = add(r[rd], im, 0, true); break;
            default: r[rd] = sub(r[rd], im, 1, true); break;
        }
        return;
    }
    if ((ins & 0xFC00) == 0x4000) {                                          // ALU operations
        const uint32_t rd = ins & 7, rs = (ins >> 3) & 7, op = (ins >> 6) & 15;
        const uint32_t a = r[rd], b = r[rs];
        const uint32_t cin = (cpsr & C) ? 1 : 0;
        bool carry = cpsr & C;
        switch (op) {
            case 0: r[rd] = a & b; set_nz(r[rd]); break;
            case 1: r[rd] = a ^ b; set_nz(r[rd]); break;
            case 2: r[rd] = shift(a, 0, b & 0xFF, true, carry); set_nz(r[rd]); cpsr = (cpsr & ~C) | (carry ? C : 0); break;
            case 3: r[rd] = shift(a, 1, b & 0xFF, true, carry); set_nz(r[rd]); cpsr = (cpsr & ~C) | (carry ? C : 0); break;
            case 4: r[rd] = shift(a, 2, b & 0xFF, true, carry); set_nz(r[rd]); cpsr = (cpsr & ~C) | (carry ? C : 0); break;
            case 5: r[rd] = add(a, b, cin, true); break;
            case 6: r[rd] = sub(a, b, cin, true); break;
            case 7: r[rd] = shift(a, 3, b & 0xFF, true, carry); set_nz(r[rd]); cpsr = (cpsr & ~C) | (carry ? C : 0); break;
            case 8: set_nz(a & b); break;
            case 9: r[rd] = sub(0, b, 1, true); break;
            case 10: sub(a, b, 1, true); break;
            case 11: add(a, b, 0, true); break;
            case 12: r[rd] = a | b; set_nz(r[rd]); break;
            case 13: r[rd] = a * b; set_nz(r[rd]); break;
            case 14: r[rd] = a & ~b; set_nz(r[rd]); break;
            default: r[rd] = ~b; set_nz(r[rd]); break;
        }
        return;
    }
    if ((ins & 0xFC00) == 0x4400) {                                          // high registers, BX
        const uint32_t op = (ins >> 8) & 3;
        const uint32_t rd = (ins & 7) | ((ins >> 4) & 8), rs = (ins >> 3) & 15;
        switch (op) {
            case 0: { const uint32_t v = r[rd] + r[rs]; if (rd == 15) set_pc(v, false); else r[rd] = v; break; }
            case 1: sub(r[rd], r[rs], 1, true); break;
            case 2: if (rd == 15) set_pc(r[rs], false); else r[rd] = r[rs]; break;
            default: set_pc(r[rs], true); break;
        }
        return;
    }
    if ((ins & 0xF800) == 0x4800) {                                          // LDR rd, [pc, #imm]
        r[(ins >> 8) & 7] = r32((r[15] & ~3u) + (ins & 0xFF) * 4u);
        return;
    }
    if ((ins & 0xF000) == 0x5000) {                                          // load / store with a register offset
        const uint32_t rd = ins & 7, a = r[(ins >> 3) & 7] + r[(ins >> 6) & 7];
        switch ((ins >> 9) & 7) {
            case 0: w32(a, r[rd]); break;
            case 1: w16(a, static_cast<uint16_t>(r[rd])); break;
            case 2: w8(a, static_cast<uint8_t>(r[rd])); break;
            case 3: r[rd] = static_cast<uint32_t>(static_cast<int8_t>(r8(a))); break;
            case 4: r[rd] = ld32(a); break;
            case 5: r[rd] = r16(a); break;
            case 6: r[rd] = r8(a); break;
            default: r[rd] = static_cast<uint32_t>(static_cast<int16_t>(r16(a))); break;
        }
        return;
    }
    if (top == 3) {                                                         // load / store with an immediate offset
        const uint32_t rd = ins & 7, rb = (ins >> 3) & 7, off = (ins >> 6) & 31;
        const bool byte = ins & 0x1000, l = ins & 0x800;
        const uint32_t a = r[rb] + (byte ? off : off * 4);
        if (l) r[rd] = byte ? r8(a) : ld32(a);
        else if (byte) w8(a, static_cast<uint8_t>(r[rd])); else w32(a, r[rd]);
        return;
    }
    if ((ins & 0xF000) == 0x8000) {                                          // LDRH, STRH (immediate)
        const uint32_t rd = ins & 7, a = r[(ins >> 3) & 7] + ((ins >> 6) & 31) * 2;
        if (ins & 0x800) r[rd] = r16(a); else w16(a, static_cast<uint16_t>(r[rd]));
        return;
    }
    if ((ins & 0xF000) == 0x9000) {                                          // load / store, sp-relative
        const uint32_t rd = (ins >> 8) & 7, a = r[13] + (ins & 0xFF) * 4u;
        if (ins & 0x800) r[rd] = ld32(a); else w32(a, r[rd]);
        return;
    }
    if ((ins & 0xF000) == 0xA000) {                                          // ADD rd, pc / sp, #imm
        const uint32_t rd = (ins >> 8) & 7, im = (ins & 0xFF) * 4u;
        r[rd] = (ins & 0x800) ? r[13] + im : (r[15] & ~3u) + im;
        return;
    }
    if ((ins & 0xFF00) == 0xB000) {                                          // ADD sp, #+-imm
        const uint32_t im = (ins & 0x7F) * 4u;
        r[13] = (ins & 0x80) ? r[13] - im : r[13] + im;
        return;
    }
    if ((ins & 0xF600) == 0xB400) {                                          // PUSH, POP
        const bool l = ins & 0x800, extra = ins & 0x100;
        const uint32_t list = ins & 0xFF;
        if (!l) {
            int cnt = extra ? 1 : 0;
            for (int i = 0; i < 8; ++i) if (list >> i & 1) ++cnt;
            uint32_t a = r[13] - 4u * cnt;
            r[13] = a;
            for (int i = 0; i < 8; ++i) if (list >> i & 1) { w32(a, r[i]); a += 4; }
            if (extra) w32(a, r[14]);
        } else {
            uint32_t a = r[13];
            for (int i = 0; i < 8; ++i) if (list >> i & 1) { r[i] = r32(a); a += 4; }
            if (extra) { const uint32_t v = r32(a); a += 4; set_pc(v, false); }
            r[13] = a;
        }
        return;
    }
    if ((ins & 0xF000) == 0xC000) {                                          // LDMIA, STMIA
        const uint32_t rb = (ins >> 8) & 7, list = ins & 0xFF;
        uint32_t a = r[rb];
        const bool l = ins & 0x800;
        for (int i = 0; i < 8; ++i) {
            if (!(list >> i & 1)) continue;
            if (l) r[i] = r32(a); else w32(a, r[i]);
            a += 4;
        }
        if (!(l && (list >> rb & 1))) r[rb] = a;
        return;
    }
    if ((ins & 0xF000) == 0xD000) {                                          // conditional branch, SWI
        const uint32_t c = (ins >> 8) & 15;
        if (c == 15) { swi(ins & 0xFF); return; }
        if (cond(c)) set_pc(r[15] + static_cast<uint32_t>(static_cast<int32_t>(static_cast<int8_t>(ins & 0xFF)) * 2), false);
        return;
    }
    if ((ins & 0xF800) == 0xE000) {                                          // B
        const int32_t off = static_cast<int32_t>(static_cast<uint32_t>(ins & 0x7FF) << 21) >> 20;
        set_pc(r[15] + static_cast<uint32_t>(off), false);
        return;
    }
    if ((ins & 0xF000) == 0xF000) {                                          // BL (two halves)
        if (!(ins & 0x800)) {
            const int32_t off = static_cast<int32_t>(static_cast<uint32_t>(ins & 0x7FF) << 21) >> 9;
            r[14] = r[15] + static_cast<uint32_t>(off);
        } else {
            const uint32_t target = r[14] + (ins & 0x7FFu) * 2;
            r[14] = (r[15] - 2) | 1;
            set_pc(target, false);
        }
        return;
    }
}

bool Machine::call(uint32_t addr, uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint64_t max_steps) {
    r[0] = a0; r[1] = a1; r[2] = a2; r[3] = a3;
    r[13] = 0x03007E00u;
    thumb = addr & 1;
    if (thumb) cpsr |= T; else cpsr &= ~T;
    r[14] = return_magic_ | (thumb ? 1u : 0u);
    r[15] = addr & ~1u;
    const uint64_t end = steps + max_steps;
    while (steps < end) {
        if ((r[15] & ~1u) == (return_magic_ & ~1u)) return true;
        step();
    }
    std::fprintf(stderr, "[gba] %08x ran too long (now at %08x)\n", addr, r[15]);
    return false;
}

bool Machine::boot_until(uint32_t addr, uint64_t max_steps) {
    thumb = false; cpsr = 0x1F; r[15] = 0x08000000u;
    const uint64_t end = steps + max_steps;
    while (steps < end) {
        if ((r[15] & ~1u) == (addr & ~1u)) return true;
        step();
    }
    std::fprintf(stderr, "[gba] the boot did not reach %08x (at %08x)\n", addr, r[15]);
    return false;
}

}  // namespace gbacpu
