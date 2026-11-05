#!/usr/bin/env bash
# User-visible launch and plugin messages follow setup/language; absent choice
# keeps the existing English output. Runtime trees stay disposable.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

copy_catalog() {
  mkdir -p "$1/i18n/messages"
  cp -R "$root/packaging/i18n/messages/helpers" "$1/i18n/messages/"
}

# herdr-pane can run before mash_isolate, so it reads the saved choice itself.
res="$tmp/pane/Resources"
home="$tmp/pane-home"
mkdir -p "$res/bin" "$home/.mash/setup"
cp "$root/packaging/herdr-pane" "$res/bin/herdr-pane"
cp "$root/packaging/lib.sh" "$res/bin/lib.sh"
cp "$root/packaging/helpers/mash-t" "$res/bin/mash-t"
copy_catalog "$res"
printf '\nmash_real_home() { printf "%%s\\n" "$HOME"; }\n' >>"$res/bin/lib.sh"
printf '#!/bin/sh\nexit 3\n' >"$res/bin/mash-wizard"
chmod +x "$res/bin/herdr-pane" "$res/bin/mash-wizard" "$res/bin/mash-t"
printf 'language=es\n' >"$home/.mash/setup/language"
out="$(HOME="$home" PATH="$PATH" "$res/bin/herdr-pane" 2>&1)"
grep -q 'La configuración de Mash no ha terminado' <<<"$out" || { echo 'FAIL: Spanish setup notice missing' >&2; exit 1; }
grep -q 'Vuelve a abrir Mash' <<<"$out" || { echo 'FAIL: Spanish setup guidance missing' >&2; exit 1; }
rm "$home/.mash/setup/language"
out="$(HOME="$home" PATH="$PATH" "$res/bin/herdr-pane" 2>&1)"
grep -q 'Mash setup is not finished, so Mash did not open.' <<<"$out" || { echo 'FAIL: no-language setup notice changed' >&2; exit 1; }

# Shell plugin panes translate notices and image errors through mash-t.
plugin_bin="$tmp/plugin-bin"
python_bin="$tmp/plugin-tools"
mkdir -p "$plugin_bin" "$python_bin"
printf '#!/bin/sh\nexit 0\n' >"$plugin_bin/herdr"
printf '#!/bin/sh\nexit 0\n' >"$plugin_bin/clear"
chmod +x "$plugin_bin/herdr" "$plugin_bin/clear"
system_python="$( [ -x /usr/bin/python3 ] && printf '%s' /usr/bin/python3 || command -v python3 )"
ln -s "$system_python" "$python_bin/python3"
ln -s "$(command -v dirname)" "$python_bin/dirname"
ln -s "$(command -v basename)" "$python_bin/basename"
plugin_path="$root/packaging/helpers:$plugin_bin:$python_bin"
out="$(env -i HOME="$tmp" PATH="$plugin_path" MASH_LANGUAGE=es MASH_I18N_DIR="$root/packaging/i18n" \
  MASH_UPDATE_CANDIDATE=0.2.0 MASH_UPDATE_INSTALLED=0.1.1 HERDR_PANE_ID=fixture \
  /bin/bash "$root/packaging/plugins/mash-update-notice/update.sh" 2>/dev/null || true)"
grep -q 'Mash 0.2.0 está disponible' <<<"$out" || { echo 'FAIL: Spanish update pane missing' >&2; exit 1; }
grep -q 'https://github.com/LuisAlejandro/mash/releases/latest' <<<"$out" || { echo 'FAIL: update URL changed' >&2; exit 1; }
out="$(env -i PATH="$plugin_path" MASH_LANGUAGE=es MASH_I18N_DIR="$root/packaging/i18n" \
  MASH_UPDATE_INSTALLED=0.2.0 HERDR_PANE_ID=fixture \
  /bin/bash "$root/packaging/plugins/mash-update-notice/updated.sh" 2>/dev/null || true)"
grep -q 'Mash 0.2.0 está instalado y en ejecución' <<<"$out" || { echo 'FAIL: Spanish update confirmation missing' >&2; exit 1; }
out="$(env -i PATH="$plugin_path" MASH_LANGUAGE=es MASH_I18N_DIR="$root/packaging/i18n" \
  IMAGE_POPUP_FILE="$tmp/no-image.png" HERDR_PANE_ID=fixture \
  /bin/bash "$root/packaging/plugins/image-popup/view.sh" 2>/dev/null || true)"
