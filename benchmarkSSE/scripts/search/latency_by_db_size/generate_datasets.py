#!/usr/bin/env python3

"""Generate exact datasets for the search-latency-by-database-size benchmark."""

from __future__ import annotations

import argparse
import itertools
import json
import os
import random
import secrets
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


DEFAULT_SEED = 42
MAX_JAVA_INT = 2_147_483_647
MAX_JAVA_LONG = 9_223_372_036_854_775_807
ROOT_DIR = Path(__file__).resolve().parents[4]
DEFAULT_VOCABULARY_PATH = ROOT_DIR / "datasets" / "vocabulary" / "vocabulary.txt"
DEFAULT_OUTPUT_DIR = (
    ROOT_DIR / "benchmarkSSE" / "datasets" / "search" / "latency_by_db_size"
)

Entry = dict[str, object]


@dataclass(frozen=True)
class GeneratorConfig:
    output_dir: Path
    vocabulary_path: Path
    db_sizes: tuple[int, ...]
    search_result_size: int
    warmup_count: int
    measurement_count: int
    filler_doc_count: int
    configured_seed: str
    effective_seed: int

    @property
    def target_keyword_count(self) -> int:
        return self.warmup_count + self.measurement_count

    @property
    def target_association_count(self) -> int:
        return self.target_keyword_count * self.search_result_size

    @property
    def benchmark_filename(self) -> str:
        return f"benchmark_queries_docs_{self.search_result_size}.ndjson"

    @property
    def benchmark_path(self) -> Path:
        return self.output_dir / self.benchmark_filename


@dataclass(frozen=True)
class DatabasePlan:
    db_size: int
    target_association_count: int
    filler_association_count: int
    full_filler_keyword_count: int
    remainder_doc_count: int

    @property
    def filler_keyword_count(self) -> int:
        return self.full_filler_keyword_count + (1 if self.remainder_doc_count else 0)

    @property
    def population_filename(self) -> str:
        return f"population_db_{self.db_size}.ndjson"

    def total_keyword_count(self, target_keyword_count: int) -> int:
        return target_keyword_count + self.filler_keyword_count


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate one shared fixed-result-size search workload and one exact "
            "population NDJSON file per configured database association count."
        ),
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help=f"Generated dataset directory. Default: {DEFAULT_OUTPUT_DIR}",
    )
    parser.add_argument(
        "--vocabulary",
        default=str(DEFAULT_VOCABULARY_PATH),
        help=f"Protocol vocabulary path. Default: {DEFAULT_VOCABULARY_PATH}",
    )
    parser.add_argument(
        "--db-sizes",
        required=True,
        type=parse_db_sizes,
        help=(
            "Strictly increasing comma-separated total keyword-document association "
            "counts, for example 100000,250000,500000."
        ),
    )
    parser.add_argument(
        "--search-result-size",
        required=True,
        type=parse_positive_java_int,
        help="Exact active document count and chain length of every searched keyword.",
    )
    parser.add_argument(
        "--warmup-count",
        required=True,
        type=parse_non_negative_java_int,
        help="Number of target keywords reserved for unmeasured warm-up searches.",
    )
    parser.add_argument(
        "--measurement-count",
        required=True,
        type=parse_positive_java_int,
        help="Number of distinct target keywords reserved for measured searches.",
    )
    parser.add_argument(
        "--filler-doc-count",
        required=True,
        type=parse_positive_java_int,
        help="Normal number of associations assigned to each unrelated filler keyword.",
    )
    parser.add_argument(
        "--seed",
        default=str(DEFAULT_SEED),
        help=f"Integer seed or 'random'. Default: {DEFAULT_SEED}.",
    )
    return parser.parse_args(argv)


