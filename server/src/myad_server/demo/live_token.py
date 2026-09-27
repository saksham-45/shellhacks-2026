"""Mint one Gemini Live EPHEMERAL token for the phone, so GEMINI_API_KEY never leaves the server.

Follows https://ai.google.dev/gemini-api/docs/ephemeral-tokens (checked 2026-09-25):
- `client.auth_tokens.create(config={...})` on a client built with `http_options={'api_version': 'v1alpha'}`;
  the phone uses `token.name` as its API key, v1alpha only, Live API only;
- `uses: 1` (one session; resumption does not count), a SHORT `expire_time` (the default is 30 min; we use
  10) and `new_session_expire_time` 60 s (the documented default, set explicitly);
- `live_connect_constraints` lock the model and the session config. With no `lock_additional_fields` the
  effective setup is taken entirely from these constraints (API reference, AuthToken.fieldMask:
  https://ai.google.dev/api/live#ephemeral-auth-tokens), so the phone cannot turn automatic activity
  detection back on or switch models.
Locked config (agents-ARCH.md §18 design constraints): model gemini-3.1-flash-live-preview, audio out,
`realtime_input_config.automatic_activity_detection.disabled = true` (push-to-talk: the phone sends
activityStart/activityEnd, https://ai.google.dev/gemini-api/docs/live-api/capabilities), input and output
audio transcription on, no proactivity (unsupported on 3.1 Flash Live), nothing persisted.
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from ..demo_models import LiveConstraints, LiveTokenRequest, LiveTokenResponse
from . import genai as G

EXPIRE_MINUTES = 10
NEW_SESSION_SECONDS = 60
TOKEN_TIMEOUT_S = 6.0


class LiveUnavailable(RuntimeError):
    pass


def _system_instruction(req: LiveTokenRequest) -> str | None:
    if not (req.source_language and req.target_language):
        return None
    return (f"Every push-to-talk turn is a translation request: translate what was said between "
            f"{req.source_language} and {req.target_language}. Translate only; never answer or advise.")


def token_config(req: LiveTokenRequest, model: str, now: datetime) -> dict[str, Any]:
    live_config: dict[str, Any] = {
        "response_modalities": ["AUDIO"],
        "input_audio_transcription": {},
        "output_audio_transcription": {},
        "realtime_input_config": {"automatic_activity_detection": {"disabled": True}},
    }
    instruction = _system_instruction(req)
    if instruction:
        live_config["system_instruction"] = instruction
    return {
        "uses": 1,
        "expire_time": now + timedelta(minutes=EXPIRE_MINUTES),
        "new_session_expire_time": now + timedelta(seconds=NEW_SESSION_SECONDS),
        "live_connect_constraints": {"model": model, "config": live_config},
        "http_options": {"api_version": G.LIVE_TOKEN_API_VERSION},
    }


def _name(token: Any) -> str | None:
    name = token.get("name") if isinstance(token, Mapping) else getattr(token, "name", None)
    return name if isinstance(name, str) and name else None


def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


async def run(req: LiveTokenRequest, *, request_id: str,
              now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> LiveTokenResponse:
    if not G.live_enabled():
        raise LiveUnavailable("offline or keyless")
    model = G.live_model()
    t0 = now()
    config = token_config(req, model, t0)
    try:
        gclient = G.client(G.LIVE_TOKEN_API_VERSION)
        token = await asyncio.wait_for(asyncio.to_thread(lambda: gclient.auth_tokens.create(config=config)),
                                       TOKEN_TIMEOUT_S)
    except Exception:  # noqa: BLE001 - never log the key, the token, or SDK error text
        raise LiveUnavailable("token call failed") from None
    name = _name(token)
    if name is None:
        raise LiveUnavailable("no token")
    return LiveTokenResponse(
        request_id=request_id,
        token=name,
        expire_time=_iso(config["expire_time"]),
        new_session_expire_time=_iso(config["new_session_expire_time"]),
        constraints=LiveConstraints(model=model),
    )
