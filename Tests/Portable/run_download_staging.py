#!/usr/bin/env python3
"""Run complete Foundation staging/cleanup sources, not the Apple download graph."""
import hashlib
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
inputs = {
    "Sources/SwiftUIDownloads/DownloadStagingPaths.swift": "Sources/SwiftUIDownloads/DownloadStagingPaths.swift",
    "Tests/SwiftUIDownloadsTests/DownloadStagingPathsTests.swift": "Tests/SwiftUIDownloadsTests/DownloadStagingPathsTests.swift",
    "Tests/SwiftUIDownloadsTests/DownloadStagingAliasTests.swift": "Tests/SwiftUIDownloadsTests/DownloadStagingAliasTests.swift",
}
subprocess.run(["swift", "--version"], check=True)
with tempfile.TemporaryDirectory(prefix="download-staging-") as scratch:
    package = pathlib.Path(scratch)
    (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DownloadStagingChecks", targets: [
    .target(name: "SwiftUIDownloads"),
    .testTarget(name: "SwiftUIDownloadsTests", dependencies: ["SwiftUIDownloads"])
])
''')
    for source, destination in inputs.items():
        data = (root / source).read_bytes()
        target = package / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(hashlib.sha256(data).hexdigest(), source, flush=True)
    for configuration in ("debug", "release"):
        command = ["swift", "test", "--package-path", str(package), "-c", configuration,
                   "--jobs", "2", "-Xswiftc", "-warnings-as-errors"]
        # Use xcsift on configured native development hosts, with pipefail-equivalent
        # status checks. This portable package has no SwiftSyntax/macros/prebuilts.
        if shutil.which("xcsift"):
            producer = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            consumer = subprocess.Popen(["xcsift"], stdin=producer.stdout)
            producer.stdout.close()
            consumer_status = consumer.wait()
            producer_status = producer.wait()
            if producer_status or consumer_status:
                raise SystemExit(producer_status or consumer_status)
        else:
            subprocess.run(command, check=True)
