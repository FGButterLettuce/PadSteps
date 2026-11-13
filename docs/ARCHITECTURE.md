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
idle readings spanning at least four seconds finish a walk. Counter resets or
uncertainty require review. Finished walks and upload state are persisted before
network changes. The Mac fetches native Fitbit HR history, checks its coverage,
then creates one Google walking workout and verifies the returned record.

The upload journal is intentionally conservative. After an uncertain POST, the
app resolves the recorded operation or adopts a matching existing workout.
It does not blindly POST the same workout again. A different overlapping workout
can hold the walk for review. Reviews can recheck deleted overlaps, compare
interval counts and offer an explicit in-place correction. See
[overlapping workouts](OVERLAPPING-WORKOUTS.md).

Data is stored in the current Mac bundle ID's Application Support directory.
An instance lock prevents two copies from writing the same recorder state.
Tokens use a bundle-specific Keychain service. The original private install's
data folder is not reused by this public build.

## iPhone steps companion

The phone has its own native Google session and read-only fitness scope. It
reads finished Google exercises and accepts only WALKING records whose source
matches the configured Mac OAuth client ID, or whose corrected pad measurements
carry a signature from the paired local recorder and match Google readback.
It never POSTs to Google.

Each imported walk uses:

```text
padsteps.google_<health-user-id>_<exercise-data-point-id>.steps
```

Full-count exports use sync version 1. In optional `missing-google` mode, the
version increases when Google sync changes the missing-step quantity; every
revision retains the same per-walk sync identifier. The ledger and any pending
write are persisted before HealthKit changes. A matching existing quantity sample is
adopted. Conflicts or a previously confirmed record that is no longer readable
are held for review, not automatically restored. The journal is persisted before
the HealthKit save; retries preserve the same identity. The write type is only
step count, not a workout, HR or distance record.

The journal is account-bound, starts at setup-day midnight and queries seven-day
windows with a three-day overlap for delayed records. Older experiments and
records published more than three days late need deliberate backfill review.
It uses atomic writes and iOS file protection. Corrupt journal data pauses sync.

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
