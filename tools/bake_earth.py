#!/usr/bin/env python3 -I
"""Bake the Earth edits into the Earth everybody gets (run right before a release).

EARTH is built by the importer from each player's own cartridge, and the map editor saves its changes
as a list on top (data/mods/maps/land_0_0.json). This writes the finished Earth - this machine's import
with every tile and wall change laid in - as builtin/earth/earth_base.gz: tile numbers and walls only,
no picture of the game. On each player's machine the game lays it over their own import once, so
everybody walks the same Earth (the importer's grown country is not quite the same on every system).

Also written: earth_changed.gz (the cells the edits touched: the minimap is redrawn there),
earth_enemies.json (the roaming foes, the same for everybody) and version.txt.
Everything else in the edits file (doors, foes, people, rocks, treasure, zones, triggers...) goes into
earth_land.json, and the edits file is left empty (a copy is kept in data/backups).

usage: python3 -I tools/bake_earth.py [FULL]   (from the project folder; the editor must be closed)
  FULL: the whole Earth as the game built it (LKR2 header + 5 layers + walls) - for an Earth RESIZED in the editor
  (its edits file's "size"): written as it is, bigger or smaller than the import; the walls with every bit kept
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
    if len(sys.argv) > 1:      # the whole Earth, as the game built it (a resized one too)
        full = open(sys.argv[1], "rb").read()
        if full[:4] != b"LKR2":
            print("not an LKR2 Earth:", sys.argv[1])
            return 1
        w2 = full[4] | full[5] << 8
        h2 = full[6] | full[7] << 8
        n2 = w2 * h2
        nl = [np.frombuffer(full, dtype="<u4", count=n2, offset=8 + k * n2 * 4).copy() for k in range(5)]
        nw = np.frombuffer(full, dtype="u1", count=n2, offset=8 + 5 * n2 * 4).copy()
        # changed: every cell not as the import has it (outside the import: all)
        ch = np.ones(n2, dtype=bool)
        ys, xs = np.divmod(np.arange(n2), w2)
        inside = (xs < w) & (ys < h)
        oi = ys[inside] * w + xs[inside]
        same = np.ones(inside.sum(), dtype=bool)
        for k in range(5):
            same &= nl[k][inside] == layers[k][oi]
        same &= nw[inside] == walk[oi]
        ch[np.nonzero(inside)[0][same]] = False
        changed = set(np.nonzero(ch)[0].tolist())
        raw = full[:8]
        layers, walk = nl, nw
        edits["cells"] = {}      # (all in the base now)
    for key, v in edits.get("cells", {}).items():
        x, y = (int(t) for t in key.split(","))
        if 0 <= x < w and 0 <= y < h:
            i = y * w + x
            for k in range(5):
                layers[k][i] = int(v[k]) & 0xFFFFFFFF
            walk[i] = int(v[5]) & 0xFF      # every bit: 1 ground, 4 HIGH GROUND (& 1 lost every roof you can land on)
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
    # everything else the edits hold (foes, people, doors, rocks, treasure, zones, triggers, moods, moved places,
    # size) goes into the game too: builtin/earth/earth_land.json. The edits file is left empty ({}: nothing laid
    # over the base - an older copy unzipped over it is replaced)
    land_f = os.path.join(OUT, "earth_land.json")
    if edits.get("has_base"):
        land = edits      # (saved by the editor after a bake: already the whole list)
    else:
        land = json.load(open(land_f)) if os.path.exists(land_f) else {}
        for k, v in edits.items():
            if k == "cells":
                continue
            if isinstance(v, dict):
                land.setdefault(k, {}).update(v)
            elif k == "size":
                if v:
                    land[k] = v
            elif isinstance(v, list):
                land[k] = land.get(k, []) + v
    land = {k: v for k, v in land.items() if k not in ("cells", "has_base")}
    json.dump(land, open(land_f, "w"))
    json.dump({}, open(EDITS, "w"))
    print("baked Earth %s: %d changed cells, %d KB, %d foes" % (
        ver, len(changed), os.path.getsize(os.path.join(OUT, "earth_base.gz")) // 1024, len(reg.get("enemies", []))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
