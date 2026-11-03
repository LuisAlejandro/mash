# Security Policy

## Supported versions

Only the latest release of Mash receives security fixes. Upgrade before
reporting, and check whether the problem still happens.

## Reporting a vulnerability

Please report vulnerabilities privately by email to
**luis@luisalejandro.org**. Do not open a public issue.

Include:

- The Mash version, your operating system, and architecture
- What an attacker can do, and the steps to reproduce it
- A proof of concept, if you have one

Mash keeps its data in `~/.mash`, which can hold credentials and session
history. Remove secrets from anything you attach.

You should get a reply within a few business days. Once the issue is
confirmed, a fix ships in a new release and the report is credited in the
release notes, unless you prefer to stay anonymous.

## Verifying a download

Every release is built by GitHub Actions from a tagged commit.

- **macOS:** the DMG is signed with an Apple Developer ID and notarized by
  Apple. Gatekeeper checks it when you open it.
- **Linux:** each `.deb` carries a GitHub build provenance attestation, and
  later updates come from Mash's signed APT repository.
- **All platforms:** `checksums-sha256.txt` lists the SHA-256 of every file in
  the release.

```sh
sha256sum -c checksums-sha256.txt
gh attestation verify letsmash-<version>-linux-amd64.deb --repo LuisAlejandro/mash
```

Only download Mash from the
[GitHub releases page](https://github.com/LuisAlejandro/mash/releases) or
[letsma.sh](https://letsma.sh).
