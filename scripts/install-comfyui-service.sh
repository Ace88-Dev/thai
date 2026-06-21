#!/usr/bin/env bash
# Install a user-level systemd service for resilient ComfyUI startup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SERVICE_DIR/comfyui.service"
START_SCRIPT="$SCRIPT_DIR/start-comfyui.sh"

if [[ ! -x "$START_SCRIPT" ]]; then
  echo "Making start script executable: $START_SCRIPT"
  chmod +x "$START_SCRIPT"
fi

mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ComfyUI (robust local service)
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
ExecStart=$START_SCRIPT --amd-vulkan
Restart=always
RestartSec=3
Environment=HOST=127.0.0.1
Environment=PORT=8188
Environment=COMFY_DATA_DIR=%h/.local/share/comfyui

[Install]
WantedBy=default.target
EOF

echo "Wrote: $SERVICE_FILE"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  echo
  echo "Enable + start service with:"
  echo "  systemctl --user enable --now comfyui.service"
  echo
  echo "Check status with:"
  echo "  systemctl --user status comfyui.service"
else
  echo "systemctl not found. Service file created but not activated."
fi
