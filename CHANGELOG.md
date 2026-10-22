# Changelog

## v44 - "LoG2 Online"

### Now on Android, Windows and Mac - and a new name
- **LoG2 Online** (Legacy of Goku 2 Online): Android (Retroid Pocket and phones), Windows, and Mac (one app for
  Apple Silicon and Intel, macOS 10.15+). All three play GLOBAL multiplayer together. Saves carry over.
- Windows / Mac: fullscreen by default (remembered), a window that fits the screen when windowed, the menus fill the
  screen at any size, keyboard (Enter / Space / J / Z select, Esc back) and mouse in every menu, QUIT GAME in OPTIONS,
  F3 shows the frame rate. The computer's own file browser for picking your game file. Dragon Ball app icon.
- AMD's built-in Radeon R-series graphics use real OpenGL (2-3x faster than the ANGLE fallback on an R4 laptop).

### Multiplayer fixes
- A player whose connection blinks now rejoins the same host (before, they were moved into a world of their own).
- A PC or Mac joining a handheld's game connects at once (the game knocked on the helper's door before it was
  open, and every try failed). The PC / Mac helper writes bridge.log (in the game's zerotier folder).
- PC / Mac hosts no longer drop a player every minute or so when two or more join (the helper mixed up connections).
- Windows: the multiplayer helper is waited for on a slow PC (no more "the multiplayer helper stopped").
- Joining a game keeps your own outfits, view size, buttons and settings (it took the host's).
- Android: R3 opens the chat with the on-screen keyboard (Enter sends, R3 again closes).
- Windows / Mac: names, world names and passwords can be typed on the keyboard (and the typing stays on that screen: it no longer
  follows you into the next screen's address or password box).
- QUIT GAME closes at once, even while a song is being recorded.
- Sharper text: names over people and speech bubbles in the game, and the map editor's labels at any zoom.
- Menus: K and Backspace go back too (like Esc and the B button).
- Map editor: SELECT a person to change their name, look and lines (the game's own people too), then SAVE CHANGES.
- Map editor: after placing a person, SAVE TO THE PERSON JUST PLACED gives them a new name, look or lines at once.
- Knocked out? You are back at the last Capsule Corp save point you saved at (this play session; a new session starts
  at the map's own spawn, so friends start together).
- Android: the saves are in Android/data/com.log2coop.game/files/saves (reachable with a cable or a file manager);
  saves already on the device are moved there the first time.
- Knocked out: the fall plays once and you lie still until a friend helps you up (it played again and again).
- A held beam stops at once when you are hit or knocked out (it went on from where it was fired, emptying your ki).
- All the words in the game - names, speech bubbles, the HUD, messages, the START menu - in the cartridge's own
  pixel font, sharp on every screen (they were a modern font, blurry or broken on handhelds).
- OPTIONS - SAVE FILES: EXPORT SAVE FILE and IMPORT SAVE FILE (all your heroes in one file - take a PC's heroes to a
  handheld and back).
- HUD on / off (OPTIONS, and HUD / MINIMAP in the START menu), remembered. The HUD box, the minimap and the START menu
  are the same size on the screen at any VIEW SIZE (tiny at PIXELS x2 and too big or cut off at x6 before).
- Map editor: Control+Z / Command+Z undo works again, and J (go where a door leads) is never taken by a side button
  clicked before (the menus' keyboard select had those keys).
- Piccolo (and Goku, Vegeta, Trunks) standing in a town keep their own name (one was called HERCULE).
- MY OWN MUSIC: picking a song to replace works again, and the game's songs with no place of their own have their names
  (Eternal Dragon, Piccolo Theme, The Green Menace, Hercule Day Parade and more).

### Earth
- Earth reworked by hand: new forests, roads, rivers, doors, and strong foes out at the edges. It ships as the base
  map (tile numbers only - drawn from your own game file), so everybody walks the same Earth and it loads quickly.
- Improved by hand: the area around Goku's House, Triceratops Jungle and West City.
- Every room behind a door has plain black round it (no more mirrored copies of the room). City Hall, the
  Antiquities shop and the West City apartments have their stone floors back. The minimap shows the edits.
- GOKU'S HOUSE: a new choice in SELECT MAP - Earth, starting in Gohan's bedroom (and back there when beaten).
  (EAST DISTRICT 439 is gone from the list: GOKU'S HOUSE is the same area, improved.)
- People are named after who they are (Krillin is KRILLIN) and say only their own lines.

### First start
- The import shows a live loading bar with each step. It no longer grows the Earth countryside on your device:
  faster, and about a third less memory.
- The game's music: choose RECORD WHILE I PLAY (a stand-in tune until each song is ready - the place you are in goes
  first) or RECORD ALL NOW, asked once for each copy of the game. The recorder runs at low priority, so the game stays smooth.

### Balance
- Foes keep their own strength from the original game (they no longer rise to your level); the tough ones are at the edges.
- Levels end at 50, as in the original (the table past 50 was reading other data). 3 points a level (+1 strength,
  power and endurance). Saved heroes keep their level (above 50: 50) and get the points their level now gives.
- Goku: SS Blue Aura at level 40, SS Blue at level 50. Beams reach full length 40 levels after you learn them.

### Controls and moves
- L3: sprint until you stop (and boost while flying). R2: sprint on / off. B lands while flying, Y boosts.
- Held beams drain ki and end when you let go or run out. Upward beams and their charge glow are drawn behind you.
- Spirit Bomb as strong as Supernova, Spirit Ball as strong as Death Ball. Specials can be switched while flying.

### New heroes and art
- Yamcha, Krillin, Tien, Android 18 and Android 17. Every villain playable except King Cold.
- Perfect Cell's walk (Chris Ruok), Teen Trunks flying in all directions, Mecha Frieza's redesign and new attack
  animations (Divinakra). Galick Gun and Sword Slash icons. Credits scroll, with a SPRITE ART section.

### DEV TOOLS (Windows / Mac)
- Map editor: REDO, brush size, smooth strokes, mirror a copy (X / Y), KEEP THE GROUND when pasting, a SAVE POINT
  thing, a picture list of foes (weakest first) with a level and a look, Backspace deletes, J jumps to where a door
  leads. Much faster on big maps. Fixed: a phantom door box after making a door, SELECT letting go of what you clicked.

## v44 (earlier builds) - "Console-like Multiplayer"

### Global multiplayer (over the internet)
- GLOBAL MULTIPLAYER: host a public game, host a private game with a password, join a game, or host a
  server without playing. Built in: no VPN app or IP address needed.
- Worlds have names, shown in the JOIN GAME list.
- Host migration: if the host leaves, the first player who joined becomes the new host and the game carries on.
- A join that fails while the internet link is still starting up tries again by itself ("STILL CONNECTING").

### Menus in the style of the Game Boy Advance game
- The start screen is the game's own title picture (read from your game file), with START / OPTIONS in its box,
  black-outlined letters and the little Dragon Ball cursor. The tiny "TM" and copyright line are redrawn as sharp text.
- Every menu uses the GBA's own fonts and the drifting purple galaxy (seamless loop), with the Dragon Ball cursor.
- New layout: START → SINGLE PLAYER (FREE PLAY / STORY MODE) or MULTIPLAYER (GLOBAL / LOCAL / SPLIT SCREEN).
- SELECT MAP: Planet Gatorra, Planet Dunara, Earth, then the game's other lands, plus a random planet.
- CHOOSE YOUR CHARACTER: every hero standing in a GBA-style box, with their level.
- YOUR NAME: a GBA-style letter board right after you pick a hero (also used for world names and passwords).
- STORY MODE lists the stories from mods. ORIGINAL STORY is still being ported.
- OPTIONS: SAVE FILES (see and delete your STORY MODE slots and FREE PLAY heroes), OPTIONS (music and sound volume, view size, on-screen buttons, A/B layout - the same as in the game), MODS (mod loader, and MY OWN MUSIC to pick a song for each part of the game, or go back to the game's
  own song) and CREDITS.
- B goes back on every screen, and each menu remembers the choice you last made.
- A loading screen while a world is built. No Godot splash at start (Puni Puni's logo instead).

### The game's real music
- All 44 of the GBA game's songs, played by the game's own sound engine from your game file (no BIOS file,
  nothing recorded ships with the app). They are made in the background after the import (a few minutes the
  first time) and loop exactly where the game loops them.
- The title song plays on every menu; every place in the world plays its own song from the GBA game.
- OPTIONS - MODS - MY OWN MUSIC lists all the game's songs by where they play: replace any one with a song of
  yours (MP3 / OGG), or bring the game's own back.
- Songs are read during the loading screen, so changing places doesn't hitch.

### Characters and outfits
- CHOOSE YOUR CHARACTER: L / R (bumpers or triggers, or tap the corners) change the highlighted hero's outfit;
  the level and the save stay the hero's.
- GOKU: Goku, SS Goku, Shirtless, SS Blue, SSBA (SS Blue with aura), Shadow. PICCOLO: Piccolo, No Weights, Yellow, Torn.
  GOHAN: Gohan, Casual, Namek Armor, Battle Suit, SS2, SS. VEGETA: Vegeta, SS Vegeta.
  TRUNKS: Trunks, Teen, Battle Suit, SS, SS Battle Suit (the game's own looks, read from your game file).
  The new looks are sprite sets by Puni Puni (shipped as only the pixels they changed).
- New playable villains (early - punch and ki blast for now): CELL (Perfect, Semi-Perfect, Imperfect),
  FRIEZA (Frieza, Mecha), COOLER, KING COLD.
- The name board remembers your name: the cursor starts on DONE.

### Gameplay
- FREE PLAY saves are shared by every map: your hero keeps their level, items and moves wherever you go.
  (Quests and story progress still belong to each world.)
- L2 (or G on a keyboard) in FREE PLAY: fly over everything - nothing blocks you and you are drawn above it all. L2 again lands.
  Mr. Satan flies sideways on a jetpack (frames drawn by Divinakra).
- Running straight up, down, left or right is now as fast as running on a diagonal.
- Beams grow with you: every 10 levels after a hero or villain learns a beam, it reaches further (from its usual
  short length up to very long). Full length 70 levels after learning it.
- Health and ki bars in the GBA's style: red health and green ki in a metal frame, with an experience bar.
- QUIT TO TITLE AND SAVE GAME goes back to the start menu instead of closing the app.
- Earth is built the same way on every device: everyone gets the same Earth.
- Flowers and grass tufts no longer block you (rows of swaying flowers included); trees, rocks and bushes still do.

### Fixes
- A mod's story (with its dark park, people and doors) only applies while you play that story, not in FREE PLAY.
- The mod list says which mods are for FREE PLAY and which add a STORY MODE story; the Shadow Goku example is gone (he is a Goku outfit now).
- ADD A MOD uses Android's own file picker, and B leaves the mod loader.
- Songs picked in MY OWN MUSIC are checked first: a file that can't be played (for example an MP4) is refused
  instead of silencing the game.

Your game file is read again on the first start of this version (about 30 seconds).
