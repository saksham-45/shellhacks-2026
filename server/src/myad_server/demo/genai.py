"""The only door to Gemini for the demo endpoints.

Rules (settings.py, logs.py):
- the key comes only from ``os.environ["GEMINI_API_KEY"]`` and is passed explicitly to the client (google-genai
  would otherwise prefer GOOGLE_API_KEY); it is never read from a file, logged, or returned;
- ``MYAD_OFFLINE=1`` short-circuits before any client exists, so offline code cannot touch the network;
- ``google-genai`` is imported lazily: the base server install (requirements.lock) does not ship it, and CI
  never needs it. Install it with the ``live`` extra (google-adk depends on google-genai).

Environment is read per call so a deploy (or a test's monkeypatch) can add the key without a restart.

Model ids, checked 2026-09-25 against https://ai.google.dev/gemini-api/docs/models (endpoint table):
- ``gemini-3.8-flash`` ("Gemini 3.8 Flash", New Stable) for the structured one-shot calls; same pin as
  server/spikes/live/fallback.py (DEFAULT_FALLBACK_MODEL);
- ``gemini-3.1-flash-live-preview`` ("Gemini 3.1 Flash Live", legacy Live API preview) for the Live token,
  as pinned in agents-ARCH.md §18 (the Live id ADK documents; it has no proactive audio, which suits
  push-to-talk). Override with MYAD_LIVE_MODEL (e.g. gemini-3.8-live) once the spike passes.
"""
from __future__ import annotations

import json
import os
from typing import Any, Callable, Mapping

DEFAULT_STRUCTURED_MODEL = "gemini-3.8-flash"
DEFAULT_LIVE_MODEL = "gemini-3.1-flash-live-preview"
# Ephemeral tokens are "only compatible with Live API" and use the v1alpha API version:
# https://ai.google.dev/gemini-api/docs/ephemeral-tokens
LIVE_TOKEN_API_VERSION = "v1alpha"


class GeminiUnavailable(RuntimeError):
    """Offline, keyless, or the optional SDK is not installed. Carries no request content."""


def env_offline(env: Mapping[str, str] | None = None) -> bool:
    e = os.environ if env is None else env
    return e.get("MYAD_OFFLINE") == "1"


def has_key(env: Mapping[str, str] | None = None) -> bool:
    e = os.environ if env is None else env
    return bool(e.get("GEMINI_API_KEY"))


def live_enabled(env: Mapping[str, str] | None = None) -> bool:
    """True only when a model call is allowed at all: not offline and a key is present."""
    return not env_offline(env) and has_key(env)


def structured_model(env: Mapping[str, str] | None = None) -> str:
    # MYAD_MODEL is deliberately not reused: ci-hook.sh sets it to "stub".
    e = os.environ if env is None else env
    return e.get("MYAD_FALLBACK_MODEL") or DEFAULT_STRUCTURED_MODEL


def live_model(env: Mapping[str, str] | None = None) -> str:
    e = os.environ if env is None else env
    return e.get("MYAD_LIVE_MODEL") or DEFAULT_LIVE_MODEL


def _default_build_client(api_version: str | None = None) -> Any:
    if env_offline():
        raise GeminiUnavailable("offline")
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise GeminiUnavailable("no key")
    try:
        from google import genai  # lazy: optional dependency
    except ImportError as e:  # pragma: no cover - depends on the install
        raise GeminiUnavailable("google-genai not installed") from e
    http_options: dict[str, Any] = {}
    if api_version:
        http_options["api_version"] = api_version
    return genai.Client(api_key=key, http_options=http_options or None)


# Tests replace this with a fake; nothing else should.
build_client: Callable[..., Any] = _default_build_client


def client(api_version: str | None = None) -> Any:
    """A google-genai client, or GeminiUnavailable. Offline and keyless never reach build_client."""
    if env_offline():
        raise GeminiUnavailable("offline")
    if not has_key():
        raise GeminiUnavailable("no key")
    return build_client(api_version) if api_version else build_client()


def _field(obj: Any, name: str) -> Any:
    if isinstance(obj, Mapping):
        return obj.get(name)
    return getattr(obj, name, None)


def structured_call(gclient: Any, *, model: str, parts: list[dict[str, Any]], schema: dict[str, Any],
                    timeout_s: float) -> dict[str, Any] | None:
    """One Interactions API call with a JSON-schema response format; the parsed object, or None.

    Shape per https://ai.google.dev/gemini-api/docs/structured-output (checked 2026-09-25):
    ``client.interactions.create(model=..., input=..., response_format={"type": "text", "mime_type":
    "application/json", "schema": ...})`` and the JSON text in ``interaction.output_text``. Inline audio parts
    are ``{"type": "audio", "data": <base64>, "mime_type": "audio/wav"}``
    (https://ai.google.dev/gemini-api/docs/audio, "Pass audio data inline"; 20 MB request cap). The docs say
    to validate values even though the JSON is syntactically guaranteed, so callers re-validate every field.
    Exceptions propagate to the caller, which degrades to its offline path without logging content.
    """
    interaction = gclient.interactions.create(
        model=model,
        input=parts,
        response_format={"type": "text", "mime_type": "application/json", "schema": schema},
        timeout=timeout_s,
    )
    text = _field(interaction, "output_text")
    if not isinstance(text, str) or not text.strip():
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None
