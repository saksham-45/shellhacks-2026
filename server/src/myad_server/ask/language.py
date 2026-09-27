"""reply_language for /v1/ask (review r3, M9): a regional BCP-47 tag maps to its base language."""
from __future__ import annotations

SUPPORTED = ("es", "en", "ht")
FALLBACK = "en"


def reply_language(tag: str | None) -> str:
    """`es-US`, `es-419`, `ht-HT`, `EN-us` -> `es`, `es`, `ht`, `en`. Unsupported languages fall back to en."""
    base = (tag or "").replace("_", "-").split("-", 1)[0].strip().casefold()
    return base if base in SUPPORTED else FALLBACK
