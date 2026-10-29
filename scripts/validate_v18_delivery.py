#!/usr/bin/env python3
"""Validate the retained outputs of one Celatlas Spatial v1.8 sample."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sample_dir", type=Path)
    args = parser.parse_args()
    root = args.sample_dir.resolve()
    sample = root.name
    required_dirs = (
        "00.sample",
        "01.barcode",
        "02.cutadapt",
        "03.star",
        "04.featureCounts",
        "05.count",
        "06.segment/01.binsegment",
        "06.segment/02.cellsegment",
        "07.outs/binned_outputs",
        "07.outs/cellsegmented_outputs",
        "08.report",
    )
    errors: list[str] = []
    for relative in required_dirs:
        path = root / relative
        if not path.is_dir() or not any(path.iterdir()):
            errors.append(f"missing or empty directory: {path}")
    report = root / f"{sample}_spatial_analysis_report.html"
    if not report.is_file() or report.stat().st_size == 0:
        errors.append(f"missing or empty report: {report}")
    cellseg_labels = root / "06.segment/02.cellsegment/stardist_inference" / f"{sample}.stardist_labels.tif"
    if not cellseg_labels.is_file() or cellseg_labels.stat().st_size == 0:
        errors.append(f"missing or empty StarDist labels: {cellseg_labels}")
    cell_matrix = root / "06.segment/02.cellsegment/cell_matrix/matrix.mtx.gz"
    if not cell_matrix.is_file() or cell_matrix.stat().st_size == 0:
        errors.append(f"missing or empty cell matrix: {cell_matrix}")
    cell_metrics = root / "07.outs/cellsegmented_outputs/metrics_summary.json"
    if not cell_metrics.is_file() or cell_metrics.stat().st_size == 0:
        errors.append(f"missing or empty cell metrics: {cell_metrics}")
    marker = root / "08.report/.stage.done"
    if not marker.is_file():
        errors.append(f"missing report marker: {marker}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"OK: validated Celatlas v1.8 delivery {root}")
    print(f"REPORT: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
