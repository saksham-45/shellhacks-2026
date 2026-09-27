"""Read sources.yaml + facts/*.json (owned by the ledger worker). One narrow write: status -> stale."""
from __future__ import annotations

import glob
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass
class Fact:
    raw: dict[str, Any]
    file: Path

    @property
    def id(self) -> str:
        return self.raw.get("id", "")

    @property
    def kind(self) -> str:
        return self.raw.get("kind") or "static"

    @property
    def status(self) -> str:
        return self.raw.get("status", "")

    def get(self, k: str, default: Any = None) -> Any:
        return self.raw.get(k, default)


@dataclass
class Ledger:
    root: Path
    sources: dict[str, dict[str, Any]]
    facts: list[Fact]
    problems: list[str] = field(default_factory=list)

    @classmethod
    def load(cls, root: str | os.PathLike) -> "Ledger":
        root = Path(root)
        problems: list[str] = []
        sources: dict[str, dict[str, Any]] = {}
        sp = root / "sources.yaml"
        if sp.exists():
            doc = yaml.safe_load(sp.read_text(encoding="utf-8")) or {}
            items = doc.get("sources", []) if isinstance(doc, dict) else doc
            for s in items or []:
                if isinstance(s, dict) and s.get("id"):
                    if s["id"] in sources:
                        problems.append(f"duplicate source id {s['id']}")
                    sources[s["id"]] = s
        else:
            problems.append(f"{sp} not found")
        facts: list[Fact] = []
        for path in sorted(glob.glob(str(root / "facts" / "*.json"))):
            try:
                doc = json.loads(Path(path).read_text(encoding="utf-8"))
            except json.JSONDecodeError as e:
                problems.append(f"{path}: invalid JSON: {e}")
                continue
            items = doc.get("facts") if isinstance(doc, dict) else doc
            if isinstance(doc, dict) and "facts" not in doc and "id" in doc:
                items = [doc]
            for f in items or []:
                if isinstance(f, dict):
                    facts.append(Fact(f, Path(path)))
        return cls(root, sources, facts, problems)

    def facts_by_source(self) -> dict[str | None, list[Fact]]:
        out: dict[str | None, list[Fact]] = {}
        for f in self.facts:
            out.setdefault(f.get("source_id"), []).append(f)
        return out

    def mark_stale(self, fact_ids: set[str]) -> list[str]:
        """Flip status verified -> stale for these ids, touching only that key. Returns ids changed."""
        changed: list[str] = []
        by_file: dict[Path, set[str]] = {}
        for f in self.facts:
            if f.id in fact_ids:
                by_file.setdefault(f.file, set()).add(f.id)
        for path, ids in by_file.items():
            doc = json.loads(path.read_text(encoding="utf-8"))  # reload: the file may have moved on
            items = doc.get("facts") if isinstance(doc, dict) and "facts" in doc else (doc if isinstance(doc, list) else [doc])
            touched = False
            for item in items:
                if isinstance(item, dict) and item.get("id") in ids and item.get("status") == "verified":
                    item["status"] = "stale"
                    changed.append(item["id"])
                    touched = True
            if touched:
                tmp = path.with_suffix(".json.tmp")
                tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                os.replace(tmp, path)
        return changed
