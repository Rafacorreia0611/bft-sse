#!/usr/bin/env python3

"""Aggregate update-latency-by-database-size summaries across topologies."""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from pathlib import Path
from typing import Sequence


METRICS = (
    "total_latency",
    "normalization_latency",
    "state_request_latency",
    "address_resolution_latency",
    "oram_lock_latency",
    "token_build_latency",
    "update_request_round_trip_latency",
    "oram_publish_latency",
)

INPUT_COLUMNS = (
    "db_size",
    "update_doc_count",
    "min_db_size_before",
    "max_db_size_before",
    "metric",
    "n",
    "min_ms",
    "median_ms",
    "mean_ms",
    "max_ms",
    "source_csv",
)

OUTPUT_COLUMNS = (
    "sse_replicas",
    "oram_replicas",
    *INPUT_COLUMNS,
    "source_run",
)

METRIC_ORDER = {metric: index for index, metric in enumerate(METRICS)}
RUN_DIR_PATTERN = re.compile(
    r"_r(?P<sse>[1-9][0-9]*)"
    r"_o(?P<oram>[1-9][0-9]*)$"
)

Row = dict[str, str]
ComparisonSignature = dict[tuple[int, str], tuple[int, int, int, int]]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate update-latency-by-database-size TSV summaries across "
            "SSE/ORAM replica topologies."
        ),
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to the aggregated replica-sweep TSV.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Per-topology update_latency_by_db_size_summary.tsv files.",
    )
    return parser.parse_args(argv)


def run_metadata(input_path: Path) -> tuple[int, int, str]:
    source_run = input_path.parent.name
    match = RUN_DIR_PATTERN.search(source_run)
    if match is None:
        raise ValueError(
            "Cannot extract SSE and ORAM replica counts from run directory: "
            f"{source_run}"
        )

    return int(match.group("sse")), int(match.group("oram")), source_run


def validate_header(fieldnames: Sequence[str], input_path: Path) -> None:
    missing = [column for column in INPUT_COLUMNS if column not in fieldnames]
    if missing:
        raise ValueError(f"{input_path} is missing required columns: {', '.join(missing)}")


def parse_positive_int(raw_value: str, field_name: str, input_path: Path) -> int:
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise ValueError(f"{input_path} field {field_name} must be a valid integer") from exc

    if value <= 0:
        raise ValueError(f"{input_path} field {field_name} must be greater than 0")
    return value


def parse_non_negative_float(raw_value: str, field_name: str, input_path: Path) -> float:
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{input_path} field {field_name} must be a valid number") from exc

    if value < 0 or not math.isfinite(value):
        raise ValueError(
            f"{input_path} field {field_name} must be a finite number of 0 or greater"
        )
    return value


def validate_row(
    row: Row,
    input_path: Path,
) -> tuple[int, int, int, int, int]:
    db_size = parse_positive_int(row["db_size"], "db_size", input_path)
    update_doc_count = parse_positive_int(
        row["update_doc_count"],
        "update_doc_count",
        input_path,
    )
    min_db_size = parse_positive_int(
        row["min_db_size_before"],
        "min_db_size_before",
        input_path,
    )
    max_db_size = parse_positive_int(
        row["max_db_size_before"],
        "max_db_size_before",
        input_path,
    )
    sample_count = parse_positive_int(row["n"], "n", input_path)

    if sample_count % 2 == 0:
        raise ValueError(f"{input_path} field n must be odd")

    half_measurements = sample_count // 2
    expected_min_db_size = db_size - half_measurements * update_doc_count
    expected_max_db_size = db_size + half_measurements * update_doc_count
    if min_db_size != expected_min_db_size or max_db_size != expected_max_db_size:
        raise ValueError(
            f"{input_path} db_size={db_size} must have database-size range "
            f"{expected_min_db_size}..{expected_max_db_size}"
        )

    metric = row["metric"]
    if metric not in METRIC_ORDER:
        raise ValueError(f"{input_path} has unexpected metric: {metric}")
    if not row["source_csv"]:
        raise ValueError(f"{input_path} has an empty source_csv")

    min_ms = parse_non_negative_float(row["min_ms"], "min_ms", input_path)
    median_ms = parse_non_negative_float(row["median_ms"], "median_ms", input_path)
    mean_ms = parse_non_negative_float(row["mean_ms"], "mean_ms", input_path)
    max_ms = parse_non_negative_float(row["max_ms"], "max_ms", input_path)

    if not min_ms <= median_ms <= max_ms:
        raise ValueError(f"{input_path} must satisfy min_ms <= median_ms <= max_ms")
    if not min_ms <= mean_ms <= max_ms:
        raise ValueError(f"{input_path} must satisfy min_ms <= mean_ms <= max_ms")

    return db_size, update_doc_count, min_db_size, max_db_size, sample_count


