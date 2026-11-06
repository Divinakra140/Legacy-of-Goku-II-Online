#!/bin/zsh
# Builds all three releases into release/v45: Android APK, Windows zip, Mac zip.
# Double-click it, or run it in Terminal. Takes a few minutes.
# Before it: if you changed the Earth in the editor, run tools/bake_earth.py first (from the project folder),
# and raise BUNDLE_VERSION in project/scripts/assets.gd so Android installs pick up the new data.
set -e
B="/Volumes/Gen2/Godot/Legacy of Goku/LoG2_Android_Build"
[ -d /Volumes/PWBuild/godot ] || hdiutil attach /Volumes/Gen2/PokeWilds-Build.sparseimage >/dev/null
cd "$B"; source tools/local.env
V=v45; R="$B/release/$V"; W="$R/LoG2Online_${V}_Windows"; M="$R/LoG2Online_${V}_Mac"; T=/private/tmp/log2_build; NAME="LoG2 Online"
mkdir -p "$T"
echo "== game data for Android"
dot_clean -m data/mods data/builtin 2>/dev/null || true
python3 -I tools/make_pack.py data project/bundle/gamedata.pack content modpacks music adventures builtin mods | tail -1
echo "== android"
bash tools/export_gradle.sh 2>&1 | tail -1
cp out/LoG2Coop.apk "$R/LoG2Online_${V}_Android.apk"
cd project
echo "== windows"
"$GODOT" --headless --export-release "Windows Desktop" ../build_win/LoG2Online.exe 2>&1 | grep -iE 'error' | tail -3 || true
cp ../build_win/LoG2Online.exe ../build_win/LoG2Online.pck "$W/"
echo "== mac"
rm -rf "$T/macrel"; mkdir -p "$T/macrel"
"$GODOT" --headless --export-release "macOS" "$T/macrel/LoG2Online.app" 2>&1 | grep -iE 'error' | tail -3 || true
if [ -f "$T/macrel/LoG2Online.zip" ]; then (cd "$T/macrel" && ditto -x -k LoG2Online.zip .); fi
P="$T/macrel/LoG2Online.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$P"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $NAME" "$P"
dot_clean -m "$T/macrel/LoG2Online.app"
codesign --force --deep -s - "$T/macrel/LoG2Online.app" 2>/dev/null
codesign --verify --deep "$T/macrel/LoG2Online.app" && echo "mac signed ok"
rm -rf "$M/LoG2Online.app"; ditto "$T/macrel/LoG2Online.app" "$M/LoG2Online.app"
cd "$B"
echo "== game data and guides into the Windows and Mac folders"
# (the folders already hold godot_export(.exe) and log2_ztbridge(.exe) - never delete those)
for D in "$W" "$M"; do
  for f in content modpacks music adventures builtin mods; do rsync -a --delete --exclude '._*' --exclude '.DS_Store' "data/$f/" "$D/$f/"; done
  cp CHANGELOG.md tools/release_docs/CHANGELOG.txt
  for f in "READ ME.txt" "DEV TOOLS.txt" "Earth Editor Guide.txt" "Story Mode Editor Guide.txt" "CHANGELOG.txt"; do cp "tools/release_docs/$f" "$D/$f"; done
  for bad in imported game.gba roms; do [ ! -e "$D/$bad" ] || { echo "STOP: $D/$bad (game data must never ship)"; exit 1; }; done
done
echo "== zips"
rm -rf "$T/zipstage"; mkdir -p "$T/zipstage"
for n in "LoG2Online_${V}_Windows" "LoG2Online_${V}_Mac"; do rsync -a --exclude '._*' --exclude '.DS_Store' "$R/$n" "$T/zipstage/"; done
cd "$T/zipstage"
for n in "LoG2Online_${V}_Windows" "LoG2Online_${V}_Mac"; do rm -f "$n.zip"; COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$n" "$n.zip"; cp "$n.zip" "$R/"; done
dot_clean -m "$R" 2>/dev/null || true
echo "== done:"; ls -la "$R" | grep -v '\._'
