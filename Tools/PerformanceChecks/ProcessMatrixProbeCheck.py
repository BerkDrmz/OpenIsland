import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('matrix',Path(__file__).resolve().parents[2]/'Scripts/process-matrix-probe.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class Checks(unittest.TestCase):
    def rows(self):
        return [dict(status='available',pid=1,binary='/test',method='ps_TIME',identity=['same'],monotonic=t,cpu_seconds=c,footprint_bytes=None,wakeups=None) for t,c in [(0,100),(20,101)]]
    def test_ps_formats(self):
        self.assertEqual(m.parse_ps_time('169:23.55'),10163.55)
        self.assertEqual(m.parse_ps_time('1-02:03:04.50'),93784.5)
    def test_missing_is_not_zero(self):
        rows=self.rows(); rows[1].update(status='unavailable',cpu_seconds=None)
        self.assertIsNone(m.summarize(rows)['cpu_percent'])
    def test_identity_change(self):
        rows=self.rows(); rows[1]['identity']=['different']
        self.assertEqual(m.summarize(rows)['status'],'N/A')
    def test_counter_reset(self):
        rows=self.rows(); rows[1]['cpu_seconds']=99
        self.assertEqual(m.summarize(rows)['status'],'N/A')
    def test_nonfinite(self):
        rows=self.rows(); rows[1]['cpu_seconds']=float('nan')
        self.assertEqual(m.summarize(rows)['status'],'N/A')
    def test_delta_not_ps_average(self):
        value=m.summarize(self.rows()); self.assertEqual(value['cpu_percent'],5)
        self.assertIsNone(value['package_idle_wakeups'])
if __name__=='__main__': unittest.main()
