"""The canary of the converted S3OD-sod: its output hash on one fixed picture, which names what the model computes when the file's own hash cannot (conversions are not byte-deterministic).
Runs the model through the Python Core AI runtime (USE_OS_COREAI=1) and prints:  INPUT <sha256 of the fp16 input tensor>   CANARY <sha256 of masks (fp16) then iou (fp32)>
usage: canary_s3od.py --model MODEL.aimodel --picture canary-DSC06673.png [--write TENSOR.f16]
The picture is the repository's CC0 canary (scripts/models/canary-DSC06673.png, 768 x 512) centred in the 1024 square with black all round (no resampler stands between Python and Swift), ImageNet normalised, planar fp16, 1 x 3 x 1024 x 1024."""
import argparse, asyncio, hashlib, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
from pathlib import Path
from PIL import Image
MEAN = np.array([0.485, 0.456, 0.406], np.float32)[:, None, None]
STD = np.array([0.229, 0.224, 0.225], np.float32)[:, None, None]
SIDE = 1024

def tensor(picture):
    rgb = np.asarray(Image.open(picture).convert("RGB"))
    if rgb.shape != (512, 768, 3): sys.exit(f"the canary picture is {rgb.shape[1]} x {rgb.shape[0]}, not 768 x 512")
    square = np.zeros((SIDE, SIDE, 3), np.uint8); top, left = (SIDE - 512) // 2, (SIDE - 768) // 2; square[top:top + 512, left:left + 768] = rgb
    planar = square.transpose(2, 0, 1).astype(np.float32)
    return ((planar / np.float32(255) - MEAN) / STD).astype(np.float16)[None]

async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--model", required=True); ap.add_argument("--picture", required=True); ap.add_argument("--write"); args = ap.parse_args()
    from coreai.runtime import AIModel, NDArray
    x = np.ascontiguousarray(tensor(args.picture))
    print("INPUT " + hashlib.sha256(x.tobytes()).hexdigest(), flush=True)
    if args.write: x[0].tofile(args.write)
    model = await AIModel.load(Path(args.model)); fn = model.load_function("main")
    hashes = set(); shapes = None
    for _ in range(3):
        out = await fn({"image": NDArray(x)}); h = hashlib.sha256()
        h.update(np.ascontiguousarray(out["masks"].numpy().astype(np.float16)).tobytes()); h.update(np.ascontiguousarray(out["iou"].numpy().astype(np.float32)).tobytes())
        hashes.add(h.hexdigest()); shapes = out["masks"].numpy().shape, out["iou"].numpy().tolist()
    print("SHAPES", shapes[0], "IOU", shapes[1], flush=True)
    print(("CANARY " + hashes.pop()) if len(hashes) == 1 else "CANARY unstable: %d distinct hashes" % len(hashes), flush=True)
asyncio.run(main())
