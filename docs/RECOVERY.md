# Recovery and workout coverage

A detected interruption needs an action, not just a warning.

| Condition | Action / outcome |
| --- | --- |
| Pad switched off before a confirmed stop | Review recorded totals; accept the preserved readings or enter larger final display totals. Original readings and the walk identity remain saved. |
| No Google walking workout | Save the recorded walk in full. |
| Google covers part of the walk | Keep its workout and save only uncovered intervals, with Fitbit HR for those intervals. |
| Google covers the full walk | Add no Google workout. Send measured steps independently to the iPhone. |
| Google detects the walk later | Update or retire only verified PadSteps-owned gap workouts. Native Fitbit workouts are retained. |
| Heart rate delayed or too incomplete | Check Fitbit again, or explicitly choose Save without heart rate. No HR is fabricated. |
| Unknown save outcome | Search for the signed original attempt; never POST another copy. |
| Confirmed rejected save | Retry rejected save / Retry rejected gap save. Uncertain attempt markers cannot be cleared by this action. |
| Review needs to wait | Keep locally / Pause checks. Resume later; counters and upload markers are retained. |
| Need evidence | Show walk files. The export stays local. |
| Paired phone unavailable | Retain the signed feed and retry transfer automatically. Open the iPhone app after unlock to apply HealthKit changes. |

The local step feed preserves a full-session step identity across any number of
Google gap workouts. The iPhone still calculates the top-up as pad steps minus
Google's all-source steps over the full measured interval. Google workout time
and daily steps are separate signals.

## Practical limits

- A cleared pad display cannot reveal unrecorded final steps. Totals confirmation
  makes that uncertainty explicit.
- A disconnected active recording stays open for reconnection; a reset may need
  reconnection before its recovery row appears.
- The relay currently requires Xcode tooling and a trusted developer-mode iPhone.
  It can copy without screen capture. iOS still controls HealthKit background
  timing; app-open catch-up is the reliable manual trigger.
- Corrupt journals and unavailable disk space pause writes. Keep the files for
  repair; do not clear the journal to bypass duplicate protection.
- The phone conservatively holds missing/unreadable/changed step samples. Its
  dedicated conflict-repair screen remains follow-up work; this release does not
  claim otherwise.
- Core tests and real Google readback cover the exercised paths. Installation
  during the user's movie used terminal tools only; no visual QA was performed.
