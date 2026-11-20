#!/bin/zsh
# Builds Remove's model: ObjectClear (SDXL inpainting with a CLIP image encoder, github.com/zjx0101/ObjectClear) as four Core AI graphs and one small file,
# with no text encoder (docs/remove-plan.md section 4.5; package H1). Writes, beside the other models:
#   build/models/objectclear-vae-decoder.aimodel      latents 1 x 4 x h x w              -> picture 1 x 3 x 8h x 8w
#   build/models/objectclear-vae-encoder.aimodel      picture 1 x 3 x H x W              -> moments 1 x 8 x H/8 x W/8
#   build/models/objectclear-object-encoder.aimodel   object 1 x 3 x 224 x 224           -> fused 1 x 2048, embeds 1 x 768     (CLIP ViT-L/14 vision and the fusion module)
#   build/models/objectclear-unet.aimodel             sample, timestep, states, pooled, time_ids -> noise 1 x 4 x h x w, attention 1 x 1 x h/2 x w/2
#   build/models/objectclear-<graph>.manifest.json    what made each, and its identity: recipe id, weights SHA-256, canary output hash
#   build/models/objectclear-text-states.f16, .json   the fixed prompt's states and pooled state, half floats (objectclear_text_states.py)
#   build/models/licences/                            the texts that travel with the models
# Each .aimodel is a folder: main.mlirb, main.hash, metadata.json. All four are half precision inside and float32 at their inputs and outputs.
# Sizes: the three graphs that see the picture have a symbolic height and width, any multiple of 16 from 64 to 1344, in one function, `main`. So one
# file serves every working size; what that costs at run time is in the manifest's notes and in objectclear_convert.py.
# Pinned: exactly the 29 hash-locked packages of the Sky model's recipe (scripts/models/requirements.lock, nothing added), the six weight files by
# SHA-256, the graphs in scripts/models/objectclear_port.py (a port of ObjectClear at the commit below and of the diffusers and transformers modules it
# uses). A conversion is not byte-deterministic; what it computes is, and the canary output hashes check it.
#
#   scripts/convert-objectclear.zsh [OUT]      OUT defaults to build/models
#   FORCE=1 rebuilds what exists.  MODELS_WORK=DIR keeps the venv and downloads there instead of OUT/.work (shared with the other models').
#   OBJECTCLEAR_WEIGHTS=DIR uses a local copy of the weights' ObjectClear folder (each file still checked) instead of downloading 7.8 GB.
#   GOLDENS=DIR also compares every graph, and the whole job, with the recorded tensors there, and fails under 35 dB (docs/remove-plan.md section 7).
#   MEMORY_LIMIT_GB=18 stops a step whose memory, resident or footprint, passes it. The UNet's conversion peaks at 11.3 GB of footprint and 13.9 GB
#   resident (measured): run nothing large beside it.
# Needs macOS 27 on Apple silicon, Homebrew Python 3.14 and the network once (PyPI, Hugging Face).
set -euo pipefail
setopt extendedglob
zmodload zsh/datetime
here=${0:A:h}
recipe=$here/models
out=${1:-$here/../build/models}; mkdir -p "$out"; out=${out:A}
work=${MODELS_WORK:-$out/.work}; mkdir -p "$work"; work=${work:A}
venv=$work/venv
limit=${MEMORY_LIMIT_GB:-18}

