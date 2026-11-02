#!/usr/bin/env python3
"""Independent process identity and CPU evidence; missing counters are never zero.
Used by developer tests only. WindowServer ps TIME fallback has 10 ms resolution.
"""
import ctypes
import errno
import importlib.util
import math
import subprocess
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location('resource_probe', Path(__file__).with_name('resource-probe.py'))
r = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r)
_lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
_lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
_lib.proc_pid_rusage.restype = ctypes.c_int
_lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
_lib.proc_pidpath.restype = ctypes.c_int
_scale = r.mach_timebase()


def parse_ps_time(value):
    days = 0
    if '-' in value:
        day, value = value.split('-', 1)
        days = int(day)
    parts = value.split(':')
    if len(parts) not in (2, 3):
        raise ValueError('unsupported ps TIME')
    seconds = float(parts[-1]) + int(parts[-2]) * 60
    if len(parts) == 3:
        seconds += int(parts[0]) * 3600
    return seconds + days * 86400


def read(pid, expected_binary=None):
    path = ctypes.create_string_buffer(4096)
    _lib.proc_pidpath(pid, path, len(path))
    binary = path.value.decode()
    if expected_binary and binary != str(Path(expected_binary).resolve()):
        raise RuntimeError(f'PID {pid} binary mismatch: {binary}')
    row = dict(pid=pid, binary=binary, epoch=time.time(), monotonic=time.monotonic())
    u = r.RUsage()
    if _lib.proc_pid_rusage(pid, 2, ctypes.byref(u)) == 0:
        row.update(status='available', method='proc_pid_rusage', cpu_seconds=r.ticks_to_ns(u.user + u.system, *_scale) / 1e9,
                   raw_cpu_ticks=u.user + u.system, timebase_numer=_scale[0], timebase_denom=_scale[1],
                   identity=[u.start, bytes(u.uuid).hex()], footprint_bytes=u.footprint, wakeups=u.wakeups)
    else:
        row.update(status='unavailable', cpu_seconds=None, errno=ctypes.get_errno(), footprint_bytes=None, wakeups=None)
    # Always record an independent cumulative ps counter for cross-checking.
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'time=', '-o', 'lstart=', '-o', 'comm='], capture_output=True, text=True)
    row['ps_raw'] = result.stdout.strip()
    if result.returncode == 0 and row['ps_raw']:
        pieces = row['ps_raw'].split(maxsplit=6)
        try:
            row['ps_cpu_seconds'] = parse_ps_time(pieces[0])
            row['ps_identity'] = ' '.join(pieces[1:6])
            row['ps_resolution_seconds'] = 0.01
            if row['status'] == 'unavailable':
                row.update(status='available', method='ps_TIME', cpu_seconds=row['ps_cpu_seconds'], identity=[row['ps_identity']])
        except (ValueError, IndexError):
            row['ps_cpu_seconds'] = None
    return row


def summarize(rows):
    if len(rows) < 2 or any(x['status'] != 'available' or x['cpu_seconds'] is None for x in rows):
        return dict(status='N/A', cpu_percent=None, reason='missing process counters')
    if any(x['identity'] != rows[0]['identity'] or x['pid'] != rows[0]['pid'] or x['binary'] != rows[0]['binary'] or x['method'] != rows[0]['method'] for x in rows):
        return dict(status='N/A', cpu_percent=None, reason='process identity or counter method changed')
    if any(not math.isfinite(x['cpu_seconds']) or not math.isfinite(x['monotonic']) for x in rows):
        return dict(status='N/A', cpu_percent=None, reason='non-finite counters')
    if any(b['cpu_seconds'] < a['cpu_seconds'] or b['monotonic'] <= a['monotonic'] for a,b in zip(rows,rows[1:])):
        return dict(status='N/A', cpu_percent=None, reason='counter reset or invalid sampling interval')
    a, b = rows[0], rows[-1]
    duration = b['monotonic'] - a['monotonic']
    cpu = b['cpu_seconds'] - a['cpu_seconds']
    if duration <= 0 or cpu < 0:
        return dict(status='N/A', cpu_percent=None, reason='invalid counter interval')
    def delta(key):
        return b[key] - a[key] if a.get(key) is not None and b.get(key) is not None else None
    return dict(status='MEASURED', cpu_percent=100 * cpu / duration, cpu_seconds=cpu, seconds=duration,
                method=a['method'], first_counter=a['cpu_seconds'], last_counter=b['cpu_seconds'],
                counter_resolution_seconds=0.01 if a['method'] == 'ps_TIME' else None,
                footprint_mib=b['footprint_bytes']/1024**2 if b.get('footprint_bytes') is not None else None,
                footprint_delta_bytes=delta('footprint_bytes'), package_idle_wakeups=delta('wakeups'),
                ps_cpu_seconds_delta=delta('ps_cpu_seconds'))
