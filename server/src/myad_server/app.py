"""FastAPI app: thin routes over the Harness (myAD Agents).

/v1/ask returns only an IntentResolution; the request id is echoed in the X-Request-ID header so the body
stays exactly the ARCHITECTURE.md §13.2 type. household-week is the typed phase-1d flow; person-next-steps is the typed phase-1e flow.
The four demo routes (fee-check, handoff-sheet, desk/translate, live/token) live in demo/ (DEMO-ENDPOINTS.md).
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from contextlib import asynccontextmanager
from typing import Callable

from fastapi import FastAPI, Request
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .demo import desk_translate as demo_translate
from .demo import fee_check as demo_fee_check
from .demo import handoff as demo_handoff
from .demo import live_token as demo_live_token
from .demo.services import DemoServices
from .harness import Harness
from .harness import harness_factory as _env_harness_factory
from .intent import AskRequest, IntentResolution
from .logs import configure_logging, log_request
from .models import (
    DemoErrorBody,
    DeskTranslateRequest,
    DeskTranslateResponse,
    FeeCheckRequest,
    FeeCheckResponse,
    HandoffSheetRequest,
    HandoffSheetResponse,
    HouseholdWeekRequest,
    HouseholdWeekResponse,
    NotImplementedBody,
    LiveTokenRequest,
    LiveTokenResponse,
    PersonNextStepsRequest,
    PersonNextStepsResponse,
)
from .settings import Settings

_NOT_IMPLEMENTED = {501: {"model": NotImplementedBody}}
_REQUEST_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
# Demo routes never echo request input, even in a 422 (FastAPI's default body repeats the offending value).
_DEMO_ROUTES = frozenset({"/v1/fee-check", "/v1/handoff-sheet", "/v1/desk/translate", "/v1/live/token"})
_DEMO_ERRORS = {code: {"model": DemoErrorBody} for code in (413, 422, 503)}


def _new_request_id() -> str:
    return uuid.uuid4().hex


def _demo_error(status: int, code: str, request: Request) -> JSONResponse:
    body = DemoErrorBody(error=code, request_id=request.state.request_id)  # type: ignore[arg-type]
    return JSONResponse(status_code=status, content=body.model_dump(exclude_none=True))


def create_app(harness_factory: Callable[[], Harness] | None = None,
               demo_factory: Callable[[Harness], DemoServices] | None = None) -> FastAPI:
    configure_logging()
    # Uvicorn's default access logger includes client addresses and query strings.
    # Keep the app's structured request log as the only request-level log.
    logging.getLogger("uvicorn.access").disabled = True
    # Start-up errors (broken ledger, bundle, topics or policy) abort here instead of serving an empty
    # harness; only a missing Regions runtime degrades to desk answers (Harness.from_settings).
    factory = harness_factory or _env_harness_factory()
    holder: dict[str, Harness] = {}
    lock = asyncio.Lock()

    async def harness() -> Harness:
        if "h" not in holder:
            async with lock:
                if "h" not in holder:
                    holder["h"] = factory()
        return holder["h"]

    demo_holder: dict[str, DemoServices] = {}

    async def demo() -> DemoServices:
        if "d" not in demo_holder:
            h = await harness()
            async with lock:
                if "d" not in demo_holder:
                    make = demo_factory or (lambda hh: DemoServices.from_settings(Settings.from_env(), hh.deps.ledger))
                    demo_holder["d"] = make(h)
        return demo_holder["d"]

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await harness()  # fail fast at start on a bad ledger, bundle or policy
        yield

    app = FastAPI(title="myAmericanDream agents", version="0.1.0", lifespan=lifespan)

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        start = time.perf_counter()
        header_id = request.headers.get("x-request-id", "")
        request.state.request_id = header_id if _REQUEST_ID.match(header_id) else _new_request_id()
        request.state.counts = {}
        try:
            response = await call_next(request)
        except Exception:  # noqa: BLE001 - never echo or log the body; the phone falls back to its matcher
            response = JSONResponse(status_code=503, content={"detail": "unavailable"})
        response.headers["X-Request-ID"] = request.state.request_id
        log_request(request.state.request_id, request.url.path, response.status_code,
                    (time.perf_counter() - start) * 1000, request.state.counts)
        return response

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        if request.url.path in _DEMO_ROUTES:
            errors = exc.errors()
            request.state.counts = {"invalid_fields": len(errors)}
            if any(e.get("loc", ())[-1:] == ("audio_b64",) and e.get("type") == "string_too_long" for e in errors):
                return _demo_error(413, "audio_too_large", request)
            return _demo_error(422, "invalid_request", request)
        return await request_validation_exception_handler(request, exc)

    def _stub(route: str) -> JSONResponse:
        return JSONResponse(status_code=501, content=NotImplementedBody(route=route).model_dump())

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/household-week", response_model=HouseholdWeekResponse)
    async def household_week(req: HouseholdWeekRequest, request: Request) -> HouseholdWeekResponse:
        if req.request_id:
            request.state.request_id = req.request_id
        h = await harness()
        response = await h.household_week(req)
        request.state.counts = {
            "facts": len(response.facts),
            "handoffs": len(response.handoffs),
            "items": len(response.items),
            "dropped_claims": response.dropped_claims,
            "demo_facts": int(response.has_demo),
        }
        return response

    @app.post("/v1/person-next-steps", response_model=PersonNextStepsResponse)
    async def person_next_steps(req: PersonNextStepsRequest, request: Request) -> PersonNextStepsResponse:
        if req.request_id:
            request.state.request_id = req.request_id
        h = await harness()
        response = await h.person_next_steps(req)
        request.state.counts = {
            "facts": len(response.facts),
            "handoffs": len(response.handoffs),
            "steps": len(response.steps),
            "origin_claims": len(response.origin_comparison),
            "dropped_claims": response.dropped_claims,
            "demo_facts": int(response.has_demo),
        }
        return response

    @app.post("/v1/ask", response_model=IntentResolution)
    async def ask(req: AskRequest, request: Request) -> IntentResolution:
        if req.request_id:
            request.state.request_id = req.request_id
        h = await harness()
        # Harness.resolve includes the synchronous Gemini ranker and must not block the event loop.
        resolution = await asyncio.to_thread(h.resolve, req)
        request.state.counts = {
            "grounded": int(resolution.grounding is not None),
            "clarification_options": len(resolution.clarification.options) if resolution.clarification else 0,
        }
        return resolution

    # ---- demo routes (FM-MYAD-DEMO-DESK; server/DEMO-ENDPOINTS.md) -------------------------------------------

    @app.post("/v1/fee-check", response_model=FeeCheckResponse, responses={422: {"model": DemoErrorBody}})
    async def fee_check(req: FeeCheckRequest, request: Request) -> FeeCheckResponse:
        if req.request_id:
            request.state.request_id = req.request_id
        d = await demo()
        response = await demo_fee_check.run(req, request_id=request.state.request_id, ledger=d.ledger,
                                            catalog=d.catalog, extractor=d.extractor_factory(), now=d.now())
        request.state.counts = {
            "facts": len(response.facts),
            "handoffs": len(response.handoffs),
            "lines": len(response.lines),
            "dropped_claims": response.dropped_claims,
            "extractor_live": int(response.extractor == "gemini"),
        }
        return response

    @app.post("/v1/handoff-sheet", response_model=HandoffSheetResponse, responses={422: {"model": DemoErrorBody}})
    async def handoff_sheet(req: HandoffSheetRequest, request: Request) -> HandoffSheetResponse:
        if req.request_id:
            request.state.request_id = req.request_id
        d = await demo()
        response = await demo_handoff.run(req, request_id=request.state.request_id,
                                          summarizer=d.summarizer_factory())
        request.state.counts = {
            "utterances": len(req.utterances),
            "sentences": len(response.sentences),
            "dropped": len(response.dropped),
            "summarizer_live": int(response.summarizer == "gemini"),
        }
        return response

    @app.post("/v1/desk/translate", response_model=DeskTranslateResponse, responses=_DEMO_ERRORS)
    async def desk_translate(req: DeskTranslateRequest, request: Request):
        if req.request_id:
            request.state.request_id = req.request_id
        request.state.counts = {"audio_input": int(req.audio_b64 is not None)}
        try:
            return await demo_translate.run(req, request_id=request.state.request_id)
        except demo_translate.AudioRejected as e:
            return _demo_error(413 if e.code == "audio_too_large" else 422, e.code, request)
        except demo_translate.FallbackUnavailable:
            return _demo_error(503, "fallback_unavailable", request)

    @app.post("/v1/live/token", response_model=LiveTokenResponse, responses={503: {"model": DemoErrorBody}})
    async def live_token(req: LiveTokenRequest, request: Request):
        if req.request_id:
            request.state.request_id = req.request_id
        try:
            response = await demo_live_token.run(req, request_id=request.state.request_id)
        except demo_live_token.LiveUnavailable:
            request.state.counts = {"minted": 0}
            return _demo_error(503, "live_unavailable", request)
        request.state.counts = {"minted": 1}
        return response

    return app


def main() -> None:
    """Run the API with Uvicorn access logging disabled."""
    import uvicorn

    uvicorn.run("myad_server.app:app", host="0.0.0.0", port=8080, access_log=False)


app = create_app()


if __name__ == "__main__":
    main()