# ---- pins ---------------------------------------------------------------------------------------------------------------
PYTHON=${MODELS_PYTHON:-/opt/homebrew/opt/python@3.14/bin/python3.14}     # tested: Homebrew Python 3.14
RECIPE_ID=objectclear-c052d91-sym64to1344-f16-1      # with the graph's name it is a manifest's recipe id
OBJECTCLEAR_COMMIT=c052d91ecd8772744a5ab97527441c813ab83009            # github.com/zjx0101/ObjectClear: what objectclear_port.py ports, and whose LICENSE is copied
WEIGHTS_URL=https://huggingface.co/jixin0101/ObjectClear/resolve/c73af80888dbd519819d0a521b5c8d0f3cda6859     # NTU S-Lab License 1.0: non-commercial
typeset -A WEIGHTS=(
  unet/diffusion_pytorch_model.fp16.safetensors   fb0c35b0be8bba4ecd61dfca4e716a0a9878639c5fc271a05a780b4dc2366c31    # 5135178536 bytes
  vae/diffusion_pytorch_model.fp16.safetensors    4ad62825e5c8b31eefb77355ba6693785619bf7d669d9b1a6fd9f19dec6d65b3    # 167335338
  image_prompt_encoder/model.fp16.safetensors     0ebf6aa2b0f8db475ca7bd1148fcc2dc131f989cb452a45103ff23e3ece825c8    # 855304146
  postfuse_module/model.fp16.safetensors          3e3f1dca78cfe25f36ff8b9a8b16ab52cfd0982c81afd04864cace1e4c2afaaf    # 28348576
  text_encoder/model.fp16.safetensors             fc83cf401d930147807e7c44021c164bcc5508c9d4cc0ff35f4e354685ca9cd0    # 246144867: read once, for the text states
  text_encoder_2/model.fp16.safetensors           a8622bd41f8d359df484fdf9de091edb9337a2fd747f0a5c9c320a62e24d1fd3    # 1389382884: the same
)
typeset -A USES=(      # which weight files a graph is made of: its manifest's weights SHA-256
  vae_decoder "vae/diffusion_pytorch_model.fp16.safetensors"  vae_encoder "vae/diffusion_pytorch_model.fp16.safetensors"
  object_encoder "image_prompt_encoder/model.fp16.safetensors postfuse_module/model.fp16.safetensors"  unet "unet/diffusion_pytorch_model.fp16.safetensors"
)
LICENCE_SHA256=73c84d2c2ebcdde03cb7fc853aaec0d4b3b280ee8b47f98a3d6c1931430d5aae     # LICENSE at that commit, kept as scripts/models/licences/ObjectClear-LICENSE-S-Lab-1.0.txt
TEXT_STATES_SHA256=1e180c5ec607d149b4e3b4cb839f5f67e7a8c6df7b95aa5964cb0d94cfef6a80     # objectclear-text-states.f16: the same on two runs (2026-11-16)
typeset -A CANARY_INPUT=(     # the float32 inputs objectclear_canary.py makes by arithmetic
  vae_decoder f5b3d43b0790c8b78450438ca8440688e2378047877413e55eba504fac05a9b5  vae_encoder 376d63130e3e5118e2a5658b610d56332ad2eb751da1b6d829fca4ec88dce261
  object_encoder b50897a8bdea79c915def9c8c8e8808464cf5085b0af8fe3dc0461fc1ce2348c  unet 249e704421cd2f63beaa597856d5e39777e406f1402384bda1eedd5b6eb621e0
)
typeset -A CANARY=(           # the float32 outputs on them: the same across conversions (2026-11-16; the three small graphs five times, the UNet four)
  vae_decoder cc781c1c5e6e0129ab0a8f5f761db9c1f490040a060ba75fbe81862853ec0bbe  vae_encoder 539a7d750adf0abd113940bfd58db5ee2d1080b71563db429c3ebacfaf2cb890
  object_encoder c428d36849a4be7e69efb5f3232b29e5490ce7a2cb4fd4272669591df7e82f91  unet 2bb82a3ae1d28130a0de4fa07a624af7804a6cb9359f8d45ee7c4327a766c9b4
)

