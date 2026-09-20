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
        libglu1-mesa \
        # Blender shared library runtime dependencies
        libatomic1 \
        libsm6 \
        libice6 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxi6 \
        libxxf86vm1 \
        libxfixes3 \
        libxrandr2 \
        libxcursor1 \
        libxinerama1 \
        libxkbcommon0 \
        libfontconfig1 \
        libfreetype6 \
        libsndfile1 \
        libpulse0 \
        # Media and transcoding
        ffmpeg \
        # System utilities and archiving
        zip \
        unzip \
        xz-utils \
        zstd \
        p7zip-full \
        # Python & database probes
        python3 \
        python3-pip \
        python3-psycopg2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Install official Node.js 22 LTS from a pinned archive
ARG NODE_VERSION=22.10.0
ARG NODE_SHA256=406791658a8bce3bc21fab786f45877adad391ea20badc87e1d65c7478b75062
RUN set -eu \
    && node_archive="/tmp/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "$node_archive" \
    && printf '%s  %s\n' "$NODE_SHA256" "$node_archive" | sha256sum -c - \
    && tar -xJ -f "$node_archive" -C /usr/local --strip-components=1 \
    && rm -f "$node_archive" \
    && node --version \
    && npm --version

# 3. Optionally pre-bake custom Blender client release for a specific GPU kernel architecture.
# The marker is the runtime identity used by the startup script before it considers
# downloading another archive.  The wheel is extracted into Blender's matching
# Python environment so frame-pixel readiness does not depend on a startup download.
ARG BLENDER_VARIANT=""
ARG BLENDER_URL=""
ARG BLENDER_SHA256=""
ARG BLENDER_ARTIFACT_ID=""
ARG BLENDER_VERSION="5.2.0"
ARG OPENIMAGEIO_WHEEL_URL="https://files.pythonhosted.org/packages/b6/d9/6cf4c59529956eb98df523a797ef7c71e6e241676720f9b443c18e53bf35/openimageio-3.1.17.0-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
ARG OPENIMAGEIO_WHEEL_SHA256="420a2cbfc7358c281a0902e9daa4ee229e7cb9071be4704ddf8943930c184f78"
ARG OPENIMAGEIO_WHEEL_BYTES="6918964"

RUN set -eu \
    && if [ -n "$BLENDER_URL" ]; then \
        echo "Installing Blender ${BLENDER_VERSION} (${BLENDER_VARIANT})" \
        && test -n "$BLENDER_SHA256" \
        && mkdir -p /tmp/blender-extract /opt/blender-${BLENDER_VERSION} \
        && blender_archive="/tmp/blender-${BLENDER_VARIANT}.tar.xz" \
        && curl -fsSL "$BLENDER_URL" -o "$blender_archive" \
        && printf '%s  %s\n' "$BLENDER_SHA256" "$blender_archive" | sha256sum -c - \
        && tar -xJ -f "$blender_archive" -C /tmp/blender-extract \
        && EXTRACTED_DIR=$(find /tmp/blender-extract -maxdepth 1 -mindepth 1 -type d -name "blender-*" | head -n 1) \
        && test -n "$EXTRACTED_DIR" \
        && test -x "$EXTRACTED_DIR/blender" \
        && cp -a "$EXTRACTED_DIR/." /opt/blender-${BLENDER_VERSION}/ \
        && site_packages=$(find /opt/blender-${BLENDER_VERSION} -type d -path '*/python/lib/python3.13/site-packages' -print -quit) \
        && test -n "$site_packages" \
        && decoder_wheel="/tmp/openimageio-${OPENIMAGEIO_WHEEL_SHA256}.whl" \
        && curl -fsSL "$OPENIMAGEIO_WHEEL_URL" -o "$decoder_wheel" \
        && test "$(wc -c < "$decoder_wheel" | tr -d '[:space:]')" = "$OPENIMAGEIO_WHEEL_BYTES" \
        && printf '%s  %s\n' "$OPENIMAGEIO_WHEEL_SHA256" "$decoder_wheel" | sha256sum -c - \
        && python3 -c 'import pathlib,sys,zipfile; p=pathlib.Path(sys.argv[1]); d=pathlib.Path(sys.argv[2]); z=zipfile.ZipFile(p); [(_ for _ in ()).throw(SystemExit(f"unsafe wheel member: {e.filename}")) if pathlib.PurePosixPath(e.filename).is_absolute() or ".." in pathlib.PurePosixPath(e.filename).parts else z.extract(e, d) for e in z.infolist()]' "$decoder_wheel" "$site_packages" \
        && decoder_root="$site_packages/OpenImageIO" \
        && test -f "$decoder_root/OpenImageIO.cpython-313-x86_64-linux-gnu.so" \
        && test -f "$decoder_root/lib/libOpenImageIO.so.3.1.17" \
        && blender_python=$(find /opt/blender-${BLENDER_VERSION} -type f -path '*/python/bin/python3.13' -print -quit) \
        && test -n "$blender_python" \
        && LD_LIBRARY_PATH="$decoder_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
           "$blender_python" -I -c 'import OpenImageIO as oiio, numpy; required = {"openexr", "jpeg", "png", "tiff", "webp"}; formats = set(oiio.get_string_attribute("format_list").split(",")); assert required <= formats, (required - formats, oiio.VERSION_STRING); print(oiio.VERSION_STRING)' \
        && rm -f "$blender_archive" "$decoder_wheel" \
        && rm -rf /tmp/blender-extract \
        && ln -sf /opt/blender-${BLENDER_VERSION}/blender /usr/local/bin/blender \
        && if [ -n "$BLENDER_ARTIFACT_ID" ]; then \
               printf '%s\n' "$BLENDER_ARTIFACT_ID" > /opt/blender-${BLENDER_VERSION}/.renderboost-runtime-artifact; \
           fi \
        && /usr/local/bin/blender --version; \
    fi

ENV RENDERBOOST_NODE_VERSION="${NODE_VERSION}" \
    RENDERBOOST_NODE_SHA256="${NODE_SHA256}" \
    RENDERBOOST_FRAME_PIXEL_DECODER_BAKED_MODULE_PATH="/opt/blender-5.2.0/5.2/python/lib/python3.13/site-packages"

# 4. Prepare runtime directories expected by RenderBoost worker scripts
RUN mkdir -p /opt/renderboost /tmp/renderboost-blender-startup-logs /usr/share/nvidia

WORKDIR /root
CMD ["/bin/bash"]
