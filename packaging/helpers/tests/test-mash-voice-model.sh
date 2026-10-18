#!/usr/bin/env bash
# Exercises mash-voice-model's cache-path and settings rules without a network
# round trip. A sparse file of the catalog's exact size makes the download
# branch short-circuit, so the destination path, the "already present" check
# and the generated pi-voice.json are all covered for real.
set -euo pipefail

helper="${1:-$(cd "$(dirname "$0")/.." && pwd)/mash-voice-model}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
res="$tmp/Resources"
mkdir -p "$res/bin" "$res/node/bin" "$res/defaults/pi/catalog"

node="$(command -v node || true)"
[ -n "$node" ] || {
	echo "node is required to exercise mash-voice-model" >&2
	exit 1
}
ln -s "$node" "$res/node/bin/node"
cp "$repo/wizard/data/catalog.json" "$res/defaults/pi/catalog/catalog.json"
cp "$helper" "$res/bin/mash-voice-model"
chmod +x "$res/bin/mash-voice-model"

# The helper is a bundle artifact: it resolves node and the catalog relative to
# itself, the way Resources/bin sits beside Resources/node and Resources/defaults.
run() { env -i HOME="$home" PATH=/usr/bin:/bin "$res/bin/mash-voice-model" "$@"; }

data="$home/.mash"
model="parakeet-unified-en-0.6b"
model_path="$data/cache/huggingface/hub/models--handy-computer--parakeet-unified-en-0.6b-gguf/snapshots/7e948f21b7bdbac698d3318db9d350f1096f3b6c/parakeet-unified-en-0.6b-Q8_0.gguf"
model_bytes=731357568
model_sha=4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795

# --plan resolves the metadata and prints where the file would land.
plan="$(run --plan "$data" "$model" en)"
expected_plan="$model_path"$'	'"$model_bytes"$'\t'"$model_sha"
[ "$plan" = "$expected_plan" ] || {
	printf 'unexpected plan:\n%s\nexpected:\n%s\n' "$plan" "$expected_plan" >&2
	exit 1
}
[ ! -e "$data/pi/agent/pi-voice.json" ] || {
	echo "--plan wrote settings" >&2
	exit 1
}

# A file of the exact size is "already present", so the run stays offline.
mkdir -p "$(dirname "$model_path")"
/usr/bin/truncate -s "$model_bytes" "$model_path"
run "$data" "$model" en 0

settings="$data/pi/agent/pi-voice.json"
[ -f "$settings" ] || {
	echo "settings were not written" >&2
	exit 1
}
for needle in \
	'"version": 1' \
	'"backend": {' \
	'"type": "transcribe-cpp"' \
	'"shortcut": "ctrl+alt+z"' \
	'"transcriptionLanguage": "en"' \
	'"id": "parakeet-unified-en-0.6b"'; do
	grep -qF "$needle" "$settings" || {
		printf 'settings are missing %s:\n' "$needle" >&2
		cat "$settings" >&2
		exit 1
	}
done
grep -qF "\"path\": \"$model_path\"" "$settings" || {
	echo "settings point somewhere other than the cache snapshot" >&2
	cat "$settings" >&2
	exit 1
}
grep -qF '"preferredLanguages": [' "$settings" || {
	echo "preferredLanguages is missing" >&2
	cat "$settings" >&2
	exit 1
}

# With the detector present, Auto is safe and the helper selects it.
detector_path="$data/cache/huggingface/hub/models--handy-computer--lang-id-voxlingua107-ecapa-gguf/snapshots/41cf26039e317c6b8883bf0a61b0785dc663fc26/lang-id-voxlingua107-ecapa-Q8_0.gguf"
mkdir -p "$(dirname "$detector_path")"
/usr/bin/truncate -s 26693632 "$detector_path"
run "$data" "$model" en 1
grep -qF '"transcriptionLanguage": "auto"' "$settings" || {
	echo "a shipped detector did not select auto-detect" >&2
	cat "$settings" >&2
	exit 1
}

# A data path Mash does not own is refused, and so is a model absent from the
# catalog the bundle ships.
if run "$tmp/elsewhere" "$model" en >/dev/null 2>&1; then
	echo "helper accepted a data path outside ~/.mash" >&2
	exit 1
fi
if run "$data" not-a-real-model en >/dev/null 2>&1; then
	echo "helper accepted an unknown model" >&2
	exit 1
fi
