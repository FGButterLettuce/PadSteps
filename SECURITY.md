# Security

This is preview software. The current main branch is the supported development
version; there are no maintained signed public releases.

Please report security problems through GitHub's **Report a vulnerability** entry
on this repository's Security tab. Do not put credentials, health exports,
Bluetooth identities or personal recordings in a public issue. Include a
synthetic reproduction where possible.

Local OAuth settings and generated projects belong in `.local/` or the ignored
bundle resource. Access and refresh tokens belong in Keychain, never source,
screenshots, repository secrets used for tests, or CI artifacts. CI builds use
dummy identifiers and do not sign in, contact a pad, or write health records.

Before publishing changes, run `make check` and a secret scan. The boundary check
examines tracked files as well as eligible untracked files, so force-adding a
blocked private file still fails. Gitleaks runs separately in CI. Neither scan is
a substitute for reviewing new screenshots, images, binary assets and generated
archives.

If a real token or key is exposed, revoke or rotate it with the issuer. Removing
it from the latest source does not remove it from Git history or existing clones.
Report exposure privately rather than copying the credential into a report.
