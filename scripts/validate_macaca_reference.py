#!/usr/bin/env python3
"""Validate a Celatlas Macaca STAR reference without modifying it."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REQUIRED = (
    "genome.fa",
    "genes.gtf",
    "Genome",
    "SA",
    "SAindex",
    "chrName.txt",
    "chrNameLength.txt",
    "genomeParameters.txt",
    "Log.out",
    "celatlas_genome.config",
    "mt_gene_ids.txt",
)


def cli() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("--star-version", default="2.7.11a")
    parser.add_argument("--assembly", default="Macaca_fascicularis_6.0")
    return parser.parse_args()


def fasta_contigs(path: Path) -> list[str]:
    return [
        line[1:].split()[0]
        for line in path.open(encoding="utf-8", errors="replace")
        if line.startswith(">")
    ]


def main() -> int:
    args = cli()
    root = args.reference.resolve()
    errors: list[str] = []
    for name in REQUIRED:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            errors.append(f"missing or empty: {path}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    fasta_text = (root / "genome.fa").read_text(encoding="utf-8", errors="replace")
    gtf_text = (root / "genes.gtf").read_text(encoding="utf-8", errors="replace")
    if args.assembly not in fasta_text:
        errors.append(f"FASTA does not identify assembly {args.assembly}")
    if args.assembly not in gtf_text[:200000]:
        errors.append(f"GTF does not identify assembly {args.assembly}")

    fasta_names = fasta_contigs(root / "genome.fa")
    star_names = [line.strip() for line in (root / "chrName.txt").read_text(encoding="utf-8").splitlines() if line.strip()]
    if fasta_names != star_names:
        errors.append("FASTA contig names/order do not match STAR chrName.txt")

    parameters = (root / "genomeParameters.txt").read_text(encoding="utf-8", errors="replace")
    log_text = (root / "Log.out").read_text(encoding="utf-8", errors="replace")
    # STAR's genomeParameters.txt stores the genome-file compatibility format
    # version, which may remain 2.7.4a even when a 2.7.11a executable creates
    # the index.  The executable version is authoritative in Log.out below.
    genome_format = re.search(r"^versionGenome\t([^\s]+)", parameters, flags=re.MULTILINE)
    if not genome_format:
        errors.append("genomeParameters.txt does not contain versionGenome")
    else:
        print(f"STAR genome format: {genome_format.group(1)}")
    if f"STAR version={args.star_version}" not in log_text:
        errors.append(f"Log.out is not STAR {args.star_version}")

    mt_ids = [line.strip() for line in (root / "mt_gene_ids.txt").read_text(encoding="utf-8").splitlines() if line.strip()]
    gtf_ids = set(re.findall(r'gene_id\s+["\']([^"\']+)', gtf_text))
    missing_mt = sorted(set(mt_ids) - gtf_ids)
    if missing_mt:
        errors.append(f"mt_gene_ids.txt contains IDs absent from GTF: {', '.join(missing_mt[:5])}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"OK: validated {root}")
    print(f"STAR: {args.star_version}; contigs: {len(fasta_names)}; mt genes: {len(mt_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
