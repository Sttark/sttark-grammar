"""Draws docs/shortcuts.svg: three keyboards with a see-through left hand.
Run: python3 docs/shortcuts.py docs/shortcuts.svg docs/shortcuts.svg"""
import json, math, re, sys
# joint spots of a left hand resting on a keyboard (thumb on Command, index on 1), from a reference photo
JOINTS = {"VNHLKIDIP":[913,992,0.80],"VNHLKIMCP":[835,1501,0.85],"VNHLKIPIP":[875,1151,0.85],"VNHLKITIP":[939,898,0.90],"VNHLKMDIP":[819,978,0.85],"VNHLKMMCP":[654,1475,0.84],"VNHLKMPIP":[746,1134,0.83],"VNHLKMTIP":[869,895,0.79],"VNHLKPDIP":[530,1153,0.81],"VNHLKPMCP":[449,1522,0.77],"VNHLKPPIP":[482,1281,0.86],"VNHLKPTIP":[583,1048,0.89],"VNHLKRDIP":[708,1031,0.82],"VNHLKRMCP":[532,1492,0.79],"VNHLKRPIP":[621,1182,0.78],"VNHLKRTIP":[768,929,0.85],"VNHLKTCMC":[841,2040,0.66],"VNHLKTIP":[1188,1566,0.90],"VNHLKTMP":[1090,1810,0.81],"VNHLKTTIP":[1242,1402,0.91],"VNHLKWRI":[507,2105,0.67]}
J = {k[5:]: complex(*v[:2]) for k, v in JOINTS.items()}
# keys come from the current picture's first keyboard
old = open(sys.argv[1]).read().splitlines()
# the first board's keys, lines between its title and its clipPath
start = next(i for i, l in enumerate(old) if 'Read aloud' in l)
end = next(i for i, l in enumerate(old) if 'Fix all' in l)
rects = [l for l in old[start + 1:end] if l.startswith('<rect')]
texts = [l for l in old[start + 1:end] if l.startswith('<text') and 'class="l' in l]
def label(r):
    x, y, w, h = (float(re.search(n + r'="([\d.]+)"', r).group(1)) for n in ('x', 'y', 'width', 'height'))
    for t in texts:
        tx, ty = float(re.search(r'x="([\d.]+)"', t).group(1)), float(re.search(r'y="([\d.]+)"', t).group(1))
        if x <= tx <= x + w and y <= ty <= y + h: return re.search(r'>([^<]*)</text>', t).group(1)
    return ''
def keys_for(target):
    on = ('command', target)
    out = [re.sub(r'class="(k|on)"', 'class="%s"' % ('on' if label(r) in on else 'k'), r) for r in rects]
    for t in texts:
        lab = re.search(r'>([^<]*)</text>', t).group(1)
        out.append(re.sub(r'class="l(on)?"', 'class="%s"' % ('lon' if lab in on else 'l'), t))
    return out
KEY = {'`': 37 + 84j, '1': 74 + 84j, '2': 111 + 84j}
CMD = (138, 215, 194, 249)
S = 0.29
FING = {'I': 16.0, 'M': 16.5, 'R': 15.0, 'P': 12.5}   # half widths at the knuckle, board px

def place(target):
    # the hand keeps the photo's angle (its keyboard sits about 9 degrees off level) and size, and slides
    # sideways so the index tip is on the key; the thumb bends a little to stay on Command
    k = KEY[target]
    rot = complex(math.cos(math.radians(-8.8)), math.sin(math.radians(-8.8)))
    f = lambda p: k + 0.31 * rot * (p - J['ITIP'])
    P = {n: f(p) for n, p in J.items()}
    t = P['TTIP']
    t = complex(min(max(t.real, CMD[0] + 12), CMD[2] - 12), min(max(t.imag, CMD[1] + 9), CMD[3] - 9))
    base = P['TCMC']; turn = (t - base) / (P['TTIP'] - base)
    for n in ('TMP', 'TIP', 'TTIP'): P[n] = base + (P[n] - base) * turn
    return P, t

def catmull(pts, closed=True):
    n = len(pts); d = ''
    rng = range(n) if closed else range(n - 1)
    for i in rng:
        p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        if not closed:
            p0 = pts[max(i - 1, 0)]; p3 = pts[min(i + 2, n - 1)]
        c1 = p1 + (p2 - p0) / 6; c2 = p2 - (p3 - p1) / 6
        if i == 0: d += 'M%.1f,%.1f' % (p1.real, p1.imag)
        d += ' C%.1f,%.1f %.1f,%.1f %.1f,%.1f' % (c1.real, c1.imag, c2.real, c2.imag, p2.real, p2.imag)
    return d + (' Z' if closed else '')

