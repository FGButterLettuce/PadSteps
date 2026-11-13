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

The phone saves one **full measured pad count**, rather than a separate difference
sample. Apple Health chooses overlapping sources using its source priorities;
a second delta source is not a reliable way to add counts there. Put PadSteps
above competing sources under Health → Steps → Data Sources & Access. Readback
of one PadSteps sample verifies import uniqueness; it does not alone prove the
merged daily total in Apple Health or Bevel. The phone needs to sync before its
new steps can appear downstream.

Editing an exercise summary does not establish daily Google step credit.

## Late Fitbit detection

Normal sync also audits up to 20 saved walks from the last three days. If another
workout arrives later, the saved walk enters overlap review without creating
another Google workout or another Apple Health sample. Keep the measured PadSteps
workout, resolve the extra exercise in Google Health, then Check again. Removing
an already-exported PadSteps exercise is not permission to recreate its steps
under a new Google resource ID.

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
