# Villain poses as RECIPES: every missing hero frame = one of the villain's own game frames + steps (mirror, shift,
# brighten, turn, tilt). Only the recipe ships; the app builds the frames from the player's own game file.
# usage: recipes.py TD ART_WORK_DIR BUILTIN_DIR PASSNAME
import sys, json
import numpy as np
from PIL import Image, ImageDraw

TD, AW, BI, PASS = sys.argv[1:5]
ANIM = {0: 'STAND', 1: 'WALK', 2: 'HURT', 3: 'KNOCKED DOWN', 4: 'POWER UP', 5: 'KI BLAST', 6: 'COMBO', 7: 'PUNCH',
        8: 'DASH / KICK', 10: 'ACTION 10', 11: 'VICTORY', 12: 'FLYING', 13: 'RUN', 14: 'BORED', 16: 'SPECIAL MELEE',
        17: 'FALLEN', 18: 'SPECIAL ENERGY A', 19: 'SPECIAL ENERGY B', 20: 'CLIMB'}
DIRS = ['DOWN', 'UP', 'LEFT', 'RIGHT']
C = 64
ref = json.load(open(TD + '/sprites/set_60.json'))
NEED = [(a, d, len(ref['slots'][4 * a + d])) for a in range(len(ref['slots']) // 4) for d in range(4) if ref['slots'][4 * a + d]]


# ---- a recipe: {"from": [slot, frame], "ops": [[op, args...], ...]}
def R(slot, f): return {'from': [slot, f], 'ops': []}
def op(r, *o): return {'from': r['from'], 'ops': r['ops'] + [list(o)]}
def mirror(r): return op(r, 'mirror')
def shift(r, dx, dy): return op(r, 'shift', dx, dy) if (dx or dy) else r
def bright(r, k): return op(r, 'bright', k)
def rot(r, q): return op(r, 'rot', q)
def tilt(r, t): return op(r, 'tilt', t)


# ---- the same steps on pictures (for the sheets you look at; the app does exactly these)
def bbox(c):
    ys, xs = np.nonzero(c[:, :, 3])
    return (0, 0, 1, 1) if len(xs) == 0 else (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def render(r, im):
    s, f = r['from']
    c = im[s * C:(s + 1) * C, f * C:(f + 1) * C].copy()
    for o in r['ops']:
        k = o[0]
        if k == 'mirror':
            x0, y0, x1, y1 = bbox(c); out = np.zeros_like(c); out[:, x0:x1] = c[:, x0:x1][:, ::-1]; c = out
        elif k == 'shift':
            dx, dy = o[1], o[2]; out = np.zeros_like(c)
            ys0, ys1 = max(0, dy), min(C, C + dy); xs0, xs1 = max(0, dx), min(C, C + dx)
            out[ys0:ys1, xs0:xs1] = c[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]; c = out
        elif k == 'bright':
            out = c.astype(int); m = out[:, :, 3] > 0
            for i in range(3): out[:, :, i][m] = np.minimum(255, out[:, :, i][m] + o[1])
            c = out.astype(np.uint8)
        elif k == 'rot':
            x0, y0, x1, y1 = bbox(c); fig = np.rot90(c[y0:y1, x0:x1], o[1]); h, w = fig.shape[:2]
            out = np.zeros_like(c); cx = (x0 + x1) // 2
            nx = max(0, min(C - w, cx - w // 2)); ny = max(0, min(C - h, y1 - h)); out[ny:ny + h, nx:nx + w] = fig; c = out
        elif k == 'tilt':
            x0, y0, x1, y1 = bbox(c); out = np.zeros_like(c)
            for y in range(y0, y1):
                off = int(round((y1 - y) * 0.6 * o[1]))
                row = np.zeros_like(c[y]);
                if off >= 0: row[off:] = c[y][:C - off] if off else c[y]
                else: row[:C + off] = c[y][-off:]
                out[y] = row
            c = out
    return c


REAL_DOWN = (74, 49, 9)   # villains whose own knocked-down frames are real: King Cold's fall, Mecha Frieza cut in half
DOWN_FRONT = (49,)     # ...drawn facing front only: every way round shows it
NOT_FLYING = ()    # (none: Yamcha and Tien fly in their own frames)
def plan(sid):
    js = json.load(open(TD + '/sprites/set_%d.json' % sid))
    im = np.array(Image.open(TD + '/sprites/set_%d.png' % sid).convert('RGBA'))
    sl = js['slots']

    def own(a, d):
        s = 4 * a + d
        if s >= len(sl) or not sl[s] or (a == 12 and sid in NOT_FLYING):
            return []
        if d >= 1 and sl[4 * a] and np.array_equal(im[s * C:(s + 1) * C, 0:C], im[4 * a * C:(4 * a + 1) * C, 0:C]):
            return []          # a side that is only the front again
        return [R(s, f) for f in range(len(sl[s]))]

    def side(a, d):
        o = {2: 3, 3: 2}.get(d)
        return [mirror(x) for x in own(a, o)] if o is not None else []

    def any_of(a, d): return own(a, d) or side(a, d)

    def base(d):
        for a in (0, 1):
            if any_of(a, d): return any_of(a, d)[0]
        return (own(0, 0) or own(1, 0))[0]

    made, tags = {}, {}
    for a, d, n in NEED:
        fr = own(a, d); tag = 'ORIGINAL'
        if a in (2, 17) or (a == 3 and sid not in REAL_DOWN) or (a == 12 and sid in NOT_FLYING): fr = []      # (an enemy's own pose there is something else - Cooler's is a walk)
        if not fr and side(a, d):
            fr, tag = side(a, d), 'MIRRORED'
        if not fr:
            tag = 'MADE'
            b = base(d)
            fx, fy = {0: (0, 2), 1: (0, -2), 2: (-2, 0), 3: (2, 0)}[d]
            if a == 0: fr = [b, b]
            elif a == 13 and (1, d) in made: fr = made[(1, d)]      # running: the walk, for now
            elif a in (1, 13): fr = [b, shift(b, 0, -1), b, shift(b, 0, -1)]
            elif a in (2, 17): fr = [b]     # hit / beaten: standing - the app flashes him red / puts him in the game's smoke (villain_fx)
            elif a == 3 and sid not in REAL_DOWN: fr = [b]
            elif a == 3 and sid in DOWN_FRONT: fr = own(3, 0)     # beaten, no knocked-down pose of his own: standing - the app fades him out in the game's smoke
            elif a == 3:
                t = -1 if d == 3 else 1
                fr = [tilt(b, t * 0.5), tilt(b, t), rot(b, 1 if t > 0 else -1), rot(b, 1 if t > 0 else -1)]
            elif a == 4: fr = [bright(b, 60), b, bright(b, 60), b]
            elif a == 11: fr = [b, shift(b, 0, -3)]
            elif a == 12:
                if d in (2, 3):
                    h = rot(b, 1 if d == 2 else -1); fr = [h, shift(h, 0, -1), h, shift(h, 0, -1)]
                else: fr = [shift(b, 0, -4), shift(b, 0, -5)]
            elif a in (18, 19):
                ki = any_of(5, d) or any_of(4, d)
                if ki:
                    fr = [ki[0], bright(ki[0], 35)] if a == 18 else [ki[-1], bright(ki[-1], 25)]
                else:
                    fr = [b, bright(b, 35)] if a == 18 else [shift(b, fx, fy), bright(shift(b, fx, fy), 25)]
            elif a == 16:
                chain = []
                for aa in (6, 7, 8): chain += any_of(aa, d)
                if not chain: chain = [b, shift(b, fx, fy), shift(b, fx * 2, fy * 2), shift(b, fx * 3, fy * 3)]
                fr = [bright(c, 30) if i % 2 else c for i, c in enumerate(chain)]
            elif a == 20: fr = [base(1), shift(base(1), 0, -1)]
            else:
                at = []
                for aa in (7, 6, 8, 5):
                    at = any_of(aa, d)
                    if at: break
                if a == 5 and any_of(5, d): at = any_of(5, d)
                fr = at or [b, shift(b, fx, fy), shift(b, fx * 2, fy * 2), b]
            if d == 1 and not own(0, 1) and not own(1, 1): tag = 'MADE (FRONT AS BACK)'
        made[(a, d)] = [fr[i % len(fr)] for i in range(n)]
        tags[(a, d)] = tag
    return js, im, made, tags


colors = json.load(open(BI + '/colors.json'))
sets = colors.setdefault('sets', {})
for name, sid in (('frieza', 48), ('mecha_frieza', 49), ('cooler', 34), ('king_cold', 74)):
    js, im, made, tags = plan(sid)
    rows = [(a, d) for a, d, n in NEED]
    T = Image.new('RGBA', (7 * C, len(rows) * C), (0, 0, 0, 0))
    G = Image.new('RGBA', (7 * C + 230, len(rows) * C), (30, 30, 50, 255)); dg = ImageDraw.Draw(G)
    anchor = js['slots'][0][0] if js['slots'] and js['slots'][0] else {'x': -8, 'y': -24}
    recipe, frames = {}, {}
    for r, (a, d) in enumerate(rows):
        for f, rc in enumerate(made[(a, d)][:7]):
            T.alpha_composite(Image.fromarray(render(rc, im)), (f * C, r * C))
        tag = tags[(a, d)]
        if tag != 'ORIGINAL':
            s = 4 * a + d
            recipe[str(s)] = made[(a, d)]
            frames[str(s)] = [{'x': int(anchor['x']), 'y': int(anchor['y']), 'w': C, 'h': C} for _ in made[(a, d)]]
        col = {'ORIGINAL': (150, 220, 150, 255), 'MIRRORED': (150, 200, 255, 255)}.get(tag, (255, 150, 120, 255))
        dg.text((6, r * C + 4), '%s %s' % (ANIM.get(a, 'ACTION %d' % a), DIRS[d]), fill=(230, 230, 240, 255))
        dg.text((6, r * C + 18), tag, fill=col)
        dg.line([(0, r * C), (G.width, r * C)], fill=(70, 70, 100, 255))
    G.alpha_composite(T, (230, 0))
    D = AW + '/villains/' + name; __import__('os').makedirs(D, exist_ok=True); T.save(D + '/%s_%s.png' % (name, PASS)); G.save(D + '/%s_%s_guide.png' % (name, PASS))
    keep = {k: v for k, v in sets.get(str(sid), {}).items() if k not in ('_note', 'make', 'frames')}
    keep['villain_fx'] = True
    keep['smoke_down'] = sid not in REAL_DOWN      # (King Cold has a real fall of his own: he keeps it)
    sets[str(sid)] = {**keep, '_note': '%s: the poses a hero needs, made from his own game frames (recipe - nothing of the game ships)' % name.upper(),
                      'make': recipe, 'frames': frames}
    print(name, 'slots made', len(recipe))
json.dump(colors, open(BI + '/colors.json', 'w'), indent=1)
