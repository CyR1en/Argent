#!/bin/zsh
# Packs Argent.app into a drag-to-Applications disk image, build/Argent-<version>.dmg: the app beside an
# Applications link, over the background in App/DMG (rendered by design/dmg/background.py), with the app's icon on
# the volume. dmgbuild, pinned by hash in scripts/dmg/requirements.lock, writes the window's layout, so Finder is
# never scripted. The app keeps build-app.sh's signature, self-signed or ad-hoc (scripts/sign-identity.sh): there is no
# notarization (docs/deferred.md), so a Mac that downloads the image asks once, in System Settings > Privacy & Security > Open
# Anyway, as the background says.
#
# The image carries the smart masks' and Remove's models that build/Argent.app holds, about 7 GB, so it takes
# minutes. Their weights must not go to anyone else until cleared (decision 24, scripts/README.md): for an image
# that leaves the owner's Macs, --no-models leaves out Contents/Resources/Models and re-signs the copy, and then
# Sky says it is unavailable, Subject falls back to Vision and Remove says it has no model.
#
#   scripts/build-dmg.sh                       release build, then build/Argent-<version>.dmg with the models
#   scripts/build-dmg.sh --no-models           the same without them
#   scripts/build-dmg.sh --skip-build          pack the build/Argent.app already there
#   scripts/build-dmg.sh --skip-build open     ... then mount the image and show its window
set -euo pipefail
cd "$(dirname "$0")/.."

with_models=1
skip_build=0
open_after=0
for arg in "$@"; do
  case $arg in
    --no-models) with_models=0 ;;
    --skip-build) skip_build=1 ;;
    open) open_after=1 ;;
    *) echo "usage: scripts/build-dmg.sh [--no-models] [--skip-build] [open]" >&2; exit 2 ;;
  esac
done

(( skip_build )) || scripts/build-app.sh release
app=build/Argent.app
[[ -d $app ]] || { echo "error: $app is missing; run scripts/build-app.sh release" >&2; exit 1; }
codesign --verify --strict "$app"

# ArgentVersion, the whole version scripts/build-app.sh took from the tag (0.2.0-beta.1), else the short one.
version=$(plutil -extract ArgentVersion raw "$app/Contents/Info.plist" 2>/dev/null \
  || plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
work=build/dmg
dmg=build/Argent-$version.dmg

# dmgbuild in its own venv, from the same Python as .venv (3.11 or later).
venv=$work/.venv
lock=scripts/dmg/requirements.lock
if [[ ! -x $venv/bin/dmgbuild || ! -f $venv/.lock || $(<$venv/.lock) != $(shasum -a 256 $lock) ]]; then
  [[ -x .venv/bin/python ]] || { echo "error: .venv is missing; create it with: python3 -m venv .venv" >&2; exit 1; }
  rm -rf "$venv"
  .venv/bin/python -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: -r "$lock"
  shasum -a 256 $lock > "$venv/.lock"
fi

# Stage a clone of the app (cp -c shares its blocks, so even 7 GB costs no disk or time).
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage"
cp -c -R "$app" "$stage/"
staged=$stage/Argent.app
if (( ! with_models )) && [[ -d $staged/Contents/Resources/Models ]]; then
  rm -rf "$staged/Contents/Resources/Models"
  # The helper's own signature is untouched; only the app's seal over its resources changes, with build-app.sh's identity.
  codesign --force --sign "$(scripts/sign-identity.sh)" --options runtime --entitlements App/Argent.entitlements "$staged"
fi
codesign --verify --deep --strict "$staged"
xattr -cr "$staged"

rm -f "$dmg"
"$venv/bin/dmgbuild" -s scripts/dmg/settings.py \
  -D app="$PWD/$staged" -D background="$PWD/App/DMG/background.png" \
  Argent "$dmg"
hdiutil verify -quiet "$dmg"
rm -rf "$stage"

models_note=$( (( with_models )) && echo "with the models" || echo "without the models" )
echo "built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '), $models_note)"
shasum -a 256 "$dmg"

if (( open_after )); then
  open "$dmg"
fi
