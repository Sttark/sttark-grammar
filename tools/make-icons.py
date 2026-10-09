"""Makes Resources/MenuIcon.pdf (the Sttark S and a text cursor, for the menu bar) and Resources/AppIcon.icns
(the same on a black rounded square: white S, cursor in Sttark Light Green). The S path is the one in the brand guide.
Run: python3 tools/make-icons.py   (needs Google Chrome to draw the app icon)"""
import os, re, subprocess, tempfile, shutil

S = ("M110.3,84.4c0,11.2-0.5,21.6,0.1,31.9c1.2,22.7,14.8,35,40.4,35.3c42.6,0.6,85.2,0.1,127.8,0.4c13.9,0.1,27.9,0.2,41.6,1.9 "
     "c60.2,7.2,98.4,57.8,89.8,118.2c-8.1,57-47.2,96.3-104.7,98.4c-62.1,2.3-124.3,0.7-186.5-0.9c-15.8-0.4-32-5.8-47-11.7 "
     "C25.1,339.5,9,297,12.5,252h91.2v9.5c0,23.4,11.4,35.7,34.9,36.2c27.7,0.6,55.3,0.2,83,0.2c20.1,0,40.3,0.1,60.4,0 "
     "c29.4-0.1,45.8-27.3,32.2-53.7c-6.9-13.3-19.5-16-32.9-16c-41.9-0.1-83.9,0.4-125.8-0.2c-19.5-0.3-39.4-0.6-58.5-4.4 "
     "c-44.5-8.9-78.1-52.9-78.1-97.5v-114c15.9,0,194.2-0.3,265.1,0.2c15.7,0.1,31.8,3.2,46.8,7.8c39.3,12,62.7,42.9,65.6,83.8 "
     "c0.5,7.3,0.1,14.6,0.1,22.2h-89.8c-0.1-1.3-0.3-2.6-0.3-3.9c-0.3-26.7-11.3-37.6-38.2-37.7c-33.2-0.1-66.4,0-99.6,0 "
     "C149.2,84.4,130,84.4,110.3,84.4")
BOX = (8, 12, 404, 362)          # the S's viewBox: x, y, width, height
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'Resources')

def pdf_ops(d, flip_h):
    """SVG path (M m C c H h V v L l Z z) to PDF drawing operators, y flipped for PDF."""
    toks = re.findall(r'[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?', d)
    ops, i, cmd, x, y, sx, sy = [], 0, None, 0.0, 0.0, 0.0, 0.0
    P = lambda a, b: '%.2f %.2f' % (a - BOX[0], flip_h - (b - BOX[1]))
    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]): cmd = toks[i]; i += 1
        if cmd in 'Zz': ops.append('h'); x, y = sx, sy; continue
        n = {'M': 2, 'L': 2, 'C': 6, 'H': 1, 'V': 1}[cmd.upper()]
        v = [float(t) for t in toks[i:i + n]]; i += n
        rel = cmd.islower()
        if cmd.upper() == 'M':
            x, y = (x + v[0], y + v[1]) if rel else (v[0], v[1]); sx, sy = x, y; ops.append(P(x, y) + ' m'); cmd = 'l' if rel else 'L'
        elif cmd.upper() == 'L':
            x, y = (x + v[0], y + v[1]) if rel else (v[0], v[1]); ops.append(P(x, y) + ' l')
        elif cmd.upper() == 'H':
            x = x + v[0] if rel else v[0]; ops.append(P(x, y) + ' l')
        elif cmd.upper() == 'V':
            y = y + v[0] if rel else v[0]; ops.append(P(x, y) + ' l')
        else:
            pts = [(x + v[k], y + v[k + 1]) if rel else (v[k], v[k + 1]) for k in (0, 2, 4)]
            ops.append(' '.join(P(*p) for p in pts) + ' c'); x, y = pts[2]
    return '\n'.join(ops) + '\nh f\n'

def write_pdf(path, w, h, content):
    objs = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Contents 4 0 R /Resources << >> >>' % (w, h),
            '<< /Length %d >>\nstream\n%s\nendstream' % (len(content), content)]
    out, offs = '%PDF-1.4\n', []
    for k, o in enumerate(objs):
        offs.append(len(out)); out += '%d 0 obj\n%s\nendobj\n' % (k + 1, o)
    x = len(out)
    out += 'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1) + ''.join('%010d 00000 n \n' % o for o in offs)
    out += 'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, x)
    open(path, 'w').write(out)

os.makedirs(RES, exist_ok=True)
# the S, a gap, then a text cursor a little taller than the S, in one box (units: the S's own)
CH = 450                                  # cursor height
CX = BOX[2] + 70 + 62                     # cursor center: S width, gap, half the cursor's width
CW = CX + 62                              # whole width
def cursor_rects(h):                      # stem and the two cross bars, as (x, y, w, h) with y going up
    return [(CX - 17, 0, 34, h), (CX - 62, h - 32, 124, 32), (CX - 62, 0, 124, 32)]
menu = '0 g\nq 1 0 0 1 0 %d cm\n%sQ\n' % ((CH - BOX[3]) // 2, pdf_ops(S, BOX[3]))
menu += ''.join('%d %d %d %d re f\n' % r for r in cursor_rects(CH))
write_pdf(os.path.join(RES, 'MenuIcon.pdf'), CW, CH, menu)

# app icon: Apple's grid puts the rounded square at 824 of 1024, centered
k = 640 / CW                              # fit S and cursor across 640 of the 824 square
ox, oy = 512 - CW * k / 2, 512 - CH * k / 2
bars = ''.join('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>' % (ox + x * k, oy + (CH - y - h) * k, w * k, h * k)
               for x, y, w, h in cursor_rects(CH))
svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
       '<rect x="100" y="100" width="824" height="824" rx="185" fill="#000"/>'
       '<g transform="translate(%.1f %.1f) scale(%.4f) translate(%d %d)"><path fill="#fff" d="%s"/></g>'
       '<g fill="#00A82D">%s</g></svg>' % (ox, oy + (CH - BOX[3]) / 2 * k, k, -BOX[0], -BOX[1], S, bars))
tmp = tempfile.mkdtemp()
open(os.path.join(tmp, 'icon.svg'), 'w').write(svg)
open(os.path.join(tmp, 'icon.html'), 'w').write('<html><body style="margin:0;background:transparent"><img src="icon.svg" width="1024" height="1024"></body></html>')
chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
png = os.path.join(tmp, 'icon.png')
import time
c = subprocess.Popen([chrome, '--headless=new', '--user-data-dir=' + os.path.join(tmp, 'c'), '--hide-scrollbars', '--window-size=1024,1024',
                      '--default-background-color=00000000', '--screenshot=' + png, 'file://' + os.path.join(tmp, 'icon.html')],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):                      # headless Chrome can stay open after the shot, so wait for the file
    if os.path.exists(png) and os.path.getsize(png) > 0: time.sleep(1); break
    time.sleep(0.5)
c.kill()
iconset = os.path.join(tmp, 'AppIcon.iconset'); os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = 'icon_%dx%d%s.png' % (size, size, '@2x' if scale == 2 else '')
        subprocess.run(['sips', '-z', str(px), str(px), png, '--out', os.path.join(iconset, name)], capture_output=True)
subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(RES, 'AppIcon.icns')], check=True)
shutil.rmtree(tmp)
print('wrote Resources/MenuIcon.pdf and Resources/AppIcon.icns')
