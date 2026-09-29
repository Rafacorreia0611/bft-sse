#!/usr/bin/env python3

"""Generate single-keyword update workloads for the update latency benchmark."""

from __future__ import annotations

import argparse
import json
import random
import secrets
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


DEFAULT_SEED = 42
ROOT_DIR = Path(__file__).resolve().parents[3]


@dataclass(frozen=True)
class WorkloadConfig:
    output_path: Path
    vocabulary_path: Path
    base_dataset_path: Path
    warmup_count: int
    measurement_count: int
    doc_count: int
    configured_seed: str
    effective_seed: int

    @property
    def entry_count(self) -> int:
        return self.warmup_count + self.measurement_count


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate one single-keyword ADD workload entry per NDJSON line.",
    )
    parser.add_argument("--output", required=True, help="Generated NDJSON path.")
    parser.add_argument("--vocabulary", required=True, help="Protocol vocabulary path.")
    parser.add_argument(
        "--base-dataset",
        required=True,
        help="Base database NDJSON whose keywords must not be selected.",
    )
    parser.add_argument(
        "--warmup-count",
        required=True,
        type=parse_non_negative_int,
        help="Number of unmeasured update entries.",
    )
    parser.add_argument(
        "--measurement-count",
        required=True,
        type=parse_positive_int,
        help="Number of measured update entries.",
    )
    parser.add_argument(
        "--doc-count",
        required=True,
        type=parse_positive_int,
        help="Document IDs added by every warm-up and measured update.",
    )
    parser.add_argument(
        "--seed",
        default=str(DEFAULT_SEED),
        help=f"Integer seed for reproducible keyword sampling, or 'random'. Default: {DEFAULT_SEED}.",
    )
    return parser.parse_args(argv)


def parse_non_negative_int(raw_value: str) -> int:
    value = parse_int(raw_value)
    if value < 0:
        raise argparse.ArgumentTypeError("must be 0 or greater")
    return value


def parse_positive_int(raw_value: str) -> int:
    value = parse_int(raw_value)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return value


def parse_int(raw_value: str) -> int:
    try:
        return int(raw_value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"must be a valid integer: {raw_value}") from exc


def build_config(args: argparse.Namespace) -> WorkloadConfig:
    configured_seed = args.seed.strip()
    config = WorkloadConfig(
        output_path=Path(args.output),
        vocabulary_path=Path(args.vocabulary).resolve(),
        base_dataset_path=Path(args.base_dataset).resolve(),
        warmup_count=args.warmup_count,
        measurement_count=args.measurement_count,
        doc_count=args.doc_count,
        configured_seed=configured_seed,
        effective_seed=resolve_seed(configured_seed),
    )
    validate_config(config)
    return config


def resolve_seed(configured_seed: str) -> int:
    if configured_seed == "random":
        return secrets.randbits(63)
    try:
        return int(configured_seed)
    except ValueError as exc:
        raise ValueError("seed must be an integer or 'random'") from exc


def validate_config(config: WorkloadConfig) -> None:
    if config.output_path.exists() and config.output_path.is_dir():
        raise ValueError(f"Output path is a directory: {config.output_path}")
    if not config.vocabulary_path.is_file():
        raise ValueError(f"Vocabulary file does not exist: {config.vocabulary_path}")
    if not config.base_dataset_path.is_file():
        raise ValueError(f"Base dataset does not exist: {config.base_dataset_path}")
    if config.measurement_count % 2 == 0:
        raise ValueError("measurement-count must be odd")


def generate_workload(config: WorkloadConfig) -> None:
    random_generator = random.Random(config.effective_seed)
    base_keywords = load_base_keywords(config.base_dataset_path)
    available_keywords = [
        keyword
        for keyword in load_usable_vocabulary(config.vocabulary_path)
        if keyword not in base_keywords
    ]
    if config.entry_count > len(available_keywords):
        raise ValueError(
            "Not enough unused vocabulary keywords: "
            f"need {config.entry_count}, found {len(available_keywords)}"
        )

    keywords = random_generator.sample(available_keywords, config.entry_count)
    doc_id_width = max(8, len(str(config.doc_count)))

    config.output_path.parent.mkdir(parents=True, exist_ok=True)
    with config.output_path.open("w", encoding="utf-8", newline="\n") as handle:
        for entry_index, keyword in enumerate(keywords, start=1):
            doc_ids = [
                format_doc_id(entry_index, doc_index, doc_id_width)
                for doc_index in range(1, config.doc_count + 1)
            ]
            entry = {"keyword": keyword, "docIds": doc_ids}
            handle.write(json.dumps(entry, separators=(",", ":")))
            handle.write("\n")

    validate_workload(config, set(keywords), base_keywords)


