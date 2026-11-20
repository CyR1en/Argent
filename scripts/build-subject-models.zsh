#!/bin/zsh
# The Subject models as one download (SubjectModelPack): S3OD-sod, EoMT and ViTMatte-S from build/models, their manifests, and the licence texts
# (scripts/models/licences), in one Apple Archive, LZFSE-compressed. Prints its size and SHA-256; with PIN=1 it also writes them into
# Sources/ArgentRoll/SubjectModelPackPins.swift, so the build that installs the pack names this very file.
#
#   scripts/build-subject-models.zsh            build/argent-subject-models-<version>.aar
#   PIN=1 scripts/build-subject-models.zsh      the same, and pin it
#
# Then upload the file, unchanged, as a release asset under the tag subject-models-<version> (SubjectModelPack.current's URL). Before it goes to anyone
# else, read scripts/models/licences/README.md: the pack is offered free and non-commercially only, with its licences shown before download.
set -euo pipefail
cd "${0:A:h}/.."
version=1
models=(s3od-sod-sq1024-f16 eomt-sq768-f16 vitmatte-s-c1k-sq1024-f16)
out=build/argent-subject-models-$version.aar
stage=build/.subject-models-$version
models_dir=${MODELS_DIR:-build/models}

for model in $models; do
  [[ -f $models_dir/$model.aimodel/main.hash && -f $models_dir/$model.manifest.json ]] || { echo "error: $models_dir/$model is missing; build it with its scripts/convert-*.zsh" >&2; exit 1 }
  [[ $(shasum -a 256 $models_dir/$model.aimodel/main.mlirb | cut -d' ' -f1) == $(xxd -p -c 64 $models_dir/$model.aimodel/main.hash) ]] || { echo "error: $model's main.mlirb is not its main.hash" >&2; exit 1 }
done
rm -rf $stage; mkdir -p $stage
for model in $models; do
  cp -c -R $models_dir/$model.aimodel $stage/
  cp $models_dir/$model.manifest.json $stage/
done
cp -R scripts/models/licences $stage/Licences
rm -f $out
aa archive -d $stage -o $out -a lzfse
installed=$(du -sk $stage | cut -f1)
rm -rf $stage
bytes=$(stat -f %z $out)
sha=$(shasum -a 256 $out | cut -d' ' -f1)
echo "built $out: $bytes bytes, sha256 $sha, $((installed * 1024)) bytes unpacked"
if [[ ${PIN:-0} == 1 ]]; then
  pins=Sources/ArgentRoll/SubjectModelPackPins.swift
  sed -i '' -E "s/(static let bytes: Int64 = )[0-9]+/\1$bytes/; s/(static let sha256 = \")[0-9a-f]+/\1$sha/; s/(static let installedBytes: Int64 = )[0-9]+/\1$((installed * 1024))/" $pins
  echo "pinned in $pins"
fi
