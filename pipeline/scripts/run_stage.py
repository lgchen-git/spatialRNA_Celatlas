#!/usr/bin/env python3
"""Run one Celatlas stage and create its completion marker."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--done", required=True, type=Path)
    parser.add_argument(
        "--check-path",
        type=Path,
        help="Path whose non-empty existence proves the stage completed; defaults to output-dir.",
    )
    parser.add_argument(
        "--alias",
        action="append",
        default=[],
        metavar="NAME=TARGET",
        help="temporary compatibility symlink under the sample root",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def add_aliases(values: list[str], sample_root: Path) -> list[Path]:
    created: list[Path] = []
    for value in values:
        if "=" not in value:
            raise ValueError(f"invalid alias, expected NAME=TARGET: {value}")
        name, target_name = value.split("=", 1)
        alias = sample_root / name
        target = sample_root / target_name
        if not target.exists():
            raise FileNotFoundError(f"alias target does not exist: {target}")
        if alias.exists() or alias.is_symlink():
            if not alias.is_symlink() or alias.resolve() != target.resolve():
                raise FileExistsError(f"refusing to replace existing path: {alias}")
            continue
        alias.symlink_to(os.path.relpath(target, alias.parent), target_is_directory=True)
        created.append(alias)
    return created


def main() -> int:
    args = parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise SystemExit("run_stage.py requires a command after --")

    output_dir = args.output_dir.resolve()
    done = args.done.resolve()
    check_path = (args.check_path or output_dir).resolve()
    sample_root = output_dir.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    # Celatlas may create this marker before its internal work is complete.
    # Remove any stale marker so a failed command cannot be mistaken for a
    # successful Snakemake output on a later run.
    done.unlink(missing_ok=True)
    created: list[Path] = []
    try:
        created = add_aliases(args.alias, sample_root)
        subprocess.run(command, check=True)
    finally:
        for alias in reversed(created):
            alias.unlink(missing_ok=True)

    if not check_path.exists():
        raise SystemExit(f"stage produced no output: {check_path}")
    if check_path.is_dir() and not any(check_path.iterdir()):
        raise SystemExit(f"stage produced an empty output directory: {check_path}")
    done.parent.mkdir(parents=True, exist_ok=True)
    done.write_text("complete\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileExistsError, FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
