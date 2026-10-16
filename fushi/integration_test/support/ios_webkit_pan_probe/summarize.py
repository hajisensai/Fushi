"""Summarize offsets.log from WebProbeTests: per variant, contentSize and the
x / y contentOffset range seen during each drag step (cross-axis range must be 0)."""
import re
import sys

res = {}
cur = step = None
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.strip()
    if line.startswith('VARIANT'):
        cur = line.split()[1]; res[cur] = {'steps': {}, 'size': None}; step = 'load'; continue
    if line.startswith('STEP'):
        step = line.split()[1]; continue
    if line.startswith('END'):
        step = None; continue
    m = re.search(r'off ([-\d.]+) ([-\d.]+) size ([\d.]+) ([\d.]+) bounds ([\d.]+) ([\d.]+)', line)
    if m and cur and step:
        x, y, cw, ch, bw, bh = map(float, m.groups())
        res[cur]['size'] = (cw, ch, bw, bh)
        res[cur]['steps'].setdefault(step, []).append((x, y))
for k, r in res.items():
    steps = ' '.join(
        '%s:x[%g..%g]y[%g..%g]' % (s, min(p[0] for p in v), max(p[0] for p in v),
                                   min(p[1] for p in v), max(p[1] for p in v))
        for s, v in r['steps'].items() if s != 'load')
    print(k, 'contentSize/bounds=%s' % (r['size'],), steps or '(no scroll at all)')
