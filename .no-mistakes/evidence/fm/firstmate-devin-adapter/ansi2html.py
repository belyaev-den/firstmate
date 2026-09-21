#!/usr/bin/env python3
"""Render tmux capture-pane -e ANSI output into a standalone HTML terminal view."""
import html, re, sys
BASIC = ['#000','#c33','#3c3','#cc3','#36c','#c3c','#3cc','#ccc']
BRIGHT = ['#666','#f66','#6f6','#ff6','#69f','#f6f','#6ff','#fff']
def c256(n):
    if n < 8: return BASIC[n]
    if n < 16: return BRIGHT[n-8]
    if n < 232:
        n -= 16; r, g, b = n//36, (n//6)%6, n%6
        return '#%02x%02x%02x' % tuple(0 if v == 0 else 55+40*v for v in (r,g,b))
    v = 8 + 10*(n-232); return '#%02x%02x%02x' % (v,v,v)
def render(text):
    out = []; fg = bg = None; bold = dim = False
    def style():
        s = []
        if fg: s.append('color:'+fg)
        if bg: s.append('background:'+bg)
        if bold: s.append('font-weight:bold')
        if dim: s.append('opacity:.6')
        return ';'.join(s)
    pos = 0
    for m in re.finditer(r'\x1b\[([0-9;]*)m', text):
        if m.start() > pos:
            seg = html.escape(text[pos:m.start()])
            st = style()
            out.append(f'<span style="{st}">{seg}</span>' if st else seg)
        pos = m.end()
        codes = [int(x) if x else 0 for x in m.group(1).split(';')]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0: fg = bg = None; bold = dim = False
            elif c == 1: bold = True
            elif c == 2: dim = True
            elif c == 22: bold = dim = False
            elif 30 <= c <= 37: fg = BASIC[c-30]
            elif 90 <= c <= 97: fg = BRIGHT[c-90]
            elif 40 <= c <= 47: bg = BASIC[c-40]
            elif c == 39: fg = None
            elif c == 49: bg = None
            elif c in (38, 48) and i+1 < len(codes):
                if codes[i+1] == 5 and i+2 < len(codes):
                    col = c256(codes[i+2]); i += 2
                elif codes[i+1] == 2 and i+4 < len(codes):
                    col = '#%02x%02x%02x' % tuple(codes[i+2:i+5]); i += 4
                else: col = None
                if c == 38: fg = col
                else: bg = col
            i += 1
    seg = html.escape(text[pos:]); st = style()
    out.append(f'<span style="{st}">{seg}</span>' if st else seg)
    return ''.join(out)
def main():
    inputs = sys.argv[2:]; dest = sys.argv[1]
    parts = []
    for path in inputs:
        with open(path, encoding='utf-8', errors='replace') as f: body = render(f.read())
        parts.append(f'<h2>{html.escape(path.rsplit("/",1)[-1])}</h2><pre>{body}</pre>')
    page = ('<!doctype html><meta charset="utf-8"><title>Devin worker pane captures</title>'
            '<style>body{background:#111;color:#ddd;font-family:ui-monospace,Menlo,monospace;padding:16px}'
            'pre{background:#000;color:#eee;padding:12px;border:1px solid #444;width:120ch;overflow-x:auto;line-height:1.2}'
            'h2{font-size:14px;color:#9cf}</style><h1>Devin worker: tmux pane captures (120x40)</h1>' + ''.join(parts))
    with open(dest, 'w', encoding='utf-8') as f: f.write(page)
main()
