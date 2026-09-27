"""Settings from the environment only. Keys come only from env GEMINI_API_KEY (never from files); CI sets
MYAD_OFFLINE=1 and never has a key, so no model is ever built there.

MYAD_ROOT          project root (default: three levels above server/src/myad_server)
MYAD_CARDS_BUNDLE  compiled card bundle (default <root>/contracts/content/cards.json)
MYAD_MODEL         main model id (default gemini-3.8-flash: stable per ai.google.dev/gemini-api/docs/models,
                   checked 2026-09-25)
MYAD_MODEL_FAST    classifier model id for /v1/ask (default gemini-3.5-flash-lite, stable, same source)
MYAD_OFFLINE       "1" = no network at all: never build a model client, and Regions runs on its saved
                   fixtures only. Wins over MYAD_LIVE (CI, tests, the offline demo).
MYAD_LIVE          "1" = Regions' live adapters (fixtures otherwise), ignored when MYAD_OFFLINE=1;
                   not used by /v1/ask
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_MODEL = "gemini-3.8-flash"
DEFAULT_MODEL_FAST = "gemini-3.5-flash-lite"


@dataclass(frozen=True)
class Settings:
    root: Path
    cards_bundle: Path
    model: str
    model_fast: str
    offline: bool
    live: bool

    @property
    def regions_live(self) -> bool:
        """Whether Regions may use its live transport: MYAD_LIVE=1 and not MYAD_OFFLINE=1."""
        return self.live and not self.offline

    @property
    def facts_dir(self) -> Path:
        return self.root / "research" / "facts"

    @property
    def sources_path(self) -> Path:
        return self.root / "research" / "sources.yaml"

    @property
    def topics_path(self) -> Path:
        return self.root / "research" / "topics.yaml"

    @property
    def command_keys_path(self) -> Path:
        return self.root / "contracts" / "intent" / "command_keys.json"

    @property
    def regionpacks_dir(self) -> Path:
        return self.root / "server" / "regionpacks"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        e = os.environ if env is None else env
        root = Path(e.get("MYAD_ROOT") or Path(__file__).resolve().parents[3])
        bundle = Path(e["MYAD_CARDS_BUNDLE"]) if e.get("MYAD_CARDS_BUNDLE") else root / "contracts" / "content" / "cards.json"
        return cls(root=root, cards_bundle=bundle, model=e.get("MYAD_MODEL") or DEFAULT_MODEL,
                   model_fast=e.get("MYAD_MODEL_FAST") or DEFAULT_MODEL_FAST,
                   offline=e.get("MYAD_OFFLINE") == "1", live=e.get("MYAD_LIVE") == "1")


def gemini_model(model_id: str, env: dict[str, str] | None = None):
    """An ADK Gemini model with the key passed explicitly from env GEMINI_API_KEY (google-genai would
    otherwise prefer GOOGLE_API_KEY). None when there is no key. Never reads a file; never logs the key."""
    e = os.environ if env is None else env
    key = e.get("GEMINI_API_KEY")
    if not key:
        return None
    from google.adk.models import Gemini

    return Gemini(model=model_id, client_kwargs={"api_key": key})
