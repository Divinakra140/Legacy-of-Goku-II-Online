// A small ARM7TDMI interpreter for running pieces of the game's own code (its sound engine) on the player's game
// file: the game's memory (game file, work RAM, fast RAM), DMA 3, and the few BIOS calls the game makes, done here
// so no BIOS file is needed. No pictures, no interrupts, no timing: code runs until it returns.
#pragma once
#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

namespace gbacpu {

struct Machine {
    std::vector<uint8_t> rom;              // the game file
    std::vector<uint8_t> ewram, iwram, io, vram, pal, oam;
    uint32_t r[16] = {};
    uint32_t cpsr = 0x1F;                  // system mode
    uint32_t bank_sp[6] = {}, bank_lr[6] = {};   // usr/sys, irq, svc, abt, und, fiq (only the stack is kept apart)
    bool thumb = false;
    uint64_t steps = 0;
    std::function<void(uint32_t addr, uint32_t value, int size)> on_write;   // a watch on the game's writes (optional)

    explicit Machine(std::vector<uint8_t> game);
    // run the game's function at addr (bit 0 = Thumb) with up to four arguments; false if it ran too long
    bool call(uint32_t addr, uint32_t a0 = 0, uint32_t a1 = 0, uint32_t a2 = 0, uint32_t a3 = 0, uint64_t max_steps = 200000000);
    // run from the game's start until it reaches addr (its main, after the boot code copied what it needs)
    bool boot_until(uint32_t addr, uint64_t max_steps = 50000000);

    uint8_t r8(uint32_t a);
    uint16_t r16(uint32_t a);
    uint32_t r32(uint32_t a);
    void w8(uint32_t a, uint8_t v);
    void w16(uint32_t a, uint16_t v);
    void w32(uint32_t a, uint32_t v);

private:
    uint32_t next_ = 0;
    bool stop_ = false;
    uint32_t return_magic_ = 0xFFFFFF00u;
    uint8_t* at(uint32_t a, bool write);
    void io_written(uint32_t a);
    void step();
    void arm(uint32_t ins);
    void thm(uint16_t ins);
    bool cond(uint32_t c) const;
    void set_mode(uint32_t mode);
    void swi(uint32_t n);
    void set_nz(uint32_t v);
    uint32_t shift(uint32_t v, uint32_t type, uint32_t amt, bool reg, bool& carry);
    uint32_t add(uint32_t a, uint32_t b, uint32_t c, bool s);
    uint32_t sub(uint32_t a, uint32_t b, uint32_t c, bool s);
    uint32_t ld32(uint32_t a);       // an ARM word load (a misaligned address turns the word round)
    void set_pc(uint32_t v, bool exchange);
};

}  // namespace gbacpu
