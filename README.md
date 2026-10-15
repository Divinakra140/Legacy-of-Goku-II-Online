# LOG2II Android Coop Port

Android port of **Legacy of Goku II - Co-op (Godot)** by **Puni Puni**
(YouTube: [@PuniPuni2026](https://www.youtube.com/@PuniPuni2026)), distributed with the developer's permission.
Built for and tested on the Retroid Pocket Flip 2; works on 64-bit ARM Android devices (Android 7+).

**No game data is included.** On first start the app asks for your own *Dragon Ball Z - The Legacy of Goku II (USA)*
.gba (CHOOSE MY GAME) and reads its maps, sprites and sounds on the device (about 30 seconds).

## What the port changes (from the v42 PC release)
- Runs the game importer on Android (built with the NDK, shipped as lib/arm64-v8a/libgodot_export.so)
- CHOOSE MY GAME uses Android's file picker
- Game folders (content, mod packs, adventures) unpacked into the app's storage on first start
- Your own music from /storage/emulated/0/Music/LoG2Coop (sounds in .../LoG2Coop/sounds)
- Gamepad navigation in the title menus; Nintendo/Retroid A/B layout by default (OPTIONS - A/B BUTTONS)
- OPTIONS - ON-SCREEN BUTTONS: AUTO / ON / OFF
- Sharp text at any screen size; menu text and controls written for handhelds
- Fixes for Godot 4.7 on Android: an audio crash during fights, slow first start

## Layout
- project/ - the Godot project (Godot 4.7.2; originally made with 4.3)
- data/ - Puni Puni's game folders packed into the APK: content/, modpacks/, adventures/, music/
- importer/source/ - the game importer (plain C++17, no other libraries)
- tools/ - make_pack.py (packs data/), export.sh (build + sign), run_on_device.sh (install via adb)

## Building
Needs Godot 4.7.2 with its Android export templates, the Android SDK (build-tools 34), the NDK, and JDK 17.
1. Build the importer for Android:
   aarch64-linux-android24-clang++ -O2 -std=c++17 -fPIE -pie -static-libstdc++ -s -Wl,--hash-style=both -o importer/android/libgodot_export.so importer/source/tools/godot_export.cpp importer/source/src/*.cpp
2. Pack the game folders: python3 tools/make_pack.py data project/bundle/gamedata.pack content modpacks music adventures builtin
3. Put android_release.apk / android_debug.apk from the Godot 4.7.2 export templates in templates/
4. Make your own release keystore in keys/ (keys/log2coop-release.keystore, alias log2coop, password in
   keys/keystore_password.txt as password: ...).
5. Point the scripts at your tools, then build - the signed APK lands in out/LoG2Coop.apk:
   export GODOT=/path/to/godot ANDROID_SDK=/path/to/android-sdk JAVA_HOME=/path/to/jdk-17 then tools/export.sh
   
## Current State
  This game is not a 1:1 port of the original GBA game and if you are thinking you will be able to play through the original story
with a friend as a coop, that is not the case...At least not yet. I am considering porting the whole story over, but maybe not,
that is a huge job. This game in its current state is a free-play style, where the developer, Puni Puni, took a bunch of 
the LOG2 tiles and rearranged them in an open world that aims to emulate the original world, but with all the areas connected. 
The combat mechanics and animations look and feel very good and the enemies and leveling up system is all pretty polished already.
The environments themselves are not polished though, and need a lot of work before they feel like a real game.

  The world is currently pretty open and flat and 2 dimensional feeling with a bunch of enemies scattered throughout that you can 
kill to level up. There are moves you can unlock as you go, for each each character and each character has different special moves. 
You can create your own story on the dev editor on the desktop version of this game and there is already a few custom stories
that have been made for the game and you can play them in this android port. You can also create custom maps from the GBA tiles. 
Think of the current state of the game as a sort of  Godot-LOG2 tech demo. We have the tools and the general layout here, we just
need developers to polish the way the game rearranges the GBA tiles into a more playable and realistic environment, and possibly 
integrate some story elements, and cutscenes ect.. Eventually the end game for this port is to have two modes: Freeplay and Story 
Mode, each with coop and maybe even PVP in Freeplay. Freeplay is the most developed of the two and even then, there is still a lot 
to go and we are open to any developers joining the team, just contact me, Divinakra or Puni Puni on Discord or Reddit or submit an 
issue here. We will get back to you as soon as we can. Thanks for your patience. 
