# How to get Buu's Fury sprites out with the LoG2 Co-op extractor (PC version, v42)

1. Use the **PC version** of LoG2 Co-op. The extractor isn't available in the Android app.
2. Put your own **Dragon Ball Z - Buu's Fury (USA)** `.gba` file (or a `.zip` with it inside) in one of these places:
   - next to `LoG2Coop.exe`
   - in a folder called `roms` next to it
   - in your **Downloads**
   - next to your Legacy of Goku II file
3. Open the game and go to **OPTIONS → DEV TOOLS**. Then either:
   - press the **OTHER GAMES** button on the map editor's toolbar, or
   - let it happen by itself: the next time the game reads your Legacy of Goku II file, it reads Buu's Fury too.
4. It takes a few seconds. The results land in the game's **`imported`** folder:
   - `imported/sprites/set_1000.png` and up: every Buu's Fury character, one PNG per character, plus a `.json` describing each frame's box
   - `imported/lib/bf/`: the map tiles (`tiles.png`) and all 419 maps
5. You can also browse the characters inside the game, in **DEV TOOLS → SPRITES** (Buu's Fury sets start at 1000).

Nothing from Buu's Fury comes with the download. Everything is read from your own copy.

(The same steps also read the original **The Legacy of Goku**: its sprite sets start at 2000.)
