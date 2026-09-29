#!/usr/bin/env python3

"""Generate synthetic keyword-to-docIds NDJSON datasets for SSE benchmarks."""

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
DEFAULT_VOCABULARY_PATH = ROOT_DIR / "datasets" / "vocabulary" / "vocabulary.txt"


@dataclass(frozen=True)
class SyntheticConfig:
    output_path: Path
    vocabulary_path: Path
    keywords_per_doc_count: int
    doc_counts: list[int]
    configured_seed: str
    effective_seed: int

    @property
    def keyword_count(self) -> int:
        return self.keywords_per_doc_count * len(self.doc_counts)

    @property
    def association_count(self) -> int:
        return self.keywords_per_doc_count * sum(self.doc_counts)

    @property
    def doc_universe_size(self) -> int:
        return max(self.doc_counts)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate an NDJSON synthetic dataset where each keyword has an exact "
            "number of associated docIds."
        ),
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to the generated NDJSON file.",
    )
    parser.add_argument(
        "--vocabulary",
        default=str(DEFAULT_VOCABULARY_PATH),
        help=f"Path to the protocol vocabulary file. Default: {DEFAULT_VOCABULARY_PATH}.",
    )
    parser.add_argument(
        "--keywords-per-doc-count",
        required=True,
        type=parse_positive_int,
        help="Number of keywords to generate for each configured doc count.",
    )
    parser.add_argument(
        "--doc-counts",
        required=True,
        type=parse_doc_counts,
        help="Comma-separated exact docId counts, for example: 10,100,1000,10000.",
    )
    parser.add_argument(
        "--seed",
        default=str(DEFAULT_SEED),
        help=f"Integer seed for reproducible generation, or 'random'. Default: {DEFAULT_SEED}.",
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


def parse_doc_counts(raw_value: str) -> list[int]:
    if raw_value is None or raw_value.strip() == "":
        raise argparse.ArgumentTypeError("doc counts cannot be empty")

    doc_counts: list[int] = []
    for raw_part in raw_value.split(","):
        part = raw_part.strip()
        if part == "":
            raise argparse.ArgumentTypeError("doc counts cannot contain empty values")
        doc_counts.append(parse_positive_int(part))

    if not doc_counts:
        raise argparse.ArgumentTypeError("at least one doc count is required")
    return doc_counts


def build_config(args: argparse.Namespace) -> SyntheticConfig:
    configured_seed = args.seed.strip()
    config = SyntheticConfig(
        output_path=Path(args.output),
        vocabulary_path=Path(args.vocabulary).resolve(),
        keywords_per_doc_count=args.keywords_per_doc_count,
        doc_counts=args.doc_counts,
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


def validate_config(config: SyntheticConfig) -> None:
    if config.output_path.exists() and config.output_path.is_dir():
        raise ValueError(f"Output path is a directory: {config.output_path}")
    if not config.vocabulary_path.exists() or not config.vocabulary_path.is_file():
        raise ValueError(f"Vocabulary file does not exist: {config.vocabulary_path}")
    if config.association_count <= 0:
        raise ValueError("Synthetic dataset must contain at least one keyword-docId association")


def generate_dataset(config: SyntheticConfig) -> None:
    random_generator = random.Random(config.effective_seed)
    keywords = sample_vocabulary_keywords(config, random_generator)
    doc_id_width = max(8, len(str(config.doc_universe_size)))
    doc_universe = [
        format_doc_id(doc_index, doc_id_width)
        for doc_index in range(1, config.doc_universe_size + 1)
    ]

    config.output_path.parent.mkdir(parents=True, exist_ok=True)
    keyword_offset = 0
    with config.output_path.open("w", encoding="utf-8", newline="\n") as handle:
        for doc_count in config.doc_counts:
            for _ in range(1, config.keywords_per_doc_count + 1):
                entry = {
                    "keyword": keywords[keyword_offset],
                    "docIds": random_generator.sample(doc_universe, doc_count),
                }
                handle.write(json.dumps(entry, separators=(",", ":")))
                handle.write("\n")
                keyword_offset += 1


def sample_vocabulary_keywords(config: SyntheticConfig, random_generator: random.Random) -> list[str]:
    vocabulary_keywords = load_usable_vocabulary(config.vocabulary_path)
    if config.keyword_count > len(vocabulary_keywords):
        raise ValueError(
            "Not enough usable vocabulary keywords: "
            f"need {config.keyword_count}, found {len(vocabulary_keywords)}"
        )
    return random_generator.sample(vocabulary_keywords, config.keyword_count)


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
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def create_temp_vocabulary_path() -> Path:
    temp_file = tempfile.NamedTemporaryFile(
        prefix="bft-sse-usable-vocabulary-",
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


def format_doc_id(doc_index: int, doc_id_width: int) -> str:
    return f"doc{doc_index:0{doc_id_width}d}"


def print_summary(config: SyntheticConfig) -> None:
    print("Generated synthetic dataset:")
    print(f"  output: {config.output_path}")
    print(f"  vocabulary: {config.vocabulary_path}")
    print(f"  keywords: {config.keyword_count}")
    print(f"  keyword-doc associations: {config.association_count}")
    print(f"  keywords per doc count: {config.keywords_per_doc_count}")
    print(f"  doc counts: {','.join(str(doc_count) for doc_count in config.doc_counts)}")
    print(f"  configured seed: {config.configured_seed}")
    print(f"  effective seed: {config.effective_seed}")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        config = build_config(args)
        generate_dataset(config)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print_summary(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
