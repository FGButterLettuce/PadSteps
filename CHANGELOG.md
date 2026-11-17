# Changelog

## Unreleased

- Audit the full recorder-to-phone flow: isolate sync-request cancellation,
  prioritize new walks, guard unreadable journals, preserve authorization through
  outages, resolve pending Google gap creates before replanning, and freeze step
  identities before publication. Exercise the production step-write transaction
  through crash, disk-failure and hidden-read replays.
- Finish disconnected recordings from preserved readings with explicit totals
  review; remove the obsolete native-workout correction path. See the
  [flow reliability audit](docs/FLOW-AUDIT.md) for evidence and remaining limits.
- Add optional missing-step exports for direct Google Health + PadSteps in Bevel,
  with versioned revisions, pending-write recovery and step-feedback detection.
- Keep full-count mode as the default for existing public configurations.

- Expose read-only source comparisons on saved walks and document Bevel direct
  Google versus Apple Health step duplication.

- Recheck pre-upload overlap reviews after an exercise is removed.
- Compare pad steps with reconciled Google interval steps and workout summaries.
- Review an app-owned in-place correction instead of creating a second workout;
  native Google/Fitbit workouts remain untouched.
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
