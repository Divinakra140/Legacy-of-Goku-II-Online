// The game's own songs, played by the game's own sound engine (run with gba_cpu on the player's game file) and
// saved as QOA files with their loop: music/song_NN.qoa + music/song_NN.json {"rate", "loop_begin", "loop_end"}.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace gbamusic {
constexpr int kSongs = 44;
// render the given songs (all when empty) into dir; returns how many were written
int export_songs(const std::vector<uint8_t>& game, const std::string& dir, const std::vector<int>& songs);
}
