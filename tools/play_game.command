#!/bin/zsh
# Double-click: starts LoG2 itself on this Mac (the debug game, from the project - every change in, no build needed),
# to play and test. Uses your own saves and data/, the same as the Earth editor.
B="/Volumes/Gen2/Godot/Legacy of Goku/LoG2_Android_Build"
[ -d /Volumes/PWBuild/godot ] || hdiutil attach /Volumes/Gen2/PokeWilds-Build.sparseimage >/dev/null
source "$B/tools/local.env"
cd "$B/project"
LOG2_EXE_DIR="$B/data" "$GODOT" --path .
