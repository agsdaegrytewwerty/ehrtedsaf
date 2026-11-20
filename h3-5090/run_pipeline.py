"""Queue the encoder and render workflows on two ComfyUI HTTPS endpoints."""
import argparse
from contextlib import nullcontext
import json
import math
import os
from pathlib import Path
import secrets
import sys
import tempfile
import time
from urllib.parse import urlencode
from uuid import uuid4

from http_client import Client, RequestError

ROOT = Path(__file__).resolve().parent
TRANSIENT = (None, 408, 429, 500, 502, 503, 504)
CONDITION_LIMIT = 128 * 1024 * 1024


def graph(name):
    return json.loads((ROOT / "workflows" / f"{name}.api.json").read_text())


def frame_count(seconds):
    if not math.isfinite(seconds) or not 1 <= seconds <= 15:
        raise ValueError("Duration must be 1 to 15 seconds")
    frames = round(24 * seconds)
    return frames + (5 - frames) % 17


def upload(client, filename, data):
    boundary = f"salad-h3-{uuid4().hex}"
    if len(data) > CONDITION_LIMIT:
        raise ValueError("Upload exceeds 128 MiB")
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ntemp\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{filename}\"\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    with client.request("/upload/image", method="POST", body=body,
                        content_type=f"multipart/form-data; boundary={boundary}") as reply:
        uploaded = json.load(reply)
    if uploaded.get("type") != "temp" or uploaded.get("subfolder") or uploaded["name"] != filename:
        raise RuntimeError("Unexpected upload location")
    return uploaded["name"]


def run_graph(client, prompt, stage, timeout):
    job = str(uuid4())
    print(f"{stage} prompt ID {job}", flush=True)
    result = client.json("/prompt", {"prompt": prompt, "prompt_id": job,
                                    "extra_data": {"extra_pnginfo": {
                                        "workflow": {"extra": {"VHS_MetadataImage": False}}
                                    }}})
    if result["prompt_id"] != job:
        raise RuntimeError(f"{stage} returned an unexpected prompt ID")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            item = client.json(f"/history/{job}").get(job)
        except RequestError as err:
            if err.status not in TRANSIENT:
                raise
            item = None
        if item:
            status = item.get("status", {}).get("status_str")
            if status != "success":
                errors = [detail for event, detail in item["status"].get("messages", [])
                          if event == "execution_error"]
                error = errors[-1] if errors else {}
                message = error.get("exception_message", "See worker logs")
                raise RuntimeError(f"{stage} failed at {error.get('node_id', '?')}: {message}")
            return item["outputs"]
        time.sleep(3)
    raise TimeoutError(f"{stage} timed out for {job}. Check worker history before resubmitting.")


def file_query(item):
    return "/view?" + urlencode({key: item[key] for key in ("filename", "subfolder", "type")})


def encode(client, args, frames, run_id, target):
    source = args.image
    supported = {".png", ".jpg", ".jpeg", ".webp"}
    if source.suffix.lower() not in supported:
        raise ValueError("Use a PNG, JPEG, or WebP reference image")
    if source.stat().st_size > 20 * 1024 * 1024:
        raise ValueError("Reference image exceeds 20 MiB")
    image = upload(client, run_id + source.suffix.lower(), source.read_bytes())
    prompt = graph("encoder")
    assets = json.loads((ROOT / "models.json").read_text())
    prompt["8"]["inputs"]["clip_name"] = Path(assets["encoder_profiles"][args.encoder_profile]["file"]).name
    prompt["3"]["inputs"]["image"] = image + " [temp]"
    prompt["18"]["inputs"]["value"] = args.prompt
    prompt["19"]["inputs"].update(width=args.width, height=args.height, length=frames,
                                 ref_image_size=args.ref_image_size)
    prompt["37"]["inputs"].update(filename=run_id + ".h3cond", width=args.width,
                                 height=args.height, frames=frames)
    result = run_graph(client, prompt, "Encoder", args.timeout)
    client.download(file_query(result["37"]["conditions"][0]), target)


