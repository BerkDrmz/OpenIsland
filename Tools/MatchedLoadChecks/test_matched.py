"""Synthetic analyzer tests, never OpenIsland CPU/performance evidence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import matched as m


class MatchingChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.a = self.root / "A"; self.a.write_bytes(b"synthetic-A")
        self.b = self.root / "B"; self.b.write_bytes(b"synthetic-B")
        self.strict = self.root / "strict.py"; self.strict.write_bytes(b"unchanged strict fixture")
        self.evidence = self.root / "functional.txt"; self.evidence.write_text("synthetic unit fixture only")
        self.frozen = self.root / "frozen.json"
        m.freeze(Path(__file__).with_name("protocol.json"), self.frozen, "fixture-commit",
                 {"A": self.a, "B": self.b}, [self.strict])
        self.doc = m.read_frozen(self.frozen)
        self.gate = self.root / "gate.json"
        self.gate_doc = {"candidate_commit": "fixture-commit", "candidate_binary_sha256": m.digest(self.b),
                         "checks": {key: {"status": "PASS", "evidence": [{"path": str(self.evidence), "sha256": m.digest(self.evidence)}]}
                                    for key in self.doc["spec"]["functional_requirements"]}}
        self.save_gate()
        self.run = {
            "run_id": "fixture-run",
            "label": "A", "binary_sha256": m.digest(self.a), "start_epoch": self.doc["frozen_at_epoch"] + 10,
            "mode": "cpu", "rate_ms": 80, "selections": 480, "observed_selected": 480,
            "tabs": self.doc["spec"]["tabs"], "playing": False, "camera_idle": True, "audio_routes": 0,
            "unsafe_events": [], "thermal_state": "nominal", "memory_pressure": "normal",
            "wall_seconds": 40, "boundary_lag_seconds": .01,
            "pre_load": self.samples(12), "phase_load": self.samples(40), "post_load": self.samples(12),
            "app_cpu_seconds": .48, "windowserver_cpu_seconds": 4,
            "footprint_bytes": 40_000_000, "wakeups": 48, "environment_fingerprint": "same-observer-power-display-os"
        }
        self.block_index = 0

    def tearDown(self):
        self.tmp.cleanup()

    def save_gate(self):
        self.gate.write_text(json.dumps(self.gate_doc))

    def samples(self, count, **kwargs):
        categories = {key: 0 for key in self.doc["spec"]["categories"]}
        categories.update(other=20, system_analysis=10)
        categories.update(kwargs)
        return [dict(seconds=1, categories=copy.deepcopy(categories), compiler_profiler_cpu=0,
                     unknown_cpu_processes=0) for _ in range(count)]

    def block(self):
        self.block_index += 1
        runs = []
        for index, label in enumerate(["A", "B", "B", "A"]):
            run = copy.deepcopy(self.run)
            run["run_id"] = f"fixture-{self.block_index}-{index}"
            run["start_epoch"] += self.block_index * 1000 + index * 70
            run["label"] = label
            run["binary_sha256"] = self.doc["binary_sha256"][label]
            if label == "B":
                run["app_cpu_seconds"] = .96
            runs.append(run)
        return {"runs": runs}

    def analyze(self, blocks=None):
        return m.analyze({"rate_ms": 80, "mode": "cpu", "attempts": blocks or [self.block(), self.block()]}, self.doc, self.gate)

    def reject_run(self, key, value):
        run = copy.deepcopy(self.run); run[key] = value
        with self.assertRaises(m.Rejected):
            m.checked_run(run, self.doc, 80, "cpu")

    def test_frozen_protocol_is_exclusive(self):
        with self.assertRaises(FileExistsError):
            m.freeze(Path(__file__).with_name("protocol.json"), self.frozen, "x", {"A": self.a, "B": self.b}, [self.strict])

    def test_tampered_envelope_rejected(self):
        x = json.loads(self.frozen.read_text()); x["document"]["spec"]["match_mean_absolute_pp"] = 1000
        self.frozen.write_text(json.dumps(x))
        with self.assertRaises(m.Rejected): m.read_frozen(self.frozen)

    def test_strict_protocol_edit_rejected(self):
        self.strict.write_bytes(b"unexpected threshold edit")
        with self.assertRaises(m.Rejected): m.read_frozen(self.frozen)

    def test_complete_synthetic_block_keeps_metrics_separate(self):
        x = self.analyze()
        self.assertEqual(x["status"], "SECONDARY_MATCHED_OBSERVATION")
        self.assertFalse(x["clean_system_acceptance"])
        self.assertFalse(x["battery_saving_proven"])
        block = x["accepted"][0]
        self.assertEqual(block["A"]["cpu_ms_per_selection"], 1)
        self.assertEqual(block["B"]["cpu_ms_per_selection"], 2)
        self.assertEqual(block["A"]["windowserver_cpu_percent"], 10)

    def test_pending_functional_check_blocks_analysis(self):
        self.gate_doc["checks"]["mixer_real_gain_route"]["status"] = "NOT_TESTED"; self.save_gate()
        with self.assertRaises(m.Rejected): self.analyze()

    def test_incomplete_functional_gate_blocks_job_plan(self):
        self.gate_doc["checks"]["voiceover_fka_panel_bodies"]["status"] = "PARTIAL"; self.save_gate()
        with self.assertRaises(m.Rejected): m.plan(self.doc, self.gate, 80, "cpu")

    def test_job_plan_never_claims_execution(self):
        x = m.plan(self.doc, self.gate, 80, "cpu")
        self.assertEqual(x["status"], "JOBS_ONLY_NOT_EXECUTED")
        self.assertEqual([job["label"] for job in x["jobs_per_attempt"]], ["A", "B", "B", "A"])

    def test_replaying_a_trial_is_rejected(self):
        block = self.block()
        with self.assertRaises(m.Rejected): self.analyze([block, block])

    def test_overlapping_trials_rejected(self):
        block = self.block(); block["runs"][1]["start_epoch"] = block["runs"][0]["start_epoch"]
        self.assertFalse(self.analyze([block])["accepted"])

    def test_missing_environment_fingerprint_rejected(self): self.reject_run("environment_fingerprint", "")

    def test_missing_check_blocks_gate(self):
        del self.gate_doc["checks"]["apple_music_real_controls"]; self.save_gate()
        with self.assertRaises(m.Rejected): self.analyze()

    def test_wrong_binary_gate(self):
        self.gate_doc["candidate_binary_sha256"] = "wrong"; self.save_gate()
        with self.assertRaises(m.Rejected): self.analyze()

    def test_changed_evidence_gate(self):
        self.evidence.write_text("modified")
        with self.assertRaises(m.Rejected): self.analyze()

    def test_pass_without_evidence_rejected(self):
        self.gate_doc["checks"]["focus_actions"]["evidence"] = []; self.save_gate()
        with self.assertRaises(m.Rejected): self.analyze()

    def test_one_block_is_not_repeatable(self):
        self.assertEqual(self.analyze([self.block()])["status"], "INCONCLUSIVE")

    def test_attempt_budget_enforced(self):
        with self.assertRaises(m.Rejected): self.analyze([self.block()] * 4)

    def test_whole_block_not_cherry_picked(self):
        block = self.block(); block["runs"][1]["phase_load"] = self.samples(40, other=90)
        x = self.analyze([block, self.block()])
        self.assertEqual(len(x["accepted"]), 1)
        self.assertEqual(len(x["rejected"]), 1)
        self.assertEqual(x["status"], "INCONCLUSIVE")

    def test_changed_environment(self):
        block = self.block(); block["runs"][2]["environment_fingerprint"] = "different-display"
        x = self.analyze([block])
        self.assertFalse(x["accepted"])

    def test_same_total_different_process_mix_rejected(self):
        block = self.block()
        for i in (1, 2):
            for phase, count in [("pre_load", 12), ("phase_load", 40), ("post_load", 12)]:
                block["runs"][i][phase] = self.samples(count, other=0, system_analysis=30)
        self.assertFalse(self.analyze([block])["accepted"])

    def test_wrong_order(self):
        block = self.block(); block["runs"][2], block["runs"][3] = block["runs"][3], block["runs"][2]
        self.assertFalse(self.analyze([block])["accepted"])

    def test_unmatched_p95_bursts(self):
        block = self.block()
        for i in (1, 2):
            for sample in block["runs"][i]["phase_load"][:3]: sample["categories"]["other"] = 75
        self.assertFalse(self.analyze([block])["accepted"])

    def test_boundary_lag(self): self.reject_run("boundary_lag_seconds", .2)
    def test_media_change(self): self.reject_run("playing", True)
    def test_data_before_freeze(self): self.reject_run("start_epoch", 0)
    def test_skipped_selections(self): self.reject_run("observed_selected", 479)
    def test_thermal_throttling(self): self.reject_run("thermal_state", "serious")
    def test_input_activity(self): self.reject_run("unsafe_events", ["pointer moved"])
    def test_nan_cpu(self): self.reject_run("app_cpu_seconds", float("nan"))
    def test_hardware_started(self): self.reject_run("audio_routes", 1)
    def test_missing_load(self): self.reject_run("phase_load", self.samples(2))

    def test_process_churn(self):
        samples = self.samples(40); samples[4]["unknown_cpu_processes"] = 1
        self.reject_run("phase_load", samples)

    def test_observer_overlap(self):
        samples = self.samples(40); samples[4]["compiler_profiler_cpu"] = 1
        self.reject_run("phase_load", samples)

    def test_frame_pts_not_accepted_as_frame_time(self):
        run = copy.deepcopy(self.run); run["mode"] = "frames"
        run["frame_source"] = "ScreenCaptureKit:PTS"
        run["frame_lifetimes_ms"] = [16] * 480; run["hitch_seconds"] = 0
        with self.assertRaises(m.Rejected): m.checked_run(run, self.doc, 80, "frames")

    def test_cpu_data_not_reused_for_frame_pass(self):
        with self.assertRaises(m.Rejected): m.checked_run(self.run, self.doc, 80, "frames")

    def test_frame_lifetimes_are_a_separate_result(self):
        run = copy.deepcopy(self.run); run.update(mode="frames", frame_source=self.doc["spec"]["frame_source"],
                                                frame_lifetimes_ms=[16, 20] * 240, hitch_seconds=.04)
        x = m.checked_run(run, self.doc, 80, "frames")
        self.assertEqual(x["frame_lifetime_p95_ms"], 20)
        self.assertNotIn("cpu_ms_per_selection", x)


if __name__ == "__main__":
    unittest.main()
