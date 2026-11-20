"""Verify role-specific weights before starting ComfyUI."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from time import time_ns

MODELS = Path("/opt/ComfyUI/models")
MANIFEST = Path(__file__).with_name("models.json")


def verified(path, model):
    if not path.is_file() or path.stat().st_size != model["bytes"]:
        return False
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest() == model["sha256"]


def prepare_model(model):
    target = MODELS / model["folder"] / Path(model["file"]).name
    target.parent.mkdir(parents=True, exist_ok=True)
    if verified(target, model):
        print(f"Verified cached {target.name}", flush=True)
        return
    partial = target.with_suffix(".partial")
    for attempt in range(2):
        if partial.exists() and partial.stat().st_size > model["bytes"]:
            partial.unlink()
        if not partial.exists() or partial.stat().st_size < model["bytes"]:
            base = f'https://huggingface.co/{model["repo"]}/resolve/{model["revision"]}/{model["file"]}'
            url = f"{base}?download=true&salad={time_ns()}"
            print(f"Fetching {target.name} ({model['bytes'] / 1e9:.2f} GB)", flush=True)
            try:
                subprocess.run(
                    ["curl", "--fail", "--location", "--silent", "--show-error",
                     "--retry", "4", "--retry-delay", "5", "--connect-timeout", "30",
                     "--speed-limit", "32768", "--speed-time", "90",
                     "--continue-at", "-", "--output", str(partial), url],
                    check=True,
                )
            except subprocess.CalledProcessError as exc:
                if exc.returncode == 33 and attempt == 0:
                    partial.unlink(missing_ok=True)
                    continue
                raise
        if verified(partial, model):
            partial.replace(target)
            print(f"Verified {target.name}", flush=True)
            return
        partial.unlink(missing_ok=True)
    raise RuntimeError(f"Model failed size or SHA-256 verification: {target.name}")


def main():
    import torch

    role = os.environ.get("H3_ROLE")
    if role not in ("encoder", "render"):
        raise SystemExit("H3_ROLE must be encoder or render")
    if not torch.cuda.is_available() or torch.cuda.get_device_capability(0) != (12, 0):
        raise SystemExit("Expected an allocation with a working Blackwell CUDA GPU")
    if "RTX 5090" not in torch.cuda.get_device_name(0):
        raise SystemExit("Expected an RTX 5090 on CUDA device 0")
    torch.ones(1, device="cuda").add_(1)
    torch.cuda.synchronize()
    print(f"{role} on {torch.cuda.get_device_name(0)}, CUDA {torch.version.cuda}", flush=True)

    manifest = json.loads(MANIFEST.read_text())
    if role == "encoder":
        profile = os.environ.get("H3_ENCODER_PROFILE", "compact")
        if profile not in manifest["encoder_profiles"]:
            raise SystemExit("H3_ENCODER_PROFILE must be compact or int8")
        role_assets = [manifest["encoder_profiles"][profile]]
    else:
        role_assets = manifest["render"] + [manifest["audio"]]
    assets = manifest["shared"] + role_assets
    for asset in assets:
        prepare_model(asset)
    flags = ["--listen", "0.0.0.0,::", "--port", "8188", "--cuda-device", "0",
             "--reserve-vram", "1", "--max-upload-size", "132",
             "--offline", "--disable-auto-launch", "--disable-assets"]
    os.execv(sys.executable, [sys.executable, "main.py", *flags])


if __name__ == "__main__":
    main()