def render(client, args, frames, run_id, conditioning):
    if conditioning.stat().st_size > CONDITION_LIMIT:
        raise ValueError("Conditioning exceeds 128 MiB")
    name = upload(client, run_id + ".h3cond", conditioning.read_bytes())
    prompt = graph("render")
    prompt["20"]["inputs"].update(width=args.width, height=args.height, length=frames)
    prompt["38"]["inputs"].update(filename=name, width=args.width,
                                 height=args.height, frames=frames)
    seed = args.seed if args.seed is not None else secrets.randbits(48)
    prompt["25"]["inputs"]["noise_seed"] = seed
    prompt["27"]["inputs"]["sampler_name"] = args.sampler
    prompt["29"]["inputs"].update(steps=args.steps, scheduler=args.scheduler)
    prompt["32"]["inputs"]["filename_prefix"] = f"salad-h3/{run_id}"
    model = ["7", 0]
    for index, (lora_name, value) in enumerate(args.lora, 100):
        strength = float(value)
        if not math.isfinite(strength) or abs(strength) > 100:
            raise ValueError("LoRA strength must be finite and within -100 to 100")
        prompt[str(index)] = {"class_type": "LoraLoaderModelOnly",
                              "inputs": {"model": model, "lora_name": lora_name,
                                         "strength_model": strength}}
        model = [str(index), 0]
    prompt["33"]["inputs"]["model"] = model
    print(f"Render with {args.width}x{args.height}, {frames} frames at 24 fps, seed {seed}",
          flush=True)
    outputs = run_graph(client, prompt, "Render", args.timeout)
    files = outputs["32"].get("gifs", [])
    video = next((item for item in files if item["filename"].lower().endswith(".mp4")), None)
    if not video:
        raise RuntimeError("Video Combine did not report an MP4")
    client.download(file_query(video), args.output)
    print(f"Saved {args.output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", type=Path)
    source.add_argument("--conditioning-in", type=Path, help="Reuse already encoded conditioning")
    parser.add_argument("--prompt")
    parser.add_argument("--conditioning-out", type=Path, help="Keep the encoded file for seed variants")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--encoder-profile", choices=("compact", "int8"),
                        default=os.environ.get("H3_ENCODER_PROFILE", "compact"))
    parser.add_argument("--encoder-url", default=os.environ.get("H3_ENCODER_URL"))
    parser.add_argument("--render-url", default=os.environ.get("H3_RENDER_URL"))
    parser.add_argument("--width", type=int, default=832)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--duration", type=float, default=5)
    parser.add_argument("--ref-image-size", choices=("match", "max"), default="match")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--sampler", choices=("euler", "er_sde"), default="euler")
    parser.add_argument("--scheduler", choices=("simple", "sgm_uniform"), default="simple")
    parser.add_argument("--lora", action="append", nargs=2, default=[], metavar=("FILENAME", "STRENGTH"))
    parser.add_argument("--timeout", type=int, default=1800, help="Seconds per stage")
    parser.add_argument("--local-test", action="store_true", help="Allow loopback HTTP only")
    args = parser.parse_args()
    if args.encoder_profile not in ("compact", "int8"):
        parser.error("H3_ENCODER_PROFILE must be compact or int8")
    key = os.environ.get("SALAD_API_KEY")
    if not key and not args.local_test:
        parser.error("Set SALAD_API_KEY in the client environment")
    if not args.render_url or (args.image and not args.encoder_url):
        parser.error("Set H3_RENDER_URL and set H3_ENCODER_URL for new conditioning")
    if args.image and not (args.prompt or "").strip():
        parser.error("--prompt is required with --image")
    if args.conditioning_in and (args.prompt or args.conditioning_out):
        parser.error("Reuse conditioning with its original geometry and duration")
    if any(side < 32 or side > 1344 or side % 32 for side in (args.width, args.height)):
        parser.error("Width and height must be multiples of 32 between 32 and 1344")
    if args.width * args.height > 1344 * 768:
        parser.error("Keep the canvas within 1344 x 768 pixels of area")
    if args.seed is not None and not 0 <= args.seed < 2**64:
        parser.error("Seed must be an unsigned 64-bit integer")
    if not 1 <= args.steps <= 100 or args.timeout <= 0:
        parser.error("Use 1 to 100 steps and a positive timeout")
    if args.output.suffix.lower() != ".mp4" or args.output.exists():
        parser.error("--output must be a new .mp4 path")
    if args.conditioning_out and (args.conditioning_out.exists()
                                  or args.conditioning_out.resolve() == args.output.resolve()):
        parser.error("--conditioning-out must be a new path distinct from the video output")
    try:
        frames = frame_count(args.duration)
        run_id = uuid4().hex
        renderer = Client(args.render_url, key, args.local_test)
        if args.conditioning_in:
            render(renderer, args, frames, run_id, args.conditioning_in)
            return
        directory = tempfile.TemporaryDirectory() if not args.conditioning_out else nullcontext(None)
        with directory as temporary:
            artifact = args.conditioning_out or Path(temporary) / "reference.h3cond"
            encode(Client(args.encoder_url, key, args.local_test), args, frames, run_id, artifact)
            render(renderer, args, frames, run_id, artifact)
    except (RuntimeError, OSError, ValueError, KeyError) as err:
        sys.exit(str(err))


if __name__ == "__main__":
    main()
