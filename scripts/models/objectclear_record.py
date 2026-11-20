"""Records the tensors a Swift port of ObjectClear is tested against (docs/remove-plan.md, package H1; H2 reads them).
Runs the reference PyTorch pipeline unchanged (ObjectClear at c052d91, on MPS, half precision, as the research measured it) and saves every
boundary a port crosses, by wrapping the pipeline's own calls: nothing here re-implements a step, so a file holds what the pipeline computed.

usage: objectclear_record.py --repo OBJECTCLEAR_REPO --weights WEIGHTS/ObjectClear --out GOLDENS_DIR [--seed 42] [--text-states DIR]
                             --run NAME:IMAGE.png:MASK.png:STEPS:GUIDANCE [--run ...]
Each run is written to GOLDENS_DIR/NAME-STEPS-GUIDANCE/ as float32 .npy files (the pipeline's half floats, widened exactly), PNGs and a
manifest.json that names each file, its shape and dtype and what it is. GOLDENS_DIR/README.md says how a run is laid out.
Needs the research environment (torch, diffusers, transformers, opencv), not the conversion's locked packages: it is the reference, not the recipe."""
import argparse, hashlib, json, os, platform, sys, time, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser()
ap.add_argument("--repo", required=True); ap.add_argument("--weights", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--seed", type=int, default=42); ap.add_argument("--run", action="append", required=True); ap.add_argument("--text-states")
ap.add_argument("--device", default="mps"); ap.add_argument("--fp32", action="store_true")
args = ap.parse_args()
sys.path.insert(0, args.repo)
import numpy as np, torch
from PIL import Image
import diffusers, transformers
import diffusers.models.autoencoders.vae as vae_module
import objectclear.pipelines.pipeline_objectclear as pipeline_module
from objectclear.pipelines import ObjectClearPipeline

PROMPT = "remove the instance of object"
FUSE_INDEX = 5   # the pipeline's own constant: the token "object"
ATTN_LAYER = "down_blocks.1.attentions.0.transformer_blocks.0.attn2"   # the pipeline's TARGET_LAYER


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""): h.update(block)
    return h.hexdigest()


class Recorder:
    """One run's files. `put` saves a tensor as float32 (or integers as they are) and notes it for the manifest, in the order made."""
    def __init__(self, folder):
        self.folder = folder; self.entries = []; self.on = False; os.makedirs(folder, exist_ok=True)
    def put(self, name, value, what):
        if not self.on: return
        t = value.detach().to("cpu") if isinstance(value, torch.Tensor) else torch.as_tensor(np.asarray(value))
        source = str(t.dtype).replace("torch.", "")
        a = t.to(torch.float32).numpy() if t.is_floating_point() else t.numpy()
        path = os.path.join(self.folder, name + ".npy"); os.makedirs(os.path.dirname(path), exist_ok=True)
        np.save(path, a)   # not ascontiguousarray: it would make a scalar a vector of one
        self.entries.append({"file": name + ".npy", "shape": list(a.shape), "dtype": str(a.dtype), "computed as": source,
                             "finite": bool(np.isfinite(a).all()) if a.dtype.kind == "f" else True, "what": what})
    def png(self, name, image, what):
        if not self.on: return
        path = os.path.join(self.folder, name + ".png"); image.save(path)
        self.entries.append({"file": name + ".png", "shape": [image.size[1], image.size[0]] + ([3] if image.mode == "RGB" else []), "dtype": "uint8",
                             "mode": image.mode, "sha256": sha(path), "what": what})


rec = Recorder(args.out)
state = {"step": -1, "draws": 0, "encodes": 0, "added_noise": 0, "last": None}
device = torch.device(args.device); dtype = torch.float32 if args.fp32 else torch.float16
t0 = time.time()
pipe = ObjectClearPipeline.from_pretrained_with_custom_modules(args.weights, torch_dtype=dtype, apply_attention_guided_fusion=True, variant=None if args.fp32 else "fp16")
pipe.to(device)
load_seconds = time.time() - t0

# ---- wraps, each around one of the pipeline's own calls ------------------------------------------------------------------------------
def wrap(owner, name, after):
    original = getattr(owner, name)
    def wrapped(*a, **k):
        out = original(*a, **k); after(a, k, out); return out
    setattr(owner, name, wrapped)

