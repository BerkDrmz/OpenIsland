# AppKit efficiency regression checks

Run from the project with Xcode selected:

```sh
python3 Deney/Tests/run-efficiency-checks.py
```

- **Nook visibility:** compiles the exact `NookPanelView` lifecycle/layout source with service spies. Exercises dormant layout, visible/hidden/reopened state, 100 hidden layout passes and widget visibility changes. It does not access reminders, user data or permissions. The panel is attached to a window that is never displayed. This is not a full UI/AX/VoiceOver test.
- **Storage lifecycle:** compiles the actual `SystemMonitor` and storage sources. Injected blocking I/O verifies cancellation reaches a detached reader on close/replacement/reopen, retired completions do not publish, and volume observers are released. A Foundation query already in progress cannot be force-interrupted; cancellation stops later queries.

Optional read-only metadata A/B/B/A benchmark:

```sh
python3 Deney/Tests/run-efficiency-checks.py --metadata-bench
```

This compiles the original `64f06a9` storage reader and candidate reader in one process. It checks volume identity/order/name/total/internal flags and capacity bounds, then runs three A/B/B/A blocks of eight reads per run. Available byte values can change naturally between reads. The numbers apply **only to storage metadata reads**, not tab switching, GPU, WindowServer, idle power or battery life. Avoid running concurrent compilers/profilers during a measured comparison.

These tests do not replace the existing Swift core tests or live nine-panel, media, drag-and-drop, keyboard/VoiceOver and animation regression checks.

## Motion experiment checks (not production performance claims)

- `CapsuleMotionCheck.swift`: exact source scalar/additive response and native layer configuration checks across six rates and three styles. No user input or permissions.
- `SwiftUISpringReferenceCheck.swift`: compares the actual native impulse mathematics with Apple's public `SwiftUI.Spring.update` oracle (position **and** velocity). This does not compare SwiftUI view transactions, spring response blending, rasterized frames or matched-geometry rendering.
- `OffscreenUIContract.swift` + `build-ui-contract.sh OUT`: builds the real AppKit source with a separate test entry point. All nine header controls, selected/AX metadata, tooltips, native hit regions, repeated fade retargets and System ownership are tested without displaying its window. `OPENISLAND_UI_OWNERSHIP_ONLY=1` is a **test-fixture-only** switch for running the identical ownership reproduction against archived old source. It does not alter application behavior.
- `NativeCapsuleLifecycleCheck.swift`: 100 real native retargets per style at 50 ms, bounded in-flight animations, retirement and weak owner release. Requires an unlocked session; returns `NOT_TESTED`/exit 3 otherwise. A preliminary **locked** diagnostic failed three retirement assertions. Its cause (session, test/commit handling, or product) is unresolved: do not silently dismiss it or call it a pass. Unlocked retirement verification is a release blocker.
- `CapsulePresentationProbe.swift`: test-only presentation-layer telemetry at 650/350/300/150/80/50 ms. Also refuses a locked session. Approximate presentation values are not screenshot parity, hardware latency, FPS or energy measurements.

Standalone math/layer tests compile `Deney/Sources/Island/Motion.swift`, `NativeCapsuleMotion.swift`, the test entry point, and the real `IslandCore` module. Supply a test-only `MotionStyle` enum with the same three product cases to avoid pulling unrelated services into the math executable. Never replace the product's enum or use that fixture in an app benchmark.

All full-code tests require **all three** of `OPENISLAND_DIAGNOSTICS` (absolute fixture log path), `OPENISLAND_TEST_DEFAULTS` (suite beginning `io.github.openisland.motion.`), and `OPENISLAND_TEST_SUPPORT` (absolute private fixture path outside the real Application Support directory). `OPENISLAND_PERFORMANCE_SCRIPT` alone does **not** enable redirection. The UI test now refuses missing isolation before constructing any services; this prevents repeating the initial harness mistake. Do not run tests against user notes/preferences. They do not grant privacy permissions, manipulate another application's windows, or qualify real VoiceOver, keyboard, drag-and-drop or media regressions as passed.
