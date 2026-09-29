#!/usr/bin/env python3
"""Run whole orphan/staging helpers; does not compile the Apple controller graph."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    inputs = (
        "Sources/SwiftUIDownloads/DownloadStagingPaths.swift",
        "Sources/SwiftUIDownloads/DownloadOrphanCleanup.swift",
        "Tests/SwiftUIDownloadsTests/DownloadOrphanCleanupTests.swift",
    )
    subprocess.run(["swift", "--version"], check=True)
    with tempfile.TemporaryDirectory(prefix="download-orphan-cleanup-") as temporary:
        package = Path(temporary)
        (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DownloadOrphanChecks", targets: [
    .target(name: "SwiftUIDownloads"),
    .testTarget(name: "SwiftUIDownloadsTests", dependencies: ["SwiftUIDownloads"])
])
''', encoding="utf-8")
        for path in inputs:
            content = (root / path).read_bytes()
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            print(hashlib.sha256(content).hexdigest(), path, flush=True)
        configurations = ("debug", "release") if args.configuration == "both" else (args.configuration,)
        for configuration in configurations:
            command = ["swift", "test", "--package-path", str(package), "-c", configuration,
                       "--jobs", "2", "-Xswiftc", "-warnings-as-errors"]
            if shutil.which("xcsift"):
                producer = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                consumer = subprocess.Popen(["xcsift"], stdin=producer.stdout)
                producer.stdout.close()
                consumer_status = consumer.wait()
                producer_status = producer.wait()
                if producer_status or consumer_status:
                    raise SystemExit(producer_status or consumer_status)
            else:
                subprocess.run(command, check=True, timeout=300)
    print("Complete helper tests passed; native controller, Combine and Brotli are not qualified.")


if __name__ == "__main__":
    main()
