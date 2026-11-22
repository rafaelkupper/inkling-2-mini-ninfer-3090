# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS source
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY scripts/fetch-engine.sh /usr/local/bin/
RUN bash /usr/local/bin/fetch-engine.sh /src

FROM python:3.12-slim-bookworm AS prepare
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu 'torch==2.13.0+cpu'
RUN pip install --no-cache-dir 'numpy==2.3.5' 'safetensors==0.8.0' tqdm pyyaml requests
COPY --from=source /src/tools /opt/ninfer/tools
COPY --from=source /src/LICENSE /src/CONTRIBUTORS.md /opt/ninfer/
RUN mkdir -p /opt/gguf && curl -fsSL --retry 4 https://github.com/unslothai/llama.cpp/releases/download/b12588-mix-c0c3de8/llama.cpp-source-commit-883286076efe5b85fddb31d9cc7035a6b698ba9b.tar.gz -o /tmp/llama.tgz \
 && echo '92ee8439f9ae51a40f15c168ac64e1d657bf8b08d301c96f8fb2d58625573607  /tmp/llama.tgz' | sha256sum -c - \
 && tar xf /tmp/llama.tgz -C /opt/gguf --strip-components=2 --wildcards '*/gguf-py/*' && rm /tmp/llama.tgz
ENV PYTHONPATH=/opt/ninfer:/opt/gguf OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=2 PYTHONDONTWRITEBYTECODE=1
COPY scripts/prepare.sh scripts/prepare-draft.py scripts/prepare-head.py scripts/download-model.py scripts/verify-native.py /opt/inkling/
COPY LICENSE NOTICE /usr/share/doc/inkling/
COPY licenses/ /usr/share/doc/inkling/licenses/
RUN python -m tools.convert --help >/dev/null && python -c 'from gguf import GGUFReader'
ENTRYPOINT ["bash", "/opt/inkling/prepare.sh"]

FROM nvidia/cuda:13.0.2-devel-ubuntu24.04@sha256:5dc1bca23d05bd37b011be68ec470c03b403a5da07ec3a86e41af9470e9d0cc6 AS configured
RUN apt-get update && apt-get install -y --no-install-recommends build-essential gcc-13 g++-13 cmake ninja-build \
    meson nasm pkg-config libcurl4-openssl-dev zlib1g-dev python3 python3-jinja2 patch curl xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=source /src/ ./
COPY patches/ninfer.patch patches/inkling2-stability-cache-ttft.patch /project/patches/
COPY bench/quality/capture-logits.patch /project/bench/quality/
COPY scripts/configure.sh /project/scripts/
ARG SCORE_CAPTURE=0
RUN bash /project/scripts/configure.sh "$SCORE_CAPTURE"

FROM configured AS build
ARG BUILD_JOBS=6
SHELL ["/bin/bash", "-c"]
RUN source /build-id.sh && cmake --build /build --parallel "$BUILD_JOBS" --target ninfer-serve ninfer-perplexity

FROM build AS notices
COPY Dockerfile LICENSE NOTICE /project/
COPY licenses/ /project/licenses/
COPY scripts/ /project/scripts/
RUN bash /project/scripts/bundle-notices.sh

FROM nvidia/cuda:13.0.2-runtime-ubuntu24.04@sha256:6a0e31b59e70890446f2c17356d6efc0d54260090a8c63d6ca7c2ad049db95d2 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4t64 zlib1g ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/apps/ninfer-serve /build/apps/ninfer-perplexity /usr/local/bin/
COPY --from=notices /notices/ /usr/share/doc/inkling/
COPY scripts/serve.sh /usr/local/bin/serve-inkling
# An image build can run on a host without an attached NVIDIA driver.
RUN export LD_LIBRARY_PATH="/usr/local/cuda/compat:${LD_LIBRARY_PATH}" \
 && ninfer-serve --version && ninfer-perplexity --help >/dev/null
EXPOSE 8080
ENTRYPOINT ["bash", "/usr/local/bin/serve-inkling"]
