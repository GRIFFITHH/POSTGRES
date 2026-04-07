#!/usr/bin/env python3
"""
Merge AS-IS scan CSV and TO-BE scan CSV into table_mapping.csv.

Input CSV format (both files):
  source_db,source_schema,source_table

Output CSV format:
  source_db,source_schema,source_table,target_db,target_schema,target_table,where_clause
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


@dataclass(frozen=True)
class Obj:
    db: str
    schema: str
    table: str


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Merge AS-IS and TO-BE scan results into mapping CSV.")
    p.add_argument("--asis", required=True, help="AS-IS scan CSV path")
    p.add_argument("--tobe", required=True, help="TO-BE scan CSV path")
    p.add_argument("--output", required=True, help="Output mapping CSV path")
    p.add_argument(
        "--join-key",
        choices=["table", "schema_table"],
        default="table",
        help="Matching rule between AS-IS and TO-BE",
    )
    p.add_argument("--unmatched-asis", help="Optional CSV output for unmatched AS-IS rows")
    p.add_argument("--unmatched-tobe", help="Optional CSV output for unmatched TO-BE rows")
    return p.parse_args()


def read_scan(path: Path) -> List[Obj]:
    with path.open(newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        if r.fieldnames is None:
            raise ValueError(f"CSV has no header: {path}")
        required = ["source_db", "source_schema", "source_table"]
        missing = [c for c in required if c not in r.fieldnames]
        if missing:
            raise ValueError(f"{path} missing columns: {', '.join(missing)}")
        out: List[Obj] = []
        for row in r:
            out.append(
                Obj(
                    db=row["source_db"].strip(),
                    schema=row["source_schema"].strip(),
                    table=row["source_table"].strip(),
                )
            )
        return out


def key_of(o: Obj, mode: str) -> Tuple[str, ...]:
    if mode == "schema_table":
        return (o.schema, o.table)
    return (o.table,)


def write_objs(path: Path, rows: List[Obj]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["source_db", "source_schema", "source_table"])
        for r in rows:
            w.writerow([r.db, r.schema, r.table])


def main() -> None:
    args = parse_args()
    asis_rows = read_scan(Path(args.asis))
    tobe_rows = read_scan(Path(args.tobe))

    tobe_idx: Dict[Tuple[str, ...], List[Obj]] = {}
    for t in tobe_rows:
        k = key_of(t, args.join_key)
        tobe_idx.setdefault(k, []).append(t)

    out_rows: List[List[str]] = []
    unmatched_asis: List[Obj] = []
    matched_tobe_ids: set[int] = set()

    for a in asis_rows:
        k = key_of(a, args.join_key)
        candidates = tobe_idx.get(k, [])
        if not candidates:
            unmatched_asis.append(a)
            continue
        t = candidates[0]
        matched_tobe_ids.add(id(t))
        out_rows.append([a.db, a.schema, a.table, t.db, t.schema, t.table, ""])

    unmatched_tobe = [t for t in tobe_rows if id(t) not in matched_tobe_ids]

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "source_db",
                "source_schema",
                "source_table",
                "target_db",
                "target_schema",
                "target_table",
                "where_clause",
            ]
        )
        w.writerows(out_rows)

    print(f"written: {out_path}")
    print(f"matched_rows: {len(out_rows)}")
    print(f"unmatched_asis: {len(unmatched_asis)}")
    print(f"unmatched_tobe: {len(unmatched_tobe)}")

    if args.unmatched_asis:
        write_objs(Path(args.unmatched_asis), unmatched_asis)
        print(f"written: {args.unmatched_asis}")
    if args.unmatched_tobe:
        write_objs(Path(args.unmatched_tobe), unmatched_tobe)
        print(f"written: {args.unmatched_tobe}")


if __name__ == "__main__":
    main()