def finger(chain, w0, w1):
    # outline: up one side, round the tip, down the other
    n = len(chain); L, R = [], []
    for i, p in enumerate(chain):
        a = chain[min(i + 1, n - 1)] - chain[max(i - 1, 0)]; a /= abs(a)
        w = w0 + (w1 - w0) * i / (n - 1)
        if 0 < i < n - 1: w *= 1.06          # knuckles a touch wider
        nrm = a * 1j
        L.append(p + nrm * w); R.append(p - nrm * w)
    a = chain[-1] - chain[-2]; a /= abs(a)
    tip = [chain[-1] + a * w1 * math.sin(th) + a * 1j * w1 * math.cos(th) for th in (0.5, 1.0, 1.5708, 2.14, 2.64)]
    return catmull(L + tip + R[::-1])

def nail(p_dip, p_tip, w):
    a = p_tip - p_dip; a /= abs(a)
    c = p_tip + a * w * 0.05
    ang = math.degrees(math.atan2(a.imag, a.real))
    return '<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" transform="rotate(%.1f %.1f %.1f)" class="nail"/>' % (c.real, c.imag, w * 1.05, w * 0.8, ang, c.real, c.imag)

def crease(p, q, w):
    a = q - p; a /= abs(a); n = a * 1j
    s, e = p + n * w * 0.55, p - n * w * 0.55
    m = p - a * w * 0.18
    return '<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" class="crease"/>' % (s.real, s.imag, m.real, m.imag, e.real, e.imag)

def hand(P, uid):
    out = []
    d = lambda n: P[n]
    # the arm runs from the wrist away from the middle knuckle
    arm = d('WRI') - d('MMCP'); arm /= abs(arm); side = arm * 1j
    wr = d('WRI')
    ww = 0.82 * abs(d('IMCP') - d('PMCP')) / 2 + 12
    thumb_side = wr - side * ww if abs(wr - side * ww - d('TCMC')) < abs(wr + side * ww - d('TCMC')) else wr + side * ww
    pinky_side = 2 * wr - thumb_side
    k = (d('IMCP') - d('PMCP')); k /= abs(k); up = -arm
    palm = [d('IMCP') + k * 13 + up * 10, (d('IMCP') + d('MMCP')) / 2 + up * 20, d('MMCP') + up * 16, (d('MMCP') + d('RMCP')) / 2 + up * 19, d('RMCP') + up * 14, (d('RMCP') + d('PMCP')) / 2 + up * 14, d('PMCP') + up * 6 - k * 10,
            d('PMCP') - k * 15 + arm * 30, pinky_side + up * 10, pinky_side + arm * 12,
            thumb_side + arm * 12, thumb_side + up * 4, d('TCMC') + (d('TCMC') - wr) * 0.25,
            d('TMP') - (d('TMP') - d('IMCP')) * 0.05, (d('TMP') + d('IMCP')) / 2 + (d('IMCP') - d('PMCP')) * 0.08]
    forearm = [pinky_side + up * 6, pinky_side + arm * 160 - side * 0, thumb_side + arm * 160, thumb_side + up * 6]
    shapes_under = []
    fingers = []
    for f in 'PRMI':
        ch = [d(f + 'MCP') + arm * 6, d(f + 'PIP'), d(f + 'DIP'), d(f + 'TIP')]
        fingers.append((f, ch, finger(ch, FING[f], FING[f] * 0.82)))
    th = [d('TCMC') + (d('TMP') - d('TCMC')) * 0.15, d('TMP'), d('TIP'), d('TTIP')]
    thumb = finger(th, 21, 14.5)
    palm_d = catmull(palm); fore_d = catmull(forearm)
    # outlines first, then fill; the group is see-through as one piece
    out.append('<g class="hand" mask="url(#fade%s)">' % uid)
    out.append('<g filter="url(#shade)">')
    out.append('<path d="%s" class="edge"/><path d="%s" class="edge"/>' % (fore_d, palm_d))
    out.append('<path d="%s" class="edge"/><path d="%s" class="skin"/>' % (thumb, thumb))
    for f, ch, dd in fingers:
        out.append('<path d="%s" class="edge"/><path d="%s" class="skin"/>' % (dd, dd))
    out.append('<path d="%s" class="skin"/><path d="%s" class="skin"/>' % (fore_d, palm_d))
    out.append('</g>')
    # back of the hand: soft knuckles and tendons
    for f in 'IMRP':
        m = d(f + 'MCP')
        out.append('<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" class="knuckle"/>' % (m.real, m.imag, FING[f] * 0.45, FING[f] * 0.32))
        a, b = m + arm * 8, (m + wr) / 2 + arm * 6
        out.append('<path d="M%.1f,%.1f L%.1f,%.1f" class="tendon"/>' % (a.real, a.imag, b.real, b.imag))
    for f, ch, dd in fingers:
        w = FING[f]
        out.append(crease(ch[1], ch[2], w * 0.9) + crease(ch[2], ch[3], w * 0.82))
        out.append(nail(ch[2], ch[3], w * 0.82 * 0.62))
    out.append(crease(th[2], th[3], 14))
    out.append(nail(th[2], th[3], 13.5 * 0.62))
    out.append('</g>')
    return out

