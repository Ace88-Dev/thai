#!/usr/bin/env bash
# Start ComfyUI on port 8188 (creates venv and installs deps on first run).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_DIR="${COMFYUI_DIR:-$SCRIPT_DIR/../ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFYUI_DIR/venv}"
PORT="${PORT:-8188}"
HOST="${HOST:-127.0.0.1}"

if [[ ! -f "$COMFYUI_DIR/main.py" ]]; then
  echo "ComfyUI not found at: $COMFYUI_DIR" >&2
  echo "Set COMFYUI_DIR to your ComfyUI install path." >&2
  exit 1
fi

cd "$COMFYUI_DIR"

if ! python3 -c "import venv" 2>/dev/null; then
  echo "python3-venv is not installed. On Ubuntu/Debian run:" >&2
  echo "  sudo apt-get install -y python3-venv python3-pip" >&2
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

if ! python -c "import sqlalchemy" 2>/dev/null; then
  echo "Installing ComfyUI dependencies (first run may take several minutes) ..."
  pip install --upgrade pip wheel setuptools
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "NVIDIA GPU detected — installing CUDA-enabled PyTorch from requirements.txt"
    pip install -r requirements.txt
  else
    echo "No NVIDIA GPU detected — installing CPU PyTorch"
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
    pip install -r requirements.txt
  fi
fi

mkdir -p models/checkpoints models/vae models/loras models/text_encoders models/diffusion_models input output custom_nodes user

echo "Starting ComfyUI at http://${HOST}:${PORT}"
exec python main.py --listen "$HOST" --port "$PORT" "$@"
