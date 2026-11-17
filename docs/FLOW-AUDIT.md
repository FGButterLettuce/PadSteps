# Flow reliability audit — 17 November 2026

The audit follows the working path: pad telemetry → durable Mac session → Google
workout coverage and Fitbit history → signed phone feed → Google interval-step
comparison → one versioned Apple Health top-up → Bevel's selected sources.

The intended result remains `max(0, measured pad steps − Google interval steps)`
in one PadSteps step sample. Workout summary steps do not substitute for Google's
daily-step rollup. Native Google/Fitbit workouts are retained; PadSteps fills
only uncovered workout time.

## Failures found and fixed

| Failure | Recovery now exercised |
| --- | --- |
| An observer's deadline cancelled a foreground sync it joined | Each requester owns its cancellation. Shared writes finish while another requester is still waiting. A new request during shutdown starts after the previous run ends. |
| Old history consumed the phone's short execution window before a new walk | New walks and interrupted writes take priority. Stable walks are rechecked less often; saved Mac workout audits rotate through the whole recent set. |
| Temporary OAuth/server failure looked like revoked access | Network failures, 429 and 5xx retain authorization. Locked/unavailable Mac Keychain restores retry without an interactive prompt. Definitively invalid authorization still requires reconnecting. |
| An unreadable/future journal could be overwritten during startup migration | All saves go through a guarded journal. Unreadable bytes are preserved; a protected phone journal can reload after unlock. Runtime disk failures pause uploads and can recover after storage is restored. |
| Google detected a walk while a gap creation was still unconfirmed | Pending tickets are resolved before changing coverage. A local ticket is never sent as a Google resource ID. Unknown outcomes retain their original attempt; known transient rejections have a delayed retry. |
| Step publication still depended on a Google workout identity | A session's step identity is frozen before its first feed publication. Confirmed measurements can reach the phone while HR/workout processing waits. Old sessions retain their original import aliases. |
| A crash after HealthKit saved a sample but before journal confirmation | The production transaction persists intent first, adopts matching readback on retry, and retains the same sync identifier/version. Failed intent persistence prevents the HealthKit write. |
| Google baseline changed after an interrupted step revision | Recover the pending revision first, then schedule the current shortfall. Do not create a second sample. A fully covered walk removes only the identified PadSteps top-up. |
| Metadata/carrier changes looked like changed pad measurements | Compare session identity, account, counters and interval with timestamp tolerance. Transport metadata does not invalidate an existing export. Conflicting measurements and multiple identities still stop safely. |
| A disconnected walk had no way to become a recoverable finished row | Explicitly finish from the last preserved readings, then confirm totals. Counter anchors remain intact to prevent recording the same cumulative steps again after reconnect. |
| An obsolete correction path could target a Fitbit-owned workout | Removed automatic native-workout correction. The remaining legacy manual correction accepts only an app-owned resource; gap reconciliation uses signed ownership checks. |

The public iPhone source also contained a personal sign-in account hint. That
hint was removed and the publication scanner now rejects hardcoded account
hints. This removes it from current source; earlier Git history was not rewritten.

## Verification

- `swift test`: 96 XCTest cases and 13 Swift Testing cases pass. Fault-injection
  tests use the same sync coordinator, export transaction, journal, gap planner,
  signed manifest and recorder used by the apps.
- A complete replay records a synthetic pad walk, signs and verifies its feed,
  writes a fake Health provider through the production transaction, persists a
  real temporary journal, restarts and adopts the existing sample, then revises
  it to zero without touching a foreign sample.
- Coverage replays check that the union of existing workout time and missing
  intervals does not add overlapping time. Other cases cover reset/reconnect,
  read denial, missing readback, disk failure, journal corruption, rejected
  operations, late detection and cancellation ownership.
- Both public native targets compile without credentials; the privately
  configured Mac and physical-iPhone targets build with signing.
- The installed Mac retained all nine real sessions with unchanged measurements.
  The phone retained eight confirmed single-sample exports and one zero export,
  with unchanged quantities and sync versions and no review warnings. Its copied
  feed matches the Mac byte-for-byte; signature, account, client and all nine
  import identities were verified. Recent Google workout audits resumed.
- The live phone check also encountered a Google 503. It preserved authorization
  and exports; its error now distinguishes temporary server failures from access
  rejection. Synthetic tests do not write to the user's Google or Apple stores.

These checks are not a claim that every possible hardware, network or OS failure
has been reproduced. A new physical walk and Bevel's refreshed daily total remain
distinct from automated replay and retained-record verification.

## Remaining conditions and user actions

| Condition | Expected behavior / action |
| --- | --- |
| Fitbit history has not synced | Step delivery proceeds independently. Open Google Health to sync Fitbit; the workout gaps retry. Save without HR is an explicit fallback, never an invented HR value. |
| Pad lost power after the last received reading | Review and confirm preserved/displayed totals. Unobserved steps cannot be recovered from a cleared counter. |
| iPhone is unavailable, locked, suspended or force-quit | Mac retains and retries the feed. Unlock and open PadSteps for immediate catch-up; iOS chooses background timing. |
| Google accepted a create but its outcome cannot yet be found | Search/adopt the original attempt. Do not create another workout just to clear a warning. Pause checks or inspect walk files if needed. |
| Health reads are hidden/denied or a confirmed sample was deliberately deleted | Preserve the journal and avoid automatic recreation. Review Steps read/write access. A true quantity/identity conflict still requires explicit repair; no destructive conflict-resolution screen is claimed. |
| Wrong Google account, revoked access or unsupported journal version | Stop writes and show the reason. Reconnect the correct account or repair/update the journal; do not clear duplicate-protection history. |
| Steps appear doubled only in Bevel | Keep direct Google Health plus PadSteps enabled. Hide the duplicate Google Health source labelled with the iPhone. PadSteps cannot control Bevel's source selection or refresh cache. |
| A stable walk changes more than three days later | Automatic recent-history reconciliation does not backfill it. Deliberate historical review is required. Pending writes remain recoverable regardless of age. |

The current phone transfer is still a developer-tool relay: Xcode, a trusted
Developer Mode iPhone, and the configured Mac must be available. It is not an
App Store background transport. No browser or screen automation was used for
this audit/install, and Bevel's current UI was not inspected.
