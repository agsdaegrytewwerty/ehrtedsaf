"""Record the private, image-built Mesa components consumed by worker readiness."""
import hashlib
import json
from pathlib import Path
import sys

FIX_ID = "mesa-26.2.3-pb-slab-unlocked-provider-v1"


def write_manifest(root: Path, source_sha512: str, patch_sha256: str):
    root = root.resolve(strict=True)
    required = ["lib/libEGL_mesa.so.0", "lib/libgallium-26.2.3.so", "lib/libgbm.so.1"]
    for relative in required:
        file = root / relative
        if not file.is_file() or not file.resolve().is_relative_to(root):
            raise ValueError(f"Missing/private Mesa component escaped prefix: {relative}")
    egl = root / "share/glvnd/egl_vendor.d/50_mesa.json"
    egl.parent.mkdir(parents=True, exist_ok=True)
    egl.write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {
        "library_path": str(root / required[0]),
    }}, indent=2) + "\n")
    files = {}
    for file in [*sorted((root / "lib").glob("*.so*")), egl]:
        if not file.is_file() or not file.resolve().is_relative_to(root):
            raise ValueError(f"Invalid Mesa component: {file}")
        data = file.read_bytes()
        if not data:
            raise ValueError(f"Empty Mesa component: {file}")
        files[str(file.relative_to(root))] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    (root / "METADATA.json").write_text(json.dumps({
        "fix_id": FIX_ID, "mesa_version": "26.2.3", "source_sha512": source_sha512,
        "patch_sha256": patch_sha256, "files": files,
    }, indent=2) + "\n")


if __name__ == "__main__":
    write_manifest(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
