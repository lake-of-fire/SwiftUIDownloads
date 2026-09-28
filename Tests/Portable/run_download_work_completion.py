#!/usr/bin/env python3
"""Run the exact completion signal/tests; does not compile the native controller."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=('debug', 'release', 'both'), default='both')
    parser.add_argument('--swift', default='swift')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='download-work-completion-') as directory:
        package = Path(directory)
        (package / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DownloadWorkCompletionChecks", targets: [
    .target(name: "SwiftUIDownloads"),
    .testTarget(name: "SwiftUIDownloadsTests", dependencies: ["SwiftUIDownloads"])
], swiftLanguageModes: [.v5])
''')
        for path in ('Sources/SwiftUIDownloads/DownloadWorkCompletion.swift',
                     'Tests/SwiftUIDownloadsTests/DownloadWorkCompletionTests.swift'):
            source = root / path
            target = package / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            print(f'{path} sha256={hashlib.sha256(source.read_bytes()).hexdigest()}', flush=True)
        configurations = ('debug', 'release') if args.configuration == 'both' else (args.configuration,)
        for configuration in configurations:
            subprocess.run([args.swift, 'test', '--package-path', str(package),
                            '--configuration', configuration, '-Xswiftc', '-warnings-as-errors'],
                           check=True, timeout=300)
    print('Completion-signal checks passed. Native controller/Combine integration remains unqualified.')


if __name__ == '__main__':
    main()
