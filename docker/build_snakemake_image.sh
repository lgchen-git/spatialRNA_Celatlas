#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${CELATLAS18_SOURCE_ROOT:-/opt/project/software/celatlas_spatial_v1.8_DV/celatlas_spatial-1.8.0/celatlas_spatial-1.8.0}"
MODEL="${CELATLAS18_MODEL:-/opt/project/software/celatlas_spatial_v1.8_DV/src/swin_tiny.pth}"
STARDIST_HE_MODEL_DIR="${STARDIST_HE_MODEL_DIR:-/opt/project/projects/spatialRNA_Celatlas/tmp/stardist-he-v18/2D_versatile_he}"
CELATLAS18_ENV="${CELATLAS18_ENV:-/opt/project/software/micromamba-root/envs/celatlas18-stardist-py311}"
PROBE_ENV="${CELATLAS_PROBE_ENV:-/opt/project/software/micromamba-root/envs/celatlas_spatial_probe}"
CONTEXT="${PROJECT_ROOT}/tmp/docker-build/snakemake-v1.8-context"
TAG="${CELATLAS_IMAGE_TAG:-celatlas-spatial-snakemake:1.8.0-he-cellseg}"
ARCHIVE="${CELATLAS_IMAGE_ARCHIVE:-${PROJECT_ROOT}/dist/celatlas-spatial-snakemake-1.8.0-he-cellseg.tar}"
BASE_IMAGE="${CELATLAS_BASE_IMAGE:-illumina-pipseq-scrna:4.5.4-1}"

usage() {
  cat <<'EOF'
Usage: docker/build_snakemake_image.sh [--no-export]

Environment overrides:
  CELATLAS18_SOURCE_ROOT, CELATLAS18_MODEL, STARDIST_HE_MODEL_DIR, CELATLAS18_ENV,
  CELATLAS_PROBE_ENV, CELATLAS_IMAGE_TAG, CELATLAS_IMAGE_ARCHIVE,
  CELATLAS_BASE_IMAGE
EOF
}

EXPORT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-export) EXPORT=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for path in "$SOURCE_ROOT" "$MODEL" "$STARDIST_HE_MODEL_DIR" "$CELATLAS18_ENV" "$PROBE_ENV"; do
  [[ -e "$path" ]] || { echo "ERROR: required v1.8 path missing: $path" >&2; exit 1; }
done
for path in config.json thresholds.json weights_best.h5; do
  [[ -f "$STARDIST_HE_MODEL_DIR/$path" ]] || {
    echo "ERROR: StarDist HE model file missing: $STARDIST_HE_MODEL_DIR/$path" >&2
    exit 1
  }
done
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync is required" >&2; exit 1; }
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || {
  echo "ERROR: local base image is unavailable: $BASE_IMAGE" >&2
  exit 2
}

rm -rf "$CONTEXT"
mkdir -p "$CONTEXT/runtime_probe" "$CONTEXT/runtime_celatlas18" "$CONTEXT/system_libs" \
  "$CONTEXT/celatlas_src/src" "$CONTEXT/stardist_model/2D_versatile_he" \
  "$CONTEXT/project_pipeline" "$CONTEXT/project_config" "$CONTEXT/docker/bin"
rsync -a --delete --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  "$SOURCE_ROOT/" "$CONTEXT/celatlas_src/"
mkdir -p "$CONTEXT/celatlas_src/src"
cp "$MODEL" "$CONTEXT/celatlas_src/src/swin_tiny.pth"
rsync -a --delete "$STARDIST_HE_MODEL_DIR/" "$CONTEXT/stardist_model/2D_versatile_he/"
rsync -a --delete --exclude='__pycache__' --exclude='*.pyc' "$CELATLAS18_ENV/" "$CONTEXT/runtime_celatlas18/"
rsync -a --delete --exclude='__pycache__' --exclude='*.pyc' "$PROBE_ENV/" "$CONTEXT/runtime_probe/"

for lib in libGL.so.1.7.0 libGLdispatch.so.0.0.0 libGLX.so.0.0.0 \
           libX11.so.6.4.0 libxcb.so.1.1.0 libXau.so.6.0.0 libXdmcp.so.6.0.0 \
           libbsd.so.0.11.5 libmd.so.0.0.5; do
  [[ -e "/lib/x86_64-linux-gnu/$lib" ]] || {
    echo "ERROR: required host library is missing: /lib/x86_64-linux-gnu/$lib" >&2
    exit 1
  }
  cp -L "/lib/x86_64-linux-gnu/$lib" "$CONTEXT/system_libs/$lib"
done

rsync -a "$PROJECT_ROOT/pipeline/" "$CONTEXT/project_pipeline/"
rsync -a "$PROJECT_ROOT/config/" "$CONTEXT/project_config/"
rsync -a "$PROJECT_ROOT/docker/bin/" "$CONTEXT/docker/bin/"
cp "$PROJECT_ROOT/docker/Dockerfile.snakemake" "$CONTEXT/Dockerfile"

docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" --file "$CONTEXT/Dockerfile" --tag "$TAG" "$CONTEXT"
if [[ "$EXPORT" == "1" ]]; then
  mkdir -p "$(dirname "$ARCHIVE")"
  docker save --output "$ARCHIVE" "$TAG"
  echo "Exported image archive: $ARCHIVE"
fi
echo "Built image: $TAG"
