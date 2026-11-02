import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('report', Path(__file__).resolve().parents[2] / 'Scripts/tab-benchmark-report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def fixture():
    lines = []
    for name in ['normal tabs', 'rapid tabs']:
        for n in range(1, 4):
            lines.extend([f'{name} {n} start; epoch=100', f'{name} {n} end; epoch=110; cpu_seconds=2'])
    return '\n'.join(lines + ['controlled finished; mode=tabs'])


class ReportCheck(unittest.TestCase):
    def test_cpu_units_and_selection_counts(self):
        result = report.summarize(fixture())
        self.assertEqual(result['normal tabs']['cpu_mean_percent_one_core'], 20)
        self.assertEqual(result['normal tabs']['selections'], 54)
        self.assertAlmostEqual(result['normal tabs']['cpu_ms_per_selection'], 6000/54)
        self.assertEqual(result['rapid tabs']['selections'], 90)

    def test_rejects_incomplete_or_failed(self):
        for text in [fixture().replace('controlled finished;', ''), fixture() + '\nFAIL: wrong tab']:
            with self.assertRaises(ValueError): report.summarize(text)

    def test_rejects_missing_and_duplicate(self):
        for text in [fixture().replace('; cpu_seconds=2', ''), fixture() + '\nnormal tabs 1 start; epoch=100']:
            with self.assertRaises(ValueError): report.summarize(text)

    def test_rejects_invalid_counters(self):
        for counter in ['unavailable', 'nan', 'inf', '-1']:
            with self.assertRaises(ValueError): report.summarize(fixture().replace('cpu_seconds=2', 'cpu_seconds=' + counter))

    def test_rejects_nonpositive_time(self):
        with self.assertRaises(ValueError): report.summarize(fixture().replace('epoch=110', 'epoch=99'))


if __name__ == '__main__': unittest.main(verbosity=2)
