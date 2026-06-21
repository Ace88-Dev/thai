#!/usr/bin/env bash
# Apply the checkpoint CLIP validation fix to an existing ComfyUI install.
set -euo pipefail

COMFYUI_DIR="${1:-.}"

if [[ ! -f "$COMFYUI_DIR/comfy/sd.py" || ! -f "$COMFYUI_DIR/nodes.py" ]]; then
  echo "Usage: $0 /path/to/ComfyUI" >&2
  echo "Could not find comfy/sd.py and nodes.py under: $COMFYUI_DIR" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cp "$REPO_ROOT/ComfyUI/comfy/sd.py" "$COMFYUI_DIR/comfy/sd.py"
cp "$REPO_ROOT/ComfyUI/nodes.py" "$COMFYUI_DIR/nodes.py"

echo "Applied CLIP validation fix to $COMFYUI_DIR"
echo "Restart ComfyUI, then re-run your workflow."
