#!/bin/zsh
# The Subject models as one download (SubjectModelPack): S3OD-sod, EoMT and ViTMatte-S from build/models, their manifests, and their user-facing
# licence texts (scripts/models/licences), in one reproducible Apple Archive, LZFSE-compressed. Prints its size and SHA-256; with PIN=1 it also
# writes them into Sources/ArgentRoll/SubjectModelPackPins.swift, so the build that installs the pack names this very file.
#
#   scripts/build-subject-models.zsh            build/argent-subject-models-<version>.aar
#   PIN=1 scripts/build-subject-models.zsh      the same, and pin it
#
# Then upload the file, unchanged, as a release asset under the tag subject-models-<version> (SubjectModelPack.current's URL). Before it goes to anyone
# else, read scripts/models/licences/README.md: the pack is offered free and non-commercially only, with its licences shown before download.
set -euo pipefail
# A relative MODELS_DIR is the caller's, so it is made absolute before the script moves to the repository.
models_dir=${MODELS_DIR:+${MODELS_DIR:A}}
cd "${0:A:h}/.."
models_dir=${models_dir:-build/models}
version=1
models=(s3od-sod-sq1024-f16 eomt-sq768-f16 vitmatte-s-c1k-sq1024-f16)
licences=("${(@f)$(<scripts/models/subject-licences.txt)}")
out=build/argent-subject-models-$version.aar
stage=build/.subject-models-$version

cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

for model in $models; do
  [[ -f $models_dir/$model.aimodel/main.hash && -f $models_dir/$model.manifest.json ]] || { echo "error: $models_dir/$model is missing; build it with its scripts/convert-*.zsh" >&2; exit 1 }
  [[ $(shasum -a 256 "$models_dir/$model.aimodel/main.mlirb" | cut -d' ' -f1) == $(xxd -p -c 64 "$models_dir/$model.aimodel/main.hash") ]] || { echo "error: $model's main.mlirb is not its main.hash" >&2; exit 1 }
done
for licence in $licences; do
  [[ -f scripts/models/licences/$licence ]] || { echo "error: scripts/models/licences/$licence is missing" >&2; exit 1 }
done

rm -rf "$stage"
mkdir -p "$stage/Licences"
for model in $models; do
  # A clone fails across volumes; what it left is cleared before the plain copy.
  cp -c -R "$models_dir/$model.aimodel" "$stage/" 2>/dev/null || { rm -rf "$stage/$model.aimodel"; cp -R "$models_dir/$model.aimodel" "$stage/" }
  cp "$models_dir/$model.manifest.json" "$stage/"
done
for licence in $licences; do
  cp "scripts/models/licences/$licence" "$stage/Licences/$licence"
done
find "$stage" -name .DS_Store -delete
# The modes are in the archive too: the same under any umask.
chmod -R u=rwX,go=rX "$stage"

# Strip host- and time-varying metadata fields so rebuilding from the same models produces a byte-identical archive.
rm -f "$out"
aa archive -d "$stage" -o "$out" -a lzfse -exclude-field uid,gid,flg,mtm,btm,ctm,xat,acl -exclude-name .DS_Store
installed=$(du -sk "$stage" | cut -f1)
installed_bytes=$((installed * 1024))
bytes=$(stat -f %z "$out")
sha=$(shasum -a 256 "$out" | cut -d' ' -f1)
[[ $bytes =~ ^[0-9]+$ && $sha =~ ^[0-9a-f]{64}$ && $installed_bytes =~ ^[0-9]+$ ]] || { echo "error: unexpected archive metadata ($bytes, $sha, $installed_bytes)" >&2; exit 1 }
echo "built $out: $bytes bytes, sha256 $sha, $installed_bytes bytes unpacked"
if [[ ${PIN:-0} == 1 ]]; then
  pins=Sources/ArgentRoll/SubjectModelPackPins.swift
  cat > "$pins.tmp" <<EOF
/// The Subject models' archive this build installs (\`SubjectModelPack.current\`). Written by \`PIN=1 scripts/build-subject-models.zsh\`; the file the owner
/// uploads to the release is the one these name.
enum SubjectModelPackPins {
    static let bytes: Int64 = $bytes
    static let sha256 = "$sha"
    static let installedBytes: Int64 = $installed_bytes
}
EOF
  mv "$pins.tmp" "$pins"
  echo "pinned in $pins"
fi
