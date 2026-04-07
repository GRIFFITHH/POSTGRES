#!/usr/bin/env python3
r"""
Generate non-destructive PostgreSQL migration command scripts.

Rules:
- Source side: read-only (\COPY ... TO STDOUT)
- Target side: insert-only (\COPY ... FROM STDIN)
- Never emits TRUNCATE/DELETE/ALTER/DROP
"""

from __future__ import annotations

import argparse
import csv
import os
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple


@dataclass(frozen=True)
class TableRef:
    db: str
    schema: str
    table: str

    @property
    def key(self) -> Tuple[str, str]:
        return (self.schema, self.table)


@dataclass(frozen=True)
class MappingRow:
    source_host: str
    source_port: str
    source_user: str
    source_db: str
    source_schema: str
    source_table: str
    target_host: str
    target_port: str
    target_user: str
    target_db: str
    target_schema: str
    target_table: str
    where_clause: str

    @property
    def source_ref(self) -> TableRef:
        return TableRef(self.source_db, self.source_schema, self.source_table)

    @property
    def target_ref(self) -> TableRef:
        return TableRef(self.target_db, self.target_schema, self.target_table)


REQUIRED_MAPPING_COLUMNS_FULL = [
    "source_host",
    "source_port",
    "source_user",
    "source_db",
    "source_schema",
    "source_table",
    "target_host",
    "target_port",
    "target_user",
    "target_db",
    "target_schema",
    "target_table",
    "where_clause",
]

REQUIRED_MAPPING_COLUMNS_MIN = [
    "source_db",
    "source_schema",
    "source_table",
    "target_db",
    "target_schema",
    "target_table",
]


@dataclass(frozen=True)
class EndpointConfig:
    host: str
    port: str
    user: str


@dataclass(frozen=True)
class MigrationConfig:
    asis: EndpointConfig
    tobe: EndpointConfig


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate PostgreSQL migration command scripts from mapping CSV."
    )
    parser.add_argument("--mapping", required=True, help="Path to table mapping CSV")
    parser.add_argument(
        "--fk-edges",
        required=False,
        help=(
            "Optional FK edge CSV path with columns: "
            "target_db,child_schema,child_table,parent_schema,parent_table"
        ),
    )
    parser.add_argument(
        "--config",
        required=False,
        help="Path to migration config env file (required for minimal mapping format)",
    )
    parser.add_argument("--out-dir", default="generated", help="Output directory")
    return parser.parse_args()


def qident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def fq(schema: str, table: str) -> str:
    return f"{qident(schema)}.{qident(table)}"


def shell_single_quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"


def load_env_config(path: Path) -> MigrationConfig:
    if not path.exists():
        raise ValueError(f"config file not found: {path}")

    values: Dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        values[key.strip()] = val.strip()

    required = ["ASIS_HOST", "ASIS_PORT", "ASIS_USER", "TOBE_HOST", "TOBE_PORT", "TOBE_USER"]
    missing = [k for k in required if not values.get(k)]
    if missing:
        raise ValueError(f"config missing required keys: {', '.join(missing)}")

    return MigrationConfig(
        asis=EndpointConfig(values["ASIS_HOST"], values["ASIS_PORT"], values["ASIS_USER"]),
        tobe=EndpointConfig(values["TOBE_HOST"], values["TOBE_PORT"], values["TOBE_USER"]),
    )