grep -q 'No hay ninguna imagen para mostrar' <<<"$out" || { echo 'FAIL: Spanish image message missing' >&2; exit 1; }
: >"$tmp/picture.png"
out="$(env -i PATH="$plugin_path" MASH_LANGUAGE=es MASH_I18N_DIR="$root/packaging/i18n" \
  IMAGE_POPUP_FILE="$tmp/picture.png" HERDR_PANE_ID=fixture \
  /bin/bash "$root/packaging/plugins/image-popup/view.sh" 2>/dev/null || true)"
grep -q 'viu no está instalado' <<<"$out" || { echo 'FAIL: Spanish missing-viu message missing' >&2; exit 1; }
grep -q "$tmp/picture.png" <<<"$out" || { echo 'FAIL: image path omitted' >&2; exit 1; }

# macOS alert is translated only when a saved language is available.
app="$tmp/Mash.app/Contents"
res="$app/Resources"
home="$tmp/mac-home"
mkdir -p "$res/bin" "$app/MacOS" "$home/.mash/setup"
cp "$root/packaging/mash" "$res/bin/mash-launch"
cp "$root/packaging/lib.sh" "$res/bin/lib.sh"
printf '\nmash_real_home() { printf "%%s\\n" "$HOME"; }\n' >>"$res/bin/lib.sh"
cp "$root/packaging/helpers/mash-t" "$res/bin/mash-t"
copy_catalog "$res"
cat >"$res/bin/launch-common.sh" <<'SH'
mash_protect_data_dir() { mkdir -p "$1"; }
mash_seed_all() { return 0; }
mash_force_updates() { return 1; }
SH
cat >"$app/MacOS/mash-terminal" <<'SH'
#!/bin/sh
printf '%s' "$MASH_SETUP_ERROR" >"$CAPTURE"
SH
chmod +x "$res/bin/mash-launch" "$res/bin/mash-t" "$app/MacOS/mash-terminal"
printf 'language=es\n' >"$home/.mash/setup/language"
CAPTURE="$tmp/mac-alert" HOME="$home" PATH="$PATH" "$res/bin/mash-launch" || true
grep -q 'Mash no pudo fijar la configuración de actualizaciones' "$tmp/mac-alert" || { printf 'FAIL: Spanish macOS alert missing: %s\n' "$(<"$tmp/mac-alert")" >&2; exit 1; }
rm "$home/.mash/setup/language"
CAPTURE="$tmp/mac-alert" HOME="$home" PATH="$PATH" "$res/bin/mash-launch" || true
grep -q '^Mash could not pin its update settings\. Details:' "$tmp/mac-alert" || { echo 'FAIL: no-language macOS alert changed' >&2; exit 1; }

# Linux launcher follows same catalog and keeps error output in English without
# a setup/language record.
linux="$tmp/linux"
res="$linux/packaging"
home="$tmp/linux-home"
mkdir -p "$res/bin" "$linux/packaging/linux" "$home/.mash/setup"
cp "$root/packaging/linux/launcher" "$linux/packaging/linux/launcher"
cp "$root/packaging/lib.sh" "$res/bin/lib.sh"
cp "$root/packaging/helpers/mash-t" "$res/bin/mash-t"
copy_catalog "$res"
cat >"$res/bin/launch-common.sh" <<'SH'
mash_protect_data_dir() { mkdir -p "$1"; }
mash_seed_all() { return 0; }
mash_force_updates() { return 1; }
SH
chmod +x "$linux/packaging/linux/launcher" "$res/bin/mash-t"
printf 'language=es\n' >"$home/.mash/setup/language"
if out="$(env -i HOME="$home" PATH="$PATH" "$linux/packaging/linux/launcher" 2>&1)"; then
  echo 'FAIL: Linux fixture unexpectedly launched' >&2; exit 1
fi
grep -q 'Mash no pudo fijar la configuración de actualizaciones' <<<"$out" || { echo 'FAIL: Spanish Linux alert missing' >&2; exit 1; }
rm "$home/.mash/setup/language"
if out="$(env -i HOME="$home" PATH="$PATH" "$linux/packaging/linux/launcher" 2>&1)"; then
  echo 'FAIL: English Linux fixture unexpectedly launched' >&2; exit 1
fi
grep -q 'Mash could not pin its update settings; the file was kept.' <<<"$out" || { echo 'FAIL: no-language Linux alert changed' >&2; exit 1; }

echo 'Mash helper i18n: ok'