wrap(pipe.image_processor, "preprocess", lambda a, k, out: rec.put("picture", out, "the picture as the pipeline's image processor gives it: 1 x 3 x H x W, RGB, value / 255 * 2 - 1"))
wrap(pipe.mask_processor, "preprocess", lambda a, k, out: rec.put("mask", out, "the object's mask as the mask processor gives it: 1 x 1 x H x W, 0 or 1 (1 where the PNG is 128 or more)"))

def after_encode_prompt(a, k, out):
    names = ["text_states", "text_states_unconditional", "pooled_text_states", "pooled_text_states_unconditional"]
    whats = ["the fixed prompt's hidden states before fusion, 1 x 77 x 2048: the two text encoders' penultimate layers side by side (768 then 1280)",
             "the unconditional branch's states (guidance above 1 only): zeros, since the pipeline zeroes an empty negative prompt",
             "the fixed prompt's pooled state, 1 x 1280 (the second text encoder's projected end-of-text state): the UNet's text_embeds",
             "the unconditional branch's pooled state: zeros"]
    for name, what, value in zip(names, whats, out):
        if value is not None: rec.put(name, value, what)
wrap(pipe, "encode_prompt", after_encode_prompt)

def none(*done): return None   # a forward hook that returns a value replaces the module's output
pipe.image_prompt_encoder.register_forward_hook(lambda m, i, o: none(
    rec.put("image_encoder_input", i[0], "the image encoder's input: picture * (mask > 0.5), 1 x 3 x H x W in [-1, 1], the object alone on zero"),
    rec.put("object_embeds", o, "the object's embedding, 1 x 1 x 768: CLIP ViT-L/14's pooled state through its visual projection")))
pipe.image_prompt_encoder.vision_processor.register_forward_hook(lambda m, i, o: none(
    rec.put("image_encoder_resized", i[0], "image_encoder_input resized to 224 x 224, bilinear with antialiasing (F.interpolate(mode='bilinear', antialias=True)): 1 x 3 x 224 x 224"),
    rec.put("image_encoder_normalized", o, "image_encoder_resized less CLIP's mean over its std, a channel: what the vision transformer takes")))
pipe.postfuse_module.register_forward_hook(lambda m, i, o: rec.put(
    "fused_prompt_states", o, f"text_states with row {FUSE_INDEX} replaced by the fusion module's output for object_embeds, 1 x 77 x 2048: the UNet's encoder_hidden_states (conditional branch)"))

def after_vae_encode(a, k, out):
    n = state["encodes"]; state["encodes"] += 1; which = ["picture", "masked"][n] if n < 2 else str(n)
    if n == 0: rec.put("vae_encoder_input", a[0], "the VAE encoder's input: the picture, 1 x 3 x H x W in [-1, 1] (the pipeline does not black out the object: masked_image is the picture itself)")
    rec.put(f"vae_encoder_moments_{which}", out.latent_dist.parameters,
            "the VAE encoder's output, 1 x 8 x H/8 x W/8: the latent's mean (channels 0 to 3) and log variance (4 to 7), before sampling and scaling" +
            ("" if n == 0 else "; the second encode of the same picture, for the UNet's masked-image channels"))
wrap(pipe.vae, "encode", after_vae_encode)

def recording_randn(original, owner):
    def randn(*a, **k):
        out = original(*a, **k); n = state["draws"]; state["draws"] += 1
        names = ["vae_sample_noise_picture", "initial_noise", "vae_sample_noise_masked"]
        whats = ["the first normal draw of the seeded generator, 1 x 4 x H/8 x W/8: the noise that samples picture_latents from the encoder's moments",
                 "the second draw: the noise the denoising starts from (and that is added back to the picture's latents after step 0)",
                 "the third draw: the noise that samples masked_picture_latents from the second encode's moments"]
        rec.put(names[n] if n < 3 else f"draw_{n}", out, whats[n] if n < 3 else "a draw the recorder did not expect")
        return out
    return randn
vae_module.randn_tensor = recording_randn(vae_module.randn_tensor, "vae")
pipeline_module.randn_tensor = recording_randn(pipeline_module.randn_tensor, "pipeline")

