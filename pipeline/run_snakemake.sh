#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIGFILE="${PROJECT_ROOT}/config/demo_250A1_v1.8.yaml"
CORES="${CELATLAS_CORES:-32}"
JOBS="${CELATLAS_JOBS:-1}"
DRY_RUN=0
SNAKEMAKE_BIN="${SNAKEMAKE_BIN:-snakemake}"

usage() {
  cat <<'EOF'
Usage: pipeline/run_snakemake.sh [options]

Options:
  --configfile FILE  Run configuration (default: config/demo_250A1_v1.8.yaml)
  --cores N           Total Snakemake CPU ceiling (default: CELATLAS_CORES or 32)
  --jobs N            Maximum concurrent jobs (default: CELATLAS_JOBS or 1)
  --snakemake FILE    Snakemake executable
  --dry-run           Print the DAG without running analysis stages
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configfile) CONFIGFILE="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --snakemake) SNAKEMAKE_BIN="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$CONFIGFILE" ]] || { echo "ERROR: config not found: $CONFIGFILE" >&2; exit 1; }
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || { echo "ERROR: --cores must be >=1" >&2; exit 2; }
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || { echo "ERROR: --jobs must be >=1" >&2; exit 2; }
command -v "$SNAKEMAKE_BIN" >/dev/null 2>&1 || [[ -x "$SNAKEMAKE_BIN" ]] || {
  echo "ERROR: Snakemake executable not found: $SNAKEMAKE_BIN" >&2
  exit 1
}

TMPDIR="${TMPDIR:-${PROJECT_ROOT}/tmp/snakemake}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-${PROJECT_ROOT}/tmp/xdg-cache}"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"
export TMPDIR XDG_CACHE_HOME
export MPLCONFIGDIR="${MPLCONFIGDIR:-${PROJECT_ROOT}/tmp/matplotlib}"
export NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR:-${PROJECT_ROOT}/tmp/numba}"
mkdir -p "$MPLCONFIGDIR" "$NUMBA_CACHE_DIR"
SNAKEMAKE_DIR="${SNAKEMAKE_DIR:-${TMPDIR}/snakemake-work}"
mkdir -p "$SNAKEMAKE_DIR"

cd "$PROJECT_ROOT"
args=(
  --directory "$SNAKEMAKE_DIR"
  --snakefile "$PROJECT_ROOT/pipeline/Snakefile"
  --configfile "$CONFIGFILE"
  --cores "$CORES"
  --jobs "$JOBS"
  --rerun-incomplete
  --latency-wait 30
  --printshellcmds
  --default-resources "tmpdir='$TMPDIR'"
)
if [[ "$DRY_RUN" == "1" ]]; then
  args+=(--dry-run)
fi

exec "$SNAKEMAKE_BIN" "${args[@]}"
