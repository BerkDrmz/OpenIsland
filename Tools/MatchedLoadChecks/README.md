# Background-matched secondary experiment

This is **not** a revision of the existing quiet-system acceptance benchmark.
The strict runner and its historical results stay unchanged. Freeze their SHA-256
hashes, this specification, the candidate commit and both executable hashes before
collecting new data. Old observations cannot be reclassified as prospective runs.

## Required ordering

1. Finish the candidate's functional acceptance, including real hardware/UI cases.
   A source-only test or AX tree cannot qualify a live hardware/VoiceOver action.
2. Every required check must be `PASS` with unchanged hashed evidence belonging to
   the exact candidate executable. `NOT_TESTED`, partial, skipped, blocked and
   missing evidence keep the measurement gate closed. Do not waive this silently.
3. Execute **A/B/B/A** with 480 real selections in each leg. Primary rate 80 ms;
   650/300/150/50 ms are independent secondary experiments, not pooled together.
   Require two valid complete blocks, with at most three whole-block attempts per
   rate/mode. Stop inconclusive when the budget is exhausted.

## Prospective load rules

The JSON contains the numeric rules; do not tune them after viewing outcomes.
There is no wait-for-quiet retry loop. Observe 12 seconds before and after each
leg and every second during its actual workload. Use CPU-time deltas, not `ps`
smoothed lifetime percentages. Exclude only the exact observed OpenIsland PID,
WindowServer (a separate outcome), and identified own measurement PIDs. Record
observer CPU separately; never credit it to an app optimization.

Classify all other work into agents, browser, Codex UI, system analysis, audio and
other. Keep original process/PID rows, including exits, births and unknown CPU.
Unmeasured churn invalidates a block. Reject active compilers/profilers, agent
bursts over 20% of one core, other-work single bins over 250%, mean over 150%,
thermal throttling, memory pressure, media/input/display/power changes or timing
gaps. Do not stop, suspend, reprioritize or reconfigure another process.

Matching is symmetric across **all four legs**, not chosen after seeing which
leg is favorable: background mean range <= max(5 percentage points, 15% of pooled
mean), P95 range <= max(15 pp, 25%), per-category L1 difference <=25 pp, and
pre/workload/post drift <=10 pp. Reject the **whole** mismatched block; report
all rejected attempts and their reasons. Thresholds are intentionally different
from the strict experiment and confer **lower confidence**, not clean acceptance.

## Outcomes stay separate

- Primary: OpenIsland's real `RUSAGE_SELF` CPU time at existing phase markers,
  CPU milliseconds per 480 completed selections, and CPU/core percent. Never
  subtract another process's CPU or a fitted background estimate from these.
- WindowServer: system-wide CPU time over the same boundaries, separately shown.
  Background matching reduces but cannot eliminate its confounding. It is not
  app-attributed GPU work, power, energy or battery life.
- Frames: separate, identically instrumented A/B/B/A passes with Instruments
  **Frame Lifetimes** and hitch durations, filtered to the exact process and phase.
  Do not combine instrumented CPU with primary uninstrumented CPU. ScreenCaptureKit
  timestamps are capture cadence; CADisplayLink callbacks are not actual frame
  lifetimes. Missing lifetime evidence remains unavailable. Record median/P95 and
  hitches independently; no automatic 16.7 ms threshold for unknown display modes.
- RAM/wakeups: raw same-boundary counters; preserve boundary observation lag.
- GPU/energy: optional matched separate collection only; unavailable is not zero.
  No battery-savings verdict from task CPU accounting or WindowServer alone.

Two valid blocks yield conditional observations, not causal proof, clean-system
acceptance or a production-ready verdict. Show each block's A and B values and
B-minus-A difference; with this small sample, do not invent confidence intervals
or claim general improvements from a tiny difference. Retain all valid blocks,
including regressions. Report CPU, WindowServer and frames even if they disagree.

## Tools

`python3 -m unittest discover -s Tools/MatchedLoadChecks -v`

`matched.py freeze` creates an exclusive hashed envelope. `matched.py gate`
refuses measurement until candidate-specific functional evidence is complete.
`matched.py plan` emits the bounded jobs only after the same gate has passed;
it does not execute them. Freeze also records analyzer/parser implementation
hashes, so changing analysis code after registration invalidates the envelope.
`matched.py analyze` validates the envelope, gate, workload, matching and attempt
budget. All unit-test numbers are **synthetic**, not app performance results.

`frame_export.py` reads the actual Instruments XML schema (including references).
Frame-lifetime rows contain no PID: it joins display + surface + swap IDs to the
process-owned updates table and drops ambiguous or unowned records. Supplying
only the trace launch PID does not establish ownership. It also excludes partial
frames crossing the phase boundaries. Historical exports can validate the parser
but are never prospective experiment results.

The analyzer is deliberately a pure data/gating tool: it does not launch an app,
move input, stop a process or change a system preference. Run collection must be
separately authorized and must preserve the raw process, phase and trace evidence.
No alternate experiment should be launched while its functional gate is closed.