fail() { print -u2 "error: $*"; exit 1 }
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
fetch() {   # url dest sha256
  if [[ -f $2 && $(sha "$2") == $3 ]]; then return; fi
  rm -f "$2"; mkdir -p "${2:h}"; curl -L --fail --retry 3 -sS -o "$2" "$1"
  [[ $(sha "$2") == $3 ]] || fail "$2 does not match its pinned SHA-256 $3"
}
footprint_kb() {   # pid: the largest of what it and its children hold, resident or as footprint (which counts the GPU's memory and what is compressed)
  local pid=$1 rss top
  rss=$(ps -axo ppid=,pid=,rss= | awk -v p=$pid '$1 == p || $2 == p { s += $3 } END { print s + 0 }')
  top=$(for p in $pid $(pgrep -P $pid 2>/dev/null); do top -l 1 -pid $p -stats mem 2>/dev/null | tail -1; done | awk '
    { v = $1; u = substr(v, length(v)); sub(/[BKMGT]\+?-?$/, "", v); m = (u == "G" ? 1048576 : u == "M" ? 1024 : u == "K" ? 1 : u == "T" ? 1073741824 : 0); if (v * m > best) best = v * m } END { print int(best + 0) }')
  print $(( rss > top ? rss : top ))
}
guarded() {   # log cmd...: the command under /usr/bin/time -l, stopped if its memory passes $limit GB
  local log=$1; shift
  /usr/bin/time -l "$@" > "$log" 2>&1 &
  local pid=$! kb
  while kill -0 $pid 2>/dev/null; do
    kb=$(footprint_kb $pid)
    if (( kb > limit * 1048576 )); then pkill -P $pid || true; kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; fail "stopped at $(( kb / 1048576 )) GB, over MEMORY_LIMIT_GB=$limit: $log"; fi
    sleep 1
  done
  wait $pid || { tail -25 "$log" >&2; fail "failed: $log" }
}
peak() { awk '/peak memory footprint/ { print $1 }' "$1" | tail -1 }     # bytes, from time -l

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "needs macOS on Apple silicon (the lock has macOS arm64 wheels)"
[[ -x $PYTHON ]] || fail "no $PYTHON (brew install python@3.14)"
[[ $($PYTHON -I -c 'import sys; print("%d.%d" % sys.version_info[:2])') == 3.14 ]] || fail "$PYTHON is not Python 3.14"

# ---- environment: exactly the locked packages ----------------------------------------------------------------------------
if [[ ! -x $venv/bin/python ]]; then $PYTHON -m venv "$venv"; fi
"$venv/bin/python" -I -m pip install -q --disable-pip-version-check --require-hashes --no-deps -r "$recipe/requirements.lock"
"$venv/bin/python" -I -m pip check
py=("$venv/bin/python" -I -B)
clean=(env -i HOME=$HOME PATH=/usr/bin:/bin)
logs=$work/logs/objectclear; mkdir -p "$logs"

# ---- inputs, in their own directory, verified -------------------------------------------------------------------------------
weights=${OBJECTCLEAR_WEIGHTS:-$work/downloads/objectclear/ObjectClear}
for rel digest in ${(kv)WEIGHTS}; do
  if [[ -n ${OBJECTCLEAR_WEIGHTS:-} ]]; then [[ -f $weights/$rel && $(sha "$weights/$rel") == $digest ]] || fail "$weights/$rel is not the pinned $digest"
  else fetch "$WEIGHTS_URL/$rel" "$weights/$rel" $digest; fi
done
[[ $(sha "$recipe/licences/ObjectClear-LICENSE-S-Lab-1.0.txt") == $LICENCE_SHA256 ]] || fail "scripts/models/licences/ObjectClear-LICENSE-S-Lab-1.0.txt is not ObjectClear's LICENSE at $OBJECTCLEAR_COMMIT"

# ---- the fixed text states ------------------------------------------------------------------------------------------------------
if [[ ! -f $out/objectclear-text-states.f16 || ${FORCE:-0} == 1 ]]; then
  states=$(cd "$work" && $clean $py "$recipe/objectclear_text_states.py" --weights "$weights" --out "$out" | awk '/^STATES / { print $2 }')
  [[ $states == $TEXT_STATES_SHA256 ]] || fail "the text states hash to $states, not the pinned $TEXT_STATES_SHA256"
  print "built $out/objectclear-text-states.f16  ($(stat -f %z "$out/objectclear-text-states.f16") bytes, sha256 $states)"
fi

# ---- the four graphs, smallest first, one at a time ------------------------------------------------------------------------------
for graph in vae_decoder vae_encoder object_encoder unet; do
  name=objectclear-${graph//_/-}
  if [[ -d $out/$name.aimodel && ${FORCE:-0} != 1 ]]; then print "$out/$name.aimodel exists (FORCE=1 rebuilds)"; continue; fi
  tmp=$out/.$name.tmp.aimodel
  t0=$EPOCHREALTIME
  (cd "$work" && guarded "$logs/convert-$graph.log" $clean SWIFT_DETERMINISTIC_HASHING=1 $py "$recipe/objectclear_convert.py" --graph $graph --weights "$weights" --out "$tmp" \
     --dtype float16 --dynamic --min-side 64 --max-side 1344)
  t1=$EPOCHREALTIME
  mlirb=$tmp/main.mlirb
  msha=$(sha "$mlirb")
  [[ $msha == $(xxd -p -c 64 "$tmp/main.hash") ]] || fail "main.hash is not main.mlirb's SHA-256"

  # identity: the canary's output hash
  (cd "$work" && guarded "$logs/canary-$graph.log" $clean USE_OS_COREAI=1 $py "$recipe/objectclear_canary.py" --kind $graph --model "$tmp")
  canary_out=$(<"$logs/canary-$graph.log")
  canary_input=${${(M)${(f)canary_out}:#INPUT *}#INPUT }
  canary=${${(M)${(f)canary_out}:#CANARY *}#CANARY }
  shapes=${${(M)${(f)canary_out}:#SHAPES *}#SHAPES }
  [[ $canary == [0-9a-f](#c64) ]] || fail "$graph: the canary gave '$canary' ($logs/canary-$graph.log)"
  if [[ ${OBJECTCLEAR_PIN:-check} == print ]]; then print "PIN $graph input $canary_input output $canary"
  else
    [[ $canary_input == ${CANARY_INPUT[$graph]} ]] || fail "$graph: canary input $canary_input is not the pinned ${CANARY_INPUT[$graph]}"
    [[ $canary == ${CANARY[$graph]} ]] || fail "$graph: canary output hash $canary is not the pinned ${CANARY[$graph]}: this model computes something else"
  fi
  rm -rf "$out/$name.aimodel"
  mv "$tmp" "$out/$name.aimodel"

  used=(); for rel in ${=USES[$graph]}; do used+=("$rel=${WEIGHTS[$rel]}"); done
  $py - "$out/$name.manifest.json" "$RECIPE_ID-$graph" "$msha" "$(stat -f %z "$out/$name.aimodel/main.mlirb")" "$(du -sk "$out/$name.aimodel" | cut -f1)" \
    "$(sha "$recipe/requirements.lock")" "$(sha "$recipe/objectclear_convert.py")" "$(sha "$recipe/objectclear_port.py")" "$(sha "$recipe/objectclear_canary.py")" \
    "$canary_input" "$canary" "$shapes" "$(printf '%.1f' $((t1 - t0)))" "$(peak "$logs/convert-$graph.log")" "$(peak "$logs/canary-$graph.log")" \
    "$(sw_vers -buildVersion)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OBJECTCLEAR_COMMIT" "$graph" $used <<'PY'
import json, sys
(path, rid, sha, size, kb, lock, conv, port, canary_py, cin, cout, shapes, secs, peak, canary_peak, build, when, commit, graph) = sys.argv[1:20]
weights = dict(w.split("=") for w in sys.argv[20:])
io = {"vae_decoder": (["latents"], ["picture"]), "vae_encoder": (["picture"], ["moments"]), "object_encoder": (["object"], ["fused", "embeds"]),
      "unet": (["sample", "timestep", "states", "pooled", "time_ids"], ["noise", "attention"])}[graph]
json.dump({"recipe id": rid, "weights sha256": weights if len(weights) > 1 else next(iter(weights.values())), "weights": weights,
           "canary input sha256": cin, "canary output sha256": cout, "canary output shapes": shapes,
           "main.mlirb sha256": sha, "main.mlirb bytes": int(size), "bundle KiB": int(kb), "function": "main", "inputs": io[0], "outputs": io[1],
           "precision": "float16 inside, float32 at the inputs and outputs",
           "sizes": "224 x 224" if graph == "object_encoder" else "height and width symbolic: any multiple of 16 from 64 to 1344 pixels",
           "requirements.lock sha256": lock, "objectclear_convert.py sha256": conv, "objectclear_port.py sha256": port, "objectclear_canary.py sha256": canary_py,
           "ported from": "github.com/zjx0101/ObjectClear at " + commit, "conversion seconds": float(secs), "conversion peak footprint bytes": int(peak or 0),
           "canary peak footprint bytes": int(canary_peak or 0), "converted on macOS build": build, "converted at": when,
           "note": "not byte-deterministic; the numbers computed are identical across conversions (the canary hash). With symbolic sizes Core AI compiles the graph "
                   "for a size at the first call with it, in every process"},
          open(path, "w"), indent=1)
PY
  print "built $out/$name.aimodel  ($(stat -f %z "$out/$name.aimodel/main.mlirb") bytes in main.mlirb, sha256 $msha, canary $canary, conversion $(printf '%.1f' $((t1 - t0))) s, peak $(( $(peak "$logs/convert-$graph.log") / 1048576 )) MiB)"
done

# ---- licences ------------------------------------------------------------------------------------------------------------------
mkdir -p "$out/licences"
cp "$recipe"/licences/*(.) "$out/licences/"

# ---- parity with the recorded tensors, where they are given -------------------------------------------------------------------------
if [[ -n ${GOLDENS:-} ]]; then
  (cd "$work" && guarded "$logs/parity-graphs.log" $clean USE_OS_COREAI=1 $py "$recipe/objectclear_parity.py" graphs --models "$out" --goldens "$GOLDENS" --json "$out/objectclear-parity-graphs.json")
  (cd "$work" && guarded "$logs/parity-run.log" $clean USE_OS_COREAI=1 $py "$recipe/objectclear_parity.py" run --models "$out" --goldens "$GOLDENS" --json "$out/objectclear-parity-run.json")
  grep -E "PSNR|psnr" "$logs/parity-run.log" || true
  $py - "$out/objectclear-parity-run.json" <<'PY'
import json, sys
worst = min(r["psnr"] for r in json.load(open(sys.argv[1])) if r.get("what") == "fused picture")
print(f"end to end against PyTorch: {worst:.2f} dB at worst over the recorded runs (the gate is 35 dB)")
sys.exit(0 if worst >= 35 else 1)
PY
fi
