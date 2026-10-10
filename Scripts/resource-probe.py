#!/usr/bin/env python3
"""Read macOS process counters without injecting code into the measured app.

CPU 100% means one core. Peaks are interval averages, not instantaneous peaks.
No extra Python package is required; this is a developer tool, not an app dependency.
"""
import argparse
import ctypes
import json
import math
import subprocess
import time
from pathlib import Path


class RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (key, ctypes.c_uint64)
        for key in (
            "user", "system", "wakeups", "interrupts", "pageins", "wired",
            "resident", "footprint", "start", "exit", "childuser", "childsystem",
            "childwakeups", "childinterrupts", "childpageins", "childelapsed",
            "read", "write",
        )
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not all(math.isfinite(value) and value > 0 for value in (args.seconds, args.interval)):
        parser.error("seconds and interval must be finite and positive")
    pid = args.pid
    if pid is None:
        ids = subprocess.check_output(["pgrep", "-x", "OpenIsland"], text=True).split()
        if len(ids) != 1:
            parser.error("expected one OpenIsland process; pass --pid explicitly")
        pid = int(ids[0])
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    samples = []
    deadline = time.monotonic() + args.seconds
    identity = None
    while True:
        usage = RUsage()
        if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)):
            raise OSError(ctypes.get_errno(), "process counters unavailable")
        current_identity = (usage.start, bytes(usage.uuid))
        if identity is not None and current_identity != identity:
            raise RuntimeError("process identity changed during measurement")
        identity = current_identity
        now = time.monotonic()
        samples.append(dict(epoch=time.time(), monotonic=now,
                            cpu_ns=usage.user + usage.system, footprint=usage.footprint,
                            read=usage.read, write=usage.write, wakeups=usage.wakeups))
        if now >= deadline and len(samples) >= 2:
            break
        time.sleep(max(0, min(args.interval, deadline - now)))
    first, last = samples[0], samples[-1]
    duration = last["monotonic"] - first["monotonic"]
    peaks = [100 * (b["cpu_ns"] - a["cpu_ns"]) / 1e9 / (b["monotonic"] - a["monotonic"])
             for a, b in zip(samples, samples[1:])]
    summary = dict(pid=pid, seconds=round(duration, 2), sample_interval_seconds=args.interval,
                   average_cpu_percent_one_core=round(100 * (last["cpu_ns"] - first["cpu_ns"]) / 1e9 / duration, 4),
                   peak_interval_cpu_percent_one_core=round(max(peaks), 4),
                   physical_footprint_mib=round(last["footprint"] / 1024**2, 2),
                   footprint_growth_mib=round((last["footprint"] - first["footprint"]) / 1024**2, 2),
                   disk_read_bytes=last["read"] - first["read"],
                   disk_write_bytes=last["write"] - first["write"],
                   package_idle_wakeups=last["wakeups"] - first["wakeups"])
    if args.output:
        args.output.write_text(json.dumps(dict(summary=summary, samples=samples), indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
