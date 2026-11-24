#!/bin/zsh
# Signs an assembled Argent.app bundle inside-out (never --deep), with hardened runtime and the app's
# and helper's entitlements, then verifies the whole bundle strictly.
#
# Uses a secure timestamp (--timestamp) for Apple-issued identities (Developer ID Application) as required
# by Apple's notarization service, and --timestamp=none for ad-hoc ("-") or legacy self-signed builds.
#
#   scripts/sign-app.sh path/to/Argent.app [IDENTITY] [--entitlements FILE]
set -euo pipefail

usage() {
  print -u2 "usage: scripts/sign-app.sh APP_BUNDLE [IDENTITY] [--entitlements FILE]"
  exit 2
}

(( $# >= 1 )) || usage
app=${1:A}
shift

root=${0:A:h:h}
identity=""
entitlements=$root/App/Argent.entitlements

while (( $# > 0 )); do
  case $1 in
    --entitlements) (( $# >= 2 )) || usage; entitlements=${2:A}; shift 2 ;;
    *)
      if [[ -z $identity ]]; then
        identity=$1
        shift
      else
        usage
      fi
      ;;
  esac
done

[[ -n $identity ]] || identity=$("$root/scripts/sign-identity.sh")
[[ -d $app ]] || { print -u2 "error: app bundle not found: $app"; exit 1; }
[[ -f $entitlements ]] || { print -u2 "error: entitlements not found: $entitlements"; exit 1; }

# Ad-hoc and self-signed identities cannot use Apple's timestamp authority; Developer ID requires it.
if [[ $identity == - || $identity == "Argent Self-Signed" ]]; then
  timestamp_flag=--timestamp=none
else
  timestamp_flag=--timestamp
fi

sign_args=(--force --sign "$identity" --options runtime "$timestamp_flag")

# Clear Finder/quarantine detritus before sealing so codesign never rejects extended attributes.
xattr -cr "$app"

# 1. Remove's helper first: sandboxed and inheriting the app's sandbox and container.
helper=$app/Contents/MacOS/argent-remove
if [[ -f $helper ]]; then
  codesign "${sign_args[@]}" --entitlements "$root/App/ArgentRemoveHelper.entitlements" "$helper"
fi

# 2. Embedded Sparkle 2 framework inside-out (XPC services and helpers before the framework bundle).
sparkle=$app/Contents/Frameworks/Sparkle.framework
if [[ -d $sparkle ]]; then
  sparkle_v=$sparkle/Versions/B
  [[ -d $sparkle_v/XPCServices/Installer.xpc ]] && codesign "${sign_args[@]}" "$sparkle_v/XPCServices/Installer.xpc"
  [[ -d $sparkle_v/XPCServices/Downloader.xpc ]] && codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle_v/XPCServices/Downloader.xpc"
  [[ -f $sparkle_v/Autoupdate ]] && codesign "${sign_args[@]}" "$sparkle_v/Autoupdate"
  [[ -d $sparkle_v/Updater.app ]] && codesign "${sign_args[@]}" "$sparkle_v/Updater.app"
  codesign "${sign_args[@]}" "$sparkle"
fi

# 3. The app bundle itself, sealing the nested helper, frameworks and resources.
codesign "${sign_args[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
