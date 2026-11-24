#!/bin/zsh
# Packs Argent.app into a drag-to-Applications disk image, build/Argent-<version>.dmg: the app beside an
# Applications link, over the background in App/DMG (rendered by design/dmg/background.py), with the app's icon on
# the volume. dmgbuild, pinned by hash in scripts/dmg/requirements.lock, writes the window's layout, so Finder is
# never scripted. The app and disk image are signed with scripts/sign-identity.sh (Developer ID Application when
# present, else "Argent Self-Signed", else ad-hoc). With --notarize, both the staged Argent.app and the signed
# disk image are notarized with Apple and stapled (scripts/notarize.sh), so Gatekeeper accepts both online and offline.
#
# The image carries the smart masks' and Remove's models that build/Argent.app holds, about 7 GB, so it takes
# minutes. Their weights must not go to anyone else until cleared (decision 24, scripts/README.md): for an image
# that leaves the owner's Macs (and whenever --notarize is used), --no-models leaves out Contents/Resources/Models
# and re-signs the copy, and then Sky says it is unavailable, Subject and Background offer the Subject models'
# download, and Remove says it has no model.
#
#   scripts/build-dmg.sh                            release build, then build/Argent-<version>.dmg with the models
#   scripts/build-dmg.sh --no-models                the same without them
#   scripts/build-dmg.sh --no-models --notarize     signed, notarized and stapled disk image for distribution
#   scripts/build-dmg.sh --skip-build               pack the build/Argent.app already there
#   scripts/build-dmg.sh --skip-build open          ... then mount the image and show its window
set -euo pipefail
cd "$(dirname "$0")/.."

with_models=1
skip_build=0
notarize=0
open_after=0
for arg in "$@"; do
  case $arg in
    --no-models) with_models=0 ;;
    --skip-build) skip_build=1 ;;
    --notarize) notarize=1 ;;
    open) open_after=1 ;;
    *) echo "usage: scripts/build-dmg.sh [--no-models] [--skip-build] [--notarize] [open]" >&2; exit 2 ;;
  esac
done

(( skip_build )) || scripts/build-app.sh release
app=build/Argent.app
[[ -d $app ]] || { echo "error: $app is missing; run scripts/build-app.sh release" >&2; exit 1; }
codesign --verify --deep --strict "$app"

identity=$(scripts/sign-identity.sh)
if (( notarize )) && [[ $identity == - || $identity == "Argent Self-Signed" ]]; then
  echo "error: --notarize requires a Developer ID Application signing identity (got: $identity)" >&2
  exit 1
fi

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
resign=0
if (( ! with_models )) && [[ -d $staged/Contents/Resources/Models ]]; then
  rm -rf "$staged/Contents/Resources/Models"
  resign=1
fi
if (( ! resign )); then
  # Decouple release signing from Models/ removal: if --skip-build staged an ad-hoc, self-signed,
  # or untimestamped copy (or ARGENT_SIGN_IDENTITY overrides the identity), re-sign the staged copy
  # while leaving build/Argent.app untouched.
  if [[ -n ${ARGENT_SIGN_IDENTITY:-} ]]; then
    sign_info=$(codesign -dvv "$staged" 2>&1 || true)
    if [[ $ARGENT_SIGN_IDENTITY == - ]]; then
      [[ $sign_info == *"Signature=adhoc"* ]] || resign=1
    elif [[ $sign_info != *"Authority=$ARGENT_SIGN_IDENTITY"* ]] || { (( notarize )) && [[ $sign_info != *"Timestamp="* ]]; }; then
      resign=1
    fi
  elif (( notarize )); then
    sign_info=$(codesign -dvv "$staged" 2>&1 || true)
    if [[ $sign_info != *"Authority=Developer ID Application:"* || $sign_info != *"Timestamp="* ]]; then
      resign=1
    fi
  fi
fi
if (( resign )); then
  scripts/sign-app.sh "$staged" "$identity"
fi
codesign --verify --deep --strict "$staged"
xattr -cr "$staged"

if (( notarize )); then
  if [[ -d $staged/Contents/Resources/Models ]]; then
    echo "error: refusing to notarize an app carrying local Models/; pass --no-models" >&2
    exit 1
  fi
  sign_info=$(codesign -dvv "$staged" 2>&1)
  if [[ $sign_info != *"Authority=Developer ID Application:"* || $sign_info != *"Timestamp="* ]]; then
    echo "error: --notarize requires a timestamped Developer ID Application signature on $staged" >&2
    print -u2 "$sign_info"
    exit 1
  fi
  # Notarize and staple the .app itself before packing into the DMG so extracted copies carry their own
  # offline ticket (needed for offline first launch and future Sparkle OTA updates).
  scripts/notarize.sh "$staged"
fi

rm -f "$dmg"
"$venv/bin/dmgbuild" -s scripts/dmg/settings.py \
  -D app="$PWD/$staged" -D background="$PWD/App/DMG/background.png" \
  Argent "$dmg"
hdiutil verify -quiet "$dmg"

if [[ $identity != - ]]; then
  if [[ $identity == "Argent Self-Signed" ]]; then
    timestamp_flag=--timestamp=none
  else
    timestamp_flag=--timestamp
  fi
  codesign --force --sign "$identity" "$timestamp_flag" "$dmg"
  codesign --verify --strict "$dmg"
fi

if (( notarize )); then
  scripts/notarize.sh "$dmg"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
fi

rm -rf "$stage"

models_note=$( (( with_models )) && echo "with the models" || echo "without the models" )
notary_note=$( (( notarize )) && echo ", notarized & stapled" || echo "" )
echo "built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '), $models_note$notary_note)"
shasum -a 256 "$dmg"

if (( open_after )); then
  open "$dmg"
fi
