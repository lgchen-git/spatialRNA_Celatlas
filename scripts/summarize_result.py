#!/usr/bin/env python3
"""Summarize Celatlas spatial result directories.

The script expects a result directory shaped as:
  result/<sample>/<chip>/.metrics.json
  result/<sample>/<chip>/07.analysis/stat.txt
  result/<sample>/<chip>/*_spatial_analysis_report.html

It writes a Chinese Markdown summary with per-sample QC metrics, paired
sample comparison for names ending in "-2", and within-pair add-sequencing
recommendations.
"""

from __future__ import annotations

import argparse
import glob
import json
import re
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-dir", required=True, help="Top-level result directory")
    parser.add_argument("--case", default="", help="Case name for the report title")
    parser.add_argument("--out", default="", help="Output markdown path")
    return parser.parse_args()


def as_number(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace("%", "").replace(",", "").strip()
    try:
        return float(text)
    except ValueError:
        return None


def fmt_int(value: float | None) -> str:
    return "NA" if value is None else f"{int(round(value)):,}"


def fmt_pct(value: float | None) -> str:
    return "NA" if value is None else f"{value:.2f}%"


def parse_pipeline_barcode(log_path: Path) -> dict[str, float]:
    if not log_path.exists():
        return {}
    text = log_path.read_text(errors="ignore")
    patterns = {
        "Raw Reads": r"Raw Reads:\s*([\d,]+)",
        "Valid Reads": r"Valid Reads:\s*([\d,]+)\(([\d.]+)%\)",
    }
    out: dict[str, float] = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if not match:
            continue
        out[key] = float(match.group(1).replace(",", ""))
        if key == "Valid Reads":
            out["Valid Reads Fraction"] = float(match.group(2))
    return out


def parse_bin50_mito(stat_path: Path) -> float | None:
    """Return bin50 Fraction of Cells Have Mito Gene Percent>5%.

    Celatlas prints four repeated mito statistic blocks in bin order
    bin10, bin20, bin50, bin100. The report focuses on bin50, so use the
    third value. If future output contains fewer blocks, fall back to None
    rather than silently using a different bin.
    """
    if not stat_path.exists():
        return None
    vals: list[float] = []
    for line in stat_path.read_text(errors="ignore").splitlines():
        match = re.search(r"Fraction of Cells Have Mito Gene Percent>5%:\s*([\d.]+)%", line)
        if match:
            vals.append(float(match.group(1)))
    return vals[2] if len(vals) >= 3 else None


def collect_rows(result_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for metrics_path in sorted(result_dir.glob("*/*/.metrics.json")):
        with metrics_path.open() as handle:
            data = json.load(handle)

        sample = metrics_path.parents[1].name
        chip = metrics_path.parent.name
        barcode = data.get("barcode_summary") or {}
        if not barcode.get("Raw Reads"):
            barcode.update(parse_pipeline_barcode(metrics_path.parent / "pipeline.log"))
        cutadapt = data.get("cutadapt_summary") or {}
        star = data.get("star_summary") or {}
        feature = data.get("featureCounts_summary") or {}
        count = data.get("count_summary") or {}
        report = next(metrics_path.parent.glob("*_spatial_analysis_report.html"), None)

        rows.append(
            {
                "sample": sample,
                "pair": sample[:-2] if sample.endswith("-2") else sample,
                "rep": 2 if sample.endswith("-2") else 1,
                "chip": chip,
                "raw": as_number(barcode.get("Raw Reads")),
                "valid_pct": as_number(barcode.get("Valid Reads Fraction")),
                "adapter_pct": as_number(cutadapt.get("Reads with Adapters Fraction")),
                "unique_pct": as_number(star.get("Uniquely Mapped Reads Fraction")),
                "exonic_pct": as_number(feature.get("Reads Assigned To Exonic Regions Fraction")),
                "cells": as_number(count.get("Estimated Number of Cells")),
                "reads_in_cells": as_number(count.get("Fraction Reads in Cells")),
                "median_umi": as_number(count.get("Median UMI per Cell")),
                "median_genes": as_number(count.get("Median Genes per Cell")),
                "saturation": as_number(count.get("Saturation")),
                "mito5_bin50": parse_bin50_mito(metrics_path.parent / "07.analysis" / "stat.txt"),
                "report": str(report.relative_to(result_dir)) if report else "",
            }
        )
    return sorted(rows, key=lambda row: (row["pair"], row["rep"], row["sample"]))


def choose_add_seq(r1: dict[str, Any], r2: dict[str, Any]) -> tuple[str, str, str]:
    """Return recommended sample, priority, and reason for a paired group."""
    sat1 = r1.get("saturation")
    sat2 = r2.get("saturation")
    umi1 = r1.get("median_umi")
    umi2 = r2.get("median_umi")
    raw1 = r1.get("raw")
    raw2 = r2.get("raw")

    # When both libraries are already relatively saturated, prioritize the
    # replicate with lower expression complexity rather than the tiny
    # saturation difference. For under-sequenced pairs, saturation remains the
    # strongest signal.
    if sat1 is not None and sat2 is not None and min(sat1, sat2) >= 40 and umi1 is not None and umi2 is not None:
        recommended = r1 if umi1 <= umi2 else r2
    elif sat1 is not None and sat2 is not None:
        recommended = r1 if sat1 <= sat2 else r2
    elif raw1 is not None and raw2 is not None:
        recommended = r1 if raw1 <= raw2 else r2
    else:
        recommended = r1

    low_sat = min(x for x in [sat1, sat2] if x is not None) if sat1 is not None or sat2 is not None else None
    if low_sat is not None and low_sat < 25:
        priority = "是"
    elif low_sat is not None and low_sat < 40:
        priority = "可选"
    else:
        priority = "否/可选"

    reasons = []
    if raw1 is not None and raw2 is not None:
        reasons.append(f"原样本/{r1['sample']} reads {raw1 / 1_000_000:.1f}M，-2 reads {raw2 / 1_000_000:.1f}M")
    if sat1 is not None and sat2 is not None:
        reasons.append(f"饱和度 {sat1:.2f}% vs {sat2:.2f}%")
    if umi1 is not None and umi2 is not None:
        reasons.append(f"Median UMI {fmt_int(umi1)} vs {fmt_int(umi2)}")
    reasons.append(f"组内优先补 `{recommended['sample']}`")
    return recommended["sample"], priority, "；".join(reasons) + "。"


def render_markdown(rows: list[dict[str, Any]], result_dir: Path, case: str) -> str:
    title = case or result_dir.name
    lines: list[str] = [
        f"# {title} 空间转录组结果小结",
        "",
        "## 1. 结果完整性",
        "",
        f"- 本目录共检测到 {len(rows)} 份 Celatlas 结果。",
        "- 指标来自各样本 `.metrics.json`、`07.analysis/stat.txt` 和最终 HTML 报告。",
        "- 线粒体相关列表示“线粒体基因比例超过 5% 的 spot/cell 占比”，不是平均线粒体比例；表中采用报告重点 bin50 对应的统计值。",
        "",
        "## 2. 单份数据核心指标",
        "",
        "| 样本 | 芯片 | 数据 | Raw reads | 有效barcode | STAR唯一比对 | 外显子比例 | 估计细胞数 | Reads in cells | Median UMI | Median genes | Saturation | 线粒体>5% spot比例（bin50） |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for row in rows:
        lines.append(
            "| {sample} | {chip} | {rep} | {raw} | {valid} | {unique} | {exonic} | {cells} | {reads_in_cells} | {umi} | {genes} | {sat} | {mito} |".format(
                sample=row["sample"],
                chip=row["chip"],
                rep=row["rep"],
                raw=fmt_int(row["raw"]),
                valid=fmt_pct(row["valid_pct"]),
                unique=fmt_pct(row["unique_pct"]),
                exonic=fmt_pct(row["exonic_pct"]),
                cells=fmt_int(row["cells"]),
                reads_in_cells=fmt_pct(row["reads_in_cells"]),
                umi=fmt_int(row["median_umi"]),
                genes=fmt_int(row["median_genes"]),
                sat=fmt_pct(row["saturation"]),
                mito=fmt_pct(row["mito5_bin50"]),
            )
        )

    pairs = []
    for pair in sorted({row["pair"] for row in rows}):
        pair_rows = sorted([row for row in rows if row["pair"] == pair], key=lambda row: row["rep"])
        if len(pair_rows) == 2:
            pairs.append((pair, pair_rows[0], pair_rows[1]))

    if pairs:
        lines.extend(
            [
                "",
                "## 3. 每组原样本与 -2 的加测推荐",
                "",
                "| 组别 | 芯片 | 推荐加测对象 | 是否强烈建议加测 | 组内判断依据 |",
                "|---|---|---|---|---|",
            ]
        )
        for pair, r1, r2 in pairs:
            rec, priority, reason = choose_add_seq(r1, r2)
            lines.append(f"| {pair} | {r1['chip']} | `{rec}` | {priority} | {reason} |")
    else:
        sat_rows = [row for row in rows if row["saturation"] is not None]
        mito_rows = [row for row in rows if row["mito5_bin50"] is not None]
        lines.extend(["", "## 3. 批次判读与建议", ""])
        if sat_rows:
            lowest_sat = min(sat_rows, key=lambda row: row["saturation"])
            lines.append(
                f"- 各样本测序饱和度为 {min(row['saturation'] for row in sat_rows):.2f}%–{max(row['saturation'] for row in sat_rows):.2f}%；"
                f"`{lowest_sat['sample']}` 最低（{lowest_sat['saturation']:.2f}%）。如后续目标是提高低丰度转录本检出，可优先考虑该样本加测；其余样本的加测优先级需结合其饱和度和文库质量综合判断。"
            )
        if mito_rows:
            high_mito = [row for row in mito_rows if row["mito5_bin50"] >= 50]
            if high_mito:
                labels = "、".join(f"`{row['sample']}`（{row['mito5_bin50']:.2f}%）" for row in high_mito)
                lines.append(
                    f"- {labels} 的 bin50 中线粒体基因比例超过 5% 的 spot/cell 占比较高。"
                    "建议结合组织形态、坏死/应激区域及下游空间定位结果进行解释；增加测序深度通常不能直接改善该指标。"
                )
        lines.append(
            "- 各样本均已生成原生空间分析报告和完整条码/表达结果，可进入组织区域、空间表达模式与生物学分组的下游解读。"
        )

    lines.extend(["", "## 4. 报告位置", ""])
    for row in rows:
        lines.append(f"- `{row['sample']}`：`{row['report']}`")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    result_dir = Path(args.result_dir).resolve()
    rows = collect_rows(result_dir)
    if not rows:
        raise SystemExit(f"ERROR: no .metrics.json files found under {result_dir}")
    out_path = Path(args.out) if args.out else result_dir / f"{args.case or result_dir.name}_result_summary.md"
    out_path.write_text(render_markdown(rows, result_dir, args.case), encoding="utf-8")
    print(out_path)


if __name__ == "__main__":
    main()
