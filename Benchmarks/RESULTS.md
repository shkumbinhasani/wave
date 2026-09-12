# Results — 2026-09-11

This change targets normal terminal use with Git integration disabled.

- **Duplicate rendering loop:** Wave called `ghostty_surface_refresh` from a
  second `CVDisplayLink` on every display refresh. The bundled renderer already
  owns a display link, starts it for changed cells/animations, and stops it when
  idle. Wave now supplies the display ID and lets Ghostty schedule rendering.
- **Hidden surfaces kept rendering:** stopping Wave's display link did not tell
  Ghostty that the tab was hidden. Wave now calls `ghostty_surface_set_occlusion`
  when tab selection or window visibility changes and when a surface detaches.
  Output processing continues while rendering pauses.
- **Wakeup bursts flooded the main queue:** the pending check happened inside
  the dispatched block. A lock-protected coalescer now makes that decision
  before dispatch, and clears its pending flag before delivering the tick so
  wakeups during delivery still schedule another pass.
- **Repeated filesystem work in sidebar grouping:** each tab normalized every
  pin, even when multiple tabs used the same directory. A resolver scoped to
  one grouping pass normalizes each pin and distinct directory once. With Git
  disabled and no pins, it returns the original directory without filesystem
  work. A new pass resolves paths again, so symlink changes are not cached
  indefinitely.

The rendering change follows the exact bundled Ghostty revision's
[display-link scheduling](https://github.com/ghostty-org/ghostty/blob/7b47213f94058c3715205ce8fa73f7ae581a652c/src/renderer/generic.zig#L1151)
and [surface visibility handling](https://github.com/ghostty-org/ghostty/blob/7b47213f94058c3715205ce8fa73f7ae581a652c/src/Surface.zig#L3306).

Measurements and validation are recorded below. See [README.md](README.md) for
workloads, limitations, and reproduction commands, and [results.json](results.json)
for every raw sample.

Machine: Apple M4 Pro; macOS-26.6.2-arm64-arm-64bit-Mach-O. Swift 6.3 in Swift 5 language mode, `-O`,
Ghostty 1.3.2-main-+7b47213f9. Baseline commit:
`06e70765f0a53686db3a84b3a6a7c1ec99048970`.

Five alternating trials per renderer variant, four seconds per scenario after
warmup. Microbenchmarks use 15 alternating trials after warmup. Values below
are medians; all raw samples are retained.

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| Visible idle CPU (% of one core) | 3.89% | 1.07% | 72.6% lower |
| Visible output CPU (% of one core) | 9.83% | 8.60% | 12.5% lower |
| Hidden-tab output CPU (% of one core) | 8.41% | 3.69% | 56.1% lower |
| Group 60 tabs, 12 pins | 8.276 ms | 0.275 ms | 30.1× faster |
| Group 60 tabs, 0 pins | 0.630 ms | 0.001 ms | 60 → 0 path resolutions |
| Coalesce 50,000 wakeups | 6.396 ms | 0.453 ms | 14.1× faster |

The synthetic wakeup burst queues 50,001 blocks before the fix and one after.
Grouping with 12 pins reduces normalization calls per pass from 780 to 24;
with no pins, it reduces them from 60 to zero.

Validation: the Release app build and all 37 XCTest tests passed. All ten
rendering runs passed initial-output, reattachment, and resize checks. The
rendered bitmap was visually inspected. `git diff --check` passed.

The CPU results are for an isolated terminal component with cursor blinking
disabled and fixed-rate output, not the full Wave application. GPU time,
WindowServer CPU, and child-process CPU are excluded. Visible-output results
measure CPU at the supplied rate, not maximum throughput or input latency.
No claim is made about the Git diff checker, which was outside the final scope.
