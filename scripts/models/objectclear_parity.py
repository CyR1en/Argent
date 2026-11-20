"""Parity of ObjectClear's graphs against the recorded tensors (goldens/README.md), for the port in PyTorch and for the converted models in Core AI.

  objectclear_parity.py port   --weights DIR --goldens DIR [--device cpu|mps] [--dtype float32|float16] [--norm float32] [--graphs ...] [--ranges]
  objectclear_parity.py graphs --models DIR --goldens DIR [--graphs ...] [--compute gpu|cpu|default]
  objectclear_parity.py run    --models DIR --goldens DIR [--runs ...] [--resident --repeat N]     the whole job through the converted graphs: PSNR of the picture
  objectclear_parity.py time   --models DIR --goldens DIR --graphs G --sizes HxW,HxW [--repeat N]     seconds a call, the first and the warm ones
  objectclear_parity.py stress --models DIR --weights DIR --goldens DIR --sizes HxW [--device mps]    the VAE in half precision on pictures made to be hard
  objectclear_parity.py sizes  --half coreai|torch --write DIR --models DIR --weights DIR --goldens DIR --sizes HxW,... [--device mps --dtype float16]
                                                                                 the graphs against the port at other sizes, a half a process

`port` runs objectclear_port.py's modules in PyTorch on the recorded inputs: it proves the port is the reference's graph, and with --ranges prints the
largest value each kind of layer sees, which is what decides where half precision is safe. `graphs` and `run` load the .aimodel folders through the Python
Core AI runtime (USE_OS_COREAI=1), as the canaries do. Every line is one comparison: worst and mean absolute error, the reference's range, and PSNR over
that range for pictures. Needs the conversion's locked packages only."""
import argparse, asyncio, json, os, sys, time, warnings
warnings.filterwarnings("ignore")
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objectclear_reference as ref

RUNS = ["p161-8-1.0", "p161-20-2.5", "p247-8-1.0", "p247-20-2.5"]
GRAPHS = ["vae_decoder", "vae_encoder", "object_encoder", "unet"]


def load(goldens, run, name): return np.load(os.path.join(goldens, run, name + ".npy"))

def psnr(got, want, peak):
    mse = float(((got.astype(np.float64) - want.astype(np.float64)) ** 2).mean())
    return float("inf") if mse == 0 else 10 * np.log10(peak ** 2 / mse)

def line(what, got, want, picture=False):
    got = np.asarray(got, np.float64); want = np.asarray(want, np.float64); assert got.shape == want.shape, (what, got.shape, want.shape)
    d = np.abs(got - want); span = float(want.max() - want.min()); bad = int((~np.isfinite(got)).sum())
    out = {"what": what, "worst": float(np.nanmax(d)) if d.size else 0.0, "mean": float(np.nanmean(d)), "range": [float(want.min()), float(want.max())], "not finite": bad,
           "psnr": psnr(got, want, 2.0 if picture else max(span, 1e-12))}
    print(f"  {what:58s} worst {out['worst']:.3e}  mean {out['mean']:.3e}  range [{out['range'][0]:.3g}, {out['range'][1]:.3g}]  "
          f"psnr {out['psnr']:.1f} dB{' (picture, peak 2)' if picture else ''}{'  NOT FINITE: %d' % bad if bad else ''}", flush=True)
    return out

def attention_reduced(raw):
    """What the UNet graph returns, from the recorded raw attention: the conditional branch's column 5, the mean over its 10 heads, as tokens."""
    return raw[-ref.HEADS:, :, ref.FUSE_INDEX].astype(np.float32).mean(0)

