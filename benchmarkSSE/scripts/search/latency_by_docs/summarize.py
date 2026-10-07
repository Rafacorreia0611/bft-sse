#!/usr/bin/env python3

"""Summarize raw SSE latency benchmark samples into a TSV file."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence


METRICS = (
    ("total_latency", "total_latency_ns"),
    ("normalization_latency", "normalization_latency_ns"),
    ("state_request_latency", "state_request_latency_ns"),
    ("address_resolution_latency", "address_resolution_latency_ns"),
    ("oram_read_latency", "oram_read_latency_ns"),
    ("token_build_latency", "token_build_latency_ns"),
    ("search_request_round_trip_latency", "search_request_round_trip_latency_ns"),
    ("result_processing_latency", "result_processing_latency_ns"),
)

REQUIRED_COLUMNS = (
    "scenario",
    "operation",
    "run",
    "keyword",
    "doc_count",
    "bucket",
) + tuple(column for _, column in METRICS)

METRIC_ORDER = {name: index for index, (name, _) in enumerate(METRICS)}


@dataclass(frozen=True)
class Sample:
    scenario: str
    operation: str
    run: int
    keyword: str
    doc_count: int
    bucket: str
    latencies_ns: tuple[int, ...]


@dataclass(frozen=True)
class SummaryRow:
    bucket: str
    bucket_min_docs: int | None
    bucket_max_docs: int | None
    metric: str
    n: int
    min_ms: float
    median_ms: float
    mean_ms: float
    p95_ms: float
    p99_ms: float
    max_ms: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize search latency CSV samples into a TSV file.",
    )
    parser.add_argument(
        "--input",
        default="benchmarkSSE/results/data/search_latency_by_docs.csv",
        help="Path to the raw benchmark CSV.",
    )
    parser.add_argument(
        "--output",
        help="Path to the summary TSV. Defaults to <input>_summary.tsv.",
    )
    parser.add_argument(
        "--scenario",
        help="Optional scenario filter.",
    )
    parser.add_argument(
        "--operation",
        help="Optional operation filter.",
    )
    return parser.parse_args()


def default_output_path(input_path: Path) -> Path:
    return input_path.with_name(f"{input_path.stem}_summary.tsv")


def read_samples(input_path: Path, scenario_filter: str | None, operation_filter: str | None) -> List[Sample]:
    if not input_path.is_file():
        raise FileNotFoundError(f"Input CSV not found: {input_path}")

    with input_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        validate_header(reader.fieldnames or [])

        samples: List[Sample] = []
        for line_number, row in enumerate(reader, start=2):
            if row is None:
                continue

            sample = parse_sample(row, line_number)
            if scenario_filter and sample.scenario != scenario_filter:
                continue
            if operation_filter and sample.operation != operation_filter:
                continue
            samples.append(sample)

    if not samples:
        raise ValueError("No samples matched the selected filters.")
    return samples


def validate_header(fieldnames: Sequence[str]) -> None:
    missing = [column for column in REQUIRED_COLUMNS if column not in fieldnames]
    if missing:
        raise ValueError(f"CSV is missing required columns: {', '.join(missing)}")


def parse_sample(row: dict[str, str], line_number: int) -> Sample:
    try:
        scenario = require_value(row, "scenario", line_number)
        operation = require_value(row, "operation", line_number)
        run = int(require_value(row, "run", line_number))
        keyword = require_value(row, "keyword", line_number)
        doc_count = int(require_value(row, "doc_count", line_number))
        bucket = require_value(row, "bucket", line_number)
        latencies_ns = tuple(
            int(require_value(row, column, line_number)) for _, column in METRICS
        )
    except ValueError as exc:
        raise ValueError(f"Invalid value on line {line_number}: {exc}") from exc

    return Sample(
        scenario=scenario,
        operation=operation,
        run=run,
        keyword=keyword,
        doc_count=doc_count,
        bucket=bucket,
        latencies_ns=latencies_ns,
    )


def require_value(row: dict[str, str], column: str, line_number: int) -> str:
    value = row.get(column)
    if value is None or value.strip() == "":
        raise ValueError(f"missing '{column}' on line {line_number}")
    return value.strip()


def summarize_samples(samples: Iterable[Sample]) -> List[SummaryRow]:
    grouped: "OrderedDict[tuple[str, str], List[float]]" = OrderedDict()
    bucket_bounds: dict[str, tuple[int | None, int | None]] = {}

    for sample in samples:
        for (metric, _), latency_ns in zip(METRICS, sample.latencies_ns):
            key = (sample.bucket, metric)
            grouped.setdefault(key, []).append(latency_ns / 1_000_000.0)
        bucket_bounds.setdefault(sample.bucket, parse_bucket_bounds(sample.bucket))

    ordered_items = sorted(
        grouped.items(),
        key=lambda item: (
            bucket_sort_key(bucket_bounds[item[0][0]][0]),
            bucket_sort_key(bucket_bounds[item[0][0]][1]),
            item[0][0],
            METRIC_ORDER[item[0][1]],
        ),
    )

    rows: List[SummaryRow] = []
    for (bucket, metric), latencies_ms in ordered_items:
        sorted_latencies = sorted(latencies_ms)
        bucket_min_docs, bucket_max_docs = bucket_bounds[bucket]
        rows.append(
            SummaryRow(
                bucket=bucket,
                bucket_min_docs=bucket_min_docs,
                bucket_max_docs=bucket_max_docs,
                metric=metric,
                n=len(sorted_latencies),
                min_ms=sorted_latencies[0],
                median_ms=statistics.median(sorted_latencies),
                mean_ms=statistics.fmean(sorted_latencies),
                p95_ms=percentile_nearest_rank(sorted_latencies, 95),
                p99_ms=percentile_nearest_rank(sorted_latencies, 99),
                max_ms=sorted_latencies[-1],
            )
        )
    return rows


def parse_bucket_bounds(bucket: str) -> tuple[int | None, int | None]:
    parts = bucket.split(":", 1)
    if len(parts) != 2:
        return (None, None)

    try:
        return (int(parts[0]), int(parts[1]))
    except ValueError:
        return (None, None)


def bucket_sort_key(value: int | None) -> int:
    return value if value is not None else sys.maxsize


def percentile_nearest_rank(sorted_values: Sequence[float], percentile: int) -> float:
    if not sorted_values:
        raise ValueError("Cannot compute percentile of an empty sample set.")
    if percentile < 0 or percentile > 100:
        raise ValueError("Percentile must be between 0 and 100.")

    if percentile == 0:
        return sorted_values[0]

    rank = max(1, math.ceil((percentile / 100.0) * len(sorted_values)))
    return sorted_values[rank - 1]


def write_summary(output_path: Path, rows: Sequence[SummaryRow]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(
            (
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
        )
        for row in rows:
            writer.writerow(
                (
                    row.bucket,
                    "" if row.bucket_min_docs is None else row.bucket_min_docs,
                    "" if row.bucket_max_docs is None else row.bucket_max_docs,
                    row.metric,
                    row.n,
                    format_float(row.min_ms),
                    format_float(row.median_ms),
                    format_float(row.mean_ms),
                    format_float(row.p95_ms),
                    format_float(row.p99_ms),
                    format_float(row.max_ms),
                )
            )


def format_float(value: float) -> str:
    return f"{value:.6f}"


def print_summary_warnings(rows: Sequence[SummaryRow]) -> None:
    warned_buckets: set[str] = set()
    for row in rows:
        if row.n < 20 and row.bucket not in warned_buckets:
            print(
                f"Warning: bucket={row.bucket} has only n={row.n} samples per metric; "
                "p95 and p99 will be unstable.",
                file=sys.stderr,
            )
            warned_buckets.add(row.bucket)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else default_output_path(input_path)

    try:
        samples = read_samples(input_path, args.scenario, args.operation)
        rows = summarize_samples(samples)
        write_summary(output_path, rows)
        print_summary_warnings(rows)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Read {len(samples)} samples from {input_path}")
    print(f"Wrote {len(rows)} summary rows to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
