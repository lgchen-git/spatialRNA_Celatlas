#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMAGE="${CELATLAS_IMAGE_TAG:-celatlas-spatial-snakemake:1.8.0-he-cellseg}"
CONFIG="/workspace/config/demo_250A1_v1.8.yaml"
SPECIES="${CELATLAS_SPECIES:-Mus_musculus}"
INPUTS=""
REFERENCE=""
OUTPUTS=""
LOG=""
TMP=""
CORES="${CELATLAS_CORES:-32}"
JOBS="${CELATLAS_JOBS:-1}"
MEMORY_GIB="${CELATLAS_MEMORY_GIB:-128}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: docker/run_snakemake.sh --inputs-host DIR --reference-host DIR \
       --outputs-host DIR --log-host DIR --tmp-host DIR [options]

Options:
  --image TAG          Docker image
  --configfile FILE    Config relative to project root
  --species NAME       Reference subdirectory (default: Mus_musculus)
  --cores N            Container CPU limit and Snakemake cores
  --jobs N             Maximum concurrent Snakemake jobs
  --memory-gib N       Container memory limit
  --dry-run            Validate and print the DAG only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --configfile) CONFIG="/workspace/config/$(basename "$2")"; shift 2 ;;
    --species) SPECIES="$2"; shift 2 ;;
    --inputs-host) INPUTS="$2"; shift 2 ;;
    --reference-host) REFERENCE="$2"; shift 2 ;;
    --outputs-host) OUTPUTS="$2"; shift 2 ;;
    --log-host) LOG="$2"; shift 2 ;;
    --tmp-host) TMP="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --memory-gib) MEMORY_GIB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for path in "$INPUTS" "$REFERENCE" "$OUTPUTS" "$LOG" "$TMP"; do
  [[ -n "$path" ]] || { echo "ERROR: all five host mount roots are required" >&2; exit 2; }
done
[[ -d "$INPUTS" && -d "$REFERENCE" ]] || { echo "ERROR: input/reference root is not a directory" >&2; exit 1; }
[[ -d "$REFERENCE/$SPECIES" ]] || { echo "ERROR: reference root must contain $SPECIES/" >&2; exit 1; }
mkdir -p "$OUTPUTS" "$LOG" "$TMP"
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || { echo "ERROR: --cores must be >=1" >&2; exit 2; }
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || { echo "ERROR: --jobs must be >=1" >&2; exit 2; }
[[ "$MEMORY_GIB" =~ ^[0-9]+$ && "$MEMORY_GIB" -ge 1 ]] || { echo "ERROR: --memory-gib must be >=1" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed" >&2; exit 1; }

docker_args=(
  run --rm
  --name "celatlas-snakemake-$$"
  --user "$(id -u):$(id -g)"
  --env "USER=$(id -un)"
  --env "LOGNAME=$(id -un)"
  --env HOME=/workspace/tmp/home
  --cpus "$CORES"
  --memory "${MEMORY_GIB}g"
  --ulimit nofile=1048576:1048576
  -v "$PROJECT_ROOT/config:/workspace/config:ro"
  -v "$PROJECT_ROOT/pipeline:/workspace/pipeline:ro"
  -v "$INPUTS:/workspace/inputs:ro"
  -v "$REFERENCE:/workspace/reference:ro"
  -v "$OUTPUTS:/workspace/outputs:rw"
  -v "$LOG:/workspace/log:rw"
  -v "$TMP:/workspace/tmp:rw"
  "$IMAGE"
  bash /workspace/pipeline/run_snakemake.sh
  --configfile "$CONFIG"
  --cores "$CORES"
  --jobs "$JOBS"
)
if [[ "$DRY_RUN" == "1" ]]; then
  docker_args+=(--dry-run)
fi
exec docker "${docker_args[@]}"
