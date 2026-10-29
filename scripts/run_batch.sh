#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run_batch.sh --samples configs/samples.tsv [options]

Options:
  --samples FILE          Required TSV with columns:
                          sample chip casno species chemistry method mode workspace fastq_name enabled
                          Optional extra column: fastq_dir
  --entry FILE            Celatlas v1.8 CLI entrypoint
                          default: /opt/project/software/micromamba-root/envs/celatlas18-stardist-py311/bin/celatlas
  --conda-env NAME        Conda environment name, default: celatlas18-stardist-py311
  --conda-sh FILE         Conda profile script, default: /opt/project/software/miniconda3/etc/profile.d/conda.sh
  --reference-root DIR    Reference root, default: /opt/project/data/reference_Celatlas
  --software-root DIR     Celatlas software root, default: /opt/project/software/celatlas_spatial_v1.8_DV
  --runtime-root DIR      Per-sample Celatlas workspaces and temporary files
  --result-root DIR       Final result root; results are copied to <root>/<sample>/<chip>/
  --threads N             Threads per sample, default: 16
  --parallel N            Number of samples to run concurrently, default: 1
  --bin SIZES             Bin size(s), default: 50
  --cell-num N            Expected cell/spot number, default: 50000
  --insert-r2 N           Insert R2 length, default: 150
  --pixel-size N          Pixel size, default: 0.5
  --skip-completed        Skip samples with an existing non-empty HTML report, default: on
  --rerun-completed       Do not skip completed reports
  --dry-run               Validate and print planned commands only
  --only LIST             Comma-separated sample IDs to run
  --help                  Show this help

Environment overrides:
  CLEAN_INTERMEDIATE, OPENBLAS_NUM_THREADS, OMP_NUM_THREADS, MKL_NUM_THREADS,
  GEM_BIN_SIZE, UMI_MIN_THRESHOLD, REGISTRATION_TYPE
EOF
}

SAMPLES_TSV=""
ENTRY="/opt/project/software/micromamba-root/envs/celatlas18-stardist-py311/bin/celatlas"
CONDA_ENV="celatlas18-stardist-py311"
CONDA_SH="/opt/project/software/miniconda3/etc/profile.d/conda.sh"
REFERENCE_ROOT="/opt/project/data/reference_Celatlas"
SOFTWARE_ROOT="/opt/project/software/celatlas_spatial_v1.8_DV"
RUNTIME_ROOT=""
RESULT_ROOT=""
THREADS=16
PARALLEL=1
BIN=50
CELL_NUM=50000
INSERT_R2=150
PIXEL_SIZE=0.5
SKIP_COMPLETED=1
DRY_RUN=0
ONLY_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples) SAMPLES_TSV="$2"; shift 2 ;;
    --entry) ENTRY="$2"; shift 2 ;;
    --conda-env) CONDA_ENV="$2"; shift 2 ;;
    --conda-sh) CONDA_SH="$2"; shift 2 ;;
    --reference-root) REFERENCE_ROOT="$2"; shift 2 ;;
    --software-root) SOFTWARE_ROOT="$2"; shift 2 ;;
    --runtime-root) RUNTIME_ROOT="$2"; shift 2 ;;
    --result-root) RESULT_ROOT="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --bin) BIN="$2"; shift 2 ;;
    --cell-num) CELL_NUM="$2"; shift 2 ;;
    --insert-r2) INSERT_R2="$2"; shift 2 ;;
    --pixel-size) PIXEL_SIZE="$2"; shift 2 ;;
    --skip-completed) SKIP_COMPLETED=1; shift ;;
    --rerun-completed) SKIP_COMPLETED=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --only) ONLY_LIST="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SAMPLES_TSV" ]] || { echo "ERROR: --samples is required" >&2; exit 2; }
[[ -f "$SAMPLES_TSV" ]] || { echo "ERROR: sample sheet not found: $SAMPLES_TSV" >&2; exit 1; }
[[ -f "$ENTRY" ]] || { echo "ERROR: Celatlas entrypoint not found: $ENTRY" >&2; exit 1; }
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || { echo "ERROR: --parallel must be >=1" >&2; exit 2; }

contains_only() {
  local sample="$1"
  [[ -z "$ONLY_LIST" ]] && return 0
  case ",$ONLY_LIST," in
    *,"$sample",*) return 0 ;;
    *) return 1 ;;
  esac
}

activate_env() {
  if [[ -f "$CONDA_SH" ]]; then
    # shellcheck disable=SC1090
    source "$CONDA_SH"
    conda activate "$CONDA_ENV"
  elif command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
    conda activate "$CONDA_ENV"
  else
    echo "ERROR: conda not found and --conda-sh does not exist: $CONDA_SH" >&2
    exit 1
  fi
}

detect_chip() {
  local workspace="$1"
  local chip="$2"
  if [[ "$chip" != "auto" && -n "$chip" ]]; then
    printf '%s\n' "$chip"
    return
  fi
  find "$workspace/ST_mask" -maxdepth 1 -type f -name '*.barcodeToPos.h5' -printf '%f\n' \
    | sed 's/\.barcodeToPos\.h5$//' | sort | head -n 1
}