def after_prepare_latents(a, k, out):
    rec.put("initial_latents", out[0], "initial_noise * init_noise_sigma: the latents before step 0")
    rec.put("picture_latents", out[2], "(mean + exp(0.5 * logvar) * vae_sample_noise_picture) * 0.13025: the picture's latents, used after step 0 to put the unmasked area back")
wrap(pipe, "prepare_latents", after_prepare_latents)

def after_prepare_mask_latents(a, k, out):
    rec.put("mask_latents", out[0][:1], "the mask at latent size, 1 x 1 x H/8 x W/8: nearest-neighbour (F.interpolate's default) of the 0/1 mask; UNet input channel 4")
    rec.put("masked_picture_latents", out[1][:1], "(mean + exp(0.5 * logvar) * vae_sample_noise_masked) * 0.13025 from the second encode: UNet input channels 5 to 8")
wrap(pipe, "prepare_mask_latents", after_prepare_mask_latents)

def after_time_ids(a, k, out):
    rec.put("time_ids", out[0], "the UNet's time_ids, 1 x 6: (height, width, 0, 0, height, width) in pixels, original size, crop corner, target size; the same for both branches")
wrap(pipe, "_get_add_time_ids", after_time_ids)

def after_scale(a, k, out):
    state["step"] += 1; s = state["step"]
    rec.put(f"step_{s:02d}/latents_in", a[0][:1], "the latents entering this step, 1 x 4 x H/8 x W/8")
    rec.put(f"step_{s:02d}/sigma", pipe.scheduler.sigmas[pipe.scheduler.step_index], "this step's sigma (sigmas[step])")
wrap(pipe.scheduler, "scale_model_input", after_scale)

def unet_pre(module, a, k):
    s = state["step"]; sample = a[0] if a else k["sample"]; timestep = a[1] if len(a) > 1 else k["timestep"]
    rec.put(f"step_{s:02d}/unet_sample", sample, "the UNet's sample input, B x 9 x H/8 x W/8 (B is 2 with guidance above 1: unconditional then conditional, the same sample twice): "
            "latents_in / sqrt(sigma^2 + 1) in channels 0 to 3, mask_latents in 4, masked_picture_latents in 5 to 8")
    rec.put(f"step_{s:02d}/unet_timestep", timestep, "the UNet's timestep input: timesteps[step], a scalar")
    if s == 0:
        rec.put("unet_encoder_hidden_states", k["encoder_hidden_states"], "the UNet's encoder_hidden_states at every step, B x 77 x 2048: with guidance above 1 row 0 is text_states_unconditional "
                "(zeros) and row 1 fused_prompt_states; else fused_prompt_states alone")
        rec.put("unet_text_embeds", k["added_cond_kwargs"]["text_embeds"], "the UNet's added condition text_embeds at every step, B x 1280: pooled_text_states (after the zeros of the unconditional branch when B is 2)")
        rec.put("unet_time_ids", k["added_cond_kwargs"]["time_ids"], "the UNet's added condition time_ids at every step, B x 6: time_ids, a row a branch")
pipe.unet.register_forward_pre_hook(unet_pre, with_kwargs=True)
pipe.unet.register_forward_hook(lambda m, i, o: rec.put(
    f"step_{state['step']:02d}/unet_out", o[0], "the UNet's output, B x 4 x H/8 x W/8: the predicted noise, a row a branch"))

def after_step(a, k, out):
    s = state["step"]
    rec.put(f"step_{s:02d}/noise_pred", a[0], "the noise the scheduler is given, 1 x 4 x H/8 x W/8: unet_out, or with guidance above 1 unconditional + guidance * (conditional - unconditional)")
    rec.put(f"step_{s:02d}/scheduler_out", out[0], "the Euler step's result: latents_in + noise_pred * (sigmas[step + 1] - sigmas[step]), in float32 and then rounded to half")
wrap(pipe.scheduler, "step", after_step)

def after_add_noise(a, k, out):
    n = state["added_noise"]; state["added_noise"] += 1
    rec.put("picture_latents_noised" if n == 0 else f"picture_latents_noised_{n}", out,
            "picture_latents + initial_noise * sigmas[1]: the picture's latents at the noise level the latents have after step 0")
