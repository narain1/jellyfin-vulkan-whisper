# syntax=docker/dockerfile:1

ARG JELLYFIN_IMAGE=jellyfin/jellyfin:latest
ARG WHISPER_VERSION=v1.9.1

# ── Build stage: compile whisper.cpp with Vulkan ─────────────────────────────
FROM ${JELLYFIN_IMAGE} AS whisper-builder
ARG WHISPER_VERSION
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git cmake g++ make pkg-config ca-certificates \
        libvulkan-dev glslc glslang-tools \
        spirv-headers spirv-tools \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${WHISPER_VERSION}" \
        https://github.com/ggml-org/whisper.cpp.git /tmp/whisper

WORKDIR /tmp/whisper
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
        -DBUILD_SHARED_LIBS=OFF \
    && cmake --build build --config Release -j"$(nproc)"

# Collect whisper-cli plus any runtime backend libraries into /opt/whisper.
# RUNPATH is rewritten to $ORIGIN so the binary resolves any sibling .so files
# from its own directory after it is copied into the final image.
RUN set -eux; \
    mkdir -p /opt/whisper; \
    cp build/bin/whisper-cli /opt/whisper/whisper-cli; \
    find build -name '*.so*' -exec cp -a {} /opt/whisper/ \; ; \
    if command -v patchelf >/dev/null 2>&1 || \
       (apt-get update && apt-get install -y --no-install-recommends patchelf && rm -rf /var/lib/apt/lists/*); then \
        patchelf --set-rpath '$ORIGIN' /opt/whisper/whisper-cli || true; \
    fi; \
    chmod +x /opt/whisper/whisper-cli

# ── Final stage: Jellyfin + Vulkan runtime libs + baked-in whisper-cli ────────
FROM ${JELLYFIN_IMAGE}
LABEL org.opencontainers.image.title="jellyfin-whisper-vulkan"
LABEL org.opencontainers.image.description="Jellyfin with Vulkan-accelerated whisper.cpp (whisper-cli) baked in at /opt/whisper for the WhisperSubs plugin."
LABEL org.opencontainers.image.source="https://github.com/narain1/infra"

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libvulkan1 mesa-vulkan-drivers libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=whisper-builder /opt/whisper /opt/whisper