def read_rows(
    input_path: Path,
) -> tuple[tuple[int, int], str, ComparisonSignature, list[Row]]:
    if not input_path.is_file():
        raise FileNotFoundError(f"Input TSV not found: {input_path}")

    sse_replicas, oram_replicas, source_run = run_metadata(input_path)
    rows: list[Row] = []
    comparison_signature: ComparisonSignature = {}
    metadata_by_db_size: dict[int, tuple[int, int, int, int]] = {}

    with input_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        validate_header(reader.fieldnames or (), input_path)

        for row in reader:
            input_row = {column: (row.get(column) or "").strip() for column in INPUT_COLUMNS}
            (
                db_size,
                update_doc_count,
                min_db_size,
                max_db_size,
                sample_count,
            ) = validate_row(input_row, input_path)
            metric = input_row["metric"]
            key = (db_size, metric)

            if key in comparison_signature:
                raise ValueError(
                    f"{input_path} contains duplicate db_size/metric row: "
                    f"{db_size}/{metric}"
                )

            metadata = (
                update_doc_count,
                min_db_size,
                max_db_size,
                sample_count,
            )
            previous_metadata = metadata_by_db_size.get(db_size)
            if previous_metadata is not None and previous_metadata != metadata:
                raise ValueError(
                    f"{input_path} has inconsistent update_doc_count, database-size "
                    f"range, or n for db_size={db_size}"
                )
            metadata_by_db_size[db_size] = metadata
            comparison_signature[key] = metadata
            rows.append(
                {
                    "sse_replicas": str(sse_replicas),
                    "oram_replicas": str(oram_replicas),
                    **input_row,
                    "source_run": source_run,
                }
            )

    if not rows:
        raise ValueError(f"Input TSV has no data rows: {input_path}")

    update_doc_counts = {metadata[0] for metadata in metadata_by_db_size.values()}
    if len(update_doc_counts) != 1:
        raise ValueError(
            f"{input_path} contains multiple update_doc_count values: "
            f"{sorted(update_doc_counts)}"
        )

    sample_counts = {metadata[3] for metadata in metadata_by_db_size.values()}
    if len(sample_counts) != 1:
        raise ValueError(
            f"{input_path} contains multiple measurement counts: {sorted(sample_counts)}"
        )

    db_sizes = set(metadata_by_db_size)
    expected_keys = {(db_size, metric) for db_size in db_sizes for metric in METRICS}
    missing_keys = expected_keys - comparison_signature.keys()
    if missing_keys:
        formatted = ", ".join(
            f"{db_size}/{metric}"
            for db_size, metric in sorted(
                missing_keys,
                key=lambda item: (item[0], METRIC_ORDER[item[1]]),
            )
        )
        raise ValueError(f"{input_path} is missing db_size/metric rows: {formatted}")

    return (
        (sse_replicas, oram_replicas),
        source_run,
        comparison_signature,
        rows,
    )


def aggregate_inputs(input_paths: Sequence[Path]) -> list[Row]:
    rows: list[Row] = []
    seen_topologies: dict[tuple[int, int], str] = {}
    expected_signature: ComparisonSignature | None = None
    expected_source_run = ""

    for input_path in input_paths:
        topology, source_run, signature, input_rows = read_rows(input_path)
        previous_run = seen_topologies.get(topology)
        if previous_run is not None:
            raise ValueError(
                f"Duplicate SSE/ORAM topology {topology[0]}/{topology[1]}: "
                f"{previous_run} and {source_run}"
            )
        seen_topologies[topology] = source_run

        if expected_signature is None:
            expected_signature = signature
            expected_source_run = source_run
        elif signature != expected_signature:
            raise ValueError(
                f"{source_run} is not comparable with {expected_source_run}: "
                "database sizes, update size, measurement count, database-size "
                "ranges, or metrics differ"
            )

        rows.extend(input_rows)

    return rows


def sort_key(row: Row) -> tuple[int, int, int, int]:
    return (
        int(row["sse_replicas"]),
        int(row["oram_replicas"]),
        int(row["db_size"]),
        METRIC_ORDER[row["metric"]],
    )


def write_rows(output_path: Path, rows: Sequence[Row]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            delimiter="\t",
            fieldnames=OUTPUT_COLUMNS,
            lineterminator="\n",
        )
        writer.writeheader()
        for row in sorted(rows, key=sort_key):
            writer.writerow(row)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    output_path = Path(args.output)

    try:
        rows = aggregate_inputs([Path(raw_input) for raw_input in args.inputs])
        write_rows(output_path, rows)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Read {len(args.inputs)} topology summary file(s)")
    print(f"Wrote {len(rows)} aggregated rows to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
