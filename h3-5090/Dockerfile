# syntax=docker/dockerfile:1
FROM python:3.13-slim-bookworm AS runtime

ENV PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl ffmpeg git libgl1 libglib2.0-0 libgomp1 libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

ARG COMFY_REV=2c75dc1b379a59e0880619d029607af5169a62ef
ARG VHS_REV=4d907bee61e92c2e65af3bd6383a4e4d356126d1
RUN git init -q /opt/ComfyUI \
    && git -C /opt/ComfyUI fetch --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_REV" \
    && git -C /opt/ComfyUI checkout --detach FETCH_HEAD \
    && rm -rf /opt/ComfyUI/.git \
    && git init -q /opt/ComfyUI/custom_nodes/VideoHelperSuite \
    && git -C /opt/ComfyUI/custom_nodes/VideoHelperSuite fetch --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "$VHS_REV" \
    && git -C /opt/ComfyUI/custom_nodes/VideoHelperSuite checkout --detach FETCH_HEAD \
    && rm -rf /opt/ComfyUI/custom_nodes/VideoHelperSuite/.git

COPY torch.constraints.txt /opt/h3/torch.constraints.txt
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu130 \
    --extra-index-url https://pypi.org/simple -r /opt/h3/torch.constraints.txt \
    && pip install --no-cache-dir -c /opt/h3/torch.constraints.txt \
       -r /opt/ComfyUI/requirements.txt -r /opt/ComfyUI/custom_nodes/VideoHelperSuite/requirements.txt \
       soundfile==0.13.1 \
    && pip check \
    && python -c 'import torch; assert torch.version.cuda.startswith("13."); assert any(a.startswith(("sm_120", "compute_120")) for a in torch._C._cuda_getArchFlags().split()), torch._C._cuda_getArchFlags()'

COPY comfy_salad_h3 /opt/ComfyUI/custom_nodes/salad_h3
COPY models.json start.py /opt/h3/
WORKDIR /opt/ComfyUI
EXPOSE 8188
CMD ["python", "/opt/h3/start.py"]

FROM runtime AS encoder
ENV H3_ROLE=encoder H3_ENCODER_PROFILE=int8
LABEL org.opencontainers.image.title="ProjectSwift H3 RTX 5090 reference encoder"

FROM runtime AS render
ENV H3_ROLE=render
LABEL org.opencontainers.image.title="ProjectSwift H3 RTX 5090 Fix1 renderer"
