#!/bin/sh
# Fetches and verifies the CC0 Sony a7 IV (ILCE-7M4) sample raws listed in
# scripts/samples.manifest (one per compression mode, about 220 MB, from raw.pixls.us) into
# ./samples, for the real-RAW regression suite (docs/ci-regression.md). The samples folder is
# ignored by git.
#
#     scripts/fetch-samples.sh           fetch what is missing or wrong, then verify everything
#     scripts/fetch-samples.sh --check   verify only, no network: exit 1 if any file is
#                                        missing, the wrong size or the wrong SHA-256
#
# A file already in place is kept only if its size and SHA-256 match the manifest; otherwise
# it is fetched again. Downloads go to samples/.incoming/ (hidden, so the roll scanner never
# sees them) and are renamed into place only once verified, so samples/ never holds a partial
# or unverified file. An interrupted download is resumed on the next run; a source that keeps
# serving the wrong bytes fails the run.
#
# For the self-test (scripts/test-regression-tooling.sh): ARGENT_SAMPLES_MANIFEST and
# ARGENT_SAMPLES_DIR replace the manifest and the folder, ARGENT_SAMPLES_PROTOCOLS the
# protocols curl may use (default https only).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${ARGENT_SAMPLES_MANIFEST:-$root/scripts/samples.manifest}
dir=${ARGENT_SAMPLES_DIR:-$root/samples}
protocols=${ARGENT_SAMPLES_PROTOCOLS:-=https}
attempts=3

case "${1:-}" in
  "") mode=fetch ;;
  --check) mode=check ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
[ -f "$manifest" ] || { echo "error: no manifest at $manifest" >&2; exit 1; }

# Read the entire manifest before creating folders or fetching any entry. Each filename
# must be a visible basename, and case-insensitive duplicates collide on a typical Mac disk.
entries=$(awk '
  function reject(message) {
    print "error: " message " in " FILENAME ":" FNR > "/dev/stderr"
    failed = 1
    exit 1
  }
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  {
    if (NF != 4 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[0-9]+$/ \
        || $3 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ \
        || $4 !~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) {
      reject("malformed manifest line for \047" $3 "\047")
    }
    if (seen[tolower($3)]++) reject("duplicate manifest filename \047" $3 "\047")
    print $1, $2, $3, $4
    count++
  }
  END {
    if (!failed && !count) {
      print "error: " FILENAME " lists no files" > "/dev/stderr"
      exit 1
    }
  }
' "$manifest") || exit 1

size_of() { wc -c < "$1" | tr -d ' '; }
sha_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

# Why `$1` does not match size `$2` and SHA-256 `$3`, or nothing if it does.
problem() {
  if [ ! -f "$1" ]; then echo "missing"; return; fi
  have=$(size_of "$1")
  if [ "$have" != "$2" ]; then echo "size $have, want $2"; return; fi
  digest=$(sha_of "$1")
  [ "$digest" = "$3" ] || echo "SHA-256 $digest, want $3"
}

# Downloads `$1` to `$2` (a partial file there is resumed) until it is `$3` bytes with
# SHA-256 `$4`. A failed or wrong attempt that made no progress, or any wrong complete file,
# starts the next attempt from nothing.
download() {
  url=$1 part=$2 size=$3 sha=$4 n=1
  while :; do
    before=0
    if [ -f "$part" ]; then
      before=$(size_of "$part")
      if [ "$before" -gt "$size" ]; then rm -f "$part"; before=0; fi
    fi
    if [ "$before" -lt "$size" ]; then
      [ "$before" -gt 0 ] && echo "resume  $(basename "$part") from byte $before"
      curl -fSL --silent --show-error --proto "$protocols" --proto-redir "$protocols" \
        --connect-timeout 30 --retry 2 --retry-delay 3 -C - -o "$part" "$url" || true
    fi
    why=$(problem "$part" "$size" "$sha")
    [ -z "$why" ] && return 0
    if [ "$n" -ge "$attempts" ]; then
      echo "error: $url: after $n attempts: $why" >&2
      # A complete but wrong file is no use to resume; a short one is kept for the next run.
      [ -f "$part" ] && [ "$(size_of "$part")" -ge "$size" ] && rm -f "$part"
      return 1
    fi
    after=0
    [ -f "$part" ] && after=$(size_of "$part")
    if [ "$after" -ge "$size" ] || [ "$after" -le "$before" ]; then rm -f "$part"; fi
    echo "retry   $(basename "$part"): $why"
    n=$((n + 1))
  done
}

[ "$mode" = check ] || mkdir -p "$dir"
failed=0 count=0
# The validated entries, on descriptor 3 so curl cannot read them.
exec 3<<EOF
$entries
EOF
while read -r sha size name url <&3; do
  count=$((count + 1))
  dest=$dir/$name
  why=$(problem "$dest" "$size" "$sha")
  if [ -z "$why" ]; then
    echo "ok      $name"
    continue
  fi
  if [ "$mode" = check ]; then
    echo "BAD     $name: $why" >&2
    failed=$((failed + 1))
    continue
  fi
  echo "fetch   $name ($why)"
  mkdir -p "$dir/.incoming"
  if download "$url" "$dir/.incoming/$name" "$size" "$sha"; then
    mv -f "$dir/.incoming/$name" "$dest"
    echo "fetched $name"
  else
    failed=$((failed + 1))
  fi
done
exec 3<&-
[ "$mode" = check ] || rmdir "$dir/.incoming" 2>/dev/null || true

if [ "$failed" -gt 0 ]; then
  if [ "$mode" = check ]; then
    echo "error: $failed of $count sample files missing or wrong in $dir; run scripts/fetch-samples.sh" >&2
  else
    echo "error: $failed of $count sample files could not be fetched and verified into $dir" >&2
  fi
  exit 1
fi
echo "verified $count sample files in $dir against $(basename "$manifest")"
