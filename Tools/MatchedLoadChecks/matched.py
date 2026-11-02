"""Prospective, lower-confidence load matching; no UI or process control.

All thresholds come from the frozen protocol. This module never calls the strict
runner, changes a setting, launches an app, signals a process, or fits a correction
that subtracts background work from the application's real CPU time.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import time


class Rejected(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def number(value, name):
    require(isinstance(value, (int, float)) and not isinstance(value, bool), name)
    require(math.isfinite(value) and value >= 0, name)
    return float(value)


def percentile(values, fraction=.95):
    require(bool(values), "no samples")
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def freeze(spec_path, destination, candidate_commit, binaries, strict_paths):
    """Exclusive creation, before collecting a run; preserve strict file hashes."""
    spec = json.loads(Path(spec_path).read_text())
    require(spec["order"] == ["A", "B", "B", "A"], "not ABBA")
    require(set(binaries) == {"A", "B"}, "two identified binaries required")
    doc = {
        "frozen_at_epoch": time.time(), "spec": spec,
        "candidate_commit": candidate_commit,
        "binary_sha256": {key: digest(path) for key, path in binaries.items()},
        "strict_files": {str(Path(p).resolve()): digest(p) for p in strict_paths},
        "implementation_files": {str(p.resolve()): digest(p) for p in
                                 [Path(__file__), Path(__file__).with_name("frame_export.py")]},
    }
    # The envelope hash includes the freeze timestamp, binaries and strict refs.
    encoded = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
    envelope = {"sha256": hashlib.sha256(encoded).hexdigest(), "document": doc}
    with Path(destination).open("x") as stream:
        json.dump(envelope, stream, indent=2)
    return envelope


def read_frozen(path):
    envelope = json.loads(Path(path).read_text())
    doc = envelope["document"]
    encoded = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
    require(hashlib.sha256(encoded).hexdigest() == envelope["sha256"], "protocol altered after freeze")
    for path, expected in doc["strict_files"].items():
        require(digest(path) == expected, "strict protocol was modified")
    for path, expected in doc.get("implementation_files", {}).items():
        require(digest(path) == expected, "analysis implementation changed after freeze")
    return doc


def functional_gate(doc, gate_path):
    gate = json.loads(Path(gate_path).read_text())
    require(gate.get("candidate_commit") == doc["candidate_commit"], "functional tests belong to another source")
    require(gate.get("candidate_binary_sha256") == doc["binary_sha256"]["B"], "functional tests belong to another binary")
    checks = gate.get("checks", {})
    pending = [key for key in doc["spec"]["functional_requirements"]
               if checks.get(key, {}).get("status") != "PASS"]
    require(not pending, "functional acceptance incomplete: " + ", ".join(pending))
    for key in doc["spec"]["functional_requirements"]:
        evidence = checks[key].get("evidence", [])
        require(bool(evidence), "PASS without evidence: " + key)
        for item in evidence:
            require(digest(item["path"]) == item["sha256"], "changed functional evidence: " + key)
    return gate


def load_summary(samples, seconds, spec):
    require(len(samples) >= 2, "insufficient load samples")
    durations = [number(x["seconds"], "sample duration") for x in samples]
    require(all(0 < dt <= spec["maximum_sample_gap_seconds"] for dt in durations), "load sample gap")
    covered = sum(durations)
    require(spec["minimum_coverage"] * seconds <= covered <= seconds + spec["maximum_sample_gap_seconds"], "load coverage")
    totals, agents = [], []
    weighted = dict.fromkeys(spec["categories"], 0.0)
    for sample, dt in zip(samples, durations):
        require(set(sample["categories"]) == set(weighted), "inconsistent process classes")
        values = {key: number(value, key) for key, value in sample["categories"].items()}
        total = sum(values.values())
        require(total <= spec["maximum_other_bin_cpu"], "extreme background burst")
        require(number(sample["compiler_profiler_cpu"], "compiler/profiler") <= spec["maximum_compiler_profiler_bin_cpu"], "compiler/profiler overlap")
        require(values["agents"] <= spec["maximum_agent_bin_cpu"], "active agent overlap")
        require(sample.get("unknown_cpu_processes") == 0, "unmeasured process churn")
        for key in weighted:
            weighted[key] += values[key] * dt
        totals.append(total)
        agents.append(values["agents"])
    categories = {key: value / covered for key, value in weighted.items()}
    mean = sum(categories.values())
    require(mean <= spec["maximum_other_mean_cpu"], "sustained background saturation")
    return {"mean": mean, "p95": percentile(totals), "categories": categories,
            "covered_seconds": covered, "bins": len(samples)}


def checked_run(run, doc, rate_ms, mode):
    spec = doc["spec"]
    label = run["label"]
    require(label in ["A", "B"], "unknown label")
    require(run["binary_sha256"] == doc["binary_sha256"][label], "wrong executable")
    require(run["start_epoch"] > doc["frozen_at_epoch"], "data predates prospective freeze")
    require(isinstance(run.get("run_id"), str) and bool(run["run_id"]), "run identity missing")
    require(isinstance(run.get("environment_fingerprint"), str) and len(run["environment_fingerprint"]) >= 16,
            "missing environment/observer fingerprint")
    require(run.get("mode") == mode, "CPU and frame instrumentation mixed")
    require(run.get("rate_ms") == rate_ms, "speed changed")
    require(run.get("selections") == spec["selections"], "incomplete selection count")
    require(run.get("observed_selected") == spec["selections"], "missing actual selected views")
    require(run.get("tabs") == spec["tabs"], "UI workload changed")
    require(run.get("playing") is False, "media state differs from paused cohort")
    require(run.get("camera_idle") is True and run.get("audio_routes") == 0, "unexpected hardware activity")
    require(not run.get("unsafe_events"), "input/lock/display/process identity change")
    require(run.get("thermal_state") in ["nominal", "fair"], "thermal throttling")
    require(run.get("memory_pressure") == "normal", "memory pressure changed")
    wall = number(run["wall_seconds"], "wall time")
    require(wall >= spec["selections"] * rate_ms / 1000 * .98, "selections compressed or skipped")
    require(number(run["boundary_lag_seconds"], "boundary lag") <= spec["maximum_boundary_lag_seconds"], "counter boundary lag")
    pre = load_summary(run["pre_load"], spec["pre_seconds"], spec)
    phase = load_summary(run["phase_load"], wall, spec)
    post = load_summary(run["post_load"], spec["post_seconds"], spec)
    means = [x["mean"] for x in [pre, phase, post]]
    require(max(means) - min(means) <= spec["match_within_run_drift_pp"], "within-run load drift")
    result = {"label": label, "load": phase, "wall_seconds": wall}
    if mode == "cpu":
        cpu = number(run["app_cpu_seconds"], "real process CPU")
        result.update(cpu_ms_per_selection=cpu * 1000 / spec["selections"],
                      app_cpu_percent=100 * cpu / wall,
                      windowserver_cpu_percent=100 * number(run["windowserver_cpu_seconds"], "WindowServer CPU") / wall,
                      footprint_bytes=number(run["footprint_bytes"], "footprint"),
                      wakeups_per_selection=number(run["wakeups"], "wakeups") / spec["selections"])
    else:
        require(run.get("frame_source") == spec["frame_source"], "capture PTS/callback intervals are not frame lifetimes")
        lifetimes = run.get("frame_lifetimes_ms")
        require(lifetimes and len(lifetimes) >= spec["selections"], "missing frame lifetime evidence")
        lifetimes = [number(x, "frame lifetime") for x in lifetimes]
        result.update(frame_lifetime_median_ms=statistics.median(lifetimes),
                      frame_lifetime_p95_ms=percentile(lifetimes),
                      hitch_seconds=number(run["hitch_seconds"], "hitches"))
    return result


def block_result(block, doc, rate_ms, mode):
    require(len(block["runs"]) == 4, "incomplete ABBA block")
    require([x["label"] for x in block["runs"]] == doc["spec"]["order"], "wrong order")
    require(len({x["environment_fingerprint"] for x in block["runs"]}) == 1,
            "power/display/refresh/observer/OS fingerprint mismatch")
    for left, right in zip(block["runs"], block["runs"][1:]):
        require(right["start_epoch"] >= left["start_epoch"] + left["wall_seconds"],
                "overlapping or out-of-order trials")
    runs = [checked_run(run, doc, rate_ms, mode) for run in block["runs"]]
    spec = doc["spec"]
    means = [x["load"]["mean"] for x in runs]
    p95s = [x["load"]["p95"] for x in runs]
    mean_tolerance = max(spec["match_mean_absolute_pp"], spec["match_mean_relative"] * statistics.mean(means))
    p95_tolerance = max(spec["match_p95_absolute_pp"], spec["match_p95_relative"] * statistics.mean(p95s))
    require(max(means) - min(means) <= mean_tolerance, "unmatched background means")
    require(max(p95s) - min(p95s) <= p95_tolerance, "unmatched background bursts")
    for a in runs:
        for b in runs:
            distance = sum(abs(a["load"]["categories"][key] - b["load"]["categories"][key]) for key in spec["categories"])
            require(distance <= spec["match_category_l1_pp"], "different background process mix")
    keys = (["cpu_ms_per_selection", "app_cpu_percent", "windowserver_cpu_percent", "footprint_bytes", "wakeups_per_selection"]
            if mode == "cpu" else ["frame_lifetime_median_ms", "frame_lifetime_p95_ms", "hitch_seconds"])
    a = {key: statistics.mean([runs[0][key], runs[3][key]]) for key in keys}
    b = {key: statistics.mean([runs[1][key], runs[2][key]]) for key in keys}
    return {"status": "MATCHED_SECONDARY_BLOCK", "runs": runs, "A": a, "B": b,
            "B_minus_A": {key: b[key] - a[key] for key in keys}}


def analyze(dataset, doc, gate_path):
    functional_gate(doc, gate_path)  # Do not bypass the user's required sequence.
    spec = doc["spec"]
    rate = dataset["rate_ms"]
    require(rate in [spec["primary_rate_ms"]] + spec["secondary_rates_ms"], "unregistered rate")
    mode = dataset["mode"]
    require(mode in ["cpu", "frames"], "unknown observation mode")
    blocks = dataset["attempts"]
    require(len(blocks) <= spec["maximum_block_attempts"], "attempt budget exceeded")
    run_ids = [run.get("run_id") for block in blocks for run in block.get("runs", [])]
    require(len(run_ids) == len(set(run_ids)), "trial reused across attempts")
    accepted, rejected = [], []
    for index, block in enumerate(blocks):
        try:
            accepted.append(block_result(block, doc, rate, mode))
        except (Rejected, KeyError, TypeError) as error:
            rejected.append({"index": index, "reason": str(error)})
    enough = len(accepted) >= spec["required_valid_blocks"]
    return {
        "status": "SECONDARY_MATCHED_OBSERVATION" if enough else "INCONCLUSIVE",
        "confidence": spec["confidence"], "mode": mode, "rate_ms": rate,
        "accepted": accepted, "rejected": rejected,
        "clean_system_acceptance": False, "battery_saving_proven": False,
        "warning": "Conditional matched association, not clean-system causal proof. CPU, system-wide WindowServer and instrumented frame lifetimes remain separate."
    }


def plan(doc, gate_path, rate_ms, mode):
    """Produce jobs only after acceptance. Never launch apps or manipulate input."""
    functional_gate(doc, gate_path)
    spec = doc["spec"]
    require(rate_ms in [spec["primary_rate_ms"]] + spec["secondary_rates_ms"], "unregistered rate")
    require(mode in ["cpu", "frames"], "unknown observation mode")
    return {"status": "JOBS_ONLY_NOT_EXECUTED", "confidence": spec["confidence"],
            "mode": mode, "rate_ms": rate_ms, "maximum_attempts": spec["maximum_block_attempts"],
            "required_valid_blocks": spec["required_valid_blocks"],
            "jobs_per_attempt": [{"ordinal": index + 1, "label": label,
                                  "binary_sha256": doc["binary_sha256"][label],
                                  "pre_seconds": spec["pre_seconds"], "post_seconds": spec["post_seconds"],
                                  "selections": spec["selections"], "tabs": spec["tabs"]}
                                 for index, label in enumerate(spec["order"])]}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    f = sub.add_parser("freeze")
    f.add_argument("--spec", required=True); f.add_argument("--out", required=True)
    f.add_argument("--commit", required=True); f.add_argument("--a", required=True); f.add_argument("--b", required=True)
    f.add_argument("--strict", nargs="+", required=True)
    g = sub.add_parser("gate")
    g.add_argument("--protocol", required=True); g.add_argument("--functional", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--protocol", required=True); p.add_argument("--functional", required=True)
    p.add_argument("--rate-ms", type=int, required=True); p.add_argument("--mode", choices=["cpu", "frames"], required=True)
    a = sub.add_parser("analyze")
    a.add_argument("--protocol", required=True); a.add_argument("--functional", required=True)
    a.add_argument("--data", required=True); a.add_argument("--out", required=True)
    args = ap.parse_args()
    try:
        if args.command == "freeze":
            print(freeze(args.spec, args.out, args.commit, {"A": args.a, "B": args.b}, args.strict)["sha256"])
        else:
            doc = read_frozen(args.protocol)
            if args.command == "gate":
                functional_gate(doc, args.functional)
                print("FUNCTIONAL_GATE_PASSED; secondary collector may be scheduled")
            elif args.command == "plan":
                print(json.dumps(plan(doc, args.functional, args.rate_ms, args.mode), indent=2))
            else:
                result = analyze(json.loads(Path(args.data).read_text()), doc, args.functional)
                with Path(args.out).open("x") as stream:
                    json.dump(result, stream, indent=2)
                print(result["status"])
    except (Rejected, KeyError, TypeError) as error:
        ap.exit(2, "REFUSED: " + str(error) + "\n")


if __name__ == "__main__":
    main()
