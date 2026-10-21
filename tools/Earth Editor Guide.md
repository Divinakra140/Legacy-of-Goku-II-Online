# Earth Editor Guide

This is the game's own DEV TOOLS map editor (Puni Puni's). Double-click `tools/earth_editor.command` to open it.

## Getting around

- **Move:** drag with the right (or middle) mouse button, or use WASD / the arrow keys.
- **Zoom:** mouse wheel. When you are zoomed far out, a left click zooms in on that spot.
- **WALLS** button: shows where you cannot walk, in red.
- **GRID** button: shows the 8×8 cells.

## Layers

Each map cell has 5 layers. Press the number keys **0–4** to choose one.

| Layer | What it holds |
|---|---|
| 0 | The ground (grass, snow, paving) |
| 1–2 | Things under the hero (trunks, fences, clothes) |
| 3–4 | Things drawn over the hero (leaves, roof edges) |

**TILE** and **ERASE** work on the chosen layer. **STAMP**, **COPY** and **PASTE** work on all 5 layers at once, plus the wall.

### Moving a tile over or under the hero

To make the hero walk behind something (a tree top, a roof edge), move its tile from layer 1–2 up to layer 3–4:

1. Press **1** (or **2**), the layer the tile is on now.
2. Choose **PICK** and click the cell. PICK takes the tile from the layer you chose. It then switches you to STAMP, so carry on with the next steps.
3. Choose **ERASE** and click the same cell. This removes the tile from that layer.
4. Press **3**, choose **TILE**, and click the cell. The tile is painted back, now over the hero.

To put a tile back under the hero, do the same the other way round: start on layer 3 or 4 and paint it on 1 or 2.

- If PICK takes the wrong tile (or none), you're on the wrong layer. Try another number and PICK again.
- A tile over the hero doesn't stop them walking there. Walls are separate: use **WALL** and **GROUND**.

## Undo and save

- **Undo:** **Control+Z** (the Control key, not Command) or the **UNDO** button. It remembers about 60 steps.
- **Redo:** **Control+Y** (or Control+Shift+Z) or the **REDO** button puts back what you undid. Making a new change forgets the steps you could redo.
- **Save:** **Control+S** or the **SAVE** button. Your changes go into `data/mods/maps`.
- **Go back to an older save:** every save is kept. Open the **CHECK** tab and use **HISTORY → RESTORE**.
- Closing without saving throws away everything since your last save.

## Copying a tree, a save point or anything else

This is the copy-and-paste you asked about:

1. Choose **COPY** and drag a box around the tree (or the Capsule Corp pad, a house, anything).
2. Choose **PASTE** and click where you want it. The box's top-left corner lands at the mouse. Click again to place more copies.

Walls come along with the copy, so a pasted tree blocks only where the original did.

**Keep the ground there:** tick **KEEP THE GROUND THERE** on the right (or press **G**) in PASTE or THINGS. The ground tiles round the edge of your copy are treated as background and left out: the ground already where you paste stays, and only the thing itself (a Capsule Corp pad, a tree, a house) is laid on it, with its walls. Copy with a little background showing on every side so it knows what to leave out.

**Mirroring:** after COPY, press **X** (or the **MIRROR LEFT-RIGHT** button on the right) to flip the copy left-right, or **Y** (**MIRROR UPSIDE DOWN**) to flip it upside down. Then PASTE as usual. Press X again to turn it back.

**New save points:** choose **THINGS** and pick **SAVE POINT** from the list, then click the map. It is the game's own Capsule Corp pad with a see-through edge, so it sits on any ground (grass, sand, snow, paving). Standing anywhere on it: A saves and heals, R2 turns PvP on or off. SAVE the map to keep it.

**THINGS** is a shortcut for whole objects. Press **FIND THINGS IN VIEW**, and it cuts out the houses, trees and fences you can see as one-click stamps.

## Painting single cells

- **PICK** then **STAMP:** click a cell with PICK to take everything in it (all layers and its wall), then paint it elsewhere with STAMP.
- **TILE:** paints one tile on the chosen layer. PICK also chooses the tile for it.
- **FILL**, **LINE**, **RECT:** drag to fill a box, draw a line or draw a rectangle with your brush.
- **SMART:** PICK a ground first (water, sand, a path), then paint. When you let go, its edges are joined up the way the game's own maps join them.

## Walls

- **WALL:** paint where you cannot walk.
- **GROUND:** paint where you can walk.

Turn WALLS on first to see what you are doing.

**Brush size:** TILE, STAMP, ERASE, WALL and GROUND have a **brush size** box on the right (1 to 32 cells across). The white square under the mouse shows how much you will paint. Dragging paints a smooth line, even when you move the mouse fast.

## Doors

- The yellow boxes are doors. Walking into one takes you through.
- **Move or resize a door:** choose **SELECT**, click its yellow box, and change it on the right. Drag to move it, or press Delete (or Backspace) to remove it.
- **Where does a door lead?** Choose **SELECT** and click its yellow box. A yellow line runs to a green dot marked ARRIVES HERE. The line stays on screen while you pan, or press **J** to jump straight there (J again jumps back). A door to another map shows "TO <map name>" above its box.
- **Make a new door:** choose **DOOR**, drag its box, then click where it should take you. To arrive on another map, use **GO TO MAP** first.

## Other tools

| Tool | What it does |
|---|---|
| **FOE** | Place a foe |
| **PERSON** | Place a person who speaks |
| **ITEM** | Place treasure |
| **ZONE** | Drag a box where foes keep coming back |
| **MOOD** | Drag a box to make the place dark, rainy, snowy or play its own music |
| **EVENT** | Drag a box that starts an event when you walk in |

## When you're done

Save. Your edits are added to the next build for everyone.
