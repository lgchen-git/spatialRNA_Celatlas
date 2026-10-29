#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/archive_results.sh --samples configs/samples.tsv --result-dir /path/to/batch/result [options]

Copies each sample's final result folder from:
  <workspace>/results/<casno>/<chip>/
to:
  <result-dir>/<sample>/<chip>/

Options:
  --samples FILE       Required sample TSV.
  --result-dir DIR     Required destination result directory.
  --metadata FILE      Optional run metadata file to copy into result/run_metadata/.
  --dry-run            Print actions only.
EOF
}

SAMPLES_TSV=""
RESULT_DIR=""
DRY_RUN=0
METADATA_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples) SAMPLES_TSV="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --metadata) METADATA_FILES+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SAMPLES_TSV" && -f "$SAMPLES_TSV" ]] || { echo "ERROR: --samples file is required" >&2; exit 2; }
[[ -n "$RESULT_DIR" ]] || { echo "ERROR: --result-dir is required" >&2; exit 2; }

if [[ "$DRY_RUN" == "0" ]]; then
  mkdir -p "$RESULT_DIR/run_metadata"
  cp -a "$SAMPLES_TSV" "$RESULT_DIR/run_metadata/"
  for f in "${METADATA_FILES[@]}"; do
    [[ -e "$f" ]] && cp -a "$f" "$RESULT_DIR/run_metadata/"
  done
fi

report_index="$RESULT_DIR/run_metadata/report_paths.txt"
[[ "$DRY_RUN" == "1" ]] || : >"$report_index"

line_no=0
while IFS=$'\t' read -r sample chip casno species chemistry method mode workspace fastq_name enabled extra; do
  line_no=$((line_no + 1))
  [[ "$line_no" -eq 1 && "$sample" == "sample" ]] && continue
  [[ -z "${sample// }" || "$sample" == \#* || "${enabled:-1}" == "0" ]] && continue
  [[ "$chip" == "auto" || -z "$chip" ]] && chip="$(find "$workspace/ST_mask" -maxdepth 1 -type f -name '*.barcodeToPos.h5' -printf '%f\n' | sed 's/\.barcodeToPos\.h5$//' | sort | head -n 1)"

  src="$workspace/results/$casno/$chip"
  dest="$RESULT_DIR/$sample/$chip"
  report="$src/${chip}_spatial_analysis_report.html"

  if [[ ! -d "$src" ]]; then
    echo "WARNING: missing result directory: $src" >&2
    continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] rsync -a $src/ $dest/"
  else
    mkdir -p "$dest"
    rsync -a "$src/" "$dest/"
    [[ -s "$report" ]] && echo "$dest/${chip}_spatial_analysis_report.html" >>"$report_index"
  fi
done < "$SAMPLES_TSV"

if [[ "$DRY_RUN" == "0" ]]; then
  echo "Archived reports: $(wc -l < "$report_index")"
  echo "Result directory: $RESULT_DIR"
fi
