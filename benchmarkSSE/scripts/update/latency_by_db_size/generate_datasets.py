#!/usr/bin/env python3

"""Generate exact datasets for the update-latency-by-database-size benchmark."""

from __future__ import annotations

import argparse
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
    ROOT_DIR / "benchmarkSSE" / "datasets" / "update" / "latency_by_db_size"
)

Entry = dict[str, object]


@dataclass(frozen=True)
class GeneratorConfig:
    output_dir: Path
    vocabulary_path: Path
    db_sizes: tuple[int, ...]
    update_doc_count: int
    warmup_count: int
    measurement_count: int
    filler_doc_count: int
    configured_seed: str
    effective_seed: int

    @property
    def workload_entry_count(self) -> int:
        return self.warmup_count + self.measurement_count

    @property
    def measurements_before_middle(self) -> int:
        return self.measurement_count // 2

    @property
    def updates_before_middle(self) -> int:
        return self.warmup_count + self.measurements_before_middle

    @property
    def workload_association_count(self) -> int:
        return self.workload_entry_count * self.update_doc_count

    @property
    def workload_filename(self) -> str:
        return f"benchmark_updates_docs_{self.update_doc_count}.ndjson"

    @property
    def workload_path(self) -> Path:
        return self.output_dir / self.workload_filename


