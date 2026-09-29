#!/usr/bin/env python3
"""Compile the whole production delivery boundary and its tests, without stubs.

Does not build the native URLSession delegate, Combine, DownloadController,
CryptoKit or Brotli. Apple Foundation replacement is explicitly skipped on Linux.
"""
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
    files = (
        "Sources/SwiftUIDownloads/DownloadHTTPResponse.swift",
        "Sources/SwiftUIDownloads/DownloadFileDelivery.swift",
        "Tests/SwiftUIDownloadsTests/DownloadFileDeliveryTests.swift",
    )
    with tempfile.TemporaryDirectory(prefix="download-file-delivery-") as directory:
        scratch = Path(directory)
        for relative in files:
            source = root / relative
            data = source.read_bytes()
            print(f"{hashlib.sha256(data).hexdigest()}  {relative}", flush=True)
            target = scratch / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        (scratch / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "SwiftUIDownloads", targets: [
    .target(name: "SwiftUIDownloads"),
    .testTarget(name: "SwiftUIDownloadsTests", dependencies: ["SwiftUIDownloads"])
], swiftLanguageVersions: [.v5])
''')
        configurations = ("debug", "release") if args.configuration == "both" else (args.configuration,)
        for configuration in configurations:
            subprocess.run(["swift", "test", "--package-path", str(scratch), "-c", configuration,
                            "-Xswiftc", "-warnings-as-errors"], check=True)


if __name__ == "__main__":
    main()