validate_sample() {
  local sample="$1" chip="$2" input_workspace="$3" run_workspace="$4" fastq_name="$5" method="$6" species="$7" fastq_dir="$8"
  local mask_dir="$input_workspace/ST_mask"
  local src_model="$run_workspace/src/swin_tiny.pth"
  local ref_dir="$REFERENCE_ROOT/$species"
  local required=(
    "$mask_dir/${chip}.barcodeToPos.h5"
    "$mask_dir/${chip}_FilterBarcodes.csv"
    "$mask_dir/${chip}_tissue_bbox.csv"
    "$ref_dir"
  )
  local fq1=""
  local fq2=""

  if [[ "$method" == "image" || "$method" == "ssDNA" ]]; then
    required+=("$input_workspace/images/${chip}.tif")
  fi

  for path in "${required[@]}"; do
    [[ -e "$path" ]] || { echo "ERROR: $sample missing required input: $path" >&2; return 1; }
  done

  if [[ -e "$fastq_dir/${fastq_name}_1.fq.gz" && -e "$fastq_dir/${fastq_name}_2.fq.gz" ]]; then
    fq1="$fastq_dir/${fastq_name}_1.fq.gz"
    fq2="$fastq_dir/${fastq_name}_2.fq.gz"
  elif [[ -e "$fastq_dir/${fastq_name}_R1.fq.gz" && -e "$fastq_dir/${fastq_name}_R2.fq.gz" ]]; then
    fq1="$fastq_dir/${fastq_name}_R1.fq.gz"
    fq2="$fastq_dir/${fastq_name}_R2.fq.gz"
  else
    echo "ERROR: $sample missing FASTQ pair in $fastq_dir for prefix $fastq_name" >&2
    echo "       Tried: ${fastq_name}_1/_2.fq.gz and ${fastq_name}_R1/_R2.fq.gz" >&2
    return 1
  fi

  [[ -s "$fq1" ]] || { echo "ERROR: $sample FASTQ is empty: $fq1" >&2; return 1; }
  [[ -s "$fq2" ]] || { echo "ERROR: $sample FASTQ is empty: $fq2" >&2; return 1; }

  if [[ "$DRY_RUN" == "0" ]]; then
    mkdir -p "$run_workspace/src" "$run_workspace/tmp/mpl" "$run_workspace/tmp/numba" || return 1
    if [[ ! -e "$src_model" && -f "$SOFTWARE_ROOT/src/swin_tiny.pth" ]]; then
      ln -s "$SOFTWARE_ROOT/src/swin_tiny.pth" "$src_model" || return 1
    fi
  fi
}

run_one() {
  local sample="$1" chip_in="$2" casno="$3" species="$4" chemistry="$5" method="$6" mode="$7" input_workspace="$8" fastq_name_in="$9" fastq_dir_in="${10:-}" tissue="${11:-unspecified}"
  local chip fastq_name mask_dir fastq_dir run_workspace report final_report log_dir sample_log final_dir rc

  chip="$(detect_chip "$input_workspace" "$chip_in")"
  [[ -n "$chip" ]] || { echo "ERROR: cannot detect chip for sample=$sample workspace=$input_workspace" >&2; return 1; }
  fastq_name="${fastq_name_in:-$chip}"
  mask_dir="$input_workspace/ST_mask"
  fastq_dir="${fastq_dir_in:-$input_workspace/fastq/$chemistry}"
  run_workspace="${RUNTIME_ROOT:+$RUNTIME_ROOT/$sample}"
  run_workspace="${run_workspace:-$input_workspace}"
  report="$run_workspace/results/$casno/$chip/${chip}_spatial_analysis_report.html"
  final_dir="${RESULT_ROOT:+$RESULT_ROOT/$sample/$chip}"
  final_report="${final_dir:+$final_dir/${chip}_spatial_analysis_report.html}"
  log_dir="$run_workspace/results/$casno/$chip/run_logs"
  sample_log="$log_dir/${sample}.run_batch.log"

  validate_sample "$sample" "$chip" "$input_workspace" "$run_workspace" "$fastq_name" "$method" "$species" "$fastq_dir"

  if [[ "$SKIP_COMPLETED" == "1" && -n "$final_report" && -s "$final_report" ]]; then
    echo "[$(date)] SKIP completed sample=$sample chip=$chip report=$final_report"
    return 0
  fi
  if [[ "$SKIP_COMPLETED" == "1" && -z "$final_report" && -s "$report" ]]; then
    echo "[$(date)] SKIP completed sample=$sample chip=$chip report=$report"
    return 0
  fi

  [[ "$DRY_RUN" == "1" ]] || mkdir -p "$log_dir" || return 1

  export CLEAN_INTERMEDIATE="${CLEAN_INTERMEDIATE:-1}"
  export CELATLAS_WORKSPACE="$run_workspace"
  export CELATLAS_SRC_DIR="$run_workspace/src"
  export CELATLAS_PYTHON="$(dirname "$ENTRY")/python"
  export PATH="/opt/project/software/micromamba-root/envs/celatlas_spatial_probe/bin:$PATH"
  export TMPDIR="$run_workspace/tmp"
  export MPLCONFIGDIR="$run_workspace/tmp/mpl"
  export NUMBA_CACHE_DIR="$run_workspace/tmp/numba"
  export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-8}"
  export OMP_NUM_THREADS="${OMP_NUM_THREADS:-$THREADS}"
  export MKL_NUM_THREADS="${MKL_NUM_THREADS:-8}"

  local runner_config="$run_workspace/tmp/celatlas_runner.yaml"
  local cmd=(
    "$ENTRY"
    count
    --id "$chip"
    --sample-name "$sample"
    --project "$casno"
    --tissue unspecified
    --targetdir "$run_workspace/results/$casno/$chip"
    --chemistry "$chemistry"
    --species "$species"
    --image "$method"
    --workflow ST
    --mode "$mode"
    --reference-dir "$REFERENCE_ROOT"
    --mask-dir "$mask_dir"
    --image-dir "$input_workspace/images"
    --fastqs "$fastq_dir"
    --fastq-name "$fastq_name"
    --thread "$THREADS"
    --featurecounts-thread "$THREADS"
    --bin "$BIN"
    --cell-num "$CELL_NUM"
    --pixel-size "$PIXEL_SIZE"
    --config "$runner_config"
  )

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] sample=%s chip=%s runtime=%s report=%s final=%s\n' "$sample" "$chip" "$run_workspace" "$report" "${final_report:-$report}"
    printf '  %q' "${cmd[@]}"
    printf '\n'
    return 0
  fi

  cat > "$runner_config" <<EOF
