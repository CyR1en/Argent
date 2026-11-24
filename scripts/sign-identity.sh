#!/bin/zsh
# Prints the identity scripts/sign-app.sh, scripts/build-app.sh and scripts/build-dmg.sh sign Argent with:
#   1. ARGENT_SIGN_IDENTITY when set ("-" forces ad-hoc);
#   2. else the single valid "Developer ID Application: ..." identity in a keychain (checked with -v);
#   3. else "Argent Self-Signed" when a keychain holds that legacy self-signed certificate and its key;
#   4. else "-", an ad-hoc signature.
#
# When more than one valid Developer ID Application identity is installed, this exits with an error rather
# than guessing; set ARGENT_SIGN_IDENTITY to a specific name or 40-hex SHA-1 hash to disambiguate.
#
#   scripts/sign-identity.sh
set -euo pipefail

if [[ -n ${ARGENT_SIGN_IDENTITY:-} ]]; then
  print -r -- "$ARGENT_SIGN_IDENTITY"
  exit 0
fi

# -v lists valid, trusted identities with private keys; deduplicate by SHA-1 hash in case the same
# certificate appears in more than one keychain on the search list.
valid=$(security find-identity -v -p codesigning 2>/dev/null || true)
typeset -A dev_id_by_hash=()
for line in ${(f)valid}; do
  if [[ $line =~ '^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(Developer ID Application: [^"]+)"' ]]; then
    dev_id_by_hash[$match[1]]=$match[2]
  fi
done

if (( ${#dev_id_by_hash} == 1 )); then
  print -r -- "${(@v)dev_id_by_hash}"
  exit 0
elif (( ${#dev_id_by_hash} > 1 )); then
  print -u2 "error: multiple valid Developer ID Application identities found; set ARGENT_SIGN_IDENTITY to choose one:"
  for hash name in ${(kv)dev_id_by_hash}; do
    print -u2 "  $hash  $name"
  done
  exit 1
fi

# Legacy self-signed fallback (without -v, since a self-signed certificate is not trusted).
legacy="Argent Self-Signed"
all=$(security find-identity -p codesigning 2>/dev/null || true)
if [[ $all == *\"$legacy\"* ]]; then
  print -r -- "$legacy"
else
  print -r -- "-"
fi
