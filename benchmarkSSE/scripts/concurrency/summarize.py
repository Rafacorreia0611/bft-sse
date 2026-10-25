#!/usr/bin/env python3

"""Summarize repeated concurrent benchmark runs."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable, Sequence


BENCHMARKS = (
    "client-scalability",
    "replication-scalability",
    "workload-mix",
    "lock-contention",
)

CHAIN_LENGTH_TIME_BUCKET_COUNT = 10

COMMON_MANIFEST_COLUMNS = (
    "run_id",
    "repetition",
    "sample_csv",
    "measurement_seconds",
    "sse_replicas",
    "oram_replicas",
    "client_count",
    "synthetic_keyword_count",
    "synthetic_documents_per_keyword",
    "dataset_seed",
    "workload_seed",
)

WORKLOAD_MANIFEST_COLUMNS = (
    "search_percentage",
    "access_distribution",
    "zipfian_exponent",
)

LOCK_MANIFEST_COLUMNS = (
    "contention_level",
    "shared_keyword_count",
)

COMMON_CONFIG_COLUMNS = (
    "sse_replicas",
    "oram_replicas",
    "client_count",
)

DATASET_CONFIG_COLUMNS = (
    "synthetic_keyword_count",
    "synthetic_documents_per_keyword",
    "dataset_seed",
    "measurement_seconds",
)

SEARCH_LATENCY_COLUMNS = (
    ("total_latency", "total_latency_ns"),
    ("normalization_latency", "normalization_latency_ns"),
    ("state_request_latency", "state_request_latency_ns"),
    ("address_resolution_latency", "address_resolution_latency_ns"),
    ("oram_access_latency", "oram_access_latency_ns"),
    ("token_build_latency", "token_build_latency_ns"),
    ("request_round_trip_latency", "request_round_trip_latency_ns"),
    ("result_processing_latency", "result_processing_latency_ns"),
)

UPDATE_LATENCY_COLUMNS = (
    ("total_latency", "total_latency_ns"),
    ("normalization_latency", "normalization_latency_ns"),
    ("state_request_latency", "state_request_latency_ns"),
    ("address_resolution_latency", "address_resolution_latency_ns"),
    ("oram_access_latency", "oram_access_latency_ns"),
    ("token_build_latency", "token_build_latency_ns"),
    ("request_round_trip_latency", "request_round_trip_latency_ns"),
    ("oram_publish_latency", "oram_publish_latency_ns"),
)

RAW_COLUMNS = (
    "scenario",
    "operation",
    "client_count",
    "client_id",
    "client_operation",
    "keyword",
    "updated_document_count",
    "observed_chain_length",
    "start_offset_ns",
    "total_latency_ns",
    "normalization_latency_ns",
    "state_request_latency_ns",
    "address_resolution_latency_ns",
    "oram_access_latency_ns",
    "oram_lock_retry_count",
    "token_build_latency_ns",
    "request_round_trip_latency_ns",
    "result_processing_latency_ns",
    "oram_publish_latency_ns",
)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize repeated concurrent SSE benchmark runs.",
    )
    parser.add_argument("--benchmark", required=True, choices=BENCHMARKS)
    parser.add_argument("--manifest", required=True, help="TSV manifest of completed runs.")
    parser.add_argument("--output-dir", required=True, help="Directory for summary TSV files.")
    parser.add_argument(
        "--expected-repetitions",
        required=True,
        type=int,
        help="Required number of repetitions for every configuration.",
    )
    args = parser.parse_args(argv)
    if args.expected_repetitions <= 0:
        parser.error("--expected-repetitions must be greater than 0")
    return args


def is_lock_benchmark(benchmark: str) -> bool:
    return benchmark == "lock-contention"


def manifest_columns(benchmark: str) -> tuple[str, ...]:
    specific = LOCK_MANIFEST_COLUMNS if is_lock_benchmark(benchmark) else WORKLOAD_MANIFEST_COLUMNS
    return COMMON_MANIFEST_COLUMNS + specific


def config_columns(benchmark: str) -> tuple[str, ...]:
    if is_lock_benchmark(benchmark):
        specific = ("contention_level", "shared_keyword_count")
    else:
        specific = ("search_percentage", "access_distribution", "zipfian_exponent")
    return COMMON_CONFIG_COLUMNS + specific + DATASET_CONFIG_COLUMNS


def parse_int(value: str, field: str, context: str, minimum: int | None = None) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{context}: {field} must be an integer") from exc
    if minimum is not None and parsed < minimum:
        raise ValueError(f"{context}: {field} must be at least {minimum}")
    return parsed


def parse_float(value: str, field: str, context: str, minimum: float = 0.0) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{context}: {field} must be a number") from exc
    if not math.isfinite(parsed) or parsed < minimum:
        raise ValueError(f"{context}: {field} must be a finite number of at least {minimum}")
    return parsed


def validate_header(fieldnames: Sequence[str], required: Iterable[str], context: str) -> None:
    missing = [column for column in required if column not in fieldnames]
    if missing:
        raise ValueError(f"{context} is missing required columns: {', '.join(missing)}")


def normalize_manifest_row(
    row: dict[str, str], benchmark: str, manifest_path: Path, line_number: int
) -> dict[str, str]:
    context = f"{manifest_path}:{line_number}"
    normalized = {key: (value or "").strip() for key, value in row.items()}

    if not normalized["run_id"]:
        raise ValueError(f"{context}: run_id cannot be empty")
    if not normalized["sample_csv"]:
        raise ValueError(f"{context}: sample_csv cannot be empty")

    positive_fields = (
        "repetition",
        "measurement_seconds",
        "sse_replicas",
        "oram_replicas",
        "client_count",
        "synthetic_keyword_count",
        "synthetic_documents_per_keyword",
    )
    for field in positive_fields:
        normalized[field] = str(parse_int(normalized[field], field, context, 1))
    for field in ("dataset_seed", "workload_seed"):
        normalized[field] = str(parse_int(normalized[field], field, context))

    if is_lock_benchmark(benchmark):
        level = normalized["contention_level"].lower()
        if level not in ("none", "moderate", "high"):
            raise ValueError(f"{context}: contention_level must be none, moderate or high")
        shared_count = parse_int(
            normalized["shared_keyword_count"], "shared_keyword_count", context, 0
        )
        if level == "none" and shared_count != 0:
            raise ValueError(f"{context}: none contention requires shared_keyword_count=0")
        if level == "moderate" and shared_count == 0:
            raise ValueError(f"{context}: moderate contention requires a positive shared_keyword_count")
        if level == "high" and shared_count != 1:
            raise ValueError(f"{context}: high contention requires shared_keyword_count=1")
        normalized["contention_level"] = level
        normalized["shared_keyword_count"] = str(shared_count)
    else:
        search_percentage = parse_int(
            normalized["search_percentage"], "search_percentage", context, 0
        )
        if search_percentage > 100:
            raise ValueError(f"{context}: search_percentage must be at most 100")
        distribution = normalized["access_distribution"].lower()
        if distribution not in ("uniform", "zipfian"):
            raise ValueError(f"{context}: access_distribution must be uniform or zipfian")
        exponent = normalized["zipfian_exponent"]
        if distribution == "uniform" and exponent:
            raise ValueError(f"{context}: uniform access must have an empty zipfian_exponent")
        if distribution == "zipfian":
            exponent = format_number(
                parse_float(exponent, "zipfian_exponent", context, minimum=0.000000001)
            )
        normalized["search_percentage"] = str(search_percentage)
        normalized["access_distribution"] = distribution
        normalized["zipfian_exponent"] = exponent

    sample_path = Path(normalized["sample_csv"])
    if not sample_path.is_absolute():
        sample_path = manifest_path.parent / sample_path
    normalized["_sample_path"] = str(sample_path.resolve())
    return normalized


def read_manifest(path: Path, benchmark: str) -> list[dict[str, str]]:
    if not path.is_file():
        raise FileNotFoundError(f"Manifest not found: {path}")

    rows: list[dict[str, str]] = []
    seen_run_ids: set[str] = set()
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        validate_header(reader.fieldnames or (), manifest_columns(benchmark), str(path))
        for line_number, row in enumerate(reader, start=2):
            normalized = normalize_manifest_row(row, benchmark, path, line_number)
            run_id = normalized["run_id"]
            if run_id in seen_run_ids:
                raise ValueError(f"{path}:{line_number}: duplicate run_id {run_id}")
            seen_run_ids.add(run_id)
            rows.append(normalized)

    if not rows:
        raise ValueError(f"Manifest has no runs: {path}")
    return rows


def group_manifest_rows(
    rows: Sequence[dict[str, str]], benchmark: str, expected_repetitions: int
) -> list[tuple[dict[str, str], list[dict[str, str]]]]:
    columns = config_columns(benchmark)
    grouped: dict[tuple[str, ...], list[dict[str, str]]] = {}
    for row in rows:
        key = tuple(row[column] for column in columns)
        grouped.setdefault(key, []).append(row)

    result = []
    expected = set(range(1, expected_repetitions + 1))
    for key, group in grouped.items():
        repetitions = [int(row["repetition"]) for row in group]
        if len(repetitions) != len(set(repetitions)):
            raise ValueError(f"Configuration {format_config(columns, key)} has duplicate repetitions")
        if set(repetitions) != expected:
            actual = ",".join(str(value) for value in sorted(repetitions))
            raise ValueError(
                f"Configuration {format_config(columns, key)} has repetitions [{actual}]; "
                f"expected 1..{expected_repetitions}"
            )
        workload_seeds = [row["workload_seed"] for row in group]
        if len(workload_seeds) != len(set(workload_seeds)):
            raise ValueError(
                f"Configuration {format_config(columns, key)} has duplicate workload seeds"
            )
        group.sort(key=lambda row: int(row["repetition"]))
        result.append((dict(zip(columns, key)), group))
    return result


def format_config(columns: Sequence[str], values: Sequence[str]) -> str:
    return ", ".join(f"{column}={value}" for column, value in zip(columns, values))


def expected_operations(entry: dict[str, str], benchmark: str) -> tuple[str, ...]:
    if is_lock_benchmark(benchmark):
        return ("UPDATE",)
    search_percentage = int(entry["search_percentage"])
    operations = []
    if search_percentage > 0:
        operations.append("SEARCH")
    if search_percentage < 100:
        operations.append("UPDATE")
    return tuple(operations)


def read_raw_run(entry: dict[str, str], benchmark: str) -> dict[str, object]:
    path = Path(entry["_sample_path"])
    if not path.is_file():
        raise FileNotFoundError(f"Run {entry['run_id']} sample CSV not found: {path}")

    latency_columns = {
        "SEARCH": SEARCH_LATENCY_COLUMNS,
        "UPDATE": UPDATE_LATENCY_COLUMNS,
    }
    latencies = {
        operation: {metric: [] for metric, _ in columns}
        for operation, columns in latency_columns.items()
    }
    counts = {"SEARCH": 0, "UPDATE": 0}
    chain_buckets = [[] for _ in range(CHAIN_LENGTH_TIME_BUCKET_COUNT)]
    retries: list[int] = []
    duration_ns = int(entry["measurement_seconds"]) * 1_000_000_000
    expected_scenario = "lock-contention" if is_lock_benchmark(benchmark) else "concurrent-workload"

    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        validate_header(reader.fieldnames or (), RAW_COLUMNS, str(path))
        for line_number, row in enumerate(reader, start=2):
            context = f"{path}:{line_number}"
            operation = (row["operation"] or "").strip().upper()
            if operation not in ("SEARCH", "UPDATE"):
                raise ValueError(f"{context}: operation must be SEARCH or UPDATE")
            if is_lock_benchmark(benchmark) and operation != "UPDATE":
                raise ValueError(f"{context}: lock-contention samples must all be updates")
            if (row["scenario"] or "").strip() != expected_scenario:
                raise ValueError(f"{context}: expected scenario {expected_scenario}")
            if parse_int(row["client_count"], "client_count", context, 1) != int(entry["client_count"]):
                raise ValueError(f"{context}: client_count does not match the manifest")

            start_offset = parse_int(row["start_offset_ns"], "start_offset_ns", context, 0)
            if start_offset >= duration_ns:
                raise ValueError(f"{context}: start_offset_ns is outside the measurement window")
            chain_length = parse_int(
                row["observed_chain_length"], "observed_chain_length", context, 0
            )
            bucket = min(
                start_offset * CHAIN_LENGTH_TIME_BUCKET_COUNT // duration_ns,
                CHAIN_LENGTH_TIME_BUCKET_COUNT - 1,
            )
            chain_buckets[bucket].append(chain_length)

            counts[operation] += 1
            for metric, column in latency_columns[operation]:
                latencies[operation][metric].append(parse_int(row[column], column, context, 0))
            if operation == "UPDATE":
                retries.append(
                    parse_int(row["oram_lock_retry_count"], "oram_lock_retry_count", context, 0)
                )

    if counts["SEARCH"] + counts["UPDATE"] == 0:
        raise ValueError(f"Run {entry['run_id']} contains no samples")
    for operation in expected_operations(entry, benchmark):
        if counts[operation] == 0:
            raise ValueError(f"Run {entry['run_id']} contains no {operation} samples")
    for operation in ("SEARCH", "UPDATE"):
        if operation not in expected_operations(entry, benchmark) and counts[operation] > 0:
            raise ValueError(f"Run {entry['run_id']} unexpectedly contains {operation} samples")

    return {
        "counts": counts,
        "latencies": latencies,
        "chain_buckets": chain_buckets,
        "retries": retries,
    }


def nearest_rank(sorted_values: Sequence[float | int], percentile: int) -> float | int:
    rank = max(1, math.ceil(percentile / 100.0 * len(sorted_values)))
    return sorted_values[rank - 1]


def describe(values: Sequence[float | int]) -> dict[str, float | int]:
    if not values:
        raise ValueError("Cannot summarize an empty sample set")
    ordered = sorted(values)
    return {
        "n": len(values),
        "mean": statistics.fmean(values),
        "stddev": statistics.pstdev(values),
        "min": ordered[0],
        "p50": statistics.median(ordered),
        "p95": nearest_rank(ordered, 95),
        "max": ordered[-1],
    }


def sample_stddev(values: Sequence[float]) -> float | None:
    return statistics.stdev(values) if len(values) > 1 else None


def format_number(value: float | int | None) -> str:
    if value is None:
        return ""
    if isinstance(value, int):
        return str(value)
    rendered = f"{value:.6f}"
    return rendered.rstrip("0").rstrip(".")


def milliseconds(value_ns: float | int) -> float:
    return float(value_ns) / 1_000_000.0


def metadata(config: dict[str, str], columns: Sequence[str]) -> dict[str, str]:
    return {column: config[column] for column in columns}


def summarize(
    groups: Sequence[tuple[dict[str, str], list[dict[str, str]]]], benchmark: str
) -> dict[str, list[dict[str, str]]]:
    columns = config_columns(benchmark)
    outputs: dict[str, list[dict[str, str]]] = defaultdict(list)

    for config, entries in groups:
        pooled_latencies = {
            "SEARCH": {metric: [] for metric, _ in SEARCH_LATENCY_COLUMNS},
            "UPDATE": {metric: [] for metric, _ in UPDATE_LATENCY_COLUMNS},
        }
        run_latency_stats: dict[tuple[str, str], list[dict[str, float | int]]] = defaultdict(list)
        run_throughputs: dict[str, list[float]] = defaultdict(list)
        operation_totals: dict[str, int] = defaultdict(int)
        pooled_chain_buckets = [[] for _ in range(CHAIN_LENGTH_TIME_BUCKET_COUNT)]
        pooled_retries: list[int] = []
        operations = expected_operations(entries[0], benchmark)

        for entry in entries:
            run = read_raw_run(entry, benchmark)
            counts = run["counts"]
            duration = int(entry["measurement_seconds"])
            total_count = counts["SEARCH"] + counts["UPDATE"]

            for operation, count in (("ALL", total_count),) + tuple(
                (operation, counts[operation]) for operation in operations
            ):
                throughput = count / float(duration)
                run_throughputs[operation].append(throughput)
                operation_totals[operation] += count
                row = metadata(config, columns)
                row.update(
                    {
                        "run_id": entry["run_id"],
                        "repetition": entry["repetition"],
                        "workload_seed": entry["workload_seed"],
                        "operation": operation,
                        "operation_count": str(count),
                        "throughput_ops_s": format_number(throughput),
                    }
                )
                outputs["per_run_throughput"].append(row)

            for operation in operations:
                for metric, _ in (
                    SEARCH_LATENCY_COLUMNS if operation == "SEARCH" else UPDATE_LATENCY_COLUMNS
                ):
                    values = run["latencies"][operation][metric]
                    stats = describe(values)
                    run_latency_stats[(operation, metric)].append(stats)
                    pooled_latencies[operation][metric].extend(values)
                    row = metadata(config, columns)
                    row.update(
                        {
                            "run_id": entry["run_id"],
                            "repetition": entry["repetition"],
                            "operation": operation,
                            "metric": metric,
                            "sample_count": str(stats["n"]),
                            "mean_ms": format_number(milliseconds(stats["mean"])),
                            "stddev_ms": format_number(milliseconds(stats["stddev"])),
                            "min_ms": format_number(milliseconds(stats["min"])),
                            "p50_ms": format_number(milliseconds(stats["p50"])),
                            "p95_ms": format_number(milliseconds(stats["p95"])),
                            "max_ms": format_number(milliseconds(stats["max"])),
                        }
                    )
                    outputs["per_run_latency"].append(row)

            for index, values in enumerate(run["chain_buckets"]):
                pooled_chain_buckets[index].extend(values)
            pooled_retries.extend(run["retries"])

        for operation in ("ALL",) + operations:
            values = run_throughputs[operation]
            row = metadata(config, columns)
            row.update(
                {
                    "operation": operation,
                    "repetitions": str(len(values)),
                    "total_operations": str(operation_totals[operation]),
                    "mean_ops_s": format_number(statistics.fmean(values)),
                    "median_ops_s": format_number(statistics.median(values)),
                    "stddev_ops_s": format_number(sample_stddev(values)),
                    "min_ops_s": format_number(min(values)),
                    "max_ops_s": format_number(max(values)),
                }
            )
            outputs["throughput_summary"].append(row)

        for (operation, metric), per_run_stats in run_latency_stats.items():
            pooled = describe(pooled_latencies[operation][metric])
            row = metadata(config, columns)
            row.update(
                {
                    "operation": operation,
                    "metric": metric,
                    "repetitions": str(len(per_run_stats)),
                    "sample_count": str(pooled["n"]),
                    "mean_ms": format_number(milliseconds(pooled["mean"])),
                    "stddev_ms": format_number(milliseconds(pooled["stddev"])),
                    "min_ms": format_number(milliseconds(pooled["min"])),
                    "p50_ms": format_number(milliseconds(pooled["p50"])),
                    "p95_ms": format_number(milliseconds(pooled["p95"])),
                    "max_ms": format_number(milliseconds(pooled["max"])),
                }
            )
            outputs["latency_pooled"].append(row)

            means = [milliseconds(stats["mean"]) for stats in per_run_stats]
            p50s = [milliseconds(stats["p50"]) for stats in per_run_stats]
            p95s = [milliseconds(stats["p95"]) for stats in per_run_stats]
            row = metadata(config, columns)
            row.update(
                {
                    "operation": operation,
                    "metric": metric,
                    "repetitions": str(len(per_run_stats)),
                    "mean_latency_ms": format_number(statistics.fmean(means)),
                    "mean_latency_stddev_ms": format_number(sample_stddev(means)),
                    "p50_mean_ms": format_number(statistics.fmean(p50s)),
                    "p50_stddev_ms": format_number(sample_stddev(p50s)),
                    "p95_mean_ms": format_number(statistics.fmean(p95s)),
                    "p95_stddev_ms": format_number(sample_stddev(p95s)),
                }
            )
            outputs["latency_summary"].append(row)

        if "UPDATE" in operations:
            for index, values in enumerate(pooled_chain_buckets):
                if not values:
                    continue
                stats = describe(values)
                row = metadata(config, columns)
                row.update(
                    {
                        "time_bucket": (
                            f"{index * 100 // CHAIN_LENGTH_TIME_BUCKET_COUNT}-"
                            f"{(index + 1) * 100 // CHAIN_LENGTH_TIME_BUCKET_COUNT}%"
                        ),
                        "repetitions": str(len(entries)),
                        "sample_count": str(stats["n"]),
                        "mean_chain_length": format_number(stats["mean"]),
                        "stddev_chain_length": format_number(stats["stddev"]),
                        "min_chain_length": format_number(stats["min"]),
                        "p50_chain_length": format_number(stats["p50"]),
                        "p95_chain_length": format_number(stats["p95"]),
                        "max_chain_length": format_number(stats["max"]),
                    }
                )
                outputs["chain_length_over_time"].append(row)

            retry_stats = describe(pooled_retries)
            retried = sum(value > 0 for value in pooled_retries)
            row = metadata(config, columns)
            row.update(
                {
                    "repetitions": str(len(entries)),
                    "total_updates": str(retry_stats["n"]),
                    "mean_retries": format_number(retry_stats["mean"]),
                    "stddev_retries": format_number(retry_stats["stddev"]),
                    "min_retries": format_number(retry_stats["min"]),
                    "p50_retries": format_number(retry_stats["p50"]),
                    "p95_retries": format_number(retry_stats["p95"]),
                    "max_retries": format_number(retry_stats["max"]),
                    "updates_with_retries": str(retried),
                    "updates_with_retries_percentage": format_number(
                        retried * 100.0 / len(pooled_retries)
                    ),
                }
            )
            outputs["lock_retry_summary"].append(row)

    return outputs


def output_columns(benchmark: str) -> dict[str, tuple[str, ...]]:
    config = config_columns(benchmark)
    return {
        "per_run_throughput": config + (
            "run_id", "repetition", "workload_seed", "operation",
            "operation_count", "throughput_ops_s",
        ),
        "per_run_latency": config + (
            "run_id", "repetition", "operation", "metric", "sample_count",
            "mean_ms", "stddev_ms", "min_ms", "p50_ms", "p95_ms", "max_ms",
        ),
        "throughput_summary": config + (
            "operation", "repetitions", "total_operations", "mean_ops_s",
            "median_ops_s", "stddev_ops_s", "min_ops_s", "max_ops_s",
        ),
        "latency_pooled": config + (
            "operation", "metric", "repetitions", "sample_count", "mean_ms",
            "stddev_ms", "min_ms", "p50_ms", "p95_ms", "max_ms",
        ),
        "latency_summary": config + (
            "operation", "metric", "repetitions", "mean_latency_ms",
            "mean_latency_stddev_ms", "p50_mean_ms", "p50_stddev_ms",
            "p95_mean_ms", "p95_stddev_ms",
        ),
        "chain_length_over_time": config + (
            "time_bucket", "repetitions", "sample_count", "mean_chain_length",
            "stddev_chain_length", "min_chain_length", "p50_chain_length",
            "p95_chain_length", "max_chain_length",
        ),
        "lock_retry_summary": config + (
            "repetitions", "total_updates", "mean_retries", "stddev_retries",
            "min_retries", "p50_retries", "p95_retries", "max_retries",
            "updates_with_retries", "updates_with_retries_percentage",
        ),
    }


def write_outputs(output_dir: Path, outputs: dict[str, list[dict[str, str]]], benchmark: str) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    columns = output_columns(benchmark)
    for name, rows in outputs.items():
        if not rows:
            continue
        output_path = output_dir / f"{name}.tsv"
        with output_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, delimiter="\t", fieldnames=columns[name])
            writer.writeheader()
            writer.writerows(rows)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    manifest_path = Path(args.manifest).resolve()
    output_dir = Path(args.output_dir).resolve()
    try:
        manifest = read_manifest(manifest_path, args.benchmark)
        groups = group_manifest_rows(manifest, args.benchmark, args.expected_repetitions)
        outputs = summarize(groups, args.benchmark)
        write_outputs(output_dir, outputs, args.benchmark)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(
        f"Summarized {len(manifest)} runs across {len(groups)} configurations into {output_dir}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
