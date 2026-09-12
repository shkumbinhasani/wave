#!/usr/bin/env python3
"""Compare terminal hot paths against a Git revision in an isolated host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='HEAD', help='Pre-fix Git revision for TerminalSurfaceView')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--seconds', type=float, default=4)
    parser.add_argument('--output', type=Path, default=ROOT / '.xcodebuild/performance')
    parser.add_argument('--micro-only', action='store_true', help='Skip the AppKit/Metal window benchmark')
    args = parser.parse_args()
    if args.runs < 1 or args.seconds <= 0:
        parser.error('runs and seconds must be positive')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=ROOT, text=True).strip()
    base_source = output / 'TerminalSurfaceView.swift'
    base_source.write_bytes(subprocess.check_output(
        ['git', 'show', f'{baseline}:tgip/Terminal/TerminalSurfaceView.swift'], cwd=ROOT))
    common = ['swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(output / 'module-cache')]

    def compile_program(name, sources, extra=()):
        binary = output / name
        with (output / f'{name}-build.log').open('w') as log:
            subprocess.run(common + list(map(str, sources)) + list(extra) + ['-o', str(binary)],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        return binary

    def run_json(binary, env=None, label=None):
        label = label or binary.name
        print(f'Running {label}', flush=True)
        with (output / f'{label}.log').open('w') as log:
            process = subprocess.run([str(binary)], env=env, cwd=ROOT, text=True,
                                     stdout=subprocess.PIPE, stderr=log, check=True, timeout=120)
        result = json.loads(process.stdout)
        (output / f'{label}.json').write_text(json.dumps(result, indent=2) + '\n')
        return result

    wakeups = compile_program('wakeups', ['tgip/Terminal/CoalescedAction.swift', 'Benchmarks/Wakeups.swift'])
    grouping = compile_program('grouping', ['tgip/GitSupport.swift',
        'tgip/Terminal/DirectoryGroupResolver.swift', 'Benchmarks/Grouping.swift'])
    binaries = {}
    if not args.micro_only:
        framework = ROOT / 'Frameworks/GhosttyKit.xcframework/macos-arm64'
        link = ['-I', str(framework / 'Headers'), str(framework / 'libghostty-internal.a'),
                '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'QuartzCore',
                '-framework', 'Carbon', '-lc++']
        for variant, source in [('before', base_source), ('after', 'tgip/Terminal/TerminalSurfaceView.swift')]:
            binaries[variant] = compile_program(f'render-{variant}', [source,
                'tgip/Terminal/TerminalSearch.swift', 'tgip/Terminal/CoalescedAction.swift',
                'Benchmarks/TerminalRendering.swift'], link)
    # All compilation finishes before timed workloads begin.
    result = {
        'baseline_commit': baseline,
        'machine': platform.platform(),
        'cpu': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
        'swift': subprocess.check_output(['swiftc', '--version'], text=True).strip(),
        'source_sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in [ROOT / 'tgip/Terminal/TerminalSurfaceView.swift',
                                       ROOT / 'tgip/Terminal/CoalescedAction.swift',
                                       ROOT / 'tgip/Terminal/DirectoryGroupResolver.swift']},
        'wakeups': run_json(wakeups),
        'grouping': run_json(grouping),
    }
    if binaries:
        config = output / 'benchmark.config'
        config.write_text('font-family = Menlo\nfont-size = 13\ncursor-style-blink = false\n'
                          'shell-integration = none\nconfirm-close-surface = false\nwindow-vsync = true\n')
        env = os.environ.copy()
        env.update(WAVE_BENCH_CONFIG=str(config), WAVE_BENCH_SECONDS=str(args.seconds),
                   GHOSTTY_RESOURCES_DIR=str(ROOT / 'tgip/Resources'),
                   XDG_STATE_HOME=str(output / 'state'))
        runs = {'before': [], 'after': []}
        for iteration in range(args.runs):
            order = ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']
            for variant in order:
                label = f'render-{variant}-{iteration + 1}'
                env['WAVE_BENCH_SCREENSHOT'] = str(output / f'{label}.png')
                runs[variant].append(run_json(binaries[variant], env, label))
        summary = {}
        for scenario in ['visible_idle', 'visible_output', 'hidden_output']:
            summary[scenario] = {}
            for variant, samples in runs.items():
                values = [next(row['cpu_percent'] for row in sample['samples'] if row['scenario'] == scenario)
                          for sample in samples]
                summary[scenario][variant + '_median_cpu_percent'] = statistics.median(values)
        result['rendering'] = {'seconds_per_scenario': args.seconds, 'runs': runs, 'summary': summary}
    report = output / 'results.json'
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result.get('rendering', {}).get('summary', {}), indent=2))
    print(f'Results: {report}', flush=True)


if __name__ == '__main__':
    main()
