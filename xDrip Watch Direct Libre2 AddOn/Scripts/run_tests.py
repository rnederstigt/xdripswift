#!/usr/bin/env python3
"""Run shared unit tests and four groups of host checks; optionally build both apps.

Examples:
    python3 run_tests.py
    python3 run_tests.py switching sync
    python3 run_tests.py --build
    python3 run_tests.py --ios-destination 'platform=iOS Simulator,id=...'

Full builds use the real project and SDKs, without source or asset substitutions.
Platform doubles test app policy, not radios, OS delivery or real Core Data storage.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback

sys.dont_write_bytecode = True
from test_support import ADDON, REPO, test_directory
import check_switching
import check_sync
import check_watch_support
import check_integration

GROUPS = {
    'switching': [check_switching.phone_handoff, check_switching.watch_handoff,
                  check_switching.watch_reconnect],
    'sync': [check_sync.history_delivery, check_sync.phone_import_routing],
    'watch-support': [check_watch_support.watch_preferences, check_watch_support.watch_background_tasks,
                      check_watch_support.watch_location, check_watch_support.watch_notification],
    'integration': [check_integration.integration, check_integration.upstream_scanning,
                    check_integration.upstream_relay, check_integration.phone_alignment],
}


def shared_tests(disable_sandbox=False):
    with test_directory('libre-shared-') as work:
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'modules'),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(work / 'modules'))
        subprocess.run(['xcrun', 'swift', 'test', *(['--disable-sandbox'] if disable_sandbox else []),
                        '--package-path', str(ADDON),
                        '--scratch-path', str(work / 'build'), '--cache-path', str(work / 'cache')],
                       env=env, check=True)


def xcode_check(scheme, destination, action, output):
    # All build settings point outside the checkout, including projects with custom
    # SYMROOT/OBJROOT settings. Preserve real resource compilation and linked targets.
    with test_directory('libre-xcode-') as work:
        log = output / (scheme.replace(' ', '-') + '-' + action + '.log')
        command = ['xcodebuild', '-project', str(REPO / 'xdrip.xcodeproj'),
                   '-scheme', scheme, '-configuration', 'Debug', '-destination', destination,
                   '-derivedDataPath', str(work / 'DerivedData'),
                   '-onlyUsePackageVersionsFromResolvedFile',
                   'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
                   'SYMROOT=' + str(work / 'Products'), 'OBJROOT=' + str(work / 'Intermediates'), action]
        print(f'Full Xcode {action}: {scheme}. Log: {log}', flush=True)
        with log.open('w') as stream:
            subprocess.run(command, cwd=REPO, stdout=stream, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('groups', nargs='*', metavar='GROUP',
                        help='core, switching, sync, watch-support, integration (default: all)')
    parser.add_argument('--disable-package-sandbox', action='store_true',
                        help='disable nested SwiftPM sandbox only when an outer sandbox prevents it')
    parser.add_argument('--build', action='store_true', help='also run unsigned iPhone and Watch device builds')
    parser.add_argument('--ios-destination', help='also execute hosted Core Data tests at this Xcode destination')
    parser.add_argument('--output', type=Path, help='Xcode log directory outside the repository (default: temporary directory)')
    args = parser.parse_args()
    selected = args.groups or ['core', *GROUPS]
    if set(selected) - {'core', *GROUPS}:
        parser.error('unknown group: ' + ', '.join(sorted(set(selected) - {'core', *GROUPS})))
    output = args.output
    if args.build or args.ios_destination:
        output = (output or Path(tempfile.mkdtemp(prefix='libre-build-logs-'))).resolve()
        if output == REPO or REPO in output.parents:
            parser.error('--output must be outside the repository')
        output.mkdir(parents=True, exist_ok=True)
    checks = []
    for group in dict.fromkeys(selected):
        if group == 'core':
            checks.append(('core/shared_tests', lambda: shared_tests(args.disable_package_sandbox)))
        else:
            checks.extend((group + '/' + check.__name__, check) for check in GROUPS[group])
    if args.build:
        for scheme, platform in [('xdrip', 'iOS'), ('xDrip Watch App', 'watchOS')]:
            checks.append(('build/' + platform, lambda s=scheme, p=platform:
                           xcode_check(s, 'generic/platform=' + p, 'build', output)))
    if args.ios_destination:
        checks.append(('hosted/CoreData', lambda: xcode_check('xdrip', args.ios_destination, 'test', output)))
    failed = []
    for name, check in checks:
        print('\nRUN ' + name, flush=True)
        try:
            check()
        except Exception:
            failed.append(name)
            traceback.print_exc()
        print(('FAIL ' if name in failed else 'PASS ') + name, flush=True)
    print(f'\n{len(checks) - len(failed)}/{len(checks)} checks passed.', flush=True)
    if failed:
        print('Failed: ' + ', '.join(failed), flush=True)
    if not args.build:
        print('Full iPhone/Watch builds not run (use --build).')
    if not args.ios_destination:
        print('Hosted Core Data tests not run (use --ios-destination).')
    return int(bool(failed))


if __name__ == '__main__':
    sys.exit(main())
