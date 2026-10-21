#!/usr/bin/env python3 -I
"""Bake the Earth edits into the Earth everybody gets (run right before a release).

EARTH is built by the importer from each player's own cartridge, and the map editor saves its changes
as a list on top (data/mods/maps/land_0_0.json). This writes the finished Earth - this machine's import
with every tile and wall change laid in - as builtin/earth/earth_base.gz: tile numbers and walls only,
no picture of the game. On each player's machine the game lays it over their own import once, so
everybody walks the same Earth (the importer's grown country is not quite the same on every system).

Also written: earth_changed.gz (the cells the edits touched: the minimap is redrawn there),
earth_enemies.json (the roaming foes, the same for everybody) and version.txt.
The tile changes are then taken out of the edits file (a copy is kept in data/backups); doors, foes,
people and treasure stay in it.

usage: python3 -I tools/bake_earth.py   (from the project folder; the editor must be closed)
"""
import gzip
import json
import os
import shutil
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
LANDS = os.path.join(DATA, "imported", "kit", "lands", "0")
EDITS = os.path.join(DATA, "mods", "maps", "land_0_0.json")
OUT = os.path.join(DATA, "builtin", "earth")


def main() -> int:
    raw = open(os.path.join(LANDS, "0.bin"), "rb").read()
    if raw[:4] != b"LKR2":
        print("the imported Earth is not an LKR2 file:", raw[:4])
        return 1
    w = raw[4] | raw[5] << 8
    h = raw[6] | raw[7] << 8
    n = w * h
    layers = [np.frombuffer(raw, dtype="<u4", count=n, offset=8 + k * n * 4).copy() for k in range(5)]
    walk = np.frombuffer(raw, dtype="u1", count=n, offset=8 + 5 * n * 4).copy()
    # an Earth baked before: start from it (its changes are no longer in the edits file)
    old = os.path.join(OUT, "earth_base.gz")
    changed = set()
    if os.path.exists(old):
        prev = gzip.decompress(open(old, "rb").read())
        if prev[:8] == raw[:8] and len(prev) == len(raw):
            layers = [np.frombuffer(prev, dtype="<u4", count=n, offset=8 + k * n * 4).copy() for k in range(5)]
            walk = np.frombuffer(prev, dtype="u1", count=n, offset=8 + 5 * n * 4).copy()
            oc = os.path.join(OUT, "earth_changed.gz")
            if os.path.exists(oc):
                changed.update(np.frombuffer(gzip.decompress(open(oc, "rb").read()), dtype="<i4").tolist())
    edits = json.load(open(EDITS))
    for key, v in edits.get("cells", {}).items():
        x, y = (int(t) for t in key.split(","))
        if 0 <= x < w and 0 <= y < h:
            i = y * w + x
            for k in range(5):
                layers[k][i] = int(v[k]) & 0xFFFFFFFF
            walk[i] = int(v[5]) & 1
            changed.add(i)
    os.makedirs(OUT, exist_ok=True)
    body = raw[:8] + b"".join(l.astype("<u4").tobytes() for l in layers) + walk.tobytes()
    open(os.path.join(OUT, "earth_base.gz"), "wb").write(gzip.compress(body, 9))
    open(os.path.join(OUT, "earth_changed.gz"), "wb").write(
        gzip.compress(np.array(sorted(changed), dtype="<i4").tobytes(), 9))
    shutil.copy2(os.path.join(LANDS, "lands.json"), os.path.join(OUT, "lands.json"))      # Earth's places, doors and foes (numbers)
    reg = json.load(open(os.path.join(LANDS, "lands.json")))["regions"][0]
    json.dump(reg.get("enemies", []), open(os.path.join(OUT, "earth_enemies.json"), "w"))
    ver = time.strftime("%Y%m%d-%H%M%S")
    open(os.path.join(OUT, "version.txt"), "w").write(ver + "\n")
    # the tile changes are the base now: out of the edits file (a copy kept)
    os.makedirs(os.path.join(DATA, "backups"), exist_ok=True)
    shutil.copy2(EDITS, os.path.join(DATA, "backups", "land_0_0_before_bake_%s.json" % ver))
    edits["cells"] = {}
    json.dump(edits, open(EDITS, "w"))
    print("baked Earth %s: %d changed cells, %d KB, %d foes" % (
        ver, len(changed), os.path.getsize(os.path.join(OUT, "earth_base.gz")) // 1024, len(reg.get("enemies", []))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
