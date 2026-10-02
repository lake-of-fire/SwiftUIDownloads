# Reader-main qualification

Canonical SwiftUIDownloads main is `669fd0240f7af043e9161277f551177c671aa8b1`.

Reader main currently selects `750e8fdd3607c04a30a137c3428f6f1d334d6247`; Reader v3-hotfix selects `12ee25fcc53f780b2fa973aab2915eac71ef967d`.

The hotfix selection is an ancestor of canonical main. Reader main has two divergent commits, but their runtime contracts are represented in the canonical line:
- local-artifact invalidation and owned transfer cancellation/fencing;
- checksum marker v2/file identity verification and staged-transfer ownership/retry behavior.

This qualification PR adds no runtime source. It runs the package's complete tests in Debug and Release on macOS, matching the package's declared Apple-only platform support. A Linux full-package run is not a valid gate because the Brotli Objective-C dependency requires Apple Foundation headers. A separate Reader root PR should pin canonical main only after this passes and then perform consumer compilation.

No Reader pin, schema, signing, rollout or CloudKit state changes.
