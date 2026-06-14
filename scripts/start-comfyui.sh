#!/usr/bin/env bash
# Robust ComfyUI launcher:
# - persistent data directory (workflow/history survives repo updates)
# - automatic workflow/settings snapshots
# - GPU profile-aware torch install (CPU/NVIDIA/AMD ROCm)
# - AMD Vulkan profile with sane env defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_DIR="${COMFYUI_DIR:-$SCRIPT_DIR/../ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFYUI_DIR/venv}"
COMFY_DATA_DIR="${COMFY_DATA_DIR:-$HOME/.local/share/comfyui}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8188}"
TORCH_PROFILE="${TORCH_PROFILE:-auto}" # auto|cpu|nvidia|amd-rocm|amd-vulkan
WORKFLOW_BACKUP_INTERVAL="${WORKFLOW_BACKUP_INTERVAL:-180}"
WORKFLOW_BACKUP_KEEP="${WORKFLOW_BACKUP_KEEP:-24}"

DRY_RUN=0
WORKFLOW_WATCHDOG=1
AMD_GFX_VERSION="${AMD_GFX_VERSION:-}"
EXTRA_ARGS=()
WATCHDOG_PID=""
SERVER_PID=""

usage() {
  cat <<'EOF'
Usage: start-comfyui.sh [options] [-- extra main.py args]

Options:
  --host <ip>                 Listen IP (default: 127.0.0.1)
  --port <port>               Listen port (default: 8188)
  --data-dir <path>           Persistent Comfy data root (default: ~/.local/share/comfyui)
  --venv-dir <path>           Python venv path (default: ComfyUI/venv)
  --torch-profile <profile>   auto|cpu|nvidia|amd-rocm|amd-vulkan
  --cpu                       Shortcut for --torch-profile cpu and passes --cpu to ComfyUI
  --amd-vulkan                Shortcut for --torch-profile amd-vulkan
  --amd-rocm                  Shortcut for --torch-profile amd-rocm
  --amd-gfx-version <value>   Sets HSA_OVERRIDE_GFX_VERSION (e.g. 10.3.0, 11.0.0)
  --no-workflow-watchdog      Disable periodic workflow/settings snapshots
  --backup-interval <seconds> Snapshot interval (default: 180)
  --backup-keep <count>       Number of snapshots to keep (default: 24)
  --dry-run                   Print environment and command without launching
  -h, --help                  Show this help

Examples:
  ./scripts/start-comfyui.sh
  ./scripts/start-comfyui.sh --amd-vulkan --amd-gfx-version 11.0.0
  HOST=0.0.0.0 PORT=8188 ./scripts/start-comfyui.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --data-dir)
      COMFY_DATA_DIR="${2:-}"
      shift 2
      ;;
    --venv-dir)
      VENV_DIR="${2:-}"
      shift 2
      ;;
    --torch-profile)
      TORCH_PROFILE="${2:-}"
      shift 2
      ;;
    --cpu)
      TORCH_PROFILE="cpu"
      EXTRA_ARGS+=("--cpu")
      shift
      ;;
    --amd-vulkan)
      TORCH_PROFILE="amd-vulkan"
      shift
      ;;
    --amd-rocm)
      TORCH_PROFILE="amd-rocm"
      shift
      ;;
    --amd-gfx-version)
      AMD_GFX_VERSION="${2:-}"
      shift 2
      ;;
    --no-workflow-watchdog)
      WORKFLOW_WATCHDOG=0
      shift
      ;;
    --backup-interval)
      WORKFLOW_BACKUP_INTERVAL="${2:-}"
      shift 2
      ;;
    --backup-keep)
      WORKFLOW_BACKUP_KEEP="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "$COMFYUI_DIR/main.py" ]]; then
  echo "ComfyUI not found at: $COMFYUI_DIR" >&2
  echo "Set COMFYUI_DIR to your ComfyUI install path." >&2
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "Invalid port: $PORT" >&2
  exit 1
fi

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

detect_nvidia() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

detect_amd() {
  if [[ -e /dev/kfd ]]; then
    return 0
  fi
  if command -v lspci >/dev/null 2>&1; then
    lspci 2>/dev/null | rg -i "vga|3d|display" | rg -qi "amd|ati|radeon"
    return $?
  fi
  return 1
}

if [[ "$TORCH_PROFILE" == "auto" ]]; then
  if detect_nvidia; then
    TORCH_PROFILE="nvidia"
  elif detect_amd; then
    TORCH_PROFILE="amd-rocm"
  else
    TORCH_PROFILE="cpu"
  fi
fi

