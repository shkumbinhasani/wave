# Performance benchmarks

Run from the repository root on an Apple Silicon Mac with Xcode and the bundled
GhosttyKit framework available:

```sh
python3 Benchmarks/run.py --baseline 06e70765f0a53686db3a84b3a6a7c1ec99048970
```

The runner compiles optimized Swift executables, then runs all measurements
sequentially. It writes raw samples, build logs, screenshots, and `results.json`
under `.xcodebuild/performance/`. Use `--output PATH` to keep another run,
`--runs N --seconds N` to change the rendering trial count/duration, or
`--micro-only` to skip the window benchmark. The default baseline is `HEAD`;
use the explicit pre-fix revision above when reproducing these results after
committing the changes.

The rendering benchmark needs access to the macOS window server and opens a
small temporary window. Keep that window visible during measurements. It
compiles the actual `TerminalSurfaceView.swift` from the baseline revision and
from the working tree into separate executables. Both use the same isolated
host, optimized Ghostty framework, fixed Menlo font, disabled cursor blinking,
and `window-vsync = true`. The host runs `/bin/cat` through Ghostty with no user
config, tmux, agent hooks, or shell startup scripts. Git and the rest of Wave's
UI are absent. Existing terminal sessions are not used.

Rendering trials alternate before/after order. Each process warms up its surface
and measures visible idle, visible output, and detached-tab output. Output is
fed at 30 batches/second, 768 bytes per batch (23,040 bytes/second); the JSON
records actual bytes and elapsed time. CPU is user + system time from
`getrusage(RUSAGE_SELF)`, expressed as a percentage of one core. It includes the
isolated host and Ghostty threads; it excludes the child process, WindowServer,
and GPU time. These are component measurements, not whole-app CPU guarantees
or maximum-throughput benchmarks.

Every rendering trial verifies terminal text before output, after reattachment,
and after resize. It also saves the final rendered bitmap for visual inspection.
The host uses the new wakeup coalescer for both variants to isolate the renderer
change. The wakeup benchmark below measures that change separately.

`Wakeups.swift` compares the original two-stage dispatch callback with the
production `CoalescedAction`, using a gated serial queue to represent a busy main
queue. It times enqueuing and delivering a burst of 50,000 wakeups over 15
alternating trials after warmup. The old callback is preserved in the benchmark;
this is a synthetic burst test, not a measurement of normal terminal event rates.

`Grouping.swift` compares the original Git-disabled grouping algorithm with the
production `DirectoryGroupResolver`. It uses 60 tabs across 12 real temporary
directories, with either 12 pins or no pins. Each of 15 alternating trials
creates a fresh resolver and includes path normalization and result creation;
there is no cache shared between trials. Both paths must return identical groups.
The fixture directory is removed afterwards.

Regression tests are included in the existing test target:

```sh
xcodegen generate
xcodebuild -project wave.xcodeproj -scheme wave -configuration Release \
  -derivedDataPath .xcodebuild -disableAutomaticPackageResolution \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test
```

The additional tests cover concurrent wakeup bursts, wakeups during delivery,
owner release, nested pins, path-component boundaries, normalized repository
lookups, duplicate working directories, the Git-disabled fast path, and a
symlink retargeted between grouping passes.
