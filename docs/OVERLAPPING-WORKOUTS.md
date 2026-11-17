# Overlapping workouts

PadSteps keeps Google's detected walking workouts. It subtracts their combined
time coverage and creates only the missing intervals. A fully covered walk adds
no extra workout. A wholly undetected walk is saved in full.

If detection arrives after PadSteps saves, recent walks are rechecked. Only
verified PadSteps-owned workouts may be shortened or retired. Native Fitbit
records are owned by Fitbit and are never rewritten. A changed or unreadable
PadSteps record is held rather than overwritten.

Full pad steps reach the phone through the signed local feed, independently of
Google workout creation. Old step sync identities survive conversion of earlier
full workouts into gap-only workouts, preventing a second Apple Health copy.

See [recovery](RECOVERY.md) for controls, limits and verification scope.
