# ComfyUI CLIP fix

Fixes the confusing ComfyUI error:

```text
ERROR: clip input is invalid: None
If the clip is from a checkpoint loader node your checkpoint does not contain a valid clip or text encoder model.
```

## What was wrong

`CheckpointLoaderSimple` can load a **diffusion model only** checkpoint and silently return `CLIP = None`. The workflow only fails later at `CLIPTextEncode`, with a message that does not explain how to fix it.

This repo patches ComfyUI so checkpoint loaders **fail immediately** with model-specific guidance (Flux, SD3, SDXL, etc.).

## Start ComfyUI locally (port 8188)

ComfyUI was not loading because dependencies were missing (`python3-venv`, Python packages, and required folders like `custom_nodes/`).

**One-command start:**

```bash
chmod +x scripts/start-comfyui.sh
./scripts/start-comfyui.sh
```

Then open: **http://127.0.0.1:8188**

The script will on first run:
1. Check for `python3-venv` (install with `sudo apt-get install -y python3-venv` if missing)
2. Create `ComfyUI/venv` and install dependencies
3. Create required folders (`models/`, `custom_nodes/`, `input/`, `output/`)
4. Start ComfyUI on port **8188**

**Options:**

```bash
# CPU-only mode (no GPU)
./scripts/start-comfyui.sh --cpu

# Listen on all interfaces (LAN access)
HOST=0.0.0.0 ./scripts/start-comfyui.sh

# Different port
PORT=8189 ./scripts/start-comfyui.sh
```

**Manual start (after deps are installed):**

```bash
cd ComfyUI
source venv/bin/activate
python main.py --listen 127.0.0.1 --port 8188
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
