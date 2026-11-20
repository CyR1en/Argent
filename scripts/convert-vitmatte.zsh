#!/bin/zsh
# Builds Argent's Subject matting model for low light: ViTMatte-S (Composition-1k), Core AI fp16, one fixed 1 x 4 x 1024 x 1024 tile (RGB normalised mean 0.5 std 0.5, trimap in 0...1),
# output "alpha" (1 x 1 x 1024 x 1024 fp16) (docs/masking-plan.md decisions 23 and 24; research task Y2's recipe, moved here). Writes, beside the other models:
#   build/models/vitmatte-s-c1k-sq1024-f16.aimodel          a folder: main.mlirb, main.hash, metadata.json
#   build/models/vitmatte-s-c1k-sq1024-f16.manifest.json    what made it, and its identity: recipe id, weights SHA-256, canary output hash
#   build/models/licences/                                  the texts that travel with the models (scripts/models/licences/README.md)
# Pinned: exactly the 29 hash-locked packages of the Sky model's recipe (scripts/models/requirements.lock), the weights by SHA-256, the graph in scripts/models/vitmatte_port.py (Y2's
# check_port.py: at most 6.4e-6 from transformers). A conversion is not byte-deterministic; what it computes is, and the canary output hash checks it.
#
#   scripts/convert-vitmatte.zsh [OUT]      OUT defaults to build/models
#   FORCE=1 rebuilds an existing model.  MODELS_WORK=DIR keeps the venv and downloads there instead of OUT/.work (shared with the other models').
# Needs macOS on Apple silicon, Homebrew Python 3.14 and the network once (PyPI, Hugging Face).
set -euo pipefail
zmodload zsh/datetime
here=${0:A:h}
recipe=$here/models
out=${1:-$here/../build/models}; mkdir -p "$out"; out=${out:A}
work=${MODELS_WORK:-$out/.work}; mkdir -p "$work"; work=${work:A}
venv=$work/venv
name=vitmatte-s-c1k-sq1024-f16
RECIPE_ID=vitmatte-s-c1k-sq1024-f16-alpha-1

# ---- pins ---------------------------------------------------------------------------------------------------------------
PYTHON=${MODELS_PYTHON:-/opt/homebrew/opt/python@3.14/bin/python3.14}     # tested: Homebrew Python 3.14
WEIGHTS_URL=https://huggingface.co/hustvl/vitmatte-small-composition-1k/resolve/6a58ad7646403c1df626fbd746900aec7361ea1d   # card: license apache-2.0; code MIT at hustvl/ViTMatte (licences/README.md)
WEIGHTS_SHA256=bda9289db1bb6762d978b42d1c62ae3f34daf7497171a347a1d09657efd788cb   # model.safetensors
CANARY_INPUT_SHA256=514b0cd2cf0f4458657f0f860647a3a6ba9dffe229af1895c3087e1d3926dd5d   # the fp16 tile canary_vitmatte.py makes from canary-DSC06673.png
CANARY_SHA256=a5d9b7870abc021a26617e03470e158956030a1473072a43632d7ac59564e23e          # fp16 alpha on it (the file Y2 measured, 2026-11-09)