def parse_integer(raw_value: str, label: str) -> int:
    try:
        return int(raw_value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{label} must be a valid integer: {raw_value}") from exc


def parse_positive_java_int(raw_value: str) -> int:
    value = parse_integer(raw_value, "value")
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    if value > MAX_JAVA_INT:
        raise argparse.ArgumentTypeError(f"must not exceed {MAX_JAVA_INT}")
    return value


def parse_non_negative_java_int(raw_value: str) -> int:
    value = parse_integer(raw_value, "value")
    if value < 0:
        raise argparse.ArgumentTypeError("must be 0 or greater")
    if value > MAX_JAVA_INT:
        raise argparse.ArgumentTypeError(f"must not exceed {MAX_JAVA_INT}")
    return value


def parse_db_sizes(raw_value: str) -> tuple[int, ...]:
    if raw_value is None or not raw_value.strip():
        raise argparse.ArgumentTypeError("database sizes cannot be empty")

    db_sizes: list[int] = []
    for raw_part in raw_value.split(","):
        part = raw_part.strip()
        if not part:
            raise argparse.ArgumentTypeError("database sizes cannot contain empty values")
        value = parse_integer(part, "database size")
        if value <= 0:
            raise argparse.ArgumentTypeError("database sizes must be greater than 0")
        if value > MAX_JAVA_LONG:
            raise argparse.ArgumentTypeError(
                f"database sizes must not exceed {MAX_JAVA_LONG}"
            )
        db_sizes.append(value)

    if len(set(db_sizes)) != len(db_sizes):
        raise argparse.ArgumentTypeError("database sizes cannot contain duplicates")
    if any(current <= previous for previous, current in zip(db_sizes, db_sizes[1:])):
        raise argparse.ArgumentTypeError("database sizes must be strictly increasing")
    return tuple(db_sizes)


def build_config(args: argparse.Namespace) -> GeneratorConfig:
    configured_seed = args.seed.strip()
    config = GeneratorConfig(
        output_dir=Path(args.output_dir).resolve(),
        vocabulary_path=Path(args.vocabulary).resolve(),
        db_sizes=args.db_sizes,
        search_result_size=args.search_result_size,
        warmup_count=args.warmup_count,
        measurement_count=args.measurement_count,
        filler_doc_count=args.filler_doc_count,
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


def validate_config(config: GeneratorConfig) -> None:
    if config.output_dir.exists() and not config.output_dir.is_dir():
        raise ValueError(f"Output directory path is not a directory: {config.output_dir}")
    if not config.vocabulary_path.is_file():
        raise ValueError(f"Vocabulary file does not exist: {config.vocabulary_path}")
    if not os.access(config.vocabulary_path, os.R_OK):
        raise ValueError(f"Vocabulary file is not readable: {config.vocabulary_path}")
    if config.target_keyword_count > MAX_JAVA_INT:
        raise ValueError(f"Total target keyword count must not exceed {MAX_JAVA_INT}")
    if config.target_association_count > MAX_JAVA_LONG:
        raise ValueError(f"Target association count must not exceed {MAX_JAVA_LONG}")
    for db_size in config.db_sizes:
        if db_size < config.target_association_count:
            raise ValueError(
                f"Database size {db_size} is smaller than the "
                f"{config.target_association_count} associations required by "
                f"{config.target_keyword_count} search targets"
            )


def build_database_plans(config: GeneratorConfig) -> tuple[DatabasePlan, ...]:
    plans: list[DatabasePlan] = []
    for db_size in config.db_sizes:
        filler_association_count = db_size - config.target_association_count
        full_filler_keyword_count, remainder_doc_count = divmod(
            filler_association_count,
            config.filler_doc_count,
        )
        plans.append(
            DatabasePlan(
                db_size=db_size,
                target_association_count=config.target_association_count,
                filler_association_count=filler_association_count,
                full_filler_keyword_count=full_filler_keyword_count,
                remainder_doc_count=remainder_doc_count,
            )
        )
    return tuple(plans)


def load_usable_vocabulary(vocabulary_path: Path) -> list[str]:
    temp_path = create_temp_vocabulary_path()
    try:
        export_usable_vocabulary(vocabulary_path, temp_path)
        with temp_path.open("r", encoding="utf-8") as handle:
            keywords = [line.strip() for line in handle if line.strip()]
    finally:
        temp_path.unlink(missing_ok=True)

    if not keywords:
        raise ValueError(f"Vocabulary has no usable keywords: {vocabulary_path}")
    if len(set(keywords)) != len(keywords):
        raise ValueError("Exported usable vocabulary contains duplicate raw keywords")
    return keywords


def create_temp_vocabulary_path() -> Path:
    temp_file = tempfile.NamedTemporaryFile(
        prefix="bft-sse-db-size-vocabulary-",
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


def select_keywords(
    vocabulary_keywords: Sequence[str],
    target_keyword_count: int,
    filler_keyword_count: int,
    effective_seed: int,
) -> tuple[list[str], list[str]]:
    required_keyword_count = target_keyword_count + filler_keyword_count
    if required_keyword_count > len(vocabulary_keywords):
        raise ValueError(
            "Not enough usable vocabulary keywords: "
            f"need {required_keyword_count}, found {len(vocabulary_keywords)}"
        )

    # Shuffle the complete vocabulary so the target prefix depends only on the
    # seed, not on the largest requested database size.
    selected_keywords = list(vocabulary_keywords)
    random_generator = random.Random(effective_seed)
    random_generator.shuffle(selected_keywords)
    selected_keywords = selected_keywords[:required_keyword_count]
    return (
        selected_keywords[:target_keyword_count],
        selected_keywords[target_keyword_count:],
    )


def build_target_entries(config: GeneratorConfig, target_keywords: Sequence[str]) -> list[Entry]:
    doc_id_width = max(8, len(str(config.search_result_size)))
    entries: list[Entry] = []
    for target_index, keyword in enumerate(target_keywords, start=1):
        entries.append(
            {
                "keyword": keyword,
                "docIds": [
                    f"target_{target_index:04d}_doc_{doc_index:0{doc_id_width}d}"
                    for doc_index in range(1, config.search_result_size + 1)
                ],
            }
        )
    return entries


def build_filler_entry(
    keyword: str,
    filler_index: int,
    doc_count: int,
    doc_id_width: int,
    filler_index_width: int,
) -> Entry:
    return {
        "keyword": keyword,
        "docIds": [
            f"filler_{filler_index:0{filler_index_width}d}_doc_{doc_index:0{doc_id_width}d}"
            for doc_index in range(1, doc_count + 1)
        ],
    }


def iter_filler_entries(
    config: GeneratorConfig,
    plan: DatabasePlan,
    filler_keywords: Sequence[str],
    max_filler_keyword_count: int,
) -> Iterator[Entry]:
    doc_id_width = max(8, len(str(config.filler_doc_count)))
    filler_index_width = max(6, len(str(max_filler_keyword_count)))

    for zero_based_index in range(plan.full_filler_keyword_count):
        yield build_filler_entry(
            keyword=filler_keywords[zero_based_index],
            filler_index=zero_based_index + 1,
            doc_count=config.filler_doc_count,
            doc_id_width=doc_id_width,
            filler_index_width=filler_index_width,
        )

    if plan.remainder_doc_count:
        zero_based_index = plan.full_filler_keyword_count
        yield build_filler_entry(
            keyword=filler_keywords[zero_based_index],
            filler_index=zero_based_index + 1,
            doc_count=plan.remainder_doc_count,
            doc_id_width=doc_id_width,
            filler_index_width=filler_index_width,
        )


def write_entries_atomically(output_path: Path, entries: Iterable[Entry]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_file = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        dir=output_path.parent,
        delete=False,
    )
    temporary_path = Path(temporary_file.name)
    try:
        with temporary_file:
            for entry in entries:
                temporary_file.write(json.dumps(entry, separators=(",", ":")))
                temporary_file.write("\n")
        temporary_path.replace(output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def parse_generated_entry(line: str, input_path: Path, line_number: int) -> Entry:
    if not line.strip():
        raise ValueError(f"Generated blank line in {input_path} at line {line_number}")
    try:
        parsed = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Generated invalid JSON in {input_path} at line {line_number}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"Generated non-object entry in {input_path} at line {line_number}")
    if set(parsed) != {"keyword", "docIds"}:
        raise ValueError(
            f"Generated entry has unexpected fields in {input_path} at line {line_number}"
        )

    keyword = parsed.get("keyword")
    doc_ids = parsed.get("docIds")
    if not isinstance(keyword, str) or not keyword or keyword != keyword.strip():
        raise ValueError(f"Generated invalid keyword in {input_path} at line {line_number}")
    if not isinstance(doc_ids, list) or not doc_ids:
        raise ValueError(f"Generated invalid docIds in {input_path} at line {line_number}")
    if any(not isinstance(doc_id, str) or not doc_id for doc_id in doc_ids):
        raise ValueError(f"Generated invalid document ID in {input_path} at line {line_number}")
    if len(set(doc_ids)) != len(doc_ids):
        raise ValueError(f"Generated duplicate document IDs in {input_path} at line {line_number}")
    return parsed


def validate_exact_entries(
    input_path: Path,
    expected_entries: Iterable[Entry],
    expected_association_count: int,
) -> int:
    seen_keywords: set[str] = set()
    actual_association_count = 0
    expected_line_count = 0

    with input_path.open("r", encoding="utf-8") as handle:
        for expected_line_count, expected_entry in enumerate(expected_entries, start=1):
            line = handle.readline()
            if line == "":
                raise ValueError(
                    f"Generated file ended early: {input_path} has fewer than "
                    f"{expected_line_count} entries"
                )
            actual_entry = parse_generated_entry(line, input_path, expected_line_count)
            if actual_entry != expected_entry:
                raise ValueError(
                    f"Generated entry differs from its plan in {input_path} "
                    f"at line {expected_line_count}"
                )

            keyword = actual_entry["keyword"]
            if not isinstance(keyword, str):  # Narrow the type for static readers.
                raise AssertionError("Validated keyword is not a string")
            if keyword in seen_keywords:
                raise ValueError(
                    f"Generated duplicate keyword in {input_path} at line {expected_line_count}: "
                    f"{keyword}"
                )
            seen_keywords.add(keyword)
            doc_ids = actual_entry["docIds"]
            if not isinstance(doc_ids, list):
                raise AssertionError("Validated docIds is not a list")
            actual_association_count += len(doc_ids)

        extra_line = handle.readline()
        if extra_line != "":
            raise ValueError(
                f"Generated file contains more than {expected_line_count} entries: {input_path}"
            )

    if expected_line_count == 0:
        raise ValueError(f"Generated file contains no entries: {input_path}")
    if actual_association_count != expected_association_count:
        raise ValueError(
            f"Generated {actual_association_count} associations in {input_path}, "
            f"expected {expected_association_count}"
        )
    return expected_line_count


def generate_datasets(config: GeneratorConfig) -> tuple[DatabasePlan, ...]:
    plans = build_database_plans(config)
    max_filler_keyword_count = max(plan.filler_keyword_count for plan in plans)
    vocabulary_keywords = load_usable_vocabulary(config.vocabulary_path)
    target_keywords, filler_keywords = select_keywords(
        vocabulary_keywords=vocabulary_keywords,
        target_keyword_count=config.target_keyword_count,
        filler_keyword_count=max_filler_keyword_count,
        effective_seed=config.effective_seed,
    )
    target_entries = build_target_entries(config, target_keywords)

    write_entries_atomically(config.benchmark_path, iter(target_entries))
    benchmark_line_count = validate_exact_entries(
        config.benchmark_path,
        iter(target_entries),
        config.target_association_count,
    )
    if benchmark_line_count != config.target_keyword_count:
        raise ValueError(
            f"Generated benchmark input has {benchmark_line_count} entries, "
            f"expected {config.target_keyword_count}"
        )

    for plan in plans:
        population_path = config.output_dir / plan.population_filename
        expected_population_entries = lambda: itertools.chain(
            target_entries,
            iter_filler_entries(
                config,
                plan,
                filler_keywords,
                max_filler_keyword_count,
            ),
        )
        write_entries_atomically(population_path, expected_population_entries())
        population_line_count = validate_exact_entries(
            population_path,
            expected_population_entries(),
            plan.db_size,
        )
        expected_line_count = plan.total_keyword_count(config.target_keyword_count)
        if population_line_count != expected_line_count:
            raise ValueError(
                f"Generated population file {population_path} has "
                f"{population_line_count} entries, expected {expected_line_count}"
            )

    return plans


def print_summary(config: GeneratorConfig, plans: Sequence[DatabasePlan]) -> None:
    print("Generated search-latency-by-database-size datasets:")
    print(f"  output directory: {config.output_dir}")
    print(f"  vocabulary: {config.vocabulary_path}")
    print(f"  benchmark input: {config.benchmark_filename}")
    print(f"  configured seed: {config.configured_seed}")
    print(f"  effective seed: {config.effective_seed}")
    print(f"  warm-up targets: {config.warmup_count}")
    print(f"  measured targets: {config.measurement_count}")
    print(f"  target keywords: {config.target_keyword_count}")
    print(f"  search result size: {config.search_result_size}")
    print(f"  target associations: {config.target_association_count}")
    print(f"  filler documents per keyword: {config.filler_doc_count}")
    print()
    print("  DB size | keywords | full fillers | remainder")
    for plan in plans:
        print(
            f"  {plan.db_size:>7} | "
            f"{plan.total_keyword_count(config.target_keyword_count):>8} | "
            f"{plan.full_filler_keyword_count:>12} | "
            f"{plan.remainder_doc_count:>9}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        config = build_config(args)
        plans = generate_datasets(config)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print_summary(config, plans)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
