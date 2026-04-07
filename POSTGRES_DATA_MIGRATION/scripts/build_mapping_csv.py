#!/usr/bin/env python3
"""
Build migration mapping CSV from a simpler table list CSV.

Input (required columns):
  source_db,source_schema,source_table

Output columns:
  source_db,source_schema,source_table,target_db,target_schema,target_table,where_clause
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import List


INPUT_COLUMNS = ["source_db", "source_schema", "source_table"]
OUTPUT_COLUMNS = [
    "source_db",
    "source_schema",
    "source_table",
    "target_db",
    "target_schema",
    "target_table",
    "where_clause",
]


@dataclass
class Row:
    source_db: str
    source_schema: str
    source_table: str


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Build table_mapping.csv from DB/Schema/Table list.")
    p.add_argument("--input", required=True, help="Input CSV (source_db,source_schema,source_table)")
    p.add_argument("--output", required=True, help="Output mapping CSV path")
    p.add_argument(
        "--target-db-mode",
        choices=["same", "empty"],
        default="same",
        help="same: copy source_db into target_db, empty: leave blank",
    )
    p.add_argument(
        "--target-schema-mode",
        choices=["same", "empty"],
        default="same",
        help="same: copy source_schema into target_schema, empty: leave blank",
    )
    p.add_argument(
        "--target-table-mode",
        choices=["same", "empty"],
        default="same",
        help="same: copy source_table into target_table, empty: leave blank",
    )
    return p.parse_args()


def read_rows(path: Path) -> List[Row]:
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("input CSV has no header")
        missing = [c for c in INPUT_COLUMNS if c not in reader.fieldnames]
        if missing:
            raise ValueError(f"input CSV missing columns: {', '.join(missing)}")

        rows: List[Row] = []
        for r in reader:
            rows.append(
                Row(
                    source_db=r["source_db"].strip(),
                    source_schema=r["source_schema"].strip(),
                    source_table=r["source_table"].strip(),
                )
            )
    if not rows:
        raise ValueError("input CSV has no rows")
    return rows


def pick(mode: str, value: str) -> str:
    return value if mode == "same" else ""


def main() -> None:
    args = parse_args()
    rows = read_rows(Path(args.input))
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)

    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        w.writeheader()
        for r in rows:
            w.writerow(
                {
                    "source_db": r.source_db,
                    "source_schema": r.source_schema,
                    "source_table": r.source_table,
                    "target_db": pick(args.target_db_mode, r.source_db),
                    "target_schema": pick(args.target_schema_mode, r.source_schema),
                    "target_table": pick(args.target_table_mode, r.source_table),
                    "where_clause": "",
                }
            )
    print(f"written: {out}")
    print(f"rows: {len(rows)}")


if __name__ == "__main__":
    main()
