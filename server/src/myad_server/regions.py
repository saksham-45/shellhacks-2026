"""The Regions runtime seam. Production imports `server/regionpacks/runtime.py` read-only through its two
documented entry points (ARCHITECTURE.md §13.z "Cross-folder reads"); tests use a stub with the same
signature and never import regionpacks.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class RegionsRuntime(Protocol):
    """Thread-safe, no shared state. `timeout_s` is clamped to <= 20 by Regions; a timeout comes back as an
    `unavailable` result and never raises."""

    def resolve(self, pin: dict[str, Any]) -> list[str]: ...

    def answer(self, pin: dict[str, Any], fact_ids: list[str] | None = None, topics: list[str] | None = None,
               timeout_s: float = 20.0) -> list[dict[str, Any]]: ...


def load_runtime(regionpacks_dir: Path) -> RegionsRuntime | None:
    """Load Regions' runtime module by path, or None if it has not landed yet. Never run in tests."""
    path = regionpacks_dir / "runtime.py"
    if not path.is_file():
        return None
    if str(regionpacks_dir) not in sys.path:  # runtime.py imports its sibling package myad_regions
        sys.path.insert(0, str(regionpacks_dir))
    spec = importlib.util.spec_from_file_location("myad_regions_runtime", path)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module  # type: ignore[return-value]  # module-level resolve/answer satisfy the protocol
