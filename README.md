<img width="7000" height="5650" alt="Legacy of Goku II Online - Updated Map" src="https://github.com/user-attachments/assets/bc7033e3-f9b0-47e8-bd6f-2845f2dd3cf0" />
 

The world's first ever online multiplayer Godot rebuild of **Legacy of Goku II** by **Puni Puni** and **Divinakra**
(YouTube: [@PuniPuni2026](https://www.youtube.com/@PuniPuni2026), [@DivinakraCreations](https://www.youtube.com/@DivinakraCreations)),
for **Android** (Handhelds and phones), **Windows** and **Mac** (Apple Silicon and Intel). All three play
GLOBAL multiplayer together. Also known as "Legacy of Goku II - Co-op". 

**Improvements** LoG2 Online v46 has some exciting impovements to both the game on all three platforms and bundled map editor
 on PC and Mac:
- **The game:** global and local multiplayer across Android, Windows and Mac, GBA-style menus, flying anywhere, new playable heroes, 
  villians and  outfits, a seamless open world Earth map that connects all the LOG2 GBA maps into one, the original 
  game's balance (level cap 50), original game music recorded from your own cartridge, and shared saves. [Download Here](https://github.com/Divinakra140/Legacy-of-Goku-II-Online/releases/tag/v46)
- **The dev tools:** a much better map editor (redo, brush sizes, mirrored copy and paste, keep-the-ground pasting,
  save points in THINGS, customizable foes, door jumping, biome paint, smart edges, walkable roofs, render layers, map resizing and a move places tool) with guides included
  ([Story.Mode.Editor.Guide.txt](https://github.com/Divinakra140/Legacy-of-Goku-II-Online/releases/download/v46/Story.Mode.Editor.Guide.txt)) ([Earth.Editor.Guide.txt](https://github.com/Divinakra140/Legacy-of-Goku-II-Online/releases/download/v46/Earth.Editor.Guide.txt)). and a [Video Guide](https://www.youtube.com/watch?v=eD4ifri5Pkg) by Divinakra.

**No game data is included.** On first start the game asks for your own *Dragon Ball Z - The Legacy of Goku II (USA)*
.gba (CHOOSE MY GAME) and reads its maps, sprites and sounds on your device. Earth ships as tile numbers only
(builtin/earth): it is drawn with the tiles from your own game file. This game acts as an asset extractor for all three legacy games as long as the .gba USA files sit next to each other somewhere on your computer. Sprites get sent to "imported" > "sprites" next to the LoG2Online.exe. 

See [CHANGELOG.md](CHANGELOG.md) for what is new.

## Android specifics (differences from the v42 PC release)
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
- tools/ - make_pack.py (packs data/), export.sh (build + sign), run_on_device.sh (install via adb),
  bake_earth.py (right before a release: lays the map editor's Earth edits into data/builtin/earth, the Earth that ships),
  release_docs/ (READ ME.txt, DEV TOOLS.txt and Earth Editor Guide.txt shipped with the Windows / Mac builds)

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

## AI Use, Progenitor Credits, Backstory and Future Remarks
This project was made with the help of AI. I first found out about Puni Puni's "Legacy of Goku II Coop" v42 from 
his youtube video and contacted him to see if he would be ok with me developing it and helping to polish it,
port it to android and mac ect.. since it was only on windows and was not polished at all and you could not even 
walk over flowers and many areas of the map were thrown together by code. To my surpise, Puni Puni wanted someone to "take over" the project. So I did! I have redrawn the entire 
map by hand, corrected the collision and rendering by hand and even added some hand drawn animation frames and a whole 
redesigned sprite sheet for Mecha Frieza. I added in public multiplayer, and begun the original story mode and made a 
bunch of the game's characters playable with my own hand drawn special attacks. Puni Puni does not have a Github account 
so I cannot add him as contributor but he is the progenitor of this project and it has been disclosed that AI was used in 
much of it, so I figure I might as well make that clear on here. If anyone wants to continue the development of this game,
please take this source code and do whatever you want with it. I will likely stop developing this unpaid passion project
after v45 or v46 as I feel my desires for this game have been implemented. 
