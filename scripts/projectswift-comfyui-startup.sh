#!/usr/bin/env bash
set -euo pipefail

runtime_root=/opt/ComfyUI-lean
comfy_dir="$runtime_root/comfyui"
python="$runtime_root/venv/bin/python"
checkpoint="$comfy_dir/models/checkpoints/ilustmix_v9.safetensors"

test "$(cat "$runtime_root/.projectswift-runtime-sha256")" = "$PROJECTSWIFT_RUNTIME_SHA256"
test "$(stat -c %s "$checkpoint")" = 7419809082

"$python" - <<'PY'
import torch

if torch.__version__ != "2.10.0+cu130.sm86.projectswift1":
    raise SystemExit(f"Unexpected baked PyTorch: {torch.__version__}")
if not torch.cuda.is_available():
    raise SystemExit("CUDA 13 is unavailable; this image requires an NVIDIA driver compatible with CUDA 13")
if torch.cuda.get_device_capability() != (8, 6):
    raise SystemExit("This image supports SM86 GPUs only")
print(f"Using baked runtime and checkpoint on {torch.cuda.get_device_name()}", flush=True)
PY

cd "$comfy_dir"
exec "$python" main.py \
    --listen :: --port "${PORT:-8188}" \
    --reserve-vram "${PROJECTSWIFT_VRAM_RESERVE_GB:-0.3}" \
    --disable-api-nodes --disable-metadata --front-end-root "$comfy_dir/web_empty" \
    --force-fp16 --fp16-unet --bf16-vae --fp16-text-enc \
    --dont-upcast-attention --fast "$@"
