"""The canary of a converted mask model: its output hash on one fixed picture, which names what the model computes when the file's own hash cannot
(conversions are not byte-deterministic). Runs the model through the Python Core AI runtime (USE_OS_COREAI=1) and prints one line per fact:
  INPUT <sha256 of the fp16 input tensor>
  CANARY <sha256 of the fp16 outputs>      or  CANARY unstable: N distinct hashes
usage: canary_check.py --kind da3|eomt --model MODEL.aimodel --picture canary-DSC06673.png

The picture is the CC0 sample ILCE-7M4_DSC06673's neutral print (argent-spike --decoder raw9 --long-edge 2560, as P0-S5 made it), area-resized to
768 x 512: exactly the content of the 768 square S5 hashed (input tensor 3af48f15..., output 63bdb66c...), stored losslessly.
  eomt: the 768 x 512 picture centred in 768 x 768, the edge rows repeated (128 above, 128 below), ImageNet mean and std, planar fp16, 1 x 3 x 768 x 768.
        The output is "maps", 1 x 3 x 192 x 192 fp16 (water, sky, class index), hashed as stored.
  da3:  the picture's centre 756 x 504 (columns 6 to 761, rows 4 to 507: a crop, so no resampler stands between Python and Swift), padded as the
        app pads it (126 rows above and below, repeated), normalised the same way, 1 x 1 x 3 x 756 x 756. The outputs are "sky" then "depth",
        each 756 x 756 fp16, hashed one after the other.
Argent's Swift canary (`MaskModelCanaryTests`) builds the same tensors and must print the same hashes: S1b and S5 found Swift and Python bit-identical
on the same tensor."""
import argparse, asyncio, hashlib, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
from pathlib import Path
from PIL import Image

MEAN = np.array([0.485, 0.456, 0.406], np.float32)[:, None, None]
STD = np.array([0.229, 0.224, 0.225], np.float32)[:, None, None]


def tensor(kind, picture):
    rgb = np.asarray(Image.open(picture).convert("RGB"))
    if rgb.shape != (512, 768, 3):
        sys.exit(f"the canary picture is {rgb.shape[1]} x {rgb.shape[0]}, not 768 x 512")
    if kind == "eomt":
        content, side = rgb, 768
    else:
        content, side = rgb[4:508, 6:762], 756
    top = (side - content.shape[0]) // 2
    square = np.concatenate([np.repeat(content[:1], top, 0), content, np.repeat(content[-1:], side - top - content.shape[0], 0)], 0)
    planar = square.transpose(2, 0, 1).astype(np.float32)
    x = (((planar / np.float32(255)) - MEAN) / STD).astype(np.float16)
    return x.reshape((1, 3, side, side) if kind == "eomt" else (1, 1, 3, side, side))


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", required=True, choices=["da3", "eomt"]); ap.add_argument("--model", required=True); ap.add_argument("--picture", required=True)
    args = ap.parse_args()
    from coreai.runtime import AIModel, NDArray
    x = np.ascontiguousarray(tensor(args.kind, args.picture))
    print("INPUT " + hashlib.sha256(x.tobytes()).hexdigest(), flush=True)
    model = await AIModel.load(Path(args.model)); fn = model.load_function("main")
    names = ["maps"] if args.kind == "eomt" else ["sky", "depth"]
    hashes = set()
    for _ in range(3):
        out = await fn({"image": NDArray(x)}); h = hashlib.sha256()
        for name in names:
            h.update(np.ascontiguousarray(out[name].numpy().astype(np.float16)).tobytes())
        hashes.add(h.hexdigest())
    print(("CANARY " + hashes.pop()) if len(hashes) == 1 else "CANARY unstable: %d distinct hashes" % len(hashes), flush=True)


asyncio.run(main())
