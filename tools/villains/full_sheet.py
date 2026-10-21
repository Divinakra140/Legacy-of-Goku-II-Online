# full_sheet.py TD BUILTIN SID NAME ART.png - a whole finished sheet (pass layout: set_60 rows, 64 px cells) as the set's overlay
import sys, json, numpy as np
from PIL import Image
TD, BI, SID, NAME, ART = sys.argv[1:6]; SID = int(SID)
src = open(__file__.replace('full_sheet.py', 'recipes.py')).read().split('\ndef plan(')[0]
sys.argv = ['x', TD, '/tmp', BI, 'x']; g = {}; exec(src, g)
render, NEED, C = g['render'], g['NEED'], 64
colors = json.load(open(BI + '/colors.json')); st = colors['sets'][str(SID)]
js = json.load(open(TD + '/sprites/set_%d.json' % SID))
base = np.array(Image.open(TD + '/sprites/set_%d.png' % SID).convert('RGBA'))
rows = max([int(k) for k in st.get('make', {})] + [4 * a + d for a, d, n in NEED]) + 1
H, W = max(base.shape[0], rows * C), max(base.shape[1], 7 * C)
made = np.zeros((H, W, 4), np.uint8); made[:base.shape[0], :base.shape[1]] = base
for k, lst in st.get('make', {}).items():
    s = int(k); made[s * C:(s + 1) * C] = 0
    for f, r in enumerate(lst): made[s * C:(s + 1) * C, f * C:(f + 1) * C] = render(r, base)
art = np.array(Image.open(ART).convert('RGBA'))
want = made.copy(); frames = st.setdefault('frames', {})
anchor = js['slots'][0][0]
for r, (a, d, n) in enumerate(NEED):
    s = 4 * a + d
    want[s * C:(s + 1) * C] = 0
    want[s * C:(s + 1) * C, :7 * C] = art[r * C:(r + 1) * C, :7 * C]
    old = frames.get(str(s)) or (js['slots'][s] if s < len(js['slots']) and js['slots'][s] else [])
    frames[str(s)] = [{'x': int((old[f] if f < len(old) else anchor)['x']), 'y': int((old[f] if f < len(old) else anchor)['y']), 'w': C, 'h': C} for f in range(n)]
ma = made[:, :, 3] > 0; wa = want[:, :, 3] > 0
diff = wa & (~ma | (np.abs(made[:, :, :3].astype(int) - want[:, :, :3].astype(int)).sum(2) > 0)); er = ma & ~wa
ov = np.zeros_like(made); ov[diff, :3] = want[diff, :3]; ov[diff, 3] = 255; ov[er, 3] = 128
Image.fromarray(ov).save(BI + '/sprites/overlay_%s.png' % NAME, optimize=True)
st['overlay'] = 'overlay_%s.png' % NAME
json.dump(colors, open(BI + '/colors.json', 'w'), indent=1)
print(NAME, W, H, 'drawn', int(diff.sum()), 'erased', int(er.sum()))
