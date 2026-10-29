#!/usr/bin/env python3
"""Generate one self-contained Celatlas spatial report from canonical outputs."""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import subprocess
import sys
from pathlib import Path


ALIASES = {
    "00.sample": "00_sample",
    "01.barcode": "01_barcode",
    "02.cutadapt": "02_cutadapt",
    "03.star": "03_star",
    "04.featureCounts": "04_featurecounts",
    "05.count": "05_count",
    "06.binSegment": "06_binsegment",
    "07.analysis": "07_analysis",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-root", required=True, type=Path)
    parser.add_argument("--report-dir", required=True, type=Path)
    parser.add_argument("--tmp-root", required=True, type=Path)
    parser.add_argument("--sample-name", required=True)
    parser.add_argument("--chemistry", required=True)
    parser.add_argument("--species", required=True)
    parser.add_argument("--done", required=True, type=Path)
    parser.add_argument("--report-script", type=Path)
    return parser.parse_args()


def clean_view(view: Path) -> None:
    if not view.exists():
        return
    for child in view.iterdir():
        if child.is_symlink() or child.is_file():
            child.unlink()
        elif child.is_dir():
            raise RuntimeError(f"refusing to remove unexpected report-view directory: {child}")


def main() -> int:
    args = parse_args()
    sample_root = args.sample_root.resolve()
    report_dir = args.report_dir.resolve()
    tmp_root = args.tmp_root.resolve()
    view = tmp_root / "report_views" / args.sample_name
    report_name = f"{args.sample_name}_spatial_analysis_report.html"
    report_dir.mkdir(parents=True, exist_ok=True)
    clean_view(view)
    view.mkdir(parents=True, exist_ok=True)

    created: list[Path] = []
    try:
        for alias, target_name in ALIASES.items():
            target = sample_root / target_name
            if not target.is_dir():
                raise FileNotFoundError(f"missing report input directory: {target}")
            link = view / alias
            link.symlink_to(os.path.relpath(target, link.parent), target_is_directory=True)
            created.append(link)

        report_bin = shutil.which("celatlas_spatial_report")
        if report_bin:
            command = [report_bin, str(view), args.sample_name]
        else:
            script = args.report_script or Path("/opt/celatlas/celatlas_spatial/tools/spatial_report_generator.py")
            if not script.is_file():
                raise FileNotFoundError(f"report generator not found: {script}")
            command = [sys.executable, str(script), str(view), args.sample_name]
        command.extend(
            [
                "--chemistry",
                args.chemistry,
                "--species",
                args.species,
                "--output-filename",
                report_name,
                "--verbose",
            ]
        )
        subprocess.run(command, check=True)
        generated = view / report_name
        if not generated.is_file() or generated.stat().st_size == 0:
            raise RuntimeError(f"report generator did not create a non-empty report: {generated}")
        target = report_dir / report_name
        target.unlink(missing_ok=True)
        shutil.copy2(generated, target)
    finally:
        for link in reversed(created):
            link.unlink(missing_ok=True)
        generated = view / report_name
        generated.unlink(missing_ok=True)

    if len(list(report_dir.glob("*.html"))) != 1:
        raise RuntimeError(f"report directory must contain exactly one HTML report: {report_dir}")
    manifest = report_dir / "delivery_manifest.tsv"
    with manifest.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["category", "description", "source", "target", "status"],
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerow(
            {
                "category": "report",
                "description": "final spatial analysis report",
                "source": report_name,
                "target": report_name,
                "status": "copied",
            }
        )
    args.done.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.done.resolve().write_text("complete\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
