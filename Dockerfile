# syntax=docker/dockerfile:1
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="RenderBoost Worker"
LABEL org.opencontainers.image.description="Optimized container for RenderBoost Blender workers with Mesa 26.x, Node.js 22, FFmpeg, and pre-baked Blender kernel runtimes"
LABEL org.opencontainers.image.source="https://github.com/agsdaegrytewwerty/ehrtedsaf"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 1. Install foundational packages and add kisak-mesa PPA for Mesa 26.x
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        software-properties-common \
    && add-apt-repository -y ppa:kisak/kisak-mesa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        # Graphics, Gallium & EEVEE D3D12 dependencies (Mesa 26.x)
        libgl1-mesa-dri \
        mesa-libgallium \
        libegl-mesa0 \
        libgl1 \
        libegl1 \
        libopengl0 \
        libgbm1 \
        # Media and transcoding
        ffmpeg \
        # System utilities and archiving
        curl \
        zip \
        unzip \
        xz-utils \
        p7zip-full \
        # Python & database probes
        python3 \
        python3-pip \
        python3-psycopg2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Install official Node.js 22 LTS
ARG NODE_VERSION=22.10.0
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    && node --version \
    && npm --version

# 3. Optionally pre-bake custom Blender client release for specific GPU kernel architecture
ARG BLENDER_VARIANT=""
ARG BLENDER_URL=""
ARG BLENDER_ARTIFACT_ID=""
ARG BLENDER_VERSION="5.2.0"

RUN if [ -n "$BLENDER_URL" ]; then \
        echo "Installing Blender ${BLENDER_VERSION} (${BLENDER_VARIANT})..." \
        && mkdir -p /tmp/blender-extract /opt/blender-${BLENDER_VERSION} \
        && curl -fsSL "$BLENDER_URL" | tar -xJ -C /tmp/blender-extract \
        && EXTRACTED_DIR=$(find /tmp/blender-extract -maxdepth 1 -mindepth 1 -type d -name "blender-*" | head -n 1) \
        && cp -a "$EXTRACTED_DIR/." /opt/blender-${BLENDER_VERSION}/ \
        && rm -rf /tmp/blender-extract \
        && ln -sf /opt/blender-${BLENDER_VERSION}/blender /usr/local/bin/blender \
        && if [ -n "$BLENDER_ARTIFACT_ID" ]; then \
               printf '%s\n' "$BLENDER_ARTIFACT_ID" > /opt/blender-${BLENDER_VERSION}/.renderboost-runtime-artifact; \
           fi \
        && /usr/local/bin/blender --version; \
    fi

# 4. Prepare runtime directories expected by RenderBoost worker scripts
RUN mkdir -p /opt/renderboost /tmp/renderboost-blender-startup-logs /usr/share/nvidia

WORKDIR /root
CMD ["/bin/bash"]
