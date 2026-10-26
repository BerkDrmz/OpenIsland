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
