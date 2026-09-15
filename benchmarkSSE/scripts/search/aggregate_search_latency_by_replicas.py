#!/usr/bin/env python3

"""Aggregate per-run search latency summaries across replica counts."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path
from typing import Sequence


INPUT_COLUMNS = (
    "bucket",
    "bucket_min_docs",
    "bucket_max_docs",
    "metric",
    "n",
    "min_ms",
    "median_ms",
    "mean_ms",
    "p95_ms",
    "p99_ms",
    "max_ms",
)

OUTPUT_COLUMNS = (
    "sse_replicas",
    "oram_replicas",
    *INPUT_COLUMNS,
    "source_run",
)

RUN_DIR_PATTERN = re.compile(r"_r(?P<sse>[0-9]+)_o(?P<oram>[0-9]+)$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Aggregate search latency TSV summaries across replica counts.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to the aggregated TSV output.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Per-run search_latency_by_docs_summary.tsv files.",
    )
    return parser.parse_args()


def run_metadata(input_path: Path) -> tuple[int, int, str]:
    run_dir = input_path.parent.name
    match = RUN_DIR_PATTERN.search(run_dir)
    if match is None:
        raise ValueError(f"Cannot extract SSE/ORAM replica counts from run directory: {run_dir}")

    return int(match.group("sse")), int(match.group("oram")), run_dir


def validate_header(fieldnames: Sequence[str], input_path: Path) -> None:
    missing = [column for column in INPUT_COLUMNS if column not in fieldnames]
    if missing:
        raise ValueError(f"{input_path} is missing required columns: {', '.join(missing)}")


def read_rows(input_path: Path) -> list[dict[str, str]]:
    if not input_path.is_file():
        raise FileNotFoundError(f"Input TSV not found: {input_path}")

    sse_replicas, oram_replicas, source_run = run_metadata(input_path)
    rows: list[dict[str, str]] = []

    with input_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        validate_header(reader.fieldnames or (), input_path)

        for row in reader:
            output_row = {
                "sse_replicas": str(sse_replicas),
                "oram_replicas": str(oram_replicas),
                "source_run": source_run,
            }
            for column in INPUT_COLUMNS:
                output_row[column] = (row.get(column) or "").strip()
            rows.append(output_row)

    if not rows:
        raise ValueError(f"Input TSV has no data rows: {input_path}")
    return rows


def sort_key(row: dict[str, str]) -> tuple[int, int, int, int, str]:
    return (
        int(row["sse_replicas"]),
        int(row["oram_replicas"]),
        int(row["bucket_min_docs"] or "0"),
        int(row["bucket_max_docs"] or "0"),
        row["bucket"],
    )


def write_rows(output_path: Path, rows: Sequence[dict[str, str]]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, delimiter="\t", fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        for row in sorted(rows, key=sort_key):
            writer.writerow(row)


def main() -> int:
    args = parse_args()
    output_path = Path(args.output)

    try:
        rows: list[dict[str, str]] = []
        for raw_input in args.inputs:
            rows.extend(read_rows(Path(raw_input)))
        write_rows(output_path, rows)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote {len(rows)} aggregated rows to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
