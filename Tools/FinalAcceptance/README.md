# Opt-in hardware acceptance

`MixerHardwareCheck.swift` links the actual mixer controller and audio route.
It is not part of application startup or the unit-test suite. It requires an
already running **owned** audio fixture, never an arbitrary user application.

Required environment and arguments:

```
OPENISLAND_ACCEPTANCE_ROOT=/absolute/dedicated/evidence/root
OPENISLAND_DIAGNOSTICS=/absolute/dedicated/evidence/root/runs/check/app.log
mixer-check OWNED_PID /absolute/dedicated/evidence/root/apps/AudioFixture.app/Contents/MacOS/AudioFixture /absolute/dedicated/evidence/root/runs/check
```

The root must contain `.openisland-acceptance`; the output directory must exist.
The executable path is checked against `NSRunningApplication` before changing
gain. Only that source's gain/route is changed. System output volume is not set.
No audio file is created. Core Audio/system-audio authorization may be required;
this check must not grant permissions or automate an authentication dialog.

The test covers gains 0/25/50/75/100%, interruption/recovery, default/current
output routing, simulated *local* sleep/wake notifications, 100 active and 100
empty visibility cycles, and replay of a retired listener after shutdown.
It fails on a synchronous command exceeding one second. Deliberately removing
the callback generation guards must fail the retired-listener check.

This is backend and responsiveness evidence, **not** proof of audible output
RMS, alternate physical-device routing, real sleep/wake, full-app keyboard/AX
acceptance, process CPU savings, or battery energy. JSON status and exit code
both indicate failure. The owner of the fixture must restore/terminate it and
any temporarily closed daily app, including after failure or timeout.
