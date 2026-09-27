"""research/freshness/state.json: what the last runs saw. Written after every source."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


class State:
    def __init__(self, path: Path, data: dict[str, Any]):
        self.path = path
        self.data = data
        self.data.setdefault("version", 1)
        self.data.setdefault("sources", {})
        self.data.setdefault("facts", {})
        self.data.setdefault("layers", {})
        self.data.setdefault("pins", {})

    @classmethod
    def load(cls, path: str | os.PathLike) -> "State":
        p = Path(path)
        data = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
        return cls(p, data)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, self.path)

    def source(self, sid: str) -> dict[str, Any]:
        return self.data["sources"].get(sid, {})

    def record_source(self, sid: str, **fields: Any) -> dict[str, Any]:
        prev = self.data["sources"].get(sid, {})
        entry = {**prev, **fields}
        if "content_sha256_text" in fields and prev.get("content_sha256_text"):
            entry["previous_sha256_text"] = prev.get("content_sha256_text")
        self.data["sources"][sid] = entry
        return entry

    def record_fact(self, fid: str, **fields: Any) -> None:
        self.data["facts"][fid] = {**self.data["facts"].get(fid, {}), **fields}

    def layer(self, key: str) -> dict[str, Any]:
        return self.data["layers"].get(key, {})

    def record_layer(self, key: str, **fields: Any) -> None:
        self.data["layers"][key] = {**self.data["layers"].get(key, {}), **fields}
