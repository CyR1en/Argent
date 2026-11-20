#!/bin/zsh
# shellcheck disable=SC2034,SC2076,SC2086,SC2128,SC2206,SC2296
# Camera-card disk images for live checks: an exFAT volume named Untitled with the listed raws in DCIM/100MSDCF,
# the folder an a7 IV writes them to. Many lanes mount one image at once: each attach gets its own shadow
# file, so the image itself is never written, and a lane's writes go when it detaches.
#
#   scripts/card-image.zsh make LIST IMAGE        LIST names one raw per line, copied from $ARGENT_CARD_SOURCE
#                                                 (~/Documents/Photography/Titos by default); IMAGE ends .sparseimage
#   scripts/card-image.zsh attach IMAGE LANE      prints the mount point, /Volumes/Untitled or /Volumes/Untitled N
#   scripts/card-image.zsh detach MOUNT           ejects a mount that attach made and deletes its shadow
set -euo pipefail

shadows=${TMPDIR:-/tmp}/argent-card-shadows

die() { print -u2 "card-image: $*"; exit 1; }

shadow_mounts() {
  hdiutil info | awk -F'\t' '
    /^=====/ { shadow = "" }
    /^shadow-path/ { sub(/^shadow-path *: /, ""); shadow = $0 }
    NF >= 3 && $3 ~ /^\// { print shadow "\t" $3 }'
}

mount_with_shadow() { shadow_mounts | awk -F'\t' -v s=$1 '$1 == s { print $2 }'; }

is_mounted() { mount | grep -qF " on $1 ("; }

# A volume that will not eject keeps its files and its image, because deleting them would write through the mount.
clean_build() {
  [[ -n ${build_mount:-} ]] || return 0
  if is_mounted $build_mount && ! diskutil eject $build_mount >/dev/null 2>&1 \
      && ! hdiutil detach -force $build_mount >/dev/null 2>&1; then
    print -u2 "card-image: $build_mount is still attached. Detach it, then delete $build_partial"
  else
    rm -f $build_partial
    rmdir $build_mount 2>/dev/null || true
  fi
  build_mount=
}

make_image() {
  local list=$1 image=$2
  local source=${ARGENT_CARD_SOURCE:-$HOME/Documents/Photography/Titos}
  [[ -f $list ]] || die "no list at $list"
  [[ $image == *.sparseimage ]] || die "the image's name ends .sparseimage: $image"
  [[ -d $source ]] || die "no folder of raws at $source (ARGENT_CARD_SOURCE)"
  local -a names missing copied
  local -aU unique
  local name size bytes=0
  names=(${(f)"$(<$list)"})
  unique=($names)
  (( $#names )) || die "$list names no raws"
  (( $#unique == $#names )) || die "$list names a raw twice"
  for name in $names; do [[ -f $source/$name ]] || missing+=$name; done
  (( $#missing )) && die "not in $source: ${(j:, :)missing}"

  for size in $(stat -f %z $source/${^names}); do (( bytes += size )); done
  build_partial=$image:h/.$image:t
  build_mount=$(mktemp -d ${TMPDIR:-/tmp}/card-image.XXXXXX)
  build_mount=${build_mount:A}
  trap clean_build EXIT
  trap 'clean_build; exit 130' INT
  trap 'clean_build; exit 143' TERM
  rm -f $build_partial
  hdiutil create -quiet -type SPARSE -fs ExFAT -volname Untitled -size $(( bytes * 11 / 10 / 1048576 + 64 ))m $build_partial
  diskutil image attach --nobrowse --mountPoint $build_mount $build_partial >/dev/null
  mkdir -p $build_mount/DCIM/100MSDCF
  cp -pX $source/${^names} $build_mount/DCIM/100MSDCF/
  copied=($build_mount/DCIM/100MSDCF/*)
  (( $#copied == $#names )) || die "copied $#copied raws, not $#names"
  diskutil eject $build_mount >/dev/null
  chmod a-w $build_partial
  mv -f $build_partial $image
  print "$image: $#names raws from $source"
}

attach() {
  local image=$1 lane=$2 shadow mount
  [[ -f $image ]] || die "no image at $image"
  [[ $lane =~ '^[A-Za-z0-9-]+$' ]] || die "a lane id is letters, digits and hyphens: $lane"
  mkdir -p $shadows
  shadow=${shadows:A}/$lane.${image:t:r}.$(print -rn -- ${image:A} | shasum | cut -c1-8).shadow
  mount=$(mount_with_shadow $shadow)
  if [[ -z $mount ]]; then
    rm -f $shadow
    hdiutil attach -quiet -shadow $shadow $image
    mount=$(mount_with_shadow $shadow)
  fi
  [[ -n $mount ]] || die "$image attached with no mount point"
  print -r -- $mount
}

detach() {
  local mount=${1%/} shadow said
  shadow=$(shadow_mounts | awk -F'\t' -v m=$mount '$2 == m { print $1 }')
  [[ $shadow == ${shadows:A}/* ]] || die "$mount is not a card image this script attached"
  said=$(diskutil eject $mount 2>&1) || die "could not eject $mount, so it stays mounted. $said"
  rm -f $shadow
  print "detached $mount"
}

case ${1:-} in
  make) (( $# == 3 )) || die "usage: card-image.zsh make LIST IMAGE"; make_image $2 $3 ;;
  attach) (( $# == 3 )) || die "usage: card-image.zsh attach IMAGE LANE"; attach $2 $3 ;;
  detach) (( $# == 2 )) || die "usage: card-image.zsh detach MOUNT"; detach $2 ;;
  *) die "usage: card-image.zsh make LIST IMAGE | attach IMAGE LANE | detach MOUNT" ;;
esac
