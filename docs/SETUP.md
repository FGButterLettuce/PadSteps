# Build your own PadSteps

This public tree is separate from the original owner's running installation.
It contains neither that installation's credentials nor its health history.
Use your own bundle IDs and Google project. Do not reuse a research installation's
app container or import journal unless you deliberately plan its migration.

## 1. Tools

Install Xcode, its required platform SDKs, Swift 6 and XcodeGen. Build the shared
package first with `swift test`; no Google credentials or hardware are needed.

macOS 14+ and iOS 17+ are the deployment minimums. The actual HealthKit import
requires an iPhone. Simulator writes are disabled. This source release is not
notarized, distributed through TestFlight, or published on the App Store.

## 2. Your Google project

In your Google Cloud project, enable **Google Health API** and configure the
OAuth consent app. You must review and accept Google's applicable terms yourself.
Access and verification requirements depend on your account and distribution.
Do not substitute the retired Google Fit API or legacy Fitbit endpoints for the
Health API used in this project.

Create two clients in the **same project**:

| Client | Type | Configuration |
| --- | --- | --- |
| Mac recorder | Desktop app | Download its JSON; place it at `.local/desktop-oauth.json`. Keep the `installed` object. The Mac uses localhost OAuth with PKCE. |
| iPhone companion | iOS | Match your `phone_bundle_id` and Apple team. Copy its client ID into `.local/settings.json`. The setup script generates its reversed-ID callback scheme. |

The setup script copies the Mac configuration into an ignored bundle resource.
Installed-app OAuth client configuration is not a substitute for token security:
native application bundles can be inspected. Access and refresh tokens live in
the operating system Keychain. Do not publish the original owner's project
configuration or distribute your personal configured binaries as a shortcut.

The Mac requests these scopes:

```text
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.writeonly
https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
```

The phone requests **only** the activity/fitness read scope, plus the Google
Sign-In SDK's basic identity scopes. The generated phone Info.plist also contains
your **desktop** client ID as `PadStepsRecorderClientID`. That value is required:
it restricts imports to workouts written by your own recorder. The phone reads
all sources and then checks provenance because its own OAuth client ID differs.
An empty trusted recorder ID rejects all imports.

Google warns that testing-mode authorizations can expire quickly. Production
status and verification are separate; switching status is not verification.
Follow [Google's OAuth production guidance](https://developers.google.com/identity/protocols/oauth2/production-readiness/policy-compliance)
for your own intended use. This repository supplies no shared public OAuth service.

## 3. Local settings

```sh
mkdir -p .local
cp config/settings.example.json .local/settings.json
cp config/desktop-oauth.example.json .local/desktop-oauth.json
```

Replace the placeholders with your own Apple team, bundle IDs and OAuth clients.
You can use the real downloaded desktop JSON directly instead of editing the
example. Never put tokens in either example file.

```sh
make configure
open PadSteps.xcodeproj
```

Select your signing team and build `PadStepsMac` and `PadStepsPhone`. The signing
capabilities include HealthKit and HealthKit background delivery for the phone.
Use the same configured Google Health account on both apps. Ordinary Google
session refresh is automatic, but revoked access can require reconnecting.

## 4. Permission setup

On the Mac, allow Bluetooth and connect Google Health. On the phone, connect
Google Health and choose **Enable Apple Health** / **Review Apple Health access**.
Allow Steps read/write and Workouts read. If Steps was already allowed, only the
new Workouts permission may appear. Workouts are read for potential background
wakes; the phone does not save workouts or HR.

Keep Background App Refresh enabled. iOS controls execution timing and suppresses
background behavior after force-quit. A locked phone can prevent HealthKit reads;
unlock and open PadSteps for catch-up. A Google workout appearing in Bevel does
not prove it exists in Apple Health or can trigger its workout observer.

## 5. Verify on a real walk

1. Keep the Mac awake near the powered pad, with SPX Fitness closed.
2. Note the readable Apple Health and Bevel daily step totals.
3. Walk briefly and stop with the remote. Compare the displayed counters with the
   Mac's saved walk. Do not manually add a second workout.
4. Let Fitbit finish syncing through Google Health. Wait for the Mac's Google
   readback confirmation.
5. Open PadSteps on the phone and check the step record and merged daily total.
6. Recheck, then relaunch the phone app: the walk should remain exactly one
   confirmed record with no extra copy.
7. Compare Bevel's daily total and confirm the existing workout/HR remains intact.

Apple Health source priority and Bevel's step-source choices need separate
verification. Do not hide all Fitbit activity without checking that your
non-pad steps remain available.

Do not delete the app, its journal or Google workouts to retry a failed sync.
Preserve the evidence and review its state first.

## Local measured-step relay

Google workouts no longer serve as the required step carrier. In your ignored
`.local/settings.json`, set `iphone_relay_device_id` to the identifier printed by
`xcrun devicectl list devices`, then rerun `make configure` and rebuild both apps.
Use the same generated pairing key for the Mac and iPhone. Trust this Mac and
enable Developer Mode on the phone as required by Xcode device services.

The Mac copies a signed manifest into only the configured companion's private
container. Keep the phone connected or available through Xcode's paired wireless
connection. A disconnected phone leaves the manifest queued for retry. Unlock
and open PadSteps to perform an immediate Apple Health catch-up.

This is a developer-tool relay. It requires Xcode on the Mac and is not an App
Store distribution mechanism. No additional Google scope, hosted backend,
Cloudflare account, or public health-data endpoint is needed.