def cases(goldens, run, graph):
    """(name, inputs, expected outputs) for one graph on one run. The UNet is one row a call: both branches of a guided run, each on its own."""
    L = lambda n: load(goldens, run, n); m = json.load(open(os.path.join(goldens, run, "manifest.json"))); steps = m["steps"]; h, w = m["height"] // 8, m["width"] // 8
    if graph == "vae_decoder": return [("decoder", {"latents": L("vae_decoder_input")}, {"picture": L("vae_decoder_output")})]
    if graph == "vae_encoder":   # the two halves apart: the log variance is near -20, where an error changes a standard deviation of 1e-5 and nothing else
        want = L("vae_encoder_moments_picture"); return [("encoder", {"picture": L("vae_encoder_input")}, {"moments": want, "moments, mean": want[:, :4], "moments, log variance": want[:, 4:]})]
    if graph == "object_encoder":
        return [("object", {"object": L("image_encoder_resized")}, {"fused": L("fused_prompt_states")[:, ref.FUSE_INDEX], "embeds": L("object_embeds")[:, 0]})]
    states, pooled, ids = L("unet_encoder_hidden_states"), L("unet_text_embeds"), L("unet_time_ids"); out = []
    for i in sorted({0, 1, steps // 2, steps - 1}):
        sample, eps = L(f"step_{i:02d}/unet_sample"), L(f"step_{i:02d}/unet_out"); t = L(f"step_{i:02d}/unet_timestep").reshape(1).astype(np.float32)
        for row in range(sample.shape[0]):
            branch = "" if sample.shape[0] == 1 else (" unconditional" if row == 0 else " conditional"); want = {"noise": eps[row:row + 1]}
            if i == steps - 1 and row == sample.shape[0] - 1: want["attention"] = attention_reduced(L("attention_raw")).reshape(1, 1, h // 2, w // 2)
            out.append((f"step {i}{branch}", {"sample": sample[row:row + 1], "timestep": t, "states": states[row:row + 1], "pooled": pooled[row:row + 1], "time_ids": ids[row:row + 1]}, want))
    return out

def compare(run, graph, name, got, want, results):
    if "moments" in got: got = dict(got, **{"moments, mean": got["moments"][:, :4], "moments, log variance": got["moments"][:, 4:]})
    for key, expected in want.items():
        r = line(f"{run} {graph} {name}: {key}", got[key], expected, picture=key == "picture"); r.update(run=run, graph=graph, case=name, output=key); results.append(r)
        if key == "attention":   # as the pipeline uses it: stretched to its range, and the byte map's threshold
            h, w = expected.shape[-2:]; stretch = lambda a: ref.attention_bytes((lambda u: (u - u.min()) / (u.max() - u.min()))(ref.half(ref._upsample_bilinear_2x(ref.half(a)))))
            a, b = stretch(np.asarray(got[key], np.float32)), stretch(expected)
            flips = int(((a > 128) != (b > 128)).sum()); print(f"  {'':58s} as the 8-bit map: worst {int(np.abs(a.astype(int) - b.astype(int)).max())} of 255, {flips} of {a.size} cross the fusion's threshold", flush=True)
            results.append({"run": run, "graph": graph, "case": name, "output": "attention bytes", "worst": int(np.abs(a.astype(int) - b.astype(int)).max()), "threshold flips": flips, "of": int(a.size)})


# ---- the port in PyTorch -----------------------------------------------------------------------------------------------------------------------
def build(graph, weights, dtype, norm):
    import torch, objectclear_port as port
    from safetensors.torch import load_file
    f = lambda rel: load_file(os.path.join(weights, rel))
    if graph == "vae_decoder": m = port.VaeDecoder().load_weights(f("vae/diffusion_pytorch_model.fp16.safetensors"))
    elif graph == "vae_encoder": m = port.VaeEncoder().load_weights(f("vae/diffusion_pytorch_model.fp16.safetensors"))
    elif graph == "object_encoder": m = port.ObjectEncoder().load_weights(f("image_prompt_encoder/model.fp16.safetensors"), f("postfuse_module/model.fp16.safetensors"))
    elif graph == "unet": m = port.UNet().load_weights(f("unet/diffusion_pytorch_model.fp16.safetensors"))
    m = m.eval().to(dtype)
    if norm is not None: port.set_norm_dtype(m, norm)
    return m

OUTPUTS = {"vae_decoder": ["picture"], "vae_encoder": ["moments"], "object_encoder": ["fused", "embeds"], "unet": ["noise", "attention"]}

def port_mode(a):
    import torch, torch.nn as nn
    DT = {"float32": torch.float32, "float16": torch.float16}; results = []
    if "text_states" in a.graphs:
        import objectclear_port as port
        from safetensors.torch import load_file
        t = port.TextStates().load_weights(load_file(os.path.join(a.weights, "text_encoder/model.fp16.safetensors")), load_file(os.path.join(a.weights, "text_encoder_2/model.fp16.safetensors"))).eval().float()
        with torch.no_grad(): states, pooled = t()
        results.append(line("text states (float32, cpu) against the pipeline's (half, mps)", states.numpy(), load(a.goldens, RUNS[0], "text_states")))
        results.append(line("pooled text state", pooled.numpy(), load(a.goldens, RUNS[0], "pooled_text_states")))
    for graph in [g for g in a.graphs if g in GRAPHS]:
        m = build(graph, a.weights, DT[a.dtype], DT[a.norm] if a.norm else None).to(a.device); peaks = {}
        if a.ranges:
            def hook(kind):
                def f(module, inputs, output):
                    x = inputs[0] if kind.startswith("into") else output
                    if isinstance(x, tuple): x = x[0]
                    v = float(x.detach().abs().max()); peaks[kind] = max(peaks.get(kind, 0.0), v)
                return f
            for name, mod in m.named_modules():
                if isinstance(mod, nn.GroupNorm): mod.register_forward_hook(hook("into a GroupNorm"))
                elif isinstance(mod, nn.LayerNorm): mod.register_forward_hook(hook("into a LayerNorm"))
                elif isinstance(mod, nn.Conv2d): mod.register_forward_hook(hook("out of a convolution"))
                elif isinstance(mod, nn.Linear): mod.register_forward_hook(hook("out of a linear layer"))
        for run in a.runs:
            for name, inputs, want in cases(a.goldens, run, graph):
                t0 = time.time()
                with torch.no_grad(): out = m(*[torch.from_numpy(v).to(a.device) for v in inputs.values()])
                out = out if isinstance(out, tuple) else (out,)
                got = {k: v.float().cpu().numpy() for k, v in zip(OUTPUTS[graph], out)}
                compare(run, graph, name + f" ({time.time() - t0:.1f} s)", got, want, results)
        if a.ranges: print(f"  largest magnitudes in {graph} ({a.dtype}): " + ", ".join(f"{k} {v:.4g}" for k, v in sorted(peaks.items())), flush=True); results.append({"graph": graph, "peaks": peaks})
        del m
    return results


# ---- the converted models, through Core AI -------------------------------------------------------------------------------------------------------
class Models:
    """The .aimodel folders of one OUT directory. By default each is loaded as it is asked for and the one before dropped, so no two graphs are resident
    at once; `resident` keeps every graph once loaded, as a helper that serves several jobs would."""
    FILES = {"vae_decoder": "objectclear-vae-decoder", "vae_encoder": "objectclear-vae-encoder", "object_encoder": "objectclear-object-encoder", "unet": "objectclear-unet"}
    def __init__(self, folder, compute="default", resident=False):
        self.folder, self.compute, self.name, self.fn, self.model, self.resident, self.kept = folder, compute, None, None, None, resident, {}
    async def function(self, graph):
        from coreai.runtime import AIModel, SpecializationOptions, ComputeUnitKind
        if self.resident and graph in self.kept: return self.kept[graph][1]
        if self.name != graph:
            self.fn = self.model = None
            path = os.path.join(self.folder, self.FILES[graph] + ".aimodel")
            options = {"default": None, "cpu": SpecializationOptions.cpu_only() if self.compute == "cpu" else None,
                       "gpu": SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()) if self.compute == "gpu" else None}[self.compute]
            t0 = time.time(); self.model = await AIModel.load(path, options) if options is not None else await AIModel.load(path)
            self.fn = self.model.load_function("main"); self.name = graph
            print(f"  loaded {graph} in {time.time() - t0:.1f} s ({self.compute})", flush=True)
            if self.resident: self.kept[graph] = (self.model, self.fn)
        return self.fn
    async def call(self, graph, inputs):
        from coreai.runtime import NDArray
        fn = await self.function(graph)
        out = await fn({k: NDArray(np.ascontiguousarray(v, dtype=np.float32)) for k, v in inputs.items()})
        got = {k: np.array(v.numpy(), copy=True) for k, v in out.items()}
        # A GPU that runs out of memory fails the command buffer, prints to stderr and hands back zeros, with no exception: say so here.
        if not all(np.any(v) for v in got.values()): raise RuntimeError(f"{graph} returned an output of zeros: the GPU's command buffer failed (see stderr)")
        return got

async def graphs_mode(a):
    models = Models(a.models, a.compute); results = []
    for graph in [g for g in a.graphs if g in GRAPHS]:
        if not os.path.isdir(os.path.join(a.models, Models.FILES[graph] + ".aimodel")): print(f"  no {graph} in {a.models}"); continue
        for run in a.runs:
            for name, inputs, want in cases(a.goldens, run, graph):
                t0 = time.time(); got = await models.call(graph, inputs)
                compare(run, graph, name + f" ({time.time() - t0:.2f} s)", got, want, results)
    return results

async def run_mode(a):
    from PIL import Image
    models = Models(a.models, a.compute, a.resident); results = []
    spec = json.load(open(os.path.join(a.models, "objectclear-text-states.json"))); raw = np.fromfile(os.path.join(a.models, spec["file"]), dtype="<f2").astype(np.float32)
    states = raw[:77 * 2048].reshape(1, 77, 2048); pooled = raw[77 * 2048:].reshape(1, 1280)
    for run in [r for r in a.runs for _ in range(a.repeat if a.mode == "run" and a.resident else 1)]:
        P = lambda n: np.asarray(Image.open(os.path.join(a.goldens, run, n + ".png"))); L = lambda n: load(a.goldens, run, n)
        m = json.load(open(os.path.join(a.goldens, run, "manifest.json"))); loop = asyncio.get_running_loop(); calls = {"seconds": 0.0}
        def sync(graph, inputs):   # reference.run is plain Python; each network call is awaited on this loop from its thread
            t0 = time.time(); out = asyncio.run_coroutine_threadsafe(models.call(graph, inputs), loop).result(); dt = time.time() - t0
            calls["seconds"] += dt; calls.setdefault(graph, []).append(round(dt, 3)); return out
        def unet(sample, t, s, p, ids):
            o = sync("unet", {"sample": sample, "timestep": np.array([t], np.float32), "states": s, "pooled": p, "time_ids": ids})
            return ref.half(o["noise"]), o["attention"]
        def job():
            # the reference's loop, with the graph's reduced attention in place of the raw one
            rgb, gray = P("input"), P("mask"); h, w = gray.shape; picture = ref.picture_tensor(rgb); mask = ref.mask_tensor(gray)
            row = sync("object_encoder", {"object": ref.resize_antialias(ref.object_alone(picture, mask))})["fused"]
            fused = ref.fuse_prompt(states, ref.half(row)); moments = ref.half(sync("vae_encoder", {"picture": picture})["moments"])
            noises = [L("vae_sample_noise_picture"), L("initial_noise"), L("vae_sample_noise_masked")]
            plat = ref.sample_latents(moments, noises[0]); mlat = ref.sample_latents(moments, noises[2]); klat = ref.mask_latents(mask)
            timesteps, sigmas, first = ref.schedule(m["steps"]); latents = ref.half(noises[1] * np.float32(first)); ids = np.array([[h, w, 0, 0, h, w]], np.float32); seen = None
            for i in range(m["steps"]):
                sample = ref.unet_sample(latents, sigmas[i], klat, mlat); eps, seen = unet(sample, timesteps[i], fused, pooled, ids)
                if m["guidance"] > 1: eps = ref.guide(np.concatenate([unet(sample, timesteps[i], np.zeros_like(fused), np.zeros_like(pooled), ids)[0], eps]), m["guidance"])
                latents = ref.euler_step(latents, eps, sigmas[i], sigmas[i + 1])
                if i == 0: latents, _ = ref.after_first_step(latents, plat, noises[1], sigmas[1], klat)
            up = ref.half(ref._upsample_bilinear_2x(ref.half(seen))); amap = ref.half((up - up.min()) / (up.max() - up.min())); abytes = ref.attention_bytes(amap)
            decoded = sync("vae_decoder", {"latents": ref.half(latents / np.float32(ref.SCALING))})["picture"]; generated = ref.picture_bytes(decoded)
            return ref.attention_guided_fusion(rgb, generated, abytes), abytes, generated, latents
        t0 = time.time(); fused_picture, abytes, generated, latents = await loop.run_in_executor(None, job); total = time.time() - t0
        print(f"{run}: {len(calls['unet'])} UNet calls, {calls['seconds']:.1f} s in the graphs of {total:.1f} s (the loads and NumPy's fusion included)", flush=True)
        print("  seconds a call: " + "; ".join(f"{g} {calls[g][:3]}{'...' if len(calls[g]) > 3 else ''} (sum {sum(calls[g]):.2f})" for g in GRAPHS[::-1] if g in calls), flush=True)
        results.append({"run": run, "what": "seconds", "graphs": calls["seconds"], "total": total, "calls": {g: calls[g] for g in GRAPHS if g in calls}})
        for what, got, want in [("fused picture", fused_picture, P("fused")), ("decoder's picture", generated, P("generated"))]:
            r = {"run": run, "what": what, "psnr": psnr(got, want, 255.0), "worst": int(np.abs(got.astype(int) - want.astype(int)).max()), "mean": float(np.abs(got.astype(float) - want.astype(float)).mean())}
            print(f"  {what:22s} PSNR {r['psnr']:.2f} dB  worst {r['worst']} of 255  mean {r['mean']:.3f}", flush=True); results.append(r)
        want = P("attention_latent"); flips = int(((abytes > 128) != (want > 128)).sum())
        print(f"  attention map          worst {int(np.abs(abytes.astype(int) - want.astype(int)).max())} of 255, {flips} of {want.size} cross the fusion's threshold; "
              f"PSNR {psnr(abytes, want, 255.0):.2f} dB", flush=True)
        results.append({"run": run, "what": "attention map", "psnr": psnr(abytes, want, 255.0), "threshold flips": flips, "of": int(want.size)})
        results.append(dict(line(f"{run} final latents", latents, L("final_latents")), run=run))
        if a.write:
            os.makedirs(a.write, exist_ok=True); Image.fromarray(fused_picture).save(os.path.join(a.write, run + "-fused.png")); Image.fromarray(abytes).save(os.path.join(a.write, run + "-attention_latent.png"))
    return results


async def time_mode(a):
    """Each graph called `--repeat` times at each of `--sizes` (height x width in pixels), in the order given: the first call at a size, then the warm ones."""
    models = Models(a.models, a.compute); results = []; rng = np.random.default_rng(0)
    for graph in [g for g in a.graphs if g in GRAPHS]:
        for size in a.sizes.split(","):
            height, width = (int(v) for v in size.split("x")); h, w = height // 8, width // 8; n = lambda *shape: rng.standard_normal(shape, dtype=np.float32)
            inputs = {"vae_decoder": {"latents": n(1, 4, h, w)}, "vae_encoder": {"picture": np.clip(n(1, 3, height, width) / 3, -1, 1)}, "object_encoder": {"object": np.clip(n(1, 3, 224, 224) / 3, -1, 1)},
                      "unet": {"sample": n(1, 9, h, w), "timestep": np.array([501.0], np.float32), "states": n(1, 77, 2048), "pooled": n(1, 1280), "time_ids": np.array([[height, width, 0, 0, height, width]], np.float32)}}[graph]
            times = []
            for _ in range(a.repeat):
                t0 = time.time(); out = await models.call(graph, inputs); times.append(time.time() - t0)
            finite = all(bool(np.isfinite(v).all()) for v in out.values())
            r = {"graph": graph, "size": size, "first": times[0], "warm median": float(np.median(times[1:])) if len(times) > 1 else None, "warm min": min(times[1:]) if len(times) > 1 else None,
                 "calls": [round(t, 3) for t in times], "finite": finite, "shapes": {k: list(v.shape) for k, v in out.items()}}
            print(f"  {graph} {size}: first {times[0]:.2f} s, warm median {r['warm median']:.3f} s (min {r['warm min']:.3f}) over {len(times) - 1}; finite {finite}; {r['shapes']}", flush=True); results.append(r)
    return results


async def sizes_mode(a):
    """The converted graphs against the port in PyTorch (`--device`, `--dtype`) at sizes no recorded run has, on seeded noise: what shows that a symbolic
    size computes the same graph at every size, landscape as well as portrait. Two processes, so that Core AI's UNet and PyTorch's are never resident
    together: `--half coreai --write DIR` runs the converted graphs and keeps what they gave, `--half torch --write DIR` runs the port and compares."""
    import gc
    results = []; os.makedirs(a.write, exist_ok=True)
    for graph in [g for g in a.graphs if g in GRAPHS and g != "object_encoder"]:
        rng = np.random.default_rng(1); made = []; kept = os.path.join(a.write, f"sizes-{graph}.npz")
        for size in a.sizes.split(","):
            H, W = (int(v) for v in size.split("x")); h, w = H // 8, W // 8; n = lambda *shape: rng.standard_normal(shape, dtype=np.float32)
            made.append((size, {"vae_decoder": {"latents": n(1, 4, h, w)}, "vae_encoder": {"picture": np.clip(n(1, 3, H, W) / 3, -1, 1)},
                                "unet": {"sample": n(1, 9, h, w), "timestep": np.array([501.0], np.float32), "states": n(1, 77, 2048), "pooled": n(1, 1280),
                                         "time_ids": np.array([[H, W, 0, 0, H, W]], np.float32)}}[graph]))
        if a.half == "coreai":
            assert graph != "unet" or len(made) <= 3, "a loaded UNet holds three sizes and no more"
            models = Models(a.models, a.compute); out = {}
            for size, inputs in made:
                for key, value in (await models.call(graph, inputs)).items(): out[f"{size}/{key}"] = value
            np.savez(kept, **out); print(f"  kept {graph} at {[m[0] for m in made]} in {kept}", flush=True); models = None; gc.collect()
        else:
            import torch
            got = np.load(kept); m = build(graph, a.weights, {"float32": torch.float32, "float16": torch.float16}[a.dtype], None).to(a.device)
            for size, inputs in made:
                with torch.no_grad(): out = m(*[torch.from_numpy(v).to(a.device) for v in inputs.values()])
                out = out if isinstance(out, tuple) else (out,)
                for key, value in zip(OUTPUTS[graph], out):
                    r = line(f"{size} {graph}: {key}", got[f"{size}/{key}"], value.float().cpu().numpy(), picture=key == "picture"); r.update(size=size, graph=graph, output=key); results.append(r)
            del m; gc.collect()
    return results


async def stress_mode(a):
    """Half precision on pictures made to be hard for SDXL's VAE, whose activations reach thousands: the converted encoder and decoder against the port in
    float32 (PyTorch on `--device`), at each of `--sizes`. A picture that overflowed would come back not finite, or far from float32.
    Mind the reference's memory, not the converted model's: PyTorch's float32 VAE took 30.7 GB of footprint on MPS at 1344 x 512 and 16.6 GB on the CPU
    at 1328 x 512 (measured). Keep the sizes small on a Mac with 24 GB."""
    import torch
    models = Models(a.models, a.compute); results = []; rng = np.random.default_rng(0)
    encoder = build("vae_encoder", a.weights, torch.float32, None).to(a.device); decoder = build("vae_decoder", a.weights, torch.float32, None).to(a.device)
    def reference(m, x):
        with torch.no_grad(): return m(torch.from_numpy(x).to(a.device)).float().cpu().numpy()
    for size in a.sizes.split(","):
        H, W = (int(v) for v in size.split("x")); yy, xx = np.mgrid[0:H, 0:W]; flat = lambda r, g, b: np.stack([np.full((H, W), v, np.float32) for v in (r, g, b)])
        pictures = {"white": flat(1, 1, 1), "black": flat(-1, -1, -1), "red": flat(1, -1, -1), "blue": flat(-1, -1, 1), "one-pixel checkerboard": np.repeat(((yy + xx) % 2 * 2 - 1)[None].astype(np.float32), 3, 0),
                    "uniform noise": rng.uniform(-1, 1, (3, H, W)).astype(np.float32), "black and white halves": np.repeat(np.where(xx < W // 2, -1.0, 1.0)[None].astype(np.float32), 3, 0),
                    "8-pixel stripes of primaries": np.stack([np.where((xx // 8) % 3 == c, 1.0, -1.0).astype(np.float32) for c in range(3)])}
        for name, picture in pictures.items():
            picture = picture[None]; got = (await models.call("vae_encoder", {"picture": picture}))["moments"]; want = reference(encoder, picture)
            r = line(f"{size} {name}: encoder's mean", got[:, :4], want[:, :4]); r.update(size=size, picture=name, graph="vae_encoder"); results.append(r)
            latents = want[:, :4]      # the float32 mean, so the decoder is judged on its own
            got = (await models.call("vae_decoder", {"latents": latents}))["picture"]; ref_picture = reference(decoder, latents)
            r = line(f"{size} {name}: decoder's picture", got, ref_picture, picture=True); r.update(size=size, picture=name, graph="vae_decoder"); results.append(r)
    return results


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("mode", choices=["port", "graphs", "run", "time", "stress", "sizes"]); ap.add_argument("--sizes", default="1328x512"); ap.add_argument("--repeat", type=int, default=6)
    ap.add_argument("--weights"); ap.add_argument("--models"); ap.add_argument("--goldens", required=True)
    ap.add_argument("--graphs", nargs="+", default=GRAPHS); ap.add_argument("--runs", nargs="+", default=RUNS)
    ap.add_argument("--device", default="cpu"); ap.add_argument("--dtype", default="float32"); ap.add_argument("--norm"); ap.add_argument("--ranges", action="store_true")
    ap.add_argument("--compute", default="default", choices=["default", "gpu", "cpu"]); ap.add_argument("--json"); ap.add_argument("--write"); ap.add_argument("--resident", action="store_true"); ap.add_argument("--half", choices=["coreai", "torch"])
    a = ap.parse_args()
    results = port_mode(a) if a.mode == "port" else asyncio.run({"graphs": graphs_mode, "run": run_mode, "time": time_mode, "stress": stress_mode, "sizes": sizes_mode}[a.mode](a))
    if a.json: json.dump(results, open(a.json, "w"), indent=1)
