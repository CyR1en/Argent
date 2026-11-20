#!/bin/zsh
# Clones or updates Argent's design notes, research and records into docs/. They are a separate private
# repository; this public one ignores docs/, and code comments cite the notes by path (docs/<file>).
# Nothing in the build, the app or the tests needs them. Cloning needs read access to the private repository
# through gh or git's own credentials.
#
#   scripts/docs.sh        clone docs/, or bring it up to date
set -euo pipefail
cd "$(dirname "$0")/.."

repo=${ARGENT_DOCS_REPO:-https://github.com/CyR1en/Argent-docs.git}
if [[ -d docs/.git ]]; then
  git -C docs pull --ff-only --quiet
elif [[ -e docs && -n "$(ls -A docs 2>/dev/null)" ]]; then
  echo "error: docs/ exists but is not a checkout of $repo; move it aside first" >&2
  exit 1
elif ! git clone --quiet "$repo" docs; then
  echo "error: could not clone $repo. Argent's notes are private; the app builds and runs without them." >&2
  exit 1
fi
git -C docs log -1 --format="docs/ is at %h (%cd): %s" --date=short
