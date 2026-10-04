# Reader-main qualification

## Historical September29 snapshot

The following pins describe the original qualification PR inputs; they are not current-main claims.


Canonical SwiftUIDownloads main is `669fd0240f7af043e9161277f551177c671aa8b1`.

Reader main currently selects `750e8fdd3607c04a30a137c3428f6f1d334d6247`; Reader v3-hotfix selects `12ee25fcc53f780b2fa973aab2915eac71ef967d`.

The hotfix selection is an ancestor of canonical main. Reader main has two divergent commits, but their runtime contracts are represented in the canonical line:
- local-artifact invalidation and owned transfer cancellation/fencing;
- checksum marker v2/file identity verification and staged-transfer ownership/retry behavior.

This qualification PR adds no runtime source. It runs the package's complete tests in Debug and Release on macOS, matching the package's declared Apple-only platform support. A Linux full-package run is not a valid gate because the Brotli Objective-C dependency requires Apple Foundation headers. A separate Reader root PR should pin canonical main only after this passes and then perform consumer compilation.

No Reader pin, schema, signing, rollout or CloudKit state changes.

## October4 metadata landing review

Current package target is `86ee8c356bb127667b272a879882ddc1c86850ce`.
A fresh normal merge-tree calculation against the original PR head
`c26a3c68eb73b92b9120fa208ca4bd3c3b0bf1b5` changes only this document and
`.github/workflows/qualify-reader-main.yml`. Current Package.swift, Sources
and Tests object identities are unchanged. This workflow can land independently
without replacing newer APIs or treating the older Debug/Release run as a run of
the advanced target. Original passing run36528366191 retains its original inputs.

No new build/test, Release, performance, MacUI, root pin or release authorization
is claimed. Root consumer qualification remains separate.