workspace: $run_workspace
src_dir: $run_workspace/src
insert_r2: $INSERT_R2
default_insert_r2: $INSERT_R2
EOF

  echo "[$(date)] START sample=$sample chip=$chip" | tee -a "$sample_log"
  set +e
  "${cmd[@]}" >>"$sample_log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && -s "$report" ]]; then
    if [[ -n "$final_dir" ]]; then
      mkdir -p "$final_dir"
      rsync -a "$run_workspace/results/$casno/$chip/" "$final_dir/"
      [[ -s "$final_report" ]] || { echo "[$(date)] FAIL sample=$sample copy_missing_report=$final_report" | tee -a "$sample_log" >&2; return 1; }
    fi
    echo "[$(date)] DONE sample=$sample chip=$chip report=${final_report:-$report}" | tee -a "$sample_log"
    return 0
  fi
  echo "[$(date)] FAIL sample=$sample chip=$chip exit=$rc report=$report" | tee -a "$sample_log" >&2
  return "$rc"
}

if [[ -x "$ENTRY" ]]; then
  celatlas_env="$(cd "$(dirname "$ENTRY")/.." && pwd)"
  export CELATLAS_PYTHON="$celatlas_env/bin/python"
  export PATH="$(dirname "$ENTRY"):/opt/project/software/micromamba-root/envs/celatlas_spatial_probe/bin:$PATH"
else
  activate_env
fi

status_root="${RUNTIME_ROOT:-$PWD/tmp}/celatlas_batch_status"
mkdir -p "$status_root"
tmp_status="$(mktemp -d "$status_root/status.XXXXXX")"
trap 'rm -rf "$tmp_status"' EXIT

line_no=0
active=0
total=0
submitted=0

while IFS=$'\t' read -r sample chip casno species chemistry method mode workspace fastq_name enabled fastq_dir extra; do
  line_no=$((line_no + 1))
  [[ "$line_no" -eq 1 && "$sample" == "sample" ]] && continue
  [[ -z "${sample// }" ]] && continue
  [[ "$sample" == \#* ]] && continue
  [[ "${enabled:-1}" == "0" ]] && continue
  contains_only "$sample" || continue

  total=$((total + 1))
  status_file="$tmp_status/${sample}.status"
  (
    rc=0
    run_one "$sample" "$chip" "$casno" "$species" "$chemistry" "$method" "$mode" "$workspace" "$fastq_name" "$fastq_dir" "unspecified" || rc=$?
    echo "$rc" >"$status_file"
    exit "$rc"
  ) &
  submitted=$((submitted + 1))
  active=$((active + 1))

  if [[ "$active" -ge "$PARALLEL" ]]; then
    wait -n || true
    active=$((active - 1))
  fi
done < "$SAMPLES_TSV"

while [[ "$active" -gt 0 ]]; do
  wait -n || true
  active=$((active - 1))
done

fail=0
for status in "$tmp_status"/*.status; do
  [[ -e "$status" ]] || continue
  rc="$(cat "$status")"
  [[ "$rc" == "0" ]] || fail=$((fail + 1))
done

echo "Batch complete: submitted=$submitted selected=$total failed=$fail"
[[ "$fail" -eq 0 ]]
