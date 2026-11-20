# 10Eros-Max on two Salad RTX 5090s

The two workflows are ComfyUI API-format JSON. Each Salad Container Group runs one replica on one desktop RTX 5090. Submit jobs from your own machine with `run_pipeline.py`. It moves the conditioning between the two authenticated Salad gateways and saves the finished MP4 locally.

| Group | Work | Model files |
| --- | --- | --- |
| `eros-h3-encoder` | Encodes the prompt and one reference image. Saves the H3 embedding, token tags, and encoded image reference. | H3 Qwen3-VL W4/W6 15.35 GB and H3 INT8 video VAE |
| `eros-h3-render` | Creates the empty audio/video latent, applies model patches, samples, decodes both streams, and writes an MP4 with generated audio. | 10Eros-Max Beta 7 Fix1 learned HQ 18.73 GB, H3 INT8 video VAE, and H3 audio VAE |

The split follows the ProjectSwift H3 workflow and its existing conditioning handoff in `gemmi/master/Support/H3_VIDEO.md` and `WorkflowEngine+H3.swift`. The image setup takes cues from `gemmi/ehrtedsaf/Dockerfile.h3`. This version uses the screenshot's **Reference to Video** conditioning and keeps the supplied image as a reference. For a prompt that names it, use `<Picture 1>`. The original ProjectSwift workflow uses a first-frame anchor and its Salad image uses an RTX 3090-specific PyTorch build.

## Checkpoint choice

