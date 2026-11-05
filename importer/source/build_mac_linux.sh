#!/bin/sh
# Builds godot_export (the game importer) for macOS or Linux. Needs a C++17 compiler:
#   macOS: xcode-select --install     Linux: sudo apt install g++
set -e
cd "$(dirname "$0")"
CXX=${CXX:-c++}
$CXX -O2 -std=c++17 -o godot_export tools/godot_export.cpp src/map_builder.cpp src/rom_tiles.cpp src/rom_sprites.cpp src/rom_catalog.cpp src/gba_music.cpp src/qoa_enc.cpp src/gba_cpu.cpp -lpthread
echo "Built ./godot_export - copy it next to project.godot (running from the Godot editor) or next to the game program."