wrap(pipe.scheduler, "add_noise", after_add_noise)

def on_step_end(p, i, t, kw):
    state["last"] = kw["latents"]
    rec.put(f"step_{i:02d}/latents_out", kw["latents"], "the latents leaving this step. Step 0: (1 - mask_latents) * picture_latents_noised + mask_latents * scheduler_out. Other steps: scheduler_out")
    return {}

def after_attn(a, k, out):
    raw, mask, index = a
    rec.put("attention_raw", raw, f"the last step's cross-attention probabilities of {ATTN_LAYER}, (B * 10 heads) x (H/16 * W/16 tokens, rows first) x 77 text tokens: "
            "softmax over the text tokens. With guidance above 1 the first 10 heads are the unconditional branch")
    rec.put("attention_map_branches", out, "resize_attn_map_divide2's result, B x 1 x H/8 x W/8: column 5 of attention_raw, the mean over the heads, bilinear to latent size (align_corners false), "
            "then (x - min) / (max - min + 1e-8) a branch")
    rec.put("attention_map", out[-1:], "the attention map the pipeline keeps, 1 x 1 x H/8 x W/8 in [0, 1]: the conditional branch of attention_map_branches")
wrap(pipe, "resize_attn_map_divide2", after_attn)

def after_decode(a, k, out):
    rec.put("vae_decoder_input", a[0], "the VAE decoder's input, 1 x 4 x H/8 x W/8: the last step's latents_out / 0.13025")
    rec.put("vae_decoder_output", out[0], "the VAE decoder's output, 1 x 3 x H x W, about [-1, 1], before clamping")
wrap(pipe.vae, "decode", after_decode)

fusion = {}
original_fusion = pipeline_module.attention_guided_fusion
def recording_fusion(ori, removed, attn_map, *a, **k):
    out = original_fusion(ori, removed, attn_map, *a, **k); fusion.update(ori=ori, removed=removed, attn=attn_map, fused=out); return out
pipeline_module.attention_guided_fusion = recording_fusion

# ---- the fixed text states, once ---------------------------------------------------------------------------------------------------------
tokens = [pipe.tokenizer(PROMPT, padding="max_length", max_length=77, truncation=True).input_ids,
          pipe.tokenizer_2(PROMPT, padding="max_length", max_length=77, truncation=True).input_ids]
if args.text_states:
    os.makedirs(args.text_states, exist_ok=True)
    with torch.no_grad():
        states, _, pooled, _ = pipe.encode_prompt(prompt=PROMPT, device=device, num_images_per_prompt=1, do_classifier_free_guidance=False)
    np.save(os.path.join(args.text_states, "text_states.reference.npy"), states.to("cpu", torch.float32).numpy())
    np.save(os.path.join(args.text_states, "pooled_text_states.reference.npy"), pooled.to("cpu", torch.float32).numpy())
    json.dump({"prompt": PROMPT, "token ids, text encoder 1": tokens[0], "token ids, text encoder 2": tokens[1], "fuse index": FUSE_INDEX,
               "computed": f"by the reference pipeline's encode_prompt on {args.device} in {dtype}; the bundled file is made by the pinned recipe instead (objectclear_text_states.py)"},
              open(os.path.join(args.text_states, "reference.json"), "w"), indent=1)

# ---- the runs -------------------------------------------------------------------------------------------------------------------------------
def weights_note():
    files = ["unet/diffusion_pytorch_model.fp16.safetensors", "vae/diffusion_pytorch_model.fp16.safetensors", "image_prompt_encoder/model.fp16.safetensors",
             "postfuse_module/model.fp16.safetensors", "text_encoder/model.fp16.safetensors", "text_encoder_2/model.fp16.safetensors"]
    return {f: os.path.getsize(os.path.join(args.weights, f)) for f in files}

