"""Portable H3 CONDITIONING only. Joint audio/video sampled latents stay on the worker."""
import io
import os
from pathlib import Path
import re
import tempfile

import torch
import folder_paths

SCHEMA = "projectswift.h3.conditioning.v1"
METADATA_FIELDS = ("cache_key", "width", "height", "frame_count", "encoder_revision",
                   "text_encoder", "video_vae", "preprocessing")


def cpu_copy(value):
    if isinstance(value, torch.Tensor):
        return value.detach().to("cpu").contiguous().clone()
    if isinstance(value, dict):
        if not all(isinstance(k, str) for k in value):
            raise ValueError("Condition metadata keys must be strings")
        return {k: cpu_copy(v) for k, v in value.items()}
    if isinstance(value, list):
        return [cpu_copy(v) for v in value]
    if isinstance(value, tuple):
        return tuple(cpu_copy(v) for v in value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"Unsupported H3 conditioning value: {type(value).__name__}")


def validate_metadata(metadata):
    if not re.fullmatch(r"[0-9a-f]{64}", metadata["cache_key"]):
        raise ValueError("Invalid conditioning cache key")
    if any(metadata[k] < 32 or metadata[k] % 32 for k in ("width", "height")):
        raise ValueError("H3 dimensions must be multiples of 32")
    if metadata["frame_count"] < 5 or metadata["frame_count"] % 17 != 5:
        raise ValueError("H3 frame count must be 17k+5")


def validate_condition(condition, metadata):
    if not isinstance(condition, (list, tuple)) or not condition:
        raise ValueError("Empty H3 conditioning")
    for entry in condition:
        if not isinstance(entry, (list, tuple)) or len(entry) != 2:
            raise ValueError("Invalid conditioning entry")
        embedding, extras = entry
        if not isinstance(embedding, torch.Tensor) or not isinstance(extras, dict):
            raise ValueError("Invalid H3 embedding or metadata")
        if not isinstance(extras.get("minimax_token_tags"), torch.Tensor):
            raise ValueError("H3 modality token tags missing")
        keyframes = extras.get("minimax_keyframes")
        if not isinstance(keyframes, list) or not keyframes:
            raise ValueError("H3 first-frame conditioning missing")
        for keyframe in keyframes:
            latent = keyframe.get("latent")
            if not isinstance(latent, torch.Tensor) or latent.ndim != 5 or latent.shape[1] != 24:
                raise ValueError("Invalid H3 keyframe latent")
            if tuple(latent.shape[-2:]) != (metadata["height"] // 16, metadata["width"] // 16):
                raise ValueError("Keyframe latent dimensions differ from target canvas")
            if not 0 <= keyframe.get("resolved_frame_index", -1) < metadata["frame_count"]:
                raise ValueError("Keyframe index outside target clip")


def save_artifact(path, condition, metadata):
    validate_metadata(metadata)
    validate_condition(condition, metadata)
    envelope = {"schema": SCHEMA, "metadata": dict(metadata), "condition": cpu_copy(condition)}
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".h3-", dir=path.parent)
    os.close(handle)
    try:
        with open(temporary, "wb") as target:
            torch.save(envelope, target)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_artifact(path, expected):
    validate_metadata(expected)
    with open(path, "rb") as handle:
        magic = handle.read(4)
    if magic == b"\x28\xb5\x2f\xfd":
        import zstandard
        with open(path, "rb") as handle, zstandard.ZstdDecompressor().stream_reader(handle) as reader:
            source = io.BytesIO(reader.read())
    else:
        source = path
    envelope = torch.load(source, map_location="cpu", weights_only=True)
    if not isinstance(envelope, dict) or envelope.get("schema") != SCHEMA:
        raise ValueError("Unsupported conditioning schema; WAN files cannot be used with H3")
    if envelope.get("metadata") != expected:
        raise ValueError("H3 conditioning profile mismatch; regenerate conditioning locally")
    validate_condition(envelope["condition"], expected)
    return envelope["condition"]


def metadata_inputs():
    return {
        "cache_key": ("STRING", {"default": ""}),
        "width": ("INT", {"default": 768, "min": 32, "step": 32}),
        "height": ("INT", {"default": 768, "min": 32, "step": 32}),
        "frame_count": ("INT", {"default": 124, "min": 5, "step": 17}),
        "encoder_revision": ("STRING", {"default": ""}),
        "text_encoder": ("STRING", {"default": ""}),
        "video_vae": ("STRING", {"default": ""}),
        "preprocessing": ("STRING", {"default": "first-frame-stretch-v1"}),
    }


def resolve_path(filename):
    path = Path(folder_paths.get_annotated_filepath(filename)).resolve()
    roots = [Path(getter()).resolve() for getter in
             (folder_paths.get_input_directory, folder_paths.get_output_directory, folder_paths.get_temp_directory)]
    if not any(path.is_relative_to(root) for root in roots):
        raise ValueError("Conditioning file must be in ComfyUI input/output/temp")
    return path


class SaveH3Condition:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"condition": ("CONDITIONING",), **metadata_inputs()}}

    RETURN_TYPES = ()
    OUTPUT_NODE = True
    CATEGORY = "ProjectSwift/H3"
    FUNCTION = "save"

    def save(self, condition, **metadata):
        subfolder = "projectswift/h3/conditions"
        validate_metadata(metadata)
        filename = metadata["cache_key"] + ".ckpt"
        save_artifact(Path(folder_paths.get_output_directory()) / subfolder / filename, condition, metadata)
        return {"ui": {"conditions": [{"filename": filename, "subfolder": subfolder, "type": "output"}]}}


class LoadH3Condition:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"filename": ("STRING", {"default": ""}), **metadata_inputs()}}

    RETURN_TYPES = ("CONDITIONING",)
    CATEGORY = "ProjectSwift/H3"
    FUNCTION = "load"

    @classmethod
    def IS_CHANGED(cls, filename, **metadata):
        path = resolve_path(filename)
        stat = path.stat()
        return (stat.st_mtime_ns, stat.st_size)

    def load(self, filename, **metadata):
        return (load_artifact(resolve_path(filename), metadata),)


NODE_CLASS_MAPPINGS = {
    "ProjectSwiftSaveH3Condition": SaveH3Condition,
    "ProjectSwiftLoadH3Condition": LoadH3Condition,
}