def validate_workload(
    config: WorkloadConfig,
    expected_keywords: set[str],
    base_keywords: set[str],
) -> None:
    entries: list[dict[str, object]] = []
    with config.output_path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"Generated invalid JSON at line {line_number}") from exc
            if not isinstance(entry, dict):
                raise RuntimeError(f"Generated invalid entry at line {line_number}")
            entries.append(entry)

    if len(entries) != config.entry_count:
        raise RuntimeError(f"Generated {len(entries)} entries, expected {config.entry_count}")

    generated_keywords: set[str] = set()
    for line_number, entry in enumerate(entries, start=1):
        keyword = entry.get("keyword")
        doc_ids = entry.get("docIds")
        if not isinstance(keyword, str) or not keyword:
            raise RuntimeError(f"Generated invalid keyword at line {line_number}")
        if keyword in base_keywords:
            raise RuntimeError(f"Generated base-dataset keyword at line {line_number}: {keyword}")
        if keyword in generated_keywords:
            raise RuntimeError(f"Generated duplicate keyword at line {line_number}: {keyword}")
        generated_keywords.add(keyword)
        if not isinstance(doc_ids, list) or len(doc_ids) != config.doc_count:
            raise RuntimeError(f"Generated invalid document count at line {line_number}")
        if any(not isinstance(doc_id, str) or not doc_id for doc_id in doc_ids):
            raise RuntimeError(f"Generated invalid document ID at line {line_number}")
        if len(set(doc_ids)) != len(doc_ids):
            raise RuntimeError(f"Generated duplicate document IDs at line {line_number}")

    if generated_keywords != expected_keywords:
        raise RuntimeError("Generated keywords do not match the selected workload keywords")


def load_base_keywords(dataset_path: Path) -> set[str]:
    keywords: set[str] = set()
    with dataset_path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            normalized_line = line.strip()
            if not normalized_line:
                continue
            try:
                entry = json.loads(normalized_line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid base dataset JSON at line {line_number}") from exc

            keyword = entry.get("keyword") if isinstance(entry, dict) else None
            if not isinstance(keyword, str) or not keyword.strip():
                raise ValueError(f"Invalid base dataset keyword at line {line_number}")
            keywords.add(keyword.strip())
    if not keywords:
        raise ValueError(f"Base dataset has no keywords: {dataset_path}")
    return keywords


def load_usable_vocabulary(vocabulary_path: Path) -> list[str]:
    temp_path = create_temp_vocabulary_path()
    try:
        export_usable_vocabulary(vocabulary_path, temp_path)
        with temp_path.open("r", encoding="utf-8") as handle:
            keywords = [line.strip() for line in handle if line.strip()]
        if not keywords:
            raise ValueError(f"Vocabulary has no usable keywords: {vocabulary_path}")
        return keywords
    finally:
        temp_path.unlink(missing_ok=True)


def create_temp_vocabulary_path() -> Path:
    temp_file = tempfile.NamedTemporaryFile(
        prefix="bft-sse-update-vocabulary-",
        suffix=".txt",
        delete=False,
    )
    temp_path = Path(temp_file.name)
    temp_file.close()
    return temp_path


def export_usable_vocabulary(vocabulary_path: Path, output_path: Path) -> None:
    command = [
        str(ROOT_DIR / "gradlew"),
        "--quiet",
        "exportUsableVocabulary",
        f"-PvocabularyInput={vocabulary_path}",
        f"-PvocabularyOutput={output_path}",
    ]
    subprocess.run(command, cwd=ROOT_DIR, check=True)


def format_doc_id(entry_index: int, doc_index: int, doc_id_width: int) -> str:
    return f"update_{entry_index:03d}_doc_{doc_index:0{doc_id_width}d}"


def print_summary(config: WorkloadConfig) -> None:
    print("Generated update workload:")
    print(f"  output: {config.output_path}")
    print(f"  entries: {config.entry_count}")
    print(f"  warm-up entries: {config.warmup_count}")
    print(f"  measured entries: {config.measurement_count}")
    print(f"  document IDs per entry: {config.doc_count}")
    print(f"  configured seed: {config.configured_seed}")
    print(f"  effective seed: {config.effective_seed}")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        config = build_config(args)
        generate_workload(config)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print_summary(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
