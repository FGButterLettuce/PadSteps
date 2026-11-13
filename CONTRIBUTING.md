# Contributing

Start with a small issue describing the behavior, expected result, hardware model
and platform versions. Reproduce with synthetic data before sharing logs.

```sh
swift test
python3 scripts/check_public_tree.py
python3 scripts/configure.py --ci
```

The Xcode schemes are `PadStepsMac` and `PadStepsPhone`. Compile-only configuration
uses dummy OAuth IDs and requires no credentials. Real integration testing needs
your own local configuration and a physical phone/pad.

Changes to recording, HR coverage, upload retries or duplicate handling should
include a meaningful shared-core test. Verify provenance filtering if you change
the importer. Never weaken duplicate safeguards simply to make a test upload
succeed. Keep motor commands out of the observation-only protocol interface.

For new hardware, report the model and synthetic/identity-free protocol facts.
Do not upload raw personal BLE captures by default. Hardware compatibility should
remain a specific verified claim, not an assumption based on a similar name.

Native interfaces use SwiftUI semantic styles, accessible text and status labels
that distinguish queued, saved, verified and onward-synced states. Brand assets
identify the project; they do not establish third-party endorsement.

Submit changes under the repository's MIT license. Third-party code and assets
must retain their original license and attribution.
