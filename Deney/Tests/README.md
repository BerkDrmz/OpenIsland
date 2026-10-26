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
- `NativeCapsuleLifecycleCheck.swift`: 100/500/1500 native retargets **per style**, bounded animations, post-settle retirement, foreign-key ownership and weak owner release. Refuses a locked session at startup **and during every phase**. The old retirement assertion was reproduced unlocked: expired client-side animation keys persist until a CA transaction boundary, including in an unrelated CABasicAnimation control. The acceptance check flushes **only in the test**, after waiting for settlement; the product has no idle flush/timer. Keys alone were not evidence of active render work. The long-run foreign sentinel is paused so it cannot expire independently during the test. This is a lifetime contract, not FPS or energy proof.
- `CapsulePresentationProbe.swift`: test-only presentation-layer telemetry at 650/350/300/150/80/50 ms. Also refuses a locked session. Approximate presentation values are not screenshot parity, hardware latency, FPS or energy measurements.

Standalone math/layer tests compile `Deney/Sources/Island/Motion.swift`, `NativeCapsuleMotion.swift`, the test entry point, and the real `IslandCore` module. Supply a test-only `MotionStyle` enum with the same three product cases to avoid pulling unrelated services into the math executable. Never replace the product's enum or use that fixture in an app benchmark.

All full-code tests require **all three** of `OPENISLAND_DIAGNOSTICS` (absolute fixture log path), `OPENISLAND_TEST_DEFAULTS` (suite beginning `io.github.openisland.motion.`), and `OPENISLAND_TEST_SUPPORT` (absolute private fixture path outside the real Application Support directory). `OPENISLAND_PERFORMANCE_SCRIPT` alone does **not** enable redirection. The UI test now refuses missing isolation before constructing any services; this prevents repeating the initial harness mistake. Do not run tests against user notes/preferences. They do not grant privacy permissions, manipulate another application's windows, or qualify real VoiceOver, keyboard, drag-and-drop or media regressions as passed.


## Native completion checks

- `FrameClockLifecycleCheck.swift`: weak shared drivers and weak windowless targets release after 100 closing/hidden windows + 100 windowless drivers without another display callback.
- `FrameClockReopenCheck.swift`: real callbacks continue when an owned cached window reopens mid-animation, then the driver releases. Not an FPS benchmark.
- `CapsuleParameterCheck.swift`: same-target response/damping retarget preserves position and velocity against public SwiftUI.Spring.
- `NativeEditingCommandsCheck.swift`: native window-event routing, undo/redo, existing menu preservation and 100 idempotent command installations. This does not qualify real VoiceOver or physical Cmd-Z as passed.
- Notes' own text view accepts the first explicit click in the nonactivating panel. It does not activate on hover.

Full-app validation identities begin `io.github.openisland.validation.`. They must fail closed before services even if double-clicked **without** fixture environment. Provide the marked, owned `OPENISLAND_TEST_ROOT`, explicit `OPENISLAND_TEST_DEFAULTS`, `OPENISLAND_TEST_SUPPORT` and `OPENISLAND_DIAGNOSTICS` together. All standard-defaults consumers, storage, Shelf cache and Clipboard must be private. Validation bundles neither request nor deliver system notifications; this is test containment, not a credited product performance change. Normal bundle identities retain their original behavior.

Interactive tests must record their executable hash and independently verify readiness, focus and owned hit-test targets. Reject concurrent pointer activity. Do not restore an old foreground app over another user's/agent's newly focused app. A unit/private-board copy test is not permission to touch the user's general clipboard. Hardware/permission tests and tests blocked by environment stay NOT_TESTED.
