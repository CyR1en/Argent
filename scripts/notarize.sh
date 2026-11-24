#!/bin/zsh
# Submits an .app bundle (zipped temporarily with ditto) or a .dmg to Apple's notary service with
# xcrun notarytool, waits for acceptance, dumps the notarization log on any failure, then staples
# and validates the ticket on the original target.
#
# Authentication priority:
#   1. Explicit flags: --key FILE --key-id ID --issuer UUID   OR   --keychain-profile NAME
#   2. Environment:    ARGENT_NOTARY_KEY, ARGENT_NOTARY_KEY_ID, ARGENT_NOTARY_ISSUER
#   3. Environment:    ARGENT_NOTARY_PROFILE (default: argent-notary)
#
#   scripts/notarize.sh build/Argent.app
#   scripts/notarize.sh build/Argent-0.1.0.dmg --keychain-profile argent-notary
#   scripts/notarize.sh build/Argent-0.1.0.dmg --key /path/to/notary.p8 --key-id ID --issuer UUID
set -euo pipefail

usage() {
  print -u2 "usage: scripts/notarize.sh PATH [--keychain-profile PROFILE | --key P8 --key-id ID --issuer UUID]"
  exit 2
}

(( $# >= 1 )) || usage
target=${1:A}
shift

profile=""
key=""
key_id=""
issuer=""
while (( $# > 0 )); do
  case $1 in
    --keychain-profile) (( $# >= 2 )) || usage; profile=$2; shift 2 ;;
    --key) (( $# >= 2 )) || usage; key=${2:A}; shift 2 ;;
    --key-id) (( $# >= 2 )) || usage; key_id=$2; shift 2 ;;
    --issuer) (( $# >= 2 )) || usage; issuer=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -e $target ]] || { print -u2 "error: notarize target not found: $target"; exit 1; }

# Find Xcode's notarytool when xcode-select points at the Command Line Tools.
if ! xcrun --find notarytool >/dev/null 2>&1; then
  for xcode in /Applications/Xcode*.app(N); do
    if [[ -x $xcode/Contents/Developer/usr/bin/notarytool ]]; then
      export DEVELOPER_DIR=$xcode/Contents/Developer
      break
    fi
  done
fi
xcrun --find notarytool >/dev/null 2>&1 || { print -u2 "error: xcrun notarytool not found; install Xcode"; exit 1; }

# Resolve authentication arguments.
auth_args=()
if [[ -n $key || -n $key_id || -n $issuer ]]; then
  [[ -n $key && -n $key_id && -n $issuer ]] || { print -u2 "error: --key, --key-id and --issuer must all be provided"; exit 2; }
  [[ -f $key ]] || { print -u2 "error: notary API key file not found: $key"; exit 1; }
  auth_args=(--key "$key" --key-id "$key_id" --issuer "$issuer")
elif [[ -n $profile ]]; then
  auth_args=(--keychain-profile "$profile")
elif [[ -n ${ARGENT_NOTARY_KEY:-} || -n ${ARGENT_NOTARY_KEY_ID:-} || -n ${ARGENT_NOTARY_ISSUER:-} ]]; then
  [[ -n ${ARGENT_NOTARY_KEY:-} && -n ${ARGENT_NOTARY_KEY_ID:-} && -n ${ARGENT_NOTARY_ISSUER:-} ]] \
    || { print -u2 "error: ARGENT_NOTARY_KEY, ARGENT_NOTARY_KEY_ID and ARGENT_NOTARY_ISSUER must all be set"; exit 1; }
  [[ -f $ARGENT_NOTARY_KEY ]] || { print -u2 "error: ARGENT_NOTARY_KEY file not found: $ARGENT_NOTARY_KEY"; exit 1; }
  auth_args=(--key "$ARGENT_NOTARY_KEY" --key-id "$ARGENT_NOTARY_KEY_ID" --issuer "$ARGENT_NOTARY_ISSUER")
else
  auth_args=(--keychain-profile "${ARGENT_NOTARY_PROFILE:-argent-notary}")
fi

tmp=""
cleanup() {
  [[ -n $tmp && -d $tmp ]] && rm -rf "$tmp"
}
trap cleanup EXIT

submission=$target
if [[ -d $target && $target == *.app ]]; then
  tmp=$(mktemp -d)
  submission=$tmp/${target:t:r}.zip
  ditto -c -k --sequesterRsrc --keepParent "$target" "$submission"
elif [[ ! -f $target ]]; then
  print -u2 "error: expected an .app bundle or file (.dmg/.pkg), got: $target"
  exit 1
fi

print "notarizing ${target:t}..."
rc=0
output=$(xcrun notarytool submit "$submission" "${auth_args[@]}" --wait --output-format json) || rc=$?

submission_status=$(plutil -extract status raw - <<< "$output" 2>/dev/null || true)
submission_id=$(plutil -extract id raw - <<< "$output" 2>/dev/null || true)

if (( rc != 0 )) || [[ $submission_status != Accepted ]]; then
  print -u2 "error: notarization failed for ${target:t} (exit=$rc, status=${submission_status:-unknown}, id=${submission_id:-none})"
  [[ -n $output ]] && print -u2 "$output"
  if [[ -n $submission_id ]]; then
    print -u2 "--- Apple notarization log ($submission_id) ---"
    xcrun notarytool log "$submission_id" "${auth_args[@]}" >&2 || true
  fi
  exit 1
fi

print "notarization accepted (${target:t}, id $submission_id)"
xcrun stapler staple "$target"
xcrun stapler validate "$target"
