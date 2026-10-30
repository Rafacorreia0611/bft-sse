#!/usr/bin/env python3

"""Merge raw concurrent benchmark samples produced by multiple client workers."""

from __future__ import annotations

import argparse
import csv
import os
import sys
import tempfile
from pathlib import Path
from typing import Sequence


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge per-worker raw sample CSV files into one benchmark sample CSV.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to the merged sample CSV.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Per-worker raw sample CSV files, in the order they should be written.",
    )
    return parser.parse_args(argv)


def validate_paths(input_paths: Sequence[Path], output_path: Path) -> None:
    resolved_output = output_path.resolve()
    for input_path in input_paths:
        if not input_path.is_file():
            raise FileNotFoundError(f"Input CSV not found: {input_path}")
        if input_path.resolve() == resolved_output:
            raise ValueError(f"Output path is also an input path: {output_path}")


def merge_samples(input_paths: Sequence[Path], output_path: Path) -> list[int]:
    validate_paths(input_paths, output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temporary_path: Path | None = None
    row_counts: list[int] = []
    expected_header: list[str] | None = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=output_path.parent,
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output_handle:
            temporary_path = Path(output_handle.name)
            writer = csv.writer(output_handle)

            for input_path in input_paths:
                with input_path.open("r", encoding="utf-8", newline="") as input_handle:
                    reader = csv.reader(input_handle)
                    try:
                        header = next(reader)
                    except StopIteration as exc:
                        raise ValueError(f"Input CSV has no header: {input_path}") from exc
                    if not header or not any(header):
                        raise ValueError(f"Input CSV has no header: {input_path}")

                    if expected_header is None:
                        expected_header = header
                        writer.writerow(header)
                    elif header != expected_header:
                        raise ValueError(f"Input CSV has a different header: {input_path}")

                    row_count = 0
                    for line_number, row in enumerate(reader, start=2):
                        if len(row) != len(expected_header):
                            raise ValueError(
                                f"{input_path}:{line_number} has {len(row)} columns; "
                                f"expected {len(expected_header)}"
                            )
                        writer.writerow(row)
                        row_count += 1
                    row_counts.append(row_count)

        os.replace(temporary_path, output_path)
    except Exception:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        raise

    return row_counts


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    input_paths = [Path(raw_path) for raw_path in args.inputs]
    output_path = Path(args.output)

    try:
        row_counts = merge_samples(input_paths, output_path)
    except (OSError, ValueError, csv.Error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print("Merged worker samples:")
    for input_path, row_count in zip(input_paths, row_counts):
        print(f"  {input_path}: {row_count} samples")
        if row_count == 0:
            print(f"Warning: {input_path} contains no samples", file=sys.stderr)
    print(f"  Total: {sum(row_counts)} samples")
    print(f"  Output: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
