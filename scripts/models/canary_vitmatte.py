"""The canary of the converted ViTMatte-S: its output hash on one fixed tile, which names what the model computes when the file's own hash cannot (conversions are not byte-deterministic).
Runs the model through the Python Core AI runtime (USE_OS_COREAI=1) and prints:  INPUT <sha256 of the fp16 input tensor>   CANARY <sha256 of the fp16 alpha>
usage: canary_vitmatte.py --model MODEL.aimodel --picture canary-DSC06673.png [--write TENSOR.f16]
The tile is the repository's CC0 canary (scripts/models/canary-DSC06673.png, 768 x 512) centred in the 1024 square with black all round, normalised as the model takes it ((x / 255 - 0.5) / 0.5, the trimap / 255),
planar fp16, 1 x 4 x 1024 x 1024. Its trimap is a rectangle inside the picture: 255 in its interior, 128 in a 32 pixel band along its inside edge, 0 elsewhere (no resampler or distance transform stands between Python and Swift)."""
import argparse, asyncio, hashlib, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
from pathlib import Path
from PIL import Image
SIDE = 1024

def tensor(picture):
    rgb = np.asarray(Image.open(picture).convert("RGB"))
    if rgb.shape != (512, 768, 3): sys.exit(f"the canary picture is {rgb.shape[1]} x {rgb.shape[0]}, not 768 x 512")
    top, left = (SIDE - 512) // 2, (SIDE - 768) // 2
    square = np.zeros((SIDE, SIDE, 3), np.uint8); square[top:top + 512, left:left + 768] = rgb
    tri = np.zeros((SIDE, SIDE), np.uint8)
    y0, y1, x0, x1 = top + 64, top + 512 - 64, left + 64, left + 768 - 64
    tri[y0:y1, x0:x1] = 128
    tri[y0 + 32:y1 - 32, x0 + 32:x1 - 32] = 255
    planar = square.transpose(2, 0, 1).astype(np.float32)
    x = np.concatenate([(planar / np.float32(255) - np.float32(0.5)) / np.float32(0.5), (tri.astype(np.float32) / np.float32(255))[None]], 0)
    return x.astype(np.float16)[None]

async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--model", required=True); ap.add_argument("--picture", required=True); ap.add_argument("--write"); args = ap.parse_args()
    from coreai.runtime import AIModel, NDArray
    x = np.ascontiguousarray(tensor(args.picture))
    print("INPUT " + hashlib.sha256(x.tobytes()).hexdigest(), flush=True)
    if args.write: x[0].tofile(args.write)
    model = await AIModel.load(Path(args.model)); fn = model.load_function("main")
    hashes = set()
    for _ in range(3):
        out = await fn({"image": NDArray(x)}); h = hashlib.sha256()
        h.update(np.ascontiguousarray(out["alpha"].numpy().astype(np.float16)).tobytes())
        hashes.add(h.hexdigest())
    print(("CANARY " + hashes.pop()) if len(hashes) == 1 else "CANARY unstable: %d distinct hashes" % len(hashes), flush=True)
asyncio.run(main())
