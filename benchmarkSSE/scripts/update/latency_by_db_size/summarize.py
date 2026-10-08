#!/usr/bin/env python3

"""Validate and summarize update latency results for several database sizes."""

from __future__ import annotations

import argparse
import csv
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


METRICS = (
    ("total_latency", "total_latency_ns"),
    ("normalization_latency", "normalization_latency_ns"),
    ("state_request_latency", "state_request_latency_ns"),
    ("address_resolution_latency", "address_resolution_latency_ns"),
    ("oram_lock_latency", "oram_lock_latency_ns"),
    ("token_build_latency", "token_build_latency_ns"),
    ("update_request_round_trip_latency", "update_request_round_trip_latency_ns"),
    ("oram_publish_latency", "oram_publish_latency_ns"),
)

REQUIRED_COLUMNS = (
    "scenario",
    "operation",
    "run",
    "keyword",
    "doc_count",
    "expected_db_size_before",
) + tuple(column for _, column in METRICS)

METRIC_ORDER = {name: index for index, (name, _) in enumerate(METRICS)}
DB_DIRECTORY_PATTERN = re.compile(r"^db([1-9][0-9]*)$")


@dataclass(frozen=True)
class Sample:
    run: int
    keyword: str
    doc_count: int
    expected_db_size_before: int
    latencies_ns: tuple[int, ...]


@dataclass(frozen=True)
class SummaryRow:
    db_size: int
    update_doc_count: int
    min_db_size_before: int
    max_db_size_before: int
    metric: str
    n: int
    min_ms: float
    median_ms: float
    mean_ms: float
    max_ms: float
    source_csv: str


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize update latency CSV files across database sizes.",
    )
    parser.add_argument("--output", required=True, help="Path to the summary TSV.")
    parser.add_argument(
        "--update-doc-count",
        required=True,
        type=parse_positive_int,
        help="Expected number of document associations added by every update.",
    )
    parser.add_argument(
        "--measurement-count",
        required=True,
        type=parse_positive_odd_int,
        help="Expected positive odd number of measurements in every input CSV.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Raw CSV files stored below db<database-size> directories.",
    )
    return parser.parse_args(argv)


def parse_positive_int(raw_value: str) -> int:
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"must be a valid integer: {raw_value}") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return value


def parse_positive_odd_int(raw_value: str) -> int:
    value = parse_positive_int(raw_value)
    if value % 2 == 0:
        raise argparse.ArgumentTypeError("must be odd")
    return value


def database_size_from_path(input_path: Path) -> int:
    match = DB_DIRECTORY_PATTERN.fullmatch(input_path.parent.name)
    if match is None:
        raise ValueError(
            f"{input_path} must be directly inside a db<database-size> directory"
        )
    return int(match.group(1))


def read_samples(
    input_path: Path,
    measurement_count: int,
    update_doc_count: int,
    db_size: int,
) -> list[Sample]:
    if not input_path.is_file():
        raise FileNotFoundError(f"Input CSV not found: {input_path}")

    with input_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        validate_header(reader.fieldnames or (), input_path)
        samples = [
            parse_sample(row, line_number, input_path)
            for line_number, row in enumerate(reader, start=2)
        ]

    if len(samples) != measurement_count:
        raise ValueError(
            f"{input_path} contains {len(samples)} measurements, expected {measurement_count}"
        )

    expected_runs = list(range(1, measurement_count + 1))
    actual_runs = [sample.run for sample in samples]
    if actual_runs != expected_runs:
        raise ValueError(
            f"{input_path} run values must be {expected_runs}, found {actual_runs}"
        )

    keywords = [sample.keyword for sample in samples]
    if len(set(keywords)) != len(keywords):
        raise ValueError(f"{input_path} contains duplicate measured keywords")

    middle_index = measurement_count // 2
    for index, sample in enumerate(samples):
        if sample.doc_count != update_doc_count:
            raise ValueError(
                f"{input_path} run {sample.run} has doc_count={sample.doc_count}, "
                f"expected {update_doc_count}"
            )

        expected_db_size_before = db_size + (index - middle_index) * update_doc_count
        if sample.expected_db_size_before != expected_db_size_before:
            raise ValueError(
                f"{input_path} run {sample.run} has expected_db_size_before="
                f"{sample.expected_db_size_before}, expected {expected_db_size_before}"
            )

    return samples


def validate_header(fieldnames: Sequence[str], input_path: Path) -> None:
    missing = [column for column in REQUIRED_COLUMNS if column not in fieldnames]
    if missing:
        raise ValueError(f"{input_path} is missing required columns: {', '.join(missing)}")


