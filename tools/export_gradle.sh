#!/bin/zsh
# export_gradle.sh [extra command line args] -> out/LoG2Coop.apk
# Godot's Gradle build (needed for the embedded ZeroTier of GLOBAL MULTIPLAYER). Gradle needs a disk with links and
# permissions, which exFAT (Gen2) has not: the project is copied to $BUILD (the PWBuild disk image) and built there.
# The copy's android/build is Godot's template + android_custom/ (the Java bridge) + libzt + the game-file importer.
# Needs: source tools/local.env (GODOT, ANDROID_SDK, JAVA_HOME), keys/, project/lobby_server.txt (private), and
# android_custom/libzt-release.aar or an existing copy in the build folder.
B="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=${BUILD:-/Volumes/PWBuild/log2-build}
P="$BUILD/project"
# the game data packed fresh every time (an APK must never carry older data than the folders hold)
dot_clean -m "$B/data/mods" "$B/data/builtin" 2>/dev/null || true
python3 -I "$B/tools/make_pack.py" "$B/data" "$B/project/bundle/gamedata.pack" content modpacks music adventures builtin mods > /dev/null || { echo "packing the game data failed"; exit 1; }
[ -d "$P/android/build" ] || { echo "No Android build template in $P/android/build (see README: Gradle build)"; exit 1; }
rsync -a --delete --exclude '._*' --exclude '.godot/' --exclude 'android/' "$B/project/" "$P/"
cp "$B"/android_custom/java/com/godot/game/*.java "$P/android/build/src/main/java/com/godot/game/"
mkdir -p "$P/android/build/libs/release/arm64-v8a"
cp "$B/importer/android/libgodot_export.so" "$P/android/build/libs/release/arm64-v8a/"
file "$P/android/build/libs/release/arm64-v8a/libgodot_export.so" | grep -q ELF || { echo "the importer is not a program (a bad copy?)"; exit 1; }
cd "$P" || exit 1
sed -i '' "s#^command_line/extra_args=.*#command_line/extra_args=\"$1\"#" export_presets.cfg
[ -n "$PKG" ] && sed -i '' "s#^package/unique_name=.*#package/unique_name=\"$PKG\"#; s#^package/name=.*#package/name=\"LoG2 TEST\"#" export_presets.cfg
export PW=$(sed -n 's/^password: //p' "$B/keys/keystore_password.txt")
mkdir -p "$B/out"; rm -f "$B/out/LoG2Coop.apk" "$B/out/LoG2Coop.apk.idsig"
GRADLE_USER_HOME=/Volumes/PWBuild/gradle-home \
GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$B/keys/log2coop-release.keystore" GODOT_ANDROID_KEYSTORE_RELEASE_USER=log2coop GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$PW" \
  "$GODOT" --headless --path . --export-release "Android" "$P/LoG2Coop.apk" > "$BUILD/export.log" 2>&1
grep -E 'ERROR|SCRIPT|FAILED|BUILD SUCCESSFUL' "$BUILD/export.log" | tail -5
[ -f "$P/LoG2Coop.apk" ] || { echo "export failed - see $BUILD/export.log"; exit 1; }
"$ANDROID_SDK/build-tools/36.1.0/apksigner" verify "$P/LoG2Coop.apk" || exit 1
cp "$P/LoG2Coop.apk" "$B/out/LoG2Coop.apk" && rm -f "$P/LoG2Coop.apk" "$P/LoG2Coop.apk.idsig"
cmp -s "$B/out/LoG2Coop.apk" "$B/out/LoG2Coop.apk" && echo "Signed: $B/out/LoG2Coop.apk"
find "$B/out" -name '._*' -delete
