#!/usr/bin/env python3
"""Developer-only regression for Apple Silicon CPU-counter units."""
import ctypes
import importlib.util
import os
from pathlib import Path
import resource
import sys
import time
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("resource_probe", root / "Scripts/resource-probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ResourceProbeCheck(unittest.TestCase):
    def test_intel_timebase(self):
        self.assertEqual(probe.ticks_to_ns(1_000_000_000, 1, 1), 1_000_000_000)

    def test_arm_timebase(self):
        self.assertEqual(probe.ticks_to_ns(24_000_000, 125, 3), 1_000_000_000)

    def test_large_counter_does_not_overflow_or_round_as_float(self):
        ticks = 2**63 + 1000
        self.assertEqual(probe.ticks_to_ns(ticks, 125, 3), ticks * 125 // 3)

    @unittest.skipUnless(sys.platform == "darwin", "live process counters require macOS")
    def test_matches_independent_getrusage_cpu_time(self):
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        lib.proc_pid_rusage.restype = ctypes.c_int
        numer, denom = probe.mach_timebase()
        def read():
            usage = probe.RUsage()
            self.assertEqual(lib.proc_pid_rusage(os.getpid(), 2, ctypes.byref(usage)), 0)
            reference = resource.getrusage(resource.RUSAGE_SELF)
            return usage.user + usage.system, reference.ru_utime + reference.ru_stime
        first = read()
        deadline = time.monotonic() + 0.2
        while time.monotonic() < deadline:
            pass
        last = read()
        seconds = probe.ticks_to_ns(last[0] - first[0], numer, denom) / 1e9
        self.assertAlmostEqual(seconds, last[1] - first[1], delta=0.01)


if __name__ == "__main__":
    unittest.main(verbosity=2)
