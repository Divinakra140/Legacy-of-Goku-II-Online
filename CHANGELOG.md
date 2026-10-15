# Changelog

## v44 - "Console-like Multiplayer"

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
- OPTIONS: MODS (mod loader, and MY OWN MUSIC to pick a song for each part of the game, or go back to the game's
  own song) and CREDITS.
- B goes back on every screen, and each menu remembers the choice you last made.
- A loading screen while a world is built. No Godot splash at start (Puni Puni's logo instead).

### New heroes
- SS GOKU, SHIRTLESS and SS BLUE: Super Saiyan Goku sprite sets by Puni Puni.
- SHADOW (Shadow Goku) is built in.

### Gameplay
- FREE PLAY saves are shared by every map: your hero keeps their level, items and moves wherever you go.
  (Quests and story progress still belong to each world.)
- L2 (or G on a keyboard) in FREE PLAY: fly over everything - nothing blocks you and you are drawn above it all. L2 again lands.
- Running straight up, down, left or right is now as fast as running on a diagonal.
- Health and ki bars in the GBA's style: red health and green ki in a metal frame, with an experience bar.
- QUIT TO TITLE AND SAVE GAME goes back to the start menu instead of closing the app.
- Earth is built the same way on every device: everyone gets the same Earth.

### Fixes
- A mod's story (with its dark park, people and doors) only applies while you play that story, not in FREE PLAY.
- ADD A MOD uses Android's own file picker, and B leaves the mod loader.
- Songs picked in MY OWN MUSIC are checked first: a file that can't be played (for example an MP4) is refused
  instead of silencing the game.

Your game file is read again on the first start of this version (about 30 seconds).
