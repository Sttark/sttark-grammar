"""Draws docs/shortcuts.svg: the left side of a Mac keyboard three times, with a see-through left hand on it.

The hand pictures in docs/hands are real-looking hands made with an image model from a pose guide: thumb on
Command, middle finger resting on the keyboard's left edge, index finger on `, 1 or 2. Each one is already
cut out and color-matched; HANDS holds the matrix that puts its fingertips on the keys.

Run: python3 docs/shortcuts.py
"""
import base64, os

HERE = os.path.dirname(os.path.abspath(__file__))

# x, y, width, height, label; one keyboard, in its own units
KEYS = [(20, 40, 52, 24, 'esc')] + [(75 + 37 * i, 40, 34, 24, 'F%d' % (i + 1)) for i in range(5)] \
     + [(20 + 37 * i, 67, 34, 34, c) for i, c in enumerate('`123456')] \
     + [(20, 104, 52, 34, 'tab')] + [(75 + 37 * i, 104, 34, 34, c) for i, c in enumerate('QWERT')] \
     + [(20, 141, 62, 34, 'caps')] + [(85 + 37 * i, 141, 34, 34, c) for i, c in enumerate('ASDFG')] \
     + [(20, 178, 80, 34, 'shift')] + [(103 + 37 * i, 178, 34, 34, c) for i, c in enumerate('ZXCVB')] \
     + [(20, 215, 34, 34, 'fn'), (57, 215, 38, 34, 'control'), (98, 215, 38, 34, 'option'), (138, 215, 56, 34, 'command'),
        (198, 215, 120, 34, '')]

# image file, then a b c d of the matrix taking image pixels to keyboard units, then where the cropped file sat
HANDS = {
    '`': ('backtick.webp', 0.39631, 0.01756, -116.81402, 42.29915, 50, 0, 952, 899),
    '1': ('one.webp', 0.40148, 0.00747, -117.67273, 22.99364, 55, 0, 916, 938),
    '2': ('two.webp', 0.37884, 0.0196, -122.1959, 36.16824, 66, 0, 958, 955),
}
PANELS = [('`', 'Read aloud', 'Command-`'), ('1', 'Fix all', 'Command-1'), ('2', 'Tidy up', 'Command-2')]
STEP, LEFT, W, H = 385, 95, 1150, 420

o = ['<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d" '
     'viewBox="0 0 %d %d" font-family="-apple-system, Helvetica, Arial, sans-serif">' % (W, H, W, H)]
o.append('<style>.k{fill:#fbfbfc;stroke:#c9c9cf}.kb{fill:#c9c9cf}.on{fill:#7c4dff;stroke:#5b30d6}.onb{fill:#5b30d6}'
         '.l{font-size:10px;fill:#555;text-anchor:middle}.lon{font-size:11px;fill:#fff;font-weight:600;text-anchor:middle}'
         '.t{font-size:15px;font-weight:600;fill:#222}.s{font-size:12.5px;fill:#444}.frame{fill:#e6e6ea;stroke:#cfcfd5}</style>')
o.append('<defs>'
         '<linearGradient id="right" x1="0" y1="0" x2="1" y2="0"><stop offset=".78" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>'
         '<mask id="kbfade" maskUnits="userSpaceOnUse" x="0" y="0" width="275" height="270"><rect x="0" y="0" width="275" height="270" fill="url(#right)"/></mask>'
         '<linearGradient id="down" x1="0" y1="0" x2="0" y2="1"><stop offset=".62" stop-color="#fff"/><stop offset=".8" stop-color="#000"/></linearGradient>'
         '<mask id="handfade" maskUnits="userSpaceOnUse" x="-95" y="0" width="360" height="%d"><rect x="-95" y="0" width="360" height="%d" fill="url(#down)"/></mask>'
         '<linearGradient id="side" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#000"/><stop offset=".16" stop-color="#fff"/></linearGradient>'
         '<mask id="handside" maskUnits="userSpaceOnUse" x="-95" y="0" width="360" height="%d"><rect x="-95" y="0" width="360" height="%d" fill="url(#side)"/></mask>'
         '<clipPath id="board"><rect x="0" y="0" width="275" height="270"/></clipPath>'
         '</defs>' % (H, H, H, H))
o.append('<rect width="100%" height="100%" fill="#ffffff"/>')

for i, (target, name, combo) in enumerate(PANELS):
    on = ('command', target)
    o.append('<g transform="translate(%d,0)">' % (LEFT + i * STEP))
    o.append('<text x="20" y="22" class="t">%s: %s</text>' % (name, combo))
    o.append('<g mask="url(#kbfade)" clip-path="url(#board)">')
    o.append('<rect x="8" y="31" width="320" height="229" rx="12" class="frame"/>')
    for x, y, w, h, lab in KEYS:
        c = 'on' if lab in on else 'k'
        o.append('<rect x="%d" y="%.1f" width="%d" height="%d" rx="5" class="%sb"/>' % (x, y + 1.5, w, h, c))
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="5" class="%s"/>' % (x, y, w, h, c))
    o.append('</g>')
    f, a, b, e, g, x0, y0, cw, ch = HANDS[target]
    data = base64.b64encode(open(os.path.join(HERE, 'hands', f), 'rb').read()).decode()
    o.append('<g mask="url(#handside)"><g mask="url(#handfade)"><g opacity="0.62" transform="matrix(%s %s %s %s %s %s)">' % (a, b, -b, a, e, g))
    o.append('<image x="%d" y="%d" width="%d" height="%d" xlink:href="data:image/webp;base64,%s"/>' % (x0, y0, cw, ch, data))
    o.append('</g></g></g>')
    # labels on top of the hand so every key stays readable
    o.append('<g mask="url(#kbfade)">')
    for x, y, w, h, lab in KEYS:
        if lab:
            o.append('<text x="%.1f" y="%.1f" class="%s">%s</text>' % (x + w / 2, y + h / 2 + 4, 'lon' if lab in on else 'l', lab))
    o.append('</g>')
    o.append('<text x="20" y="%d" class="s">Index finger on %s, thumb on command</text>' % (H - 56, target))
    o.append('</g>')

o.append('<text x="%d" y="%d" style="font-size:13px;fill:#555">The thumb stays on Command and the middle finger rests on the '
         'keyboard\'s left edge. Only the index finger moves.</text>' % (LEFT + 20, H - 20))
o.append('</svg>')
open(os.path.join(HERE, 'shortcuts.svg'), 'w').write('\n'.join(o) + '\n')