@dataclass(frozen=True)
class DatabasePlan:
    target_db_size: int
    initial_db_size: int
    min_measured_db_size: int
    max_measured_db_size: int
    final_db_size: int
    full_filler_keyword_count: int
    remainder_doc_count: int

    @property
    def filler_keyword_count(self) -> int:
        return self.full_filler_keyword_count + (1 if self.remainder_doc_count else 0)

    @property
    def population_filename(self) -> str:
        return f"population_db_{self.target_db_size}.ndjson"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate one shared fixed-update-size workload and one exact initial "
            "population NDJSON file per target database association count."
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
            "Strictly increasing comma-separated target database association "
            "counts, for example 100000,250000,500000."
        ),
    )
    parser.add_argument(
        "--update-doc-count",
        required=True,
        type=parse_positive_java_int,
        help="Exact number of document associations added by every update.",
    )
    parser.add_argument(
        "--warmup-count",
        required=True,
        type=parse_non_negative_java_int,
        help="Number of unmeasured updates executed before the measured updates.",
    )
    parser.add_argument(
        "--measurement-count",
        required=True,
        type=parse_positive_java_int,
        help="Positive odd number of measured updates around each target DB size.",
    )
    parser.add_argument(
        "--filler-doc-count",
        required=True,
        type=parse_positive_java_int,
        help="Normal number of associations assigned to each population keyword.",
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
        update_doc_count=args.update_doc_count,
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
    if config.measurement_count % 2 == 0:
        raise ValueError("measurement-count must be odd")
    if config.workload_entry_count > MAX_JAVA_INT:
        raise ValueError(f"Total workload entry count must not exceed {MAX_JAVA_INT}")
    if config.workload_association_count > MAX_JAVA_LONG:
        raise ValueError(f"Total workload association count must not exceed {MAX_JAVA_LONG}")

    initial_offset = config.updates_before_middle * config.update_doc_count
    final_offset = (config.measurements_before_middle + 1) * config.update_doc_count
    for target_db_size in config.db_sizes:
        if target_db_size <= initial_offset:
            raise ValueError(
                f"Database size {target_db_size} is too small: it must be greater "
                f"than the {initial_offset} associations added before the middle measurement"
            )
        if target_db_size + final_offset > MAX_JAVA_LONG:
            raise ValueError(
                f"Database size {target_db_size} would exceed {MAX_JAVA_LONG} "
                "after the configured measured updates"
            )


def build_database_plans(config: GeneratorConfig) -> tuple[DatabasePlan, ...]:
    plans: list[DatabasePlan] = []
    before_middle = config.updates_before_middle * config.update_doc_count
    measured_half_width = config.measurements_before_middle * config.update_doc_count
    final_growth = (config.measurements_before_middle + 1) * config.update_doc_count

    for target_db_size in config.db_sizes:
        initial_db_size = target_db_size - before_middle
        full_filler_keyword_count, remainder_doc_count = divmod(
            initial_db_size,
            config.filler_doc_count,
        )
        plans.append(
            DatabasePlan(
                target_db_size=target_db_size,
                initial_db_size=initial_db_size,
                min_measured_db_size=target_db_size - measured_half_width,
                max_measured_db_size=target_db_size + measured_half_width,
                final_db_size=target_db_size + final_growth,
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
        prefix="bft-sse-update-db-size-vocabulary-",
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
    workload_keyword_count: int,
    filler_keyword_count: int,
    effective_seed: int,
) -> tuple[list[str], list[str]]:
    required_keyword_count = workload_keyword_count + filler_keyword_count
    if required_keyword_count > len(vocabulary_keywords):
        raise ValueError(
            "Not enough usable vocabulary keywords: "
            f"need {required_keyword_count}, found {len(vocabulary_keywords)}"
        )

    # The workload prefix depends only on the seed, not on the largest DB size.
    selected_keywords = list(vocabulary_keywords)
    random_generator = random.Random(effective_seed)
    random_generator.shuffle(selected_keywords)
    selected_keywords = selected_keywords[:required_keyword_count]
    return (
        selected_keywords[:workload_keyword_count],
        selected_keywords[workload_keyword_count:],
    )


def build_workload_entries(
    config: GeneratorConfig,
    workload_keywords: Sequence[str],
) -> list[Entry]:
    entry_index_width = max(3, len(str(config.workload_entry_count)))
    doc_id_width = max(8, len(str(config.update_doc_count)))
    entries: list[Entry] = []
    for entry_index, keyword in enumerate(workload_keywords, start=1):
        entries.append(
            {
                "keyword": keyword,
                "docIds": [
                    f"update_{entry_index:0{entry_index_width}d}_doc_"
                    f"{doc_index:0{doc_id_width}d}"
                    for doc_index in range(1, config.update_doc_count + 1)
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
            f"filler_{filler_index:0{filler_index_width}d}_doc_"
            f"{doc_index:0{doc_id_width}d}"
            for doc_index in range(1, doc_count + 1)
        ],
    }


def iter_population_entries(
    config: GeneratorConfig,
    plan: DatabasePlan,
    filler_keywords: Sequence[str],
    filler_index_width: int,
) -> Iterator[Entry]:
    doc_id_width = max(8, len(str(config.filler_doc_count)))

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
    forbidden_keywords: set[str] | None = None,
) -> tuple[int, set[str], set[str]]:
    seen_keywords: set[str] = set()
    seen_doc_ids: set[str] = set()
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
            doc_ids = actual_entry["docIds"]
            if not isinstance(keyword, str) or not isinstance(doc_ids, list):
                raise AssertionError("Validated entry has unexpected types")
            if keyword in seen_keywords:
                raise ValueError(
                    f"Generated duplicate keyword in {input_path} at line "
                    f"{expected_line_count}: {keyword}"
                )
            if forbidden_keywords is not None and keyword in forbidden_keywords:
                raise ValueError(
                    f"Generated forbidden keyword in {input_path} at line "
                    f"{expected_line_count}: {keyword}"
                )
            seen_keywords.add(keyword)
            for doc_id in doc_ids:
                if not isinstance(doc_id, str):
                    raise AssertionError("Validated document ID is not a string")
                if doc_id in seen_doc_ids:
                    raise ValueError(
                        f"Generated duplicate document ID across entries in {input_path}: {doc_id}"
                    )
                seen_doc_ids.add(doc_id)
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
    return expected_line_count, seen_keywords, seen_doc_ids


def validate_nested_populations(smaller_path: Path, larger_path: Path) -> None:
    with (
        smaller_path.open("r", encoding="utf-8") as smaller_handle,
        larger_path.open("r", encoding="utf-8") as larger_handle,
    ):
        line_number = 0
        while True:
            smaller_line = smaller_handle.readline()
            if smaller_line == "":
                break
            line_number += 1
            larger_line = larger_handle.readline()
            if larger_line == "":
                raise ValueError(
                    f"Larger population {larger_path} ended before {smaller_path}"
                )

            smaller_entry = parse_generated_entry(smaller_line, smaller_path, line_number)
            larger_entry = parse_generated_entry(larger_line, larger_path, line_number)
            if smaller_entry["keyword"] != larger_entry["keyword"]:
                raise ValueError(
                    f"Population keyword nesting differs at line {line_number}: "
                    f"{smaller_path} and {larger_path}"
                )
            smaller_doc_ids = smaller_entry["docIds"]
            larger_doc_ids = larger_entry["docIds"]
            if not isinstance(smaller_doc_ids, list) or not isinstance(larger_doc_ids, list):
                raise AssertionError("Validated docIds are not lists")
            if smaller_doc_ids != larger_doc_ids[: len(smaller_doc_ids)]:
                raise ValueError(
                    f"Population associations are not nested at line {line_number}: "
                    f"{smaller_path} and {larger_path}"
                )
            if len(smaller_doc_ids) < len(larger_doc_ids):
                if smaller_handle.readline() != "":
                    raise ValueError(
                        f"Partial final keyword is not last in smaller population {smaller_path}"
                    )
                break


def generate_datasets(config: GeneratorConfig) -> tuple[DatabasePlan, ...]:
    plans = build_database_plans(config)
    max_filler_keyword_count = max(plan.filler_keyword_count for plan in plans)
    vocabulary_keywords = load_usable_vocabulary(config.vocabulary_path)
    workload_keywords, filler_keywords = select_keywords(
        vocabulary_keywords=vocabulary_keywords,
        workload_keyword_count=config.workload_entry_count,
        filler_keyword_count=max_filler_keyword_count,
        effective_seed=config.effective_seed,
    )
    filler_index_width = max(8, len(str(len(vocabulary_keywords))))
    workload_entries = build_workload_entries(config, workload_keywords)

    write_entries_atomically(config.workload_path, iter(workload_entries))
    workload_line_count, workload_keyword_set, workload_doc_ids = validate_exact_entries(
        config.workload_path,
        iter(workload_entries),
        config.workload_association_count,
    )
    if workload_line_count != config.workload_entry_count:
        raise ValueError(
            f"Generated workload has {workload_line_count} entries, "
            f"expected {config.workload_entry_count}"
        )

    population_paths: list[Path] = []
    for plan in plans:
        population_path = config.output_dir / plan.population_filename

        def expected_population_entries() -> Iterator[Entry]:
            return iter_population_entries(
                config,
                plan,
                filler_keywords,
                filler_index_width,
            )

        write_entries_atomically(population_path, expected_population_entries())
        population_line_count, _, population_doc_ids = validate_exact_entries(
            population_path,
            expected_population_entries(),
            plan.initial_db_size,
            forbidden_keywords=workload_keyword_set,
        )
        if population_line_count != plan.filler_keyword_count:
            raise ValueError(
                f"Generated population {population_path} has {population_line_count} entries, "
                f"expected {plan.filler_keyword_count}"
            )
        if workload_doc_ids.intersection(population_doc_ids):
            raise ValueError(
                f"Generated workload and population document IDs overlap: {population_path}"
            )
        population_paths.append(population_path)

    for smaller_path, larger_path in zip(population_paths, population_paths[1:]):
        validate_nested_populations(smaller_path, larger_path)

    return plans


def print_summary(config: GeneratorConfig, plans: Sequence[DatabasePlan]) -> None:
    print("Generated update-latency-by-database-size datasets:")
    print(f"  output directory: {config.output_dir}")
    print(f"  vocabulary: {config.vocabulary_path}")
    print(f"  benchmark workload: {config.workload_filename}")
    print(f"  configured seed: {config.configured_seed}")
    print(f"  effective seed: {config.effective_seed}")
    print(f"  warm-up updates: {config.warmup_count}")
    print(f"  measured updates: {config.measurement_count}")
    print(f"  workload entries: {config.workload_entry_count}")
    print(f"  documents per update: {config.update_doc_count}")
    print(f"  filler documents per keyword: {config.filler_doc_count}")
    print()
    print("  Target DB | Initial DB | keywords | full fillers | remainder | measured range")
    for plan in plans:
        measured_range = f"{plan.min_measured_db_size}..{plan.max_measured_db_size}"
        print(
            f"  {plan.target_db_size:>9} | "
            f"{plan.initial_db_size:>10} | "
            f"{plan.filler_keyword_count:>8} | "
            f"{plan.full_filler_keyword_count:>12} | "
            f"{plan.remainder_doc_count:>9} | "
            f"{measured_range}"
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
