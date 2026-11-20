"""The canary of a converted ObjectClear graph: its output hash on one fixed input, which names what the model computes when the file's own hash cannot
(conversions are not byte-deterministic). Runs the model through the Python Core AI runtime (USE_OS_COREAI=1) and prints one line per fact:
  INPUT <sha256 of the float32 inputs, in the graph's input order>
  CANARY <sha256 of the float32 outputs, in the graph's output order>      or  CANARY unstable: N distinct hashes
  SHAPES <the outputs' shapes>
usage: objectclear_canary.py --kind vae_decoder|vae_encoder|object_encoder|unet --model MODEL.aimodel

The input is arithmetic, so that Swift builds the same bytes with no file and no resampler between it and Python. Value i of a tensor (C order) is
    ((i + salt) * 2654435761 mod 2^32) >> 8, as a float32, / 2^24 * 2 - 1        in [-1, 1), every step exact in float32
with a salt a tensor. The picture is 512 high and 768 wide (latents 64 x 96), a size no recorded run has:
  vae_decoder      latents 1 x 4 x 64 x 96 (salt 1)
  vae_encoder      picture 1 x 3 x 512 x 768 (salt 2)
  object_encoder   object 1 x 3 x 224 x 224 (salt 3)
  unet             sample 1 x 9 x 64 x 96 (salt 4), timestep [501], states 1 x 77 x 2048 (salt 5), pooled 1 x 1280 (salt 6), time_ids [512, 768, 0, 0, 512, 768]
Outputs are hashed as float32, little-endian, C order, one after the other."""
import argparse, asyncio, hashlib, warnings
warnings.filterwarnings("ignore")
import numpy as np
from pathlib import Path

HEIGHT, WIDTH = 512, 768
ORDER = {"vae_decoder": (["latents"], ["picture"]), "vae_encoder": (["picture"], ["moments"]), "object_encoder": (["object"], ["fused", "embeds"]),
         "unet": (["sample", "timestep", "states", "pooled", "time_ids"], ["noise", "attention"])}


def pattern(shape, salt):
    i = np.arange(int(np.prod(shape)), dtype=np.uint64)
    v = (((i + np.uint64(salt)) * np.uint64(2654435761)) & np.uint64(0xFFFFFFFF)) >> np.uint64(8)
    return (v.astype(np.float32) / np.float32(1 << 24) * np.float32(2) - np.float32(1)).reshape(shape)


def inputs(kind):
    h, w = HEIGHT // 8, WIDTH // 8
    if kind == "vae_decoder": return {"latents": pattern((1, 4, h, w), 1)}
    if kind == "vae_encoder": return {"picture": pattern((1, 3, HEIGHT, WIDTH), 2)}
    if kind == "object_encoder": return {"object": pattern((1, 3, 224, 224), 3)}
    return {"sample": pattern((1, 9, h, w), 4), "timestep": np.array([501], np.float32), "states": pattern((1, 77, 2048), 5), "pooled": pattern((1, 1280), 6),
            "time_ids": np.array([[HEIGHT, WIDTH, 0, 0, HEIGHT, WIDTH]], np.float32)}


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--kind", required=True, choices=list(ORDER)); ap.add_argument("--model", required=True); args = ap.parse_args()
    from coreai.runtime import AIModel, NDArray
    names_in, names_out = ORDER[args.kind]; x = inputs(args.kind); h = hashlib.sha256()
    for name in names_in: h.update(np.ascontiguousarray(x[name], dtype="<f4").tobytes())
    print("INPUT " + h.hexdigest(), flush=True)
    model = await AIModel.load(Path(args.model)); fn = model.load_function("main")
    hashes = set(); shapes = None; finite = True
    for _ in range(3):
        out = await fn({name: NDArray(np.ascontiguousarray(x[name])) for name in names_in}); h = hashlib.sha256()
        for name in names_out:
            a = np.ascontiguousarray(out[name].numpy(), dtype="<f4"); h.update(a.tobytes()); finite = finite and bool(np.isfinite(a).all())
        hashes.add(h.hexdigest()); shapes = {name: list(out[name].numpy().shape) for name in names_out}
    print("SHAPES " + " ".join(f"{k}={'x'.join(map(str, v))}" for k, v in shapes.items()), flush=True)
    if not finite: print("CANARY not finite", flush=True)
    else: print(("CANARY " + hashes.pop()) if len(hashes) == 1 else "CANARY unstable: %d distinct hashes" % len(hashes), flush=True)
asyncio.run(main())
