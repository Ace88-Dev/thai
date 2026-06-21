# ComfyUI CLIP fix

Fixes the confusing ComfyUI error:

```text
ERROR: clip input is invalid: None
If the clip is from a checkpoint loader node your checkpoint does not contain a valid clip or text encoder model.
```

## What was wrong

`CheckpointLoaderSimple` can load a **diffusion model only** checkpoint and silently return `CLIP = None`. The workflow only fails later at `CLIPTextEncode`, with a message that does not explain how to fix it.

This repo patches ComfyUI so checkpoint loaders **fail immediately** with model-specific guidance (Flux, SD3, SDXL, etc.).

## Start ComfyUI locally (robust mode, port 8188)

Use the hardened launcher:

```bash
chmod +x scripts/start-comfyui.sh
./scripts/start-comfyui.sh
```

Open: **http://127.0.0.1:8188**

### What this launcher does

1. Creates/uses `ComfyUI/venv`
2. Installs dependencies and the correct PyTorch backend profile
3. Runs ComfyUI against a **persistent data root** (default: `~/.local/share/comfyui`)
4. Persists `models/`, `input/`, `output/`, `custom_nodes/`, `user/`, and `comfyui.db`
5. Automatically snapshots workflows + settings at startup/shutdown and on interval
6. One-time migration of legacy workflows/settings from `ComfyUI/user/default`

This avoids common “workflow disappeared/reset” cases after repo updates or crashes.

### AMD Vulkan profile

For AMD users wanting Vulkan-oriented startup defaults:

```bash
./scripts/start-comfyui.sh --amd-vulkan
```

Optional GFX override (for cards that need it):

```bash
./scripts/start-comfyui.sh --amd-vulkan --amd-gfx-version 11.0.0
```

Notes:
- ComfyUI compute backend is still PyTorch ROCm on Linux AMD.
- The Vulkan profile sets AMD/Vulkan environment defaults and ROCm tuning vars for stability/performance.

### Useful options

```bash
# CPU-only
./scripts/start-comfyui.sh --cpu

# LAN access
HOST=0.0.0.0 ./scripts/start-comfyui.sh

# Different port
PORT=8189 ./scripts/start-comfyui.sh

# Change persistent data location
COMFY_DATA_DIR=/mnt/fastssd/comfyui ./scripts/start-comfyui.sh

# Print final startup command without launching
./scripts/start-comfyui.sh --dry-run
```

### Optional: run as an auto-restarting user service

```bash
chmod +x scripts/install-comfyui-service.sh
./scripts/install-comfyui-service.sh
systemctl --user enable --now comfyui.service
```

## Quick start (manual)

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
