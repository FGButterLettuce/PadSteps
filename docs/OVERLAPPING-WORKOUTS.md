# Overlapping workouts

PadSteps preserves the pad's measured total and avoids uploading a second Google
exercise simply because another source undercounts it.

## Review a blocked walk

**Check again** repeats the Google lookup. If you deleted the overlapping exercise,
the walk can leave review and upload normally. A pre-upload overlap also rechecks
on the normal sync cycle. Counter-reset reviews and uncertain POSTs cannot become
fresh uploads through this action. Older overlap reviews migrate without editing
their saved health measurements.

**Compare steps** reads Google's all-sources steps rollup for the exact physical
time interval of the pad walk. It shows the pad total, Google's interval total,
and `max(0, pad − Google)` as the missing count. Workout summary steps are shown
separately with each workout's actual source and times. They are not equivalent
to the interval total or a change to Google's daily steps. An absent, malformed,
failed or unfinished response means **Unknown**, never zero.

If there is exactly one WALKING workout whose start and end each differ by no
more than 60 seconds from the pad walk, **Use pad totals for this workout…** offers
an explicit confirmation. It PATCHes that same exercise resource with absolute
pad steps, distance, interval and duration, plus synced Fitbit average HR. It does
not POST a difference workout. Other summary metrics and ordinary notes are
retained; old splits/pause events are removed because they belong to the prior
interval. The original record and requested replacement are saved locally first.
Google may reject edits to a given source; only matching readback marks a
correction saved. A timeout never authorizes a new workout: Check again reads the
known target, and a reviewed retry updates the same target to the same totals.

Partial overlaps, different exercise types, and several workouts require manual
resolution in Google Health before another check. PadSteps will not invent which
portion of another exercise belongs to the pad.

## iPhone and Apple Health

An edited Google/Fitbit exercise can retain its original source. A paired local
Ed25519 key lets the Mac attach a signed pad measurement in its notes; the iPhone
accepts it only with the configured public key, recorder ID, resource, interval
and matching counters. Unedited native workouts and arbitrary notes are not
eligible step imports. The existing Google account binding and per-resource
HealthKit sync identity still apply. The phone has no Google write access.

In the default `full` export mode, the phone saves one **full measured pad count**, rather than a separate difference
sample. Apple Health chooses overlapping sources using its source priorities;
a second delta source is not a reliable way to add counts there. Put PadSteps
above competing sources under Health → Steps → Data Sources & Access. Readback
of one PadSteps sample verifies import uniqueness; it does not alone prove the
merged daily total in Apple Health or Bevel. The phone needs to sync before its
new steps can appear downstream.

Editing an exercise summary does not establish daily Google step credit.

## Two automatic Bevel feeds: Google plus missing pad steps

For a Bevel setup using **direct Google Health Steps** and **PadSteps**, set
`"step_export_mode": "missing-google"` in `.local/settings.json`, regenerate the
project, and rebuild/install the phone app. The default `full` mode remains
available for users who want full measured samples prioritized in Apple Health.

The phone reads Google's steps rollup for the **exact pad interval**, then exports
`max(0, measured pad steps − Google steps)`. For example, a measured 2,000-step
walk with 500 Google steps produces one 1,500-step PadSteps top-up. Google keeps
the full workout and HR; its workout summary is not used as a substitute for the
step-data query. Use the same all-sources Google feed as the direct integration,
not the narrower wearable-only family. The phone checks for its own app appearing
in Google's step sources and stops rather than feeding its exported steps back
into the subtraction.

In Bevel → Profile → Data Sources → Steps → Hide Data Sources:

- Keep **Google Health without an iPhone/device label** enabled (direct feed).
- Keep **PadSteps** enabled (the top-ups exported through Apple Health).
- Hide the duplicate **Google Health labeled with your iPhone** (Apple Health copy).
- The **Health** source represents manual entries; it is not the merged Apple
  Health daily counter. Enable it only when those manual entries are intentional.
