# Changelog

## Unreleased

- Recheck pre-upload overlap reviews after an exercise is removed.
- Compare pad steps with reconciled Google interval steps and workout summaries.
- Review an in-place correction instead of creating a second workout; pair the
  phone to verify measured steps on corrected native exercises.
- Audit recent saved walks for later auto-detected exercises.
- Keep uncertain attempts protected and preserve per-resource HealthKit identity.
- Verify one recovered walk through Google and the phone: one HealthKit sample,
  repeat-sync adoption, and an observed daily increase equal to the missing steps.

See [overlapping workouts](docs/OVERLAPPING-WORKOUTS.md) for limits and validation.


## 0.3.0 — public source preview

- Publish a clean, configurable Mac recorder and iPhone steps companion.
- Keep the Google walking workout and Fitbit HR route separate from Apple Health
  step-count writes.
- Preserve per-walk upload/import journals and conservative duplicate decisions.
- Replace installation-specific settings and test identities with local templates
  and synthetic fixtures.
- Add setup, architecture, protocol and privacy docs; public-tree and secret
  checks; and PadSteps identity assets.

This is a source milestone, not an App Store or signed binary release. A fresh
automatic walk import, real background wake, and Bevel daily aggregation remain
integration checks for the next physical walk.
