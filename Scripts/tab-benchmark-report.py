#!/usr/bin/env python3
"""Summarize a complete controlled tabs run, never infer missing CPU counters.

CPU 100% means one core. Phase getrusage values are seconds, not Mach ticks.
The 650/80 ms cadence and six-tab sequence are the existing diagnostics workload.
"""
import argparse
import json
import math
import re
from pathlib import Path


def summarize(text):
    if 'controlled finished;' not in text or 'FAIL:' in text:
        raise ValueError('incomplete or failed controlled workload')
    result = {}
    for name, selections in [('normal tabs', 18), ('rapid tabs', 30)]:
        phases = []
        for round_number in range(1, 4):
            prefix = re.escape(f'{name} {round_number}')
            starts = re.findall(r'^' + prefix + r' start; epoch=([0-9.]+)$', text, re.M)
            ends = re.findall(r'^' + prefix + r' end; epoch=([0-9.]+); cpu_seconds=([^\s;]+)$', text, re.M)
            if len(starts) != 1 or len(ends) != 1:
                raise ValueError('missing or duplicate phase/counter')
            elapsed = float(ends[0][0]) - float(starts[0])
            cpu = float(ends[0][1])
            if not math.isfinite(elapsed) or elapsed <= 0 or not math.isfinite(cpu) or cpu < 0:
                raise ValueError('invalid elapsed or CPU time')
            phases.append({'wall_seconds': elapsed, 'cpu_seconds': cpu})
        wall = sum(p['wall_seconds'] for p in phases)
        cpu = sum(p['cpu_seconds'] for p in phases)
        result[name] = {'phases': phases, 'selections': selections * 3,
                        'cpu_seconds': cpu, 'wall_seconds': wall,
                        'cpu_mean_percent_one_core': 100 * cpu / wall,
                        'cpu_ms_per_selection': 1000 * cpu / (selections * 3)}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(summarize(args.log.read_text()), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(2, f'Invalid benchmark: {error}\n')