- Workouts and Heart Rate source settings are independent of these Steps choices.

Apple Health's own daily counter can be lower in this mode: it prioritizes
sources over overlapping intervals instead of summing the Fitbit count and the
PadSteps top-up. The mode targets Bevel's **direct Google + PadSteps** combination.
Do not claim its Apple Health counter is a fully measured daily total.

Late Google step sync revises the **same** HealthKit sync identifier at a higher
version. Repeat checks adopt an unchanged export. When Google already covers a
walk, no top-up is created; an existing redundant top-up is removed only after
matching this app's known record. Conflicting, duplicated or user-deleted records
remain protected. A successful empty Google query means no steps are recorded
there yet; a provisional full-pad top-up is rechecked later. Failed or malformed
queries never become guessed zero counts. Pending write journals preserve the
absolute intended quantity across interrupted updates.

Physical controlled replacements and app-open reconciliation have been checked.
Background delivery still depends on iOS, and the next newly recorded real walk
is the remaining full-lifecycle integration check. Opening the phone app forces
catch-up. Bevel may cache changes; [its troubleshooting guide](https://help.bevel.health/en/articles/11257729)
describes refreshing and reloading data. [Its source controls](https://help.bevel.health/en/articles/10416897)
apply separately to each data category.

## Late Fitbit detection

Normal sync also audits up to 20 saved walks from the last three days. If another
workout arrives later, the saved walk enters overlap review without creating
another Google workout or another Apple Health sample. Keep the measured PadSteps
workout, resolve the extra exercise in Google Health, then Check again. Removing
an already-exported PadSteps exercise is not permission to recreate its steps
under a new Google resource ID.

## Optional automatic reuse of a matching Fitbit exercise

Set `"auto_correct_matching_workouts": true` in the local settings to let the Mac
reuse a single matching Fitbit Air WALKING exercise automatically. Default is
false for existing public configurations. Both start/end must match within 60
seconds and at least 90% of both intervals must overlap. Its source and recording method must be known, and the pad upload must
not already have an uncertain result. Manual entries, other devices, partial or
multiple overlaps stay in review. The same snapshot/revalidation, signed receipt,
persisted PATCH target and readback rules apply. A native-source update may be
rejected by Google, in which case the app keeps the walk for review; this branch
still needs the next genuine Fitbit overlap to validate end to end. It never
creates a second exercise to work around a rejected PATCH.

## Local pairing and publication

`scripts/configure.py` generates `.local/correction-key.json` once for personal
builds, bundles its private half only with the Mac, and puts the public half in
the phone's Info.plist. Keep that local file across builds. Rebuilding with a new
key will not validate old native-workout corrections. Rebuild/install both apps
when introducing or changing pairing. Do not publish personalized app bundles,
key files, OAuth configuration or workout evidence. Compile-only CI builds have
no correction key and cannot perform this operation.

## Validation boundary

Synthetic tests cover retry eligibility, signed native-workout acceptance,
tampering, wrong recorder/resource/key, unknown rollups and partial overlaps.
The deleted-overlap recovery was verified against a physical walk and a Google
workout readback. The companion confirmed one full measured step sample; a
repeat foreground sync adopted it, and the observed Apple Health daily increase
matched the measured shortfall rather than adding the full count twice. This
is one physical foreground-sync check, not a background-delivery guarantee or
a Bevel daily-total verification. Editing an actual Fitbit auto-detected workout remains an
integration check for the next real overlap; Google's PATCH support for a data
type is not proof that every source permits every update.

Official API references: [exercise updates](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/patch),
[interval rollups](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/rollUp),
and [source metadata](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints#datasource).

Step-change observers exclude PadSteps itself to avoid feedback from its own writes.
The phone registers step and (when permitted) workout background delivery. Apple
limits step delivery frequency to hourly; iOS may schedule it later. App-open
checks and scheduled refresh remain catch-up routes. Background registration is
not proof of an end-to-end wake for a newly recorded walk.
