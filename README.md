# ComfyUI CLIP fix

Fixes the confusing ComfyUI error:

```text
ERROR: clip input is invalid: None
If the clip is from a checkpoint loader node your checkpoint does not contain a valid clip or text encoder model.
```

## What was wrong

`CheckpointLoaderSimple` can load a **diffusion model only** checkpoint and silently return `CLIP = None`. The workflow only fails later at `CLIPTextEncode`, with a message that does not explain how to fix it.

This repo patches ComfyUI so checkpoint loaders **fail immediately** with model-specific guidance (Flux, SD3, SDXL, etc.).

## Quick start

```bash
cd ComfyUI
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python main.py
```

## Apply to an existing ComfyUI install

```bash
chmod +x scripts/apply-clip-fix.sh
./scripts/apply-clip-fix.sh /path/to/your/ComfyUI
```

Restart ComfyUI after applying.

## If you still see the CLIP error

### SD 1.5 / SDXL (single checkpoint)

Use a **full** checkpoint that includes text encoders, not a UNet-only file.

- Put the file in `models/checkpoints/`
- Use `Load Checkpoint` (`CheckpointLoaderSimple`)
- Connect the **CLIP** output (middle pin) to `CLIP Text Encode`

### Flux / SD3 / split models

These usually ship as separate files. **Do not** use `CheckpointLoaderSimple` for the UNet alone.

| Component | Folder | Loader node |
|-----------|--------|-------------|
| UNet | `models/diffusion_models/` | Load Diffusion Model (`UNETLoader`) |
| Text encoders | `models/text_encoders/` | DualCLIPLoader (type: `flux` or `sd3`) |
| VAE | `models/vae/` | Load VAE (`VAELoader`) |

`models/clip/` is also accepted for text encoders (ComfyUI alias).

### Flux example workflow

```text
UNETLoader -> KSampler (model)
DualCLIPLoader (flux: clip-l + t5-xxl) -> CLIPTextEncode -> KSampler (positive/negative)
VAELoader -> VAE Decode
```

### Common mistakes

- LoRA file in `models/checkpoints/` instead of `models/loras/`
- Incomplete or corrupt download (re-download the checkpoint)
- CLIP output not wired to `CLIPTextEncode`
- MODEL or VAE output connected to `CLIPTextEncode` by mistake

## Changed files

- `ComfyUI/comfy/sd.py` — `checkpoint_clip_missing_hint()` and `ensure_checkpoint_clip()`
- `ComfyUI/nodes.py` — validation in checkpoint loader nodes
