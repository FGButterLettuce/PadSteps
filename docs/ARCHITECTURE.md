# Architecture

Three pieces, two native apps, no PadSteps health-data server.

## Shared core

`PadStepsCore` uses Foundation and CryptoKit and exposes the pad protocol, cumulative recording
state, time-weighted heart-rate coverage, upload decisions and step import
identity. Its tests run without Bluetooth, Google or HealthKit. Fixtures use
fictional identities and measurements; idle protocol vectors contain no account
or device identity.

## Mac recorder

CoreBluetooth discovers a P2 Max advertising the verified UART service. The Mac
subscribes to notifications and sends status queries. It learns the selected
device ID at runtime; the repository has no saved peripheral UUID.

The recorder preserves cumulative pad counters across reconnects. Five stable
idle readings spanning at least four seconds finish a walk. A power-off/reset
preserves its last readings and offers explicit totals confirmation.

For confirmed walks, the Mac subtracts the union of existing walking-workout
intervals from the pad interval. It fills only gaps longer than five seconds;
a wholly undetected walk is retained in full. Only a full-session workout gets
full pad steps and distance. Partial-gap workouts carry actual interval HR,
without proportionally invented steps or distance.

Google assigns new exercise IDs. An attempt marker and signed session receipt
allow an interrupted create to be found and adopted; an unknown outcome cannot
produce another POST. Definitively rejected creates have an explicit retry.
When Fitbit detection arrives later, PadSteps reshapes or retires only its own
verified workouts. Native Fitbit records are never edited. Google restricts
updates to the creating application; see [data management](https://developers.google.com/health/data-management).

Full-session measured steps travel independently in a signed local manifest.
Xcode's `devicectl` copies it over the existing trusted device pairing into the
companion's private container. The relay targets only the configured device and
bundle. Offline/locked transport failures queue another attempt; they do not
cause a fake Google workout to be created as a step carrier. This transport
requires developer tooling and is not the proposed App Store sync solution.

Data is stored in the current Mac bundle ID's Application Support directory.
An instance lock prevents two copies from writing the same recorder state.
Tokens use a bundle-specific Keychain service. The original private install's
data folder is not reused by this public build.

## iPhone steps companion

The phone keeps a native read-only Google session for baseline steps and legacy
workouts. It verifies the local manifest against the paired Mac public key,
expected account and recorder client ID. New sessions use a UUID-based sync
identity independent of the number of Google gap workouts. Older sessions retain
their original Google-resource-based step identity even after their redundant
Google workout is removed. A signature cannot cross accounts or recorder clients.

Legacy exercises and signed gap receipts remain readable as a fallback. Two
workout carriers for one session resolve to the same HealthKit identity and
measured interval. Carrier location is not treated as a conflicting measurement.

Full-count exports use sync version 1. In optional `missing-google` mode, the
version increases when Google sync changes the missing-step quantity; every
revision retains the same per-walk sync identifier. The ledger and any pending
write are persisted before HealthKit changes. A matching existing quantity sample is
adopted. Conflicts or a previously confirmed record that is no longer readable
are held for review, not automatically restored. The journal is persisted before
the HealthKit save; retries preserve the same identity. The write type is only
step count, not a workout, HR or distance record.

The journal is account-bound and starts at setup-day midnight. A verified local
feed is authoritative; legacy Google workout discovery runs only when no feed
exists and looks back three days. New sessions and pending writes run before
stable history. Completed walks are rechecked for three days; interrupted writes
remain recoverable regardless of age. Older baseline changes need deliberate
backfill review. Atomic writes and iOS file protection retain unreadable journals
instead of silently replacing them. See the [flow audit](FLOW-AUDIT.md).

Foreground opening and visible-app checks provide catch-up. HealthKit workout
notifications can help only when a matching workout actually reaches Apple
Health. `BGAppRefreshTask` is a scheduling fallback, not a fifteen-minute promise.
Google/HealthKit authorization and locked-store failures must remain visible.

## Publication boundaries

Public: source, synthetic fixtures, configuration templates, protocol facts,
project-created branding and docs. Local only: Google/Apple settings, credentials,
Keychain tokens, raw Bluetooth captures, personal research notes, workout evidence,
health exports, device identifiers, signing files and generated projects.

The public repository was prepared from a file allowlist, rather than pushing
the original experiment directory and hoping `.gitignore` was sufficient.

Step-change observers exclude PadSteps itself to avoid feedback from its own writes.
The phone registers step and (when permitted) workout background delivery. Apple
limits step delivery frequency to hourly; iOS may schedule it later. App-open
checks and scheduled refresh remain catch-up routes. Background registration is
not proof of an end-to-end wake for a newly recorded walk.

### Heart-rate coverage

The Mac requires Fitbit Air samples within five seconds of both walk boundaries.
Intervals over 15 seconds are treated as unobserved and excluded from the
weighted average. Isolated gaps up to 30 seconds are accepted only when their
combined duration is at most 5% of the walk. Longer or more extensive gaps keep
the walk queued with a coverage-specific message. No missing heart-rate samples
are created. Downloaded observations remain in local evidence, including failed
coverage checks, so a sensor dropout is distinguishable from delayed sync.
