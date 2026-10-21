#!/bin/zsh
# Double-click: opens LoG2's DEV TOOLS (the map editor) on this Mac. Edits are saved into data/mods/maps
# (press SAVE in the editor) and go into the next Android build for everyone.
B="/Volumes/Gen2/Godot/Legacy of Goku/LoG2_Android_Build"
[ -d /Volumes/PWBuild/godot ] || hdiutil attach /Volumes/Gen2/PokeWilds-Build.sparseimage >/dev/null
source "$B/tools/local.env"
cd "$B/project"
LOG2_EXE_DIR="$B/data" "$GODOT" --path . -- --devtools
