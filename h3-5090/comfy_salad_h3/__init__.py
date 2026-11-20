"""Move MiniMax H3 Ref2V conditioning between ComfyUI instances."""
import json
import re
from pathlib import Path
from tempfile import NamedTemporaryFile

import folder_paths
import torch
from safetensors import safe_open
from safetensors.torch import save_file

SCHEMA = "salad-h3.ref2v.conditioning.v1"
MAX_BYTES = 128 * 1024 * 1024
NAME = re.compile(r"[a-zA-Z0-9_-]{1,100}\.h3cond")


def condition_path(filename):
    if not NAME.fullmatch(filename):
        raise ValueError("Expected an H3 conditioning basename ending in .h3cond")
    root = Path(folder_paths.get_temp_directory()).resolve()
    path = root / filename
    if path.is_symlink():
        raise ValueError("Conditioning file must be a regular file")
    return path


def validate_condition(condition, width, height, frames):
    if min(width, height) < 32 or width % 32 or height % 32:
        raise ValueError("H3 canvas dimensions must be multiples of 32")
    if frames < 5 or frames % 17 != 5:
        raise ValueError("H3 frame count must be 17k + 5")
    if not isinstance(condition, (list, tuple)) or not condition:
        raise ValueError("H3 conditioning is empty")
    for embedding, extra in condition:
        if not isinstance(embedding, torch.Tensor) or embedding.ndim != 3:
            raise ValueError("H3 conditioning requires a 3-D embedding tensor")
        if not isinstance(extra.get("minimax_token_tags"), torch.Tensor):
            raise ValueError("H3 conditioning is missing modality token tags")
        refs = extra.get("minimax_refs", [])
        if not any(ref.get("kind") == "image" and isinstance(ref.get("latent"), torch.Tensor)
                   for ref in refs):
            raise ValueError("H3 conditioning is missing the VAE-encoded reference image")


def flatten(value, tensors):
    if isinstance(value, torch.Tensor):
        key = f"t{len(tensors)}"
        tensors[key] = value.detach().to(device="cpu", copy=True).contiguous()
        return ["tensor", key]
    if isinstance(value, dict) and all(isinstance(k, str) for k in value):
        return ["dict", {key: flatten(item, tensors) for key, item in value.items()}]
    if isinstance(value, (list, tuple)):
        return ["tuple" if isinstance(value, tuple) else "list",
                [flatten(item, tensors) for item in value]]
    if value is None or type(value) in (bool, str, int, float):
        return ["scalar", value]
    raise TypeError(f"Unsupported H3 conditioning value: {type(value).__name__}")


def restore(value, archive):
    kind, item = value
    if kind == "tensor":
        return archive.get_tensor(item)
    if kind == "dict":
        return {key: restore(child, archive) for key, child in item.items()}
    if kind in ("list", "tuple"):
        children = [restore(child, archive) for child in item]
        return tuple(children) if kind == "tuple" else children
    if kind == "scalar" and (item is None or type(item) in (bool, str, int, float)):
        return item
    raise ValueError("Unsupported H3 conditioning field")


def write_condition(path, condition, width, height, frames):
    validate_condition(condition, width, height, frames)
    tensors = {}
    tree = flatten(condition, tensors)
    metadata = {"schema": SCHEMA, "geometry": json.dumps([width, height, frames]),
                "tree": json.dumps(tree, allow_nan=False, separators=(",", ":"))}
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, delete=False) as staging:
        temp = Path(staging.name)
    try:
        save_file(tensors, str(temp), metadata=metadata)
        if temp.stat().st_size > MAX_BYTES:
            raise ValueError("H3 conditioning exceeds the 128 MiB transfer limit")
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def read_condition(path, width, height, frames):
    if not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError("H3 conditioning file is missing or exceeds 128 MiB")
    with safe_open(path, framework="pt", device="cpu") as archive:
        metadata = archive.metadata() or {}
        if metadata.get("schema") != SCHEMA:
            raise ValueError("Unsupported H3 conditioning schema")
        if json.loads(metadata["geometry"]) != [width, height, frames]:
            raise ValueError("Conditioning geometry does not match the render latent")
        condition = restore(json.loads(metadata["tree"]), archive)
    validate_condition(condition, width, height, frames)
    return condition


def file_inputs():
    return {"filename": ("STRING", {"default": "encoder-test.h3cond"}),
            "width": ("INT", {"default": 832, "min": 32, "step": 32}),
            "height": ("INT", {"default": 480, "min": 32, "step": 32}),
            "frames": ("INT", {"default": 124, "min": 5, "step": 17})}


class SaveH3Condition:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"conditioning": ("CONDITIONING",), **file_inputs()}}

    RETURN_TYPES = ()
    FUNCTION = "save"
    OUTPUT_NODE = True
    CATEGORY = "MiniMax H3/Salad"

    def save(self, conditioning, filename, width, height, frames):
        write_condition(condition_path(filename), conditioning, width, height, frames)
        return {"ui": {"conditions": [{"filename": filename, "subfolder": "", "type": "temp"}]}}


class LoadH3Condition:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": file_inputs()}

    RETURN_TYPES = ("CONDITIONING",)
    FUNCTION = "load"
    CATEGORY = "MiniMax H3/Salad"

    @classmethod
    def IS_CHANGED(cls, filename, **_):
        stat = condition_path(filename).stat()
        return (stat.st_mtime_ns, stat.st_size)

    def load(self, filename, width, height, frames):
        return (read_condition(condition_path(filename), width, height, frames),)


NODE_CLASS_MAPPINGS = {"SaladH3SaveCondition": SaveH3Condition,
                       "SaladH3LoadCondition": LoadH3Condition}
NODE_DISPLAY_NAME_MAPPINGS = {"SaladH3SaveCondition": "Save H3 Reference Conditioning",
                              "SaladH3LoadCondition": "Load H3 Reference Conditioning"}