if [[ "$TORCH_PROFILE" == "cpu" ]] && ! has_arg "--cpu" "${EXTRA_ARGS[@]}"; then
  EXTRA_ARGS=("--cpu" "${EXTRA_ARGS[@]}")
fi

if [[ -n "$AMD_GFX_VERSION" ]]; then
  export HSA_OVERRIDE_GFX_VERSION="$AMD_GFX_VERSION"
fi

if [[ "$TORCH_PROFILE" == "amd-vulkan" ]]; then
  # ROCm remains the compute backend for ComfyUI, but these Vulkan/AMD env vars
  # improve compatibility for AMD Mesa stacks and some mixed workloads.
  export PYTORCH_TUNABLEOP_ENABLED="${PYTORCH_TUNABLEOP_ENABLED:-1}"
  export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL="${TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL:-1}"
  if [[ -z "${VK_ICD_FILENAMES:-}" ]]; then
    for icd in \
      /usr/share/vulkan/icd.d/radeon_icd.x86_64.json \
      /etc/vulkan/icd.d/radeon_icd.x86_64.json \
      /usr/share/vulkan/icd.d/amd_icd64.json \
      /etc/vulkan/icd.d/amd_icd64.json; do
      if [[ -f "$icd" ]]; then
        export VK_ICD_FILENAMES="$icd"
        break
      fi
    done
  fi
fi

if (( DRY_RUN )); then
  DB_PATH="$COMFY_DATA_DIR/user/comfyui.db"
  CMD=(
    python "$COMFYUI_DIR/main.py"
    --listen "$HOST"
    --port "$PORT"
    --base-directory "$COMFY_DATA_DIR"
    --user-directory "$COMFY_DATA_DIR/user"
    --input-directory "$COMFY_DATA_DIR/input"
    --output-directory "$COMFY_DATA_DIR/output"
    --temp-directory "$COMFY_DATA_DIR/temp"
    --database-url "sqlite:///$DB_PATH"
  )
  CMD+=("${EXTRA_ARGS[@]}")

  echo "ComfyUI dir        : $COMFYUI_DIR"
  echo "Data dir           : $COMFY_DATA_DIR"
  echo "Torch profile      : $TORCH_PROFILE"
  echo "Workflow snapshots : $COMFY_DATA_DIR/backups/workflows"
  echo "Server URL         : http://$HOST:$PORT"
  if [[ "$TORCH_PROFILE" == "amd-vulkan" ]]; then
    echo "AMD Vulkan profile enabled (VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-auto})"
  fi
  echo "Dry run command:"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

if ! python3 -c "import venv" >/dev/null 2>&1; then
  echo "python3-venv is not installed. On Ubuntu/Debian run:" >&2
  echo "  sudo apt-get install -y python3-venv python3-pip" >&2
  exit 1
fi

mkdir -p "$COMFY_DATA_DIR"
mkdir -p "$COMFY_DATA_DIR/models/checkpoints"
mkdir -p "$COMFY_DATA_DIR/models/vae"
mkdir -p "$COMFY_DATA_DIR/models/loras"
mkdir -p "$COMFY_DATA_DIR/models/text_encoders"
mkdir -p "$COMFY_DATA_DIR/models/diffusion_models"
mkdir -p "$COMFY_DATA_DIR/models/embeddings"
mkdir -p "$COMFY_DATA_DIR/custom_nodes"
mkdir -p "$COMFY_DATA_DIR/input"
mkdir -p "$COMFY_DATA_DIR/output"
mkdir -p "$COMFY_DATA_DIR/temp"
mkdir -p "$COMFY_DATA_DIR/user/default/workflows"
mkdir -p "$COMFY_DATA_DIR/logs"
mkdir -p "$COMFY_DATA_DIR/backups/workflows"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

TORCH_MARKER="$VENV_DIR/.torch-profile"
CURRENT_MARKER=""
if [[ -f "$TORCH_MARKER" ]]; then
  CURRENT_MARKER="$(<"$TORCH_MARKER")"
fi

need_install=0
if ! python -c "import sqlalchemy, aiohttp, yaml, PIL" >/dev/null 2>&1; then
  need_install=1
fi
if ! python -c "import torch" >/dev/null 2>&1; then
  need_install=1
fi
if [[ "$CURRENT_MARKER" != "$TORCH_PROFILE" ]]; then
  need_install=1
fi

if (( need_install )); then
  echo "Installing/refreshing dependencies for profile: $TORCH_PROFILE"
  pip install --upgrade pip wheel "setuptools<82"
  case "$TORCH_PROFILE" in
    cpu)
      pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
      ;;
    nvidia)
      pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130
      ;;
    amd-rocm|amd-vulkan)
      pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2
      ;;
    *)
      echo "Unknown torch profile: $TORCH_PROFILE" >&2
      exit 1
      ;;
  esac
  pip install -r "$COMFYUI_DIR/requirements.txt"
  echo "$TORCH_PROFILE" > "$TORCH_MARKER"