fail() { print -u2 "error: $*"; exit 1 }
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
fetch() {   # url dest sha256
  if [[ -f $2 && $(sha "$2") == $3 ]]; then return; fi
  rm -f "$2"; curl -L --fail --retry 3 -sS -o "$2" "$1"
  [[ $(sha "$2") == $3 ]] || fail "$2 does not match its pinned SHA-256 $3"
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "needs macOS on Apple silicon (the lock has macOS arm64 wheels)"
[[ -x $PYTHON ]] || fail "no $PYTHON (brew install python@3.14)"
[[ $($PYTHON -I -c 'import sys; print("%d.%d" % sys.version_info[:2])') == 3.14 ]] || fail "$PYTHON is not Python 3.14"
if [[ -d $out/$name.aimodel && ${FORCE:-0} != 1 ]]; then print "$out/$name.aimodel exists (FORCE=1 rebuilds)"; exit 0; fi

# ---- environment: exactly the locked packages ----------------------------------------------------------------------------
if [[ ! -x $venv/bin/python ]]; then $PYTHON -m venv "$venv"; fi
"$venv/bin/python" -I -m pip install -q --disable-pip-version-check --require-hashes --no-deps -r "$recipe/requirements.lock"
"$venv/bin/python" -I -m pip check

# ---- inputs, in their own directory, verified -------------------------------------------------------------------------------
mkdir -p "$work/downloads/vitmatte-s-c1k"
fetch "$WEIGHTS_URL/model.safetensors" "$work/downloads/vitmatte-s-c1k/model.safetensors" $WEIGHTS_SHA256

# ---- convert, from a folder of its own with a scrubbed environment -----------------------------------------------------------
tmp=$out/.$name.tmp.aimodel
t0=$EPOCHREALTIME
(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin SWIFT_DETERMINISTIC_HASHING=1 \
  "$venv/bin/python" -I -B "$recipe/convert_vitmatte.py" --weights "$work/downloads/vitmatte-s-c1k/model.safetensors" --out "$tmp" --dtype float16)
t1=$EPOCHREALTIME
mlirb=$tmp/main.mlirb
msha=$(sha "$mlirb")
[[ $msha == $(xxd -p -c 64 "$tmp/main.hash") ]] || fail "main.hash is not main.mlirb's SHA-256"

# ---- identity: the canary's output hash ------------------------------------------------------------------------------------
canary_out=$(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin USE_OS_COREAI=1 \
  "$venv/bin/python" -I -B "$recipe/canary_vitmatte.py" --model "$tmp" --picture "$recipe/canary-DSC06673.png" 2>/dev/null)
canary_input=${${(M)${(f)canary_out}:#INPUT *}#INPUT }
canary=${${(M)${(f)canary_out}:#CANARY *}#CANARY }
[[ $canary_input == $CANARY_INPUT_SHA256 ]] || fail "canary input $canary_input is not the pinned $CANARY_INPUT_SHA256"
[[ $canary == $CANARY_SHA256 ]] || fail "canary output hash $canary is not the pinned $CANARY_SHA256: this model computes something else"
rm -rf "$out/$name.aimodel"
mv "$tmp" "$out/$name.aimodel"

# ---- licences and record -----------------------------------------------------------------------------------------------------
mkdir -p "$out/licences"
cp "$recipe"/licences/*(.) "$out/licences/"
"$venv/bin/python" -I - "$out/$name.manifest.json" "$RECIPE_ID" "$msha" "$(stat -f %z "$out/$name.aimodel/main.mlirb")" "$(du -sk "$out/$name.aimodel" | cut -f1)" \
  "$(sha "$recipe/requirements.lock")" "$(sha "$recipe/convert_vitmatte.py")" "$(sha "$recipe/vitmatte_port.py")" "$WEIGHTS_SHA256" "$canary_input" "$canary" \
  "$(printf '%.1f' $((t1 - t0)))" "$(sw_vers -buildVersion)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
(path, rid, sha, size, kb, lock, conv, port, w, cin, cout, secs, build, when) = sys.argv[1:]
json.dump({"recipe id": rid, "weights sha256": w, "canary input sha256": cin, "canary output sha256": cout, "main.mlirb sha256": sha, "main.mlirb bytes": int(size), "bundle KiB": int(kb),
           "requirements.lock sha256": lock, "convert_vitmatte.py sha256": conv, "vitmatte_port.py sha256": port, "conversion seconds": float(secs), "converted on macOS build": build, "converted at": when,
           "note": "not byte-deterministic: random symbol suffixes in the last ~16 KB of main.mlirb; the numbers computed are identical across conversions (the canary hash)"},
          open(path, "w"), indent=1)
PY
print "built $out/$name.aimodel  ($(stat -f %z "$out/$name.aimodel/main.mlirb") bytes in main.mlirb, sha256 $msha, canary $canary, conversion $(printf '%.1f' $((t1 - t0))) s)"