The renderer uses **Beta 7 Fix1 learned W6/INT8 HQ**, the 18.73 GB checkpoint. Its model card reports better calibration reconstruction and a subjective preference over the 22.94 GB native INT8 Fix1 companion in some runs. There is no controlled video-quality ranking. The older 18.69 GB W6/INT8 HQ quant uses Beta 5 weights. [Quantization notes](https://huggingface.co/LokkenJP/TenEros_Max_optimized_learned/blob/main/README.md)

The first smoke test uses the compact 15.35 GB encoder. For a quality-focused encoder comparison, set `H3_ENCODER_PROFILE=int8` before both `salad.py plan` / `create` and `run_pipeline.py`. This selects the official 27.14 GB H3 Qwen3-VL INT8 ConvRot encoder and brings the encoder's total weight download to about 30 GB. Use a different group prefix if you want to preserve an existing pair. The INT8 profile leaves less working VRAM and may offload more. [Official H3 text encoders](https://huggingface.co/Comfy-Org/MiniMax-H3/tree/main/text_encoders)

## Build and publish

Requires a Salad organization and project, a Salad API key, and a registry image that Salad can pull. The client requires Python 3.10+ and uses the standard library. Keep the Salad API key on the client.

- **GitHub Actions.** Put this directory at the root of a repository and manually dispatch **Build Salad H3 runtime**. It pushes to GHCR. Copy the full `image@sha256:...` from the job summary. Make the package pullable by Salad, or set registry authentication on the Salad groups before starting.
- **Docker Buildx.** Push to a registry you control. Use the immutable image digest printed by the build. Both roles use the same image.

```sh
docker buildx build --platform linux/amd64 \
  --tag YOUR_REGISTRY/salad-h3:v1 --push .
```

The image pins ComfyUI v0.44.0, VideoHelperSuite, and CUDA 13 PyTorch with Blackwell support. On first boot, the encoder downloads about **18.2 GB** and the renderer about **22.2 GB**. Each model is revision-pinned and verified against its byte count and SHA-256 before ComfyUI starts. The download runs at startup so the image stays small, a tradeoff for longer cold starts when a node is replaced. Use the Salad logs to distinguish GPU allocation, image pull, model download, and ComfyUI readiness. [Salad registry docs](https://docs.salad.com/container-engine/explanation/infrastructure-platform/container-registries) · [ComfyUI CUDA runtime](https://github.com/Comfy-Org/ComfyUI-Standalone-Environments/releases)

## Create and start the two groups

In your shell, set `SALAD_API_KEY` securely and set these non-secret values.

```sh
export SALAD_ORG=your-organization
export SALAD_PROJECT=your-project
export H3_IMAGE=YOUR_REGISTRY/salad-h3@sha256:YOUR_DIGEST

python3 salad.py plan
python3 salad.py create
python3 salad.py start
python3 salad.py status
```

`plan` reads the organization's live GPU classes and prints the two group payloads. `create` creates groups with autostart off. `start` is the billable step. The default plan requests 4 vCPU, 32 GiB RAM, 64 GiB disk, and Batch priority per group. Supply `--gpu-class ID` if the organization lists several RTX 5090 classes. Supply the same `--prefix` on each command if you need names other than `eros-h3-encoder` and `eros-h3-render`. The script leaves mismatched existing groups for the operator to resolve. For a private registry, set the registry credentials in the Salad Portal after creating the stopped groups or create the groups there with the settings in the plan. [Salad GPU class API](https://docs.salad.com/reference/saladcloud-api/organizations/list-gpu-classes) · [Salad Container Gateway](https://docs.salad.com/container-engine/explanation/infrastructure-platform/networking)

Use the two authenticated HTTPS gateway URLs from `status`. Wait until the groups report ready in Salad and both URLs answer `/system_stats` with the `Salad-Api-Key` request header. A node is first considered ready after its weights are verified and ComfyUI is listening. The weight files, queue history, and outputs live in the container and are lost on reallocation.

## Run the smoke clip

```sh
export H3_ENCODER_URL=https://YOUR_ENCODER_GATEWAY
export H3_RENDER_URL=https://YOUR_RENDER_GATEWAY

python3 run_pipeline.py \
  --image smoke-reference.png \
  --prompt 'The paper windmill in <Picture 1> slowly turns in a light breeze. Static camera. Quiet garden ambience.' \
  --width 832 --height 480 --duration 5 --seed 12345 \
  --conditioning-out smoke.h3cond --output smoke.mp4

ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,r_frame_rate,nb_frames \
  -of json smoke.mp4
```

Expect video and audio streams, 832 × 480 dimensions, 24 fps, and 124 frames. A request for 5 seconds rounds up to the H3 frame grid `17k + 5`, so the video lasts about 5.17 seconds. Play the MP4 to check reference adherence and synced audio. Record both prompt IDs and seed from the client output for repeatability. Once finished, `python3 salad.py stop` stops the two groups.

## Use with your own images

Replace the smoke image and prompt. Default sampler settings are Euler / Simple, 8 steps, denoise 1, video shift 12, and audio shift 3. The renderer uses native H3 video decoding with the VAE’s internal tiling and H.264/AAC output at 24 fps. This rebuild uses ComfyUI's default attention backend. [10Eros-Max model card](https://huggingface.co/TenStrip/10Eros-Max) · [H3 reference template](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_minimax_h3_r2v.json)

- For repeat seeds or an interrupted renderer, use `--conditioning-in smoke.h3cond` with the original canvas and duration. The encoder server is only needed when making new conditioning.
- For a model-only LoRA, first make the compatible file available in the renderer's ComfyUI `models/loras` folder, for example through a derivative runtime image. Use `--lora FILE STRENGTH`. Repeat to build a stack. There are no default LoRAs and the image installs none.
- The workflows use the screenshot's internal node IDs where practical. The client exposes the image, prompt, duration, seed, steps, LoRA stack, and video output without requiring the original wrapper's v6 JSON. For another client, queue the encoder graph, fetch node 37's `conditions` file, upload it as `temp` on the render server, queue the render graph, then fetch node 32's MP4. Only the client-facing uploader and downloader need the API key.
- Start at the smoke dimensions and increase resolution or duration after a real 5090 canary. Each graph is queued through `/prompt` and polled through `/history`. If a POST times out, check the printed prompt ID on that worker before resubmitting.

## Validation status

See `VALIDATION.md` for local test results and the remaining Salad canary. The build and deployment commands are included for your registry and Salad project.