for spec in args.run:
    name, image_path, mask_path, steps, guidance = spec.split(":"); steps = int(steps); guidance = float(guidance)
    folder = os.path.join(args.out, f"{name}-{steps}-{guidance:.1f}")
    rec.__init__(folder); state.update(step=-1, draws=0, encodes=0, added_noise=0, last=None); fusion.clear()
    image = Image.open(image_path).convert("RGB"); mask = Image.open(mask_path).convert("L"); w, h = image.size
    rec.on = True
    rec.png("input", image, "the model's input picture at the working size, as the research wrote it (the engine job's image.png)")
    rec.png("mask", mask, "the object's mask, 0 or 255 (the engine job's mask.png)")
    generator = torch.Generator(device="cpu").manual_seed(args.seed)
    t1 = time.time()
    result = pipe(prompt=PROMPT, image=image, mask_image=mask, generator=generator, num_inference_steps=steps, guidance_scale=guidance, height=h, width=w,
                  return_attn_map=True, callback_on_step_end=on_step_end, callback_on_step_end_tensor_inputs=["latents"])
    seconds = time.time() - t1
    rec.put("timesteps", pipe.scheduler.timesteps, "the scheduler's timesteps, one a step: 'leading' spacing, (steps - 1 ... 0) * (1000 // steps) + 1")
    rec.put("sigmas", pipe.scheduler.sigmas, "the scheduler's sigmas, steps + 1 values: sqrt((1 - a) / a) of the training schedule, read at the timesteps by linear interpolation, then 0")
    rec.put("init_noise_sigma", torch.as_tensor(float(pipe.scheduler.init_noise_sigma)), "what initial_noise is multiplied by: sqrt(sigmas[0]^2 + 1) ('leading' spacing)")
    rec.put("final_latents", state["last"], "the last step's latents_out, again")
    rec.png("generated", Image.fromarray(fusion["removed"]), "the decoder's picture before the fusion: round-to-nearest of (vae_decoder_output / 2 + 0.5) clamped to [0, 1], times 255")
    rec.png("attention_latent", Image.fromarray(fusion["attn"]), "the attention map as the pipeline returns it, H/8 x W/8: attention_map * 255 truncated to 8 bits")
    rec.png("fused", result.images[0].resize((w, h)), "the pipeline's picture: attention_guided_fusion(input, generated, attention_latent) (objectclear/utils/attention_guided_fusion.py); "
            "what run_oc.py writes as out.png")
    rec.png("attention", result.attns[0].resize((w, h)), "attention_latent resized to the working size as run_oc.py does (PIL's default for an L image, bicubic): what it writes as attn.png")
    rec.on = False
    assert state["draws"] == 3 and state["encodes"] == 2 and state["step"] == steps - 1, (state, steps)
    bad = [e["file"] for e in rec.entries if not e.get("finite", True)]
    manifest = {"run": os.path.basename(folder), "input": name, "width": w, "height": h, "steps": steps, "guidance": guidance, "seed": args.seed,
                "prompt": PROMPT, "token ids, text encoder 1": tokens[0], "token ids, text encoder 2": tokens[1], "fuse index": FUSE_INDEX, "attention layer": ATTN_LAYER,
                "device": args.device, "precision": str(dtype).replace("torch.", ""), "unet calls a step": 1, "unet batch": 2 if guidance > 1 else 1,
                "vae scaling factor": float(pipe.vae.config.scaling_factor), "scheduler": dict(pipe.scheduler.config),
                "inference seconds (with recording)": round(seconds, 2), "not finite": bad,
                "source": {"objectclear": "c052d91", "torch": torch.__version__, "diffusers": diffusers.__version__, "transformers": transformers.__version__,
                           "numpy": np.__version__, "python": platform.python_version(), "macOS": platform.mac_ver()[0], "weights bytes": weights_note()},
                "numbers": "every .npy is float32 (integers stay integers); 'computed as' is the dtype the pipeline held, so a float16 value is exact in its file",
                "files": rec.entries}
    json.dump(manifest, open(os.path.join(folder, "manifest.json"), "w"), indent=1)
    print("RECORDED " + json.dumps({"run": os.path.basename(folder), "size": [w, h], "files": len(rec.entries), "seconds": round(seconds, 2), "not finite": bad}), flush=True)
print("DONE " + json.dumps({"load_s": round(load_seconds, 2), "mps_driver_gb": round(torch.mps.driver_allocated_memory() / 1e9, 2) if args.device == "mps" else None}), flush=True)
