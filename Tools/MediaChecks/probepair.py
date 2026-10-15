# usage: python3 -I probepair.py probe.jsonl — her tick'i HEMEN ARDINDAN gelen tick-okumasıyla (aynı an) eşler.
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
pairs, pending = [], None
for r in rows:
    if r['kind'] == 'tick': pending = r
    elif r['kind'] == 'truth' and r.get('why') == 'tick' and pending is not None:
        if 'position' in r and r.get('state') == 'playing' and pending['isPlaying']:
            pairs.append((pending['t'], pending['shownElapsed'] - r['position'], r['position'], pending['shownElapsed']))
        pending = None
d = [p[1] for p in pairs]
print(f"playing ticks={len(d)} median Δ={statistics.median(d):+.2f}s p5={sorted(d)[len(d)//20]:+.2f} p95={sorted(d)[len(d)*19//20]:+.2f}")
big = [p for p in pairs if abs(p[1]) > 3]
print(f"|Δ|>3s: {len(big)}", [(round(p[0]), round(p[1], 1), round(p[2], 1)) for p in big[:6]])