fi

WORKFLOW_DIR="$COMFY_DATA_DIR/user/default/workflows"
SETTINGS_FILE="$COMFY_DATA_DIR/user/default/comfy.settings.json"
BACKUP_ROOT="$COMFY_DATA_DIR/backups/workflows"

migrate_legacy_state() {
  local migration_marker="$COMFY_DATA_DIR/user/.legacy_migration_done"
  if [[ -f "$migration_marker" ]]; then
    return
  fi

  local legacy_user_dir="$COMFYUI_DIR/user/default"
  local copied=0

  if [[ -d "$legacy_user_dir/workflows" ]] && [[ -z "$(ls -A "$WORKFLOW_DIR" 2>/dev/null)" ]]; then
    cp -a "$legacy_user_dir/workflows/." "$WORKFLOW_DIR/" 2>/dev/null || true
    copied=1
  fi

  if [[ -f "$legacy_user_dir/comfy.settings.json" ]] && [[ ! -f "$SETTINGS_FILE" ]]; then
    cp "$legacy_user_dir/comfy.settings.json" "$SETTINGS_FILE"
    copied=1
  fi

  if (( copied )); then
    echo "Migrated existing workflows/settings from $legacy_user_dir"
  fi
  touch "$migration_marker"
}

snapshot_workflows() {
  local reason="${1:-snapshot}"
  local stamp
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  local snapshot_dir="$BACKUP_ROOT/snapshot-${stamp}-${reason}"
  mkdir -p "$snapshot_dir"
  if [[ -d "$WORKFLOW_DIR" ]]; then
    mkdir -p "$snapshot_dir/workflows"
    cp -a "$WORKFLOW_DIR/." "$snapshot_dir/workflows/" 2>/dev/null || true
  fi
  if [[ -f "$SETTINGS_FILE" ]]; then
    cp "$SETTINGS_FILE" "$snapshot_dir/comfy.settings.json"
  fi
}

prune_snapshots() {
  mapfile -t snapshots < <(ls -1dt "$BACKUP_ROOT"/snapshot-* 2>/dev/null || true)
  local keep_count
  keep_count="${WORKFLOW_BACKUP_KEEP:-24}"
  if [[ ! "$keep_count" =~ ^[0-9]+$ ]]; then
    keep_count=24
  fi
  if (( ${#snapshots[@]} > keep_count )); then
    local old
    for old in "${snapshots[@]:$keep_count}"; do
      rm -rf "$old"
    done
  fi
}

start_watchdog() {
  if (( WORKFLOW_WATCHDOG == 0 )); then
    return
  fi
  if [[ ! "$WORKFLOW_BACKUP_INTERVAL" =~ ^[0-9]+$ ]] || (( WORKFLOW_BACKUP_INTERVAL <= 0 )); then
    return
  fi
  (
    while true; do
      sleep "$WORKFLOW_BACKUP_INTERVAL"
      snapshot_workflows "interval"
      prune_snapshots
    done
  ) &
  WATCHDOG_PID="$!"
}

stop_watchdog() {
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
}

on_signal() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}

DB_PATH="$COMFY_DATA_DIR/user/comfyui.db"
CMD=(
  python "$COMFYUI_DIR/main.py"
  --listen "$HOST"
  --port "$PORT"
  --base-directory "$COMFY_DATA_DIR"
  --user-directory "$COMFY_DATA_DIR/user"
  --input-directory "$COMFY_DATA_DIR/input"
  --output-directory "$COMFY_DATA_DIR/output"
  --temp-directory "$COMFY_DATA_DIR/temp"
  --database-url "sqlite:///$DB_PATH"
)
CMD+=("${EXTRA_ARGS[@]}")

echo "ComfyUI dir        : $COMFYUI_DIR"
echo "Data dir           : $COMFY_DATA_DIR"
echo "Torch profile      : $TORCH_PROFILE"
echo "Workflow snapshots : $BACKUP_ROOT"
echo "Server URL         : http://$HOST:$PORT"
if [[ "$TORCH_PROFILE" == "amd-vulkan" ]]; then
  echo "AMD Vulkan profile enabled (VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-auto})"
fi

migrate_legacy_state
snapshot_workflows "startup"
prune_snapshots
start_watchdog

trap on_signal INT TERM

"${CMD[@]}" &
SERVER_PID="$!"
wait "$SERVER_PID"
status="$?"

snapshot_workflows "shutdown"
prune_snapshots
stop_watchdog

exit "$status"
