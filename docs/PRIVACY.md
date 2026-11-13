# Privacy and data boundaries

PadSteps runs on your Mac and iPhone. There is no PadSteps-hosted health database,
analytics service, advertising SDK or shared sign-in account.

## What goes where

| Information | Destination |
| --- | --- |
| Pad counters and status | Bluetooth from the pad to your Mac; recorded locally. |
| Fitbit heart-rate history | Read directly from your authorized Google Health account by the Mac. |
| Walking workout | Written by the Mac directly to that Google Health account, with measured counters and HR summary. |
| Finished PadSteps exercise summary | Read from Google by your iPhone using its own read-only authorization. |
| Measured step samples | Written by the iPhone into Apple Health with your permission. |
| Daily total / existing samples | Read locally from HealthKit to check the import. |
| Workouts | Read locally as a possible background-sync trigger; not copied or created by the phone. |
| Google tokens | OS Keychain on the device holding that session. |
| Import/upload journals and evidence | Application Support on your own device. These contain health data. |

Google Sign-In also provides basic account identity and communicates with Google
to authorize and refresh access. Third-party services have their own privacy
practices. Bevel's onward data use is configured in Bevel and is not controlled by
this repository.

## Public vs private

The GitHub repository contains source, fictional test identities, empty templates
and project-created brand assets. It does **not** contain the original owner's
recordings, health exports, account identifiers, Bluetooth peripheral IDs, Google
configuration, tokens, certificates, provisioning profiles, or personal
troubleshooting notes. Those stayed outside the public export.

Client IDs are normally public identifiers, but the owner's real project values
were still removed. Settings are injected locally instead of hidden behind
encoding, hashing, renamed variables, or reversible obfuscation. A private GitHub
repository is not used as a health-data or credential vault.

When contributing, keep raw captures and local reports off GitHub, including issue
attachments and CI artifacts. Use synthetic reproductions. Source-level scanning
cannot establish that an arbitrary screenshot or binary contains no private data;
review those before adding them.

## Control and deletion

You can stop pad monitoring, disable automatic phone checks, revoke Google access,
and manage Health permissions in the respective apps/settings. Previously saved
Google workouts and Apple Health steps remain until you manage them there.

Do not erase an app's local journal as a retry mechanism. It is part of duplicate
protection and records what was already saved. Review or migrate existing health
records before changing bundle IDs, accounts or local storage.

This file describes the public source build, not a hosted privacy service or a
promise about independently modified forks.