W, H = 1110, 420
o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="-apple-system, Helvetica, Arial, sans-serif">' % (W, H, W, H)]
o.append('<style>.k{fill:#f2f2f4;stroke:#c8c8cc}.on{fill:#7c4dff;stroke:#5b30d6}.l{font-size:10px;fill:#555;text-anchor:middle}.lon{font-size:11px;fill:#fff;font-weight:600;text-anchor:middle}.t{font-size:15px;font-weight:600;fill:#222}.s{font-size:12.5px;fill:#444}'
         '.hand{opacity:.62}.skin{fill:url(#skin)}.edge{fill:none;stroke:#b9805c;stroke-width:3;stroke-linejoin:round}'
         '.nail{fill:#fbe8dc;stroke:#d9a585;stroke-width:.9}.crease{fill:none;stroke:#c48d6a;stroke-width:1;stroke-linecap:round;opacity:.7}'
         '.knuckle{fill:#fde6d4;opacity:.55}.tendon{stroke:#e6b694;stroke-width:3;stroke-linecap:round;opacity:.45}</style>')
o.append('<defs><filter id="shade" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur in="SourceAlpha" stdDeviation="4" result="b"/><feComposite in="SourceAlpha" in2="b" operator="out" result="rim"/><feFlood flood-color="#b8774f" flood-opacity=".9"/><feComposite in2="rim" operator="in" result="r"/><feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="r"/></feMerge></filter><linearGradient id="skin" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f8d9c0"/><stop offset=".55" stop-color="#f1c4a2"/><stop offset="1" stop-color="#e3a985"/></linearGradient></defs>')
o.append('<rect width="100%" height="100%" fill="#ffffff"/>')
titles = [('`', 'Read aloud: Command-`'), ('1', 'Fix all: Command-1'), ('2', 'Tidy up: Command-2')]
for i, (tg, title) in enumerate(titles):
    ox = 95 + i * 365
    P, t = place(tg)
    k = KEY[tg]
    o.append('<g transform="translate(%d,0)">' % ox)
    o.append('<text x="20" y="28" class="t">%s</text>' % title)
    ks = keys_for(tg)
    o += [l for l in ks if l.startswith('<rect')]
    o.append('<mask id="fade%d" maskUnits="userSpaceOnUse" x="-95" y="0" width="360" height="%d"><rect x="-95" y="0" width="360" height="%d" fill="url(#fadeg)"/></mask>' % (i, H, H))
    o += hand(P, i)
    o += [l for l in ks if l.startswith('<text')]
    o.append('<text x="20" y="%d" class="s">Left thumb on command, index finger on %s</text>' % (H - 52, tg))
    o.append('<circle cx="%.1f" cy="%.1f" r="4" fill="#5b30d6"/><circle cx="%.1f" cy="%.1f" r="4" fill="#5b30d6"/>' % (k.real, k.imag, t.real, t.imag))
    o.append('</g>')
o.insert(4, '<defs><linearGradient id="fadeg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset=".62" stop-color="#fff"/><stop offset=".8" stop-color="#000"/></linearGradient></defs>')
o.append('<text x="%d" y="%d" style="font-size:13px;fill:#555">One hand, no stretch: the left thumb rests on Command and the index finger reaches up to the top row.</text>' % (115, H - 18))
o.append('</svg>')
open(sys.argv[2], 'w').write('\n'.join(o) + '\n')