def parse_sample(row: dict[str, str], line_number: int, input_path: Path) -> Sample:
    scenario = require_value(row, "scenario", line_number, input_path)
    operation = require_value(row, "operation", line_number, input_path)
    if scenario != "update-latency-by-docs":
        raise ValueError(f"{input_path} line {line_number} has unexpected scenario: {scenario}")
    if operation != "UPDATE":
        raise ValueError(f"{input_path} line {line_number} has unexpected operation: {operation}")

    return Sample(
        run=parse_positive_row_int(row, "run", line_number, input_path),
        keyword=require_value(row, "keyword", line_number, input_path),
        doc_count=parse_positive_row_int(row, "doc_count", line_number, input_path),
        expected_db_size_before=parse_positive_row_int(
            row,
            "expected_db_size_before",
            line_number,
            input_path,
        ),
        latencies_ns=tuple(
            parse_non_negative_row_int(row, column, line_number, input_path)
            for _, column in METRICS
        ),
    )


def require_value(
    row: dict[str, str],
    column: str,
    line_number: int,
    input_path: Path,
) -> str:
    value = row.get(column)
    if value is None or not value.strip():
        raise ValueError(f"{input_path} line {line_number} is missing '{column}'")
    return value.strip()


def parse_row_int(
    row: dict[str, str],
    column: str,
    line_number: int,
    input_path: Path,
) -> int:
    raw_value = require_value(row, column, line_number, input_path)
    try:
        return int(raw_value)
    except ValueError as exc:
        raise ValueError(
            f"{input_path} line {line_number} field {column} must be a valid integer"
        ) from exc


def parse_positive_row_int(
    row: dict[str, str],
    column: str,
    line_number: int,
    input_path: Path,
) -> int:
    value = parse_row_int(row, column, line_number, input_path)
    if value <= 0:
        raise ValueError(f"{input_path} line {line_number} field {column} must be greater than 0")
    return value


def parse_non_negative_row_int(
    row: dict[str, str],
    column: str,
    line_number: int,
    input_path: Path,
) -> int:
    value = parse_row_int(row, column, line_number, input_path)
    if value < 0:
        raise ValueError(f"{input_path} line {line_number} field {column} must be 0 or greater")
    return value


def summarize_samples(
    samples: Sequence[Sample],
    db_size: int,
    update_doc_count: int,
    source_csv: str,
) -> list[SummaryRow]:
    db_sizes_before = [sample.expected_db_size_before for sample in samples]
    rows: list[SummaryRow] = []

    for metric_index, (metric, _) in enumerate(METRICS):
        latencies_ms = [sample.latencies_ns[metric_index] / 1_000_000.0 for sample in samples]
        rows.append(
            SummaryRow(
                db_size=db_size,
                update_doc_count=update_doc_count,
                min_db_size_before=min(db_sizes_before),
                max_db_size_before=max(db_sizes_before),
                metric=metric,
                n=len(latencies_ms),
                min_ms=min(latencies_ms),
                median_ms=statistics.median(latencies_ms),
                mean_ms=statistics.fmean(latencies_ms),
                max_ms=max(latencies_ms),
                source_csv=source_csv,
            )
        )

    return rows


def summarize_inputs(
    input_paths: Sequence[Path],
    measurement_count: int,
    update_doc_count: int,
) -> list[SummaryRow]:
    rows: list[SummaryRow] = []
    source_by_db_size: dict[int, Path] = {}

    for input_path in input_paths:
        db_size = database_size_from_path(input_path)
        previous_source = source_by_db_size.get(db_size)
        if previous_source is not None:
            raise ValueError(
                f"Duplicate database size {db_size} in {previous_source} and {input_path}"
            )
        source_by_db_size[db_size] = input_path

        samples = read_samples(
            input_path,
            measurement_count,
            update_doc_count,
            db_size,
        )
        rows.extend(
            summarize_samples(samples, db_size, update_doc_count, str(input_path))
        )

    return sorted(rows, key=lambda row: (row.db_size, METRIC_ORDER[row.metric]))


def write_summary(output_path: Path, rows: Sequence[SummaryRow]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(
            (
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
        )
        for row in rows:
            writer.writerow(
                (
                    row.db_size,
                    row.update_doc_count,
                    row.min_db_size_before,
                    row.max_db_size_before,
                    row.metric,
                    row.n,
                    format_float(row.min_ms),
                    format_float(row.median_ms),
                    format_float(row.mean_ms),
                    format_float(row.max_ms),
                    row.source_csv,
                )
            )


def format_float(value: float) -> str:
    return f"{value:.6f}"


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    input_paths = [Path(raw_input) for raw_input in args.inputs]
    output_path = Path(args.output)

    try:
        rows = summarize_inputs(
            input_paths,
            args.measurement_count,
            args.update_doc_count,
        )
        write_summary(output_path, rows)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    sample_count = args.measurement_count * len(input_paths)
    print(f"Read {sample_count} samples from {len(input_paths)} CSV file(s)")
    print(f"Wrote {len(rows)} summary rows to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