def read_mapping(path: Path, cfg: MigrationConfig | None) -> List[MappingRow]:
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("mapping CSV has no header")
        has_full = all(c in reader.fieldnames for c in REQUIRED_MAPPING_COLUMNS_FULL)
        has_min = all(c in reader.fieldnames for c in REQUIRED_MAPPING_COLUMNS_MIN)

        if not has_full and not has_min:
            raise ValueError(
                "mapping CSV format invalid. expected either full columns "
                f"{REQUIRED_MAPPING_COLUMNS_FULL} or minimal columns {REQUIRED_MAPPING_COLUMNS_MIN}"
            )
        if has_min and not has_full and cfg is None:
            raise ValueError("minimal mapping format requires --config")

        rows: List[MappingRow] = []
        for r in reader:
            if has_full:
                rows.append(
                    MappingRow(
                        source_host=r["source_host"].strip(),
                        source_port=r["source_port"].strip(),
                        source_user=r["source_user"].strip(),
                        source_db=r["source_db"].strip(),
                        source_schema=r["source_schema"].strip(),
                        source_table=r["source_table"].strip(),
                        target_host=r["target_host"].strip(),
                        target_port=r["target_port"].strip(),
                        target_user=r["target_user"].strip(),
                        target_db=r["target_db"].strip(),
                        target_schema=r["target_schema"].strip(),
                        target_table=r["target_table"].strip(),
                        where_clause=r.get("where_clause", "").strip(),
                    )
                )
            else:
                assert cfg is not None
                rows.append(
                    MappingRow(
                        source_host=cfg.asis.host,
                        source_port=cfg.asis.port,
                        source_user=cfg.asis.user,
                        source_db=r["source_db"].strip(),
                        source_schema=r["source_schema"].strip(),
                        source_table=r["source_table"].strip(),
                        target_host=cfg.tobe.host,
                        target_port=cfg.tobe.port,
                        target_user=cfg.tobe.user,
                        target_db=r["target_db"].strip(),
                        target_schema=r["target_schema"].strip(),
                        target_table=r["target_table"].strip(),
                        where_clause=r.get("where_clause", "").strip(),
                    )
                )

    if not rows:
        raise ValueError("mapping CSV contains no rows")
    return rows


def read_fk_edges(path: Path | None) -> Dict[str, List[Tuple[Tuple[str, str], Tuple[str, str]]]]:
    """
    Returns:
      target_db -> list of edges (parent -> child), each endpoint=(schema, table)
    """
    if path is None:
        return {}

    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = ["target_db", "child_schema", "child_table", "parent_schema", "parent_table"]
        if reader.fieldnames is None:
            raise ValueError("fk edge CSV has no header")
        missing = [c for c in required if c not in reader.fieldnames]
        if missing:
            raise ValueError(f"fk edge CSV missing columns: {', '.join(missing)}")

        out: Dict[str, List[Tuple[Tuple[str, str], Tuple[str, str]]]] = defaultdict(list)
        for r in reader:
            db = r["target_db"].strip()
            child = (r["child_schema"].strip(), r["child_table"].strip())
            parent = (r["parent_schema"].strip(), r["parent_table"].strip())
            out[db].append((parent, child))
    return out


def topo_order(
    nodes: Set[Tuple[str, str]],
    edges: Iterable[Tuple[Tuple[str, str], Tuple[str, str]]],
) -> Tuple[List[Tuple[str, str]], List[Tuple[str, str]]]:
    """
    Kahn topological sort on subset of nodes.
    edges are parent -> child.
    Returns (ordered_nodes, cyclic_nodes)
    """
    graph: Dict[Tuple[str, str], Set[Tuple[str, str]]] = {n: set() for n in nodes}
    indeg: Dict[Tuple[str, str], int] = {n: 0 for n in nodes}

    for parent, child in edges:
        if parent not in nodes or child not in nodes:
            continue
        if child not in graph[parent]:
            graph[parent].add(child)
            indeg[child] += 1

    q = deque(sorted([n for n in nodes if indeg[n] == 0]))
    ordered: List[Tuple[str, str]] = []

    while q:
        node = q.popleft()
        ordered.append(node)
        for nxt in sorted(graph[node]):
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                q.append(nxt)

    cyclic = sorted([n for n in nodes if n not in set(ordered)])
    return ordered, cyclic


