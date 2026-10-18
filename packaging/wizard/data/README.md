# Vendored Pi Voice selection data

`catalog.json` and `recommendations.json` are copied verbatim from
`@earendil-works/pi-voice`'s own `catalog/` directory at the version Mash pins
in `packaging/build.sh`.

The wizard embeds both with `include_str!` so it can make the same
Best/Fast model pick the extension's onboarding would, and `mash-voice-model`
reads the shipped copy at runtime for each model's repository, revision, size
and checksum.

Do not hand-edit them. Refresh them from the bundled package when the pinned
pi-voice moves:

```sh
installed="$(mktemp -d)"
npm pack @earendil-works/pi-voice@<version> --pack-destination "$installed" >/dev/null
tar -xzf "$installed"/*.tgz -C "$installed"
cp "$installed"/package/catalog/*.json packaging/wizard/data/
```

`packaging/build.sh` fails the build when these disagree with the pi-voice it
just installed, so a stale copy is caught before a bundle ships.
