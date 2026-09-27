"""Topic vocabulary: research/topics.yaml is the only list of topic tags (ARCHITECTURE.md §13.x).

Accepted shapes (the file is Research's; its exact layout is not final): a top-level `topics:` list of
slugs or of mappings with `id`/`slug`, or a top-level mapping `topics: {slug: description}`.
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

SLUG = re.compile(r"^[a-z0-9]+([_-][a-z0-9]+)*$")


class TopicError(ValueError):
    pass


def load_topics(path: Path) -> frozenset[str] | None:
    """The vocabulary, or None when the file does not exist yet (then tags are not checked)."""
    if not path.is_file():
        return None
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    raw = data.get("topics", data) if isinstance(data, dict) else data
    slugs: list[str] = []
    if isinstance(raw, dict):
        slugs = [str(k) for k in raw]
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                slugs.append(item)
            elif isinstance(item, dict) and (item.get("id") or item.get("slug")):
                slugs.append(str(item.get("id") or item.get("slug")))
            else:
                raise TopicError(f"{path}: unreadable topic entry {item!r}")
    else:
        raise TopicError(f"{path}: expected a topics list or mapping")
    bad = [s for s in slugs if not SLUG.match(s)]
    if bad:
        raise TopicError(f"{path}: bad topic slugs {bad}")
    if len(set(slugs)) != len(slugs):
        raise TopicError(f"{path}: repeated topic slugs")
    return frozenset(slugs)


def unknown_topics(tags: list[str] | tuple[str, ...], vocab: frozenset[str] | None) -> list[str]:
    if vocab is None:
        return []
    return sorted({t for t in tags if t not in vocab})