def build_copy_command(row: MappingRow) -> str:
    source_select = f"SELECT * FROM {fq(row.source_schema, row.source_table)}"
    if row.where_clause:
        source_select += f" WHERE {row.where_clause}"

    src_conn = (
        f"host={row.source_host} port={row.source_port} "
        f"dbname={row.source_db} user={row.source_user}"
    )
    tgt_conn = (
        f"host={row.target_host} port={row.target_port} "
        f"dbname={row.target_db} user={row.target_user}"
    )

    src_copy_sql = f"\\COPY ({source_select}) TO STDOUT WITH (FORMAT csv)"
    tgt_copy_sql = f"\\COPY {fq(row.target_schema, row.target_table)} FROM STDIN WITH (FORMAT csv)"

    return (
        f"psql \"{src_conn}\" -v ON_ERROR_STOP=1 "
        f"-c {shell_single_quote(src_copy_sql)} "
        f"| psql \"{tgt_conn}\" -v ON_ERROR_STOP=1 "
        f"-c {shell_single_quote(tgt_copy_sql)}"
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def write_file(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def main() -> None:
    args = parse_args()
    mapping_path = Path(args.mapping)
    fk_path = Path(args.fk_edges) if args.fk_edges else None
    cfg_path = Path(args.config) if args.config else None
    out_dir = Path(args.out_dir)
    ensure_dir(out_dir)

    cfg = load_env_config(cfg_path) if cfg_path else None
    mappings = read_mapping(mapping_path, cfg)
    fk_edges_by_db = read_fk_edges(fk_path)

    by_target_db: Dict[str, List[MappingRow]] = defaultdict(list)
    for row in mappings:
        by_target_db[row.target_db].append(row)

    summary_lines: List[str] = []
    summary_lines.append("# Migration Command Generation Summary")
    summary_lines.append(f"- mapping_file: {mapping_path}")
    summary_lines.append(f"- fk_edges_file: {fk_path if fk_path else '(none)'}")
    summary_lines.append("")

    for target_db in sorted(by_target_db):
        rows = by_target_db[target_db]
        target_nodes = {r.target_ref.key for r in rows}
        edges = fk_edges_by_db.get(target_db, [])
        ordered_nodes, cyclic_nodes = topo_order(target_nodes, edges)

        if not edges:
            ordered_nodes = sorted(target_nodes)

        order_index = {node: idx for idx, node in enumerate(ordered_nodes)}
        rows_sorted = sorted(
            rows,
            key=lambda r: (
                order_index.get(r.target_ref.key, 10**9),
                r.target_ref.schema,
                r.target_ref.table,
            ),
        )

        order_lines = [
            f"# FK-based execution order for target_db={target_db}",
            "# Parent (referenced) first -> Child (referencing) later",
        ]
        for i, node in enumerate(ordered_nodes, start=1):
            order_lines.append(f"{i:03d}. {node[0]}.{node[1]}")
        if cyclic_nodes:
            order_lines.append("")
            order_lines.append("# WARNING: FK cycle detected for tables below")
            for node in cyclic_nodes:
                order_lines.append(f"- {node[0]}.{node[1]}")
        order_lines.append("")
        order_path = out_dir / f"01_fk_order_{target_db}.txt"
        write_file(order_path, "\n".join(order_lines))

        cmd_lines = [
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            "",
            "# Generated non-destructive data migration commands",
            "# - Source side: read only",
            "# - Target side: insert only",
            "# - No TRUNCATE/DELETE/ALTER/DROP emitted",
            "",
        ]
        for row in rows_sorted:
            cmd_lines.append(
                f"# {row.source_db}.{row.source_schema}.{row.source_table} "
                f"-> {row.target_db}.{row.target_schema}.{row.target_table}"
            )
            cmd_lines.append(build_copy_command(row))
            cmd_lines.append("")

        cmd_path = out_dir / f"02_commands_{target_db}.sh"
        write_file(cmd_path, "\n".join(cmd_lines))
        os.chmod(cmd_path, 0o750)

        summary_lines.append(f"## target_db={target_db}")
        summary_lines.append(f"- tables: {len(rows)}")
        summary_lines.append(f"- order_file: {order_path}")
        summary_lines.append(f"- command_file: {cmd_path}")
        summary_lines.append(f"- fk_cycle_detected: {'yes' if cyclic_nodes else 'no'}")
        summary_lines.append("")

    summary_path = out_dir / "00_generation_summary.md"
    write_file(summary_path, "\n".join(summary_lines))
    print(f"Generated files in: {out_dir.resolve()}")
    print(f"Summary: {summary_path.resolve()}")


if __name__ == "__main__":
    main()
