#!/bin/zsh
# Prints the identity scripts/build-app.sh and scripts/build-dmg.sh sign Argent.app with:
#   ARGENT_SIGN_IDENTITY when set ("-" forces ad-hoc);
#   else "Argent Self-Signed" when a keychain holds that certificate;
#   else "-", an ad-hoc signature.
#
# "Argent Self-Signed" is a self-signed code-signing certificate, the same on the owner's Macs and in CI (the secrets
# SIGNING_P12 and SIGNING_P12_PASSWORD, .github/workflows/dmg.yml). It makes the app's designated requirement
# `identifier "camera.argent.Argent" and certificate leaf = H"..."`, the same for every build, so macOS takes a new build
# for the same app (its permissions and its container) where an ad-hoc signature's requirement is that one build's hash.
# Gatekeeper trusts it no more than ad-hoc: a downloaded copy still asks once, in Privacy & Security > Open Anyway.
#
#   scripts/sign-identity.sh
set -euo pipefail

name="Argent Self-Signed"
if [[ -n ${ARGENT_SIGN_IDENTITY:-} ]]; then
  print -r -- "$ARGENT_SIGN_IDENTITY"
elif security find-certificate -c "$name" >/dev/null 2>&1; then
  print -r -- "$name"
else
  print -r -- "-"
fi
