# Validation

Local checks passed for the deployment package.

- Both API graphs passed validation against the pinned ComfyUI v0.44.0 server node registry. The encoder graph was checked with both the compact and official INT8 encoder filenames installed as schema fixtures.
- The native H3 Reference-to-Video node ran on CPU with test doubles for the Qwen and VAE weights. Its empty joint audio/video latent matched the empty latent made on the renderer. The safetensors handoff preserved the embedding, modality tags, and reference latent. The loader rejected mismatched dimensions and frame counts.
- A two-server loopback test used simulated inference to check multipart uploads, prompt submission, history polling, artifact downloads, conditioning reuse, and model-only LoRA placement.
- Pinned VideoHelperSuite and FFmpeg wrote a test MP4 from synthetic frames and audio. FFprobe verified H.264, AAC, and 24 fps.
- Both one-replica Salad payloads passed validation against the published Salad OpenAPI create schema. Hugging Face's pinned file metadata matched the recorded byte counts and SHA-256 digests.

The GPU-side Docker build, image pull, model downloads, and real RTX 5090 inference require the registry and Salad project run. The included smoke clip checks the first real deployment. Peak VRAM, output quality, cold-start time, and cross-worker transfer times remain unmeasured.
