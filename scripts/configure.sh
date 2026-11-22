#!/usr/bin/env bash
set -euo pipefail
capture=${1:?expected 0 or 1}
cd /src
patch --fuzz=0 -p1 </project/patches/ninfer.patch
patch --fuzz=0 -p1 </project/patches/inkling2-stability-cache-ttft.patch
case "$capture" in
    0) suffix= ;;
    1) patch --fuzz=0 -p1 </project/bench/quality/capture-logits.patch; suffix=-score-capture ;;
    *) exit 2 ;;
esac
# Preserve notices in the modified source tree as well as in the distributed diffs.
awk '/^\+\+\+ b\// {print substr($2,3)}' /project/patches/ninfer.patch /project/patches/inkling2-stability-cache-ttft.patch | sort -u | while read -r file; do
    sed -i '1i// Modified for Inkling 2 Mini on RTX 3090. See the project NOTICE and patches.' "$file"
done
tag=$(cat /project/patches/ninfer.patch /project/patches/inkling2-stability-cache-ttft.patch | sha256sum | cut -c1-12)
printf 'export NINFER_VERSION=2026-11-21.2\nexport NINFER_BUILD_ID=395ce8b85627-inkling-%s%s\n' "$tag" "$suffix" > /build-id.sh
source /build-id.sh
bash scripts/fetch-media-sources.sh
cmake -S . -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=86 \
    -DCMAKE_C_COMPILER=gcc-13 -DCMAKE_CXX_COMPILER=g++-13 -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
    -DNINFER_BUILD_APPS=ON -DNINFER_BUILD_BENCHMARKS=OFF -DBUILD_TESTING=OFF
