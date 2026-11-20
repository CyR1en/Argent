#!/bin/zsh
# The baked stocks' stamp: a digest of what the bake reads, the bake tool, the profiles and the
# papers. scripts/build-app.sh bakes build/stocks again when it differs from build/stocks/.stamp and
# writes it there; the measurements refuse stocks whose stamp is not bake/'s now.
#
#   scripts/stocks-stamp.sh
set -euo pipefail
cd "$(dirname "$0")/.."
find bake/argent_bake bake/stocks bake/papers -type f \( -name '*.py' -o -name '*.json' -o -name '*.csv' \) -print0 \
  | sort -z | xargs -0 shasum | shasum | cut -c1-16
