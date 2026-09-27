"""The model-choice step, behind one interface so the model (or none) is a swap.

The chooser only picks among candidate ids that deterministic retrieval produced, or "none". It never
writes text that reaches the person. `AdkChooser` builds a per-request pydantic schema whose only field is a
Literal of the candidate ids plus "none", so structured output cannot name anything else; any failure
(timeout, invalid output, network) falls back to the deterministic top candidate and is counted, never
logged with content.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from dataclasses import dataclass
from typing import Literal, Protocol

from pydantic import create_model

NONE = "none"


@dataclass(frozen=True)
class ChoiceOption:
    id: str                    # candidate id (a card id)
    title_en: str              # reviewed card title, for the model's context
    examples: tuple[str, ...]  # a few reviewed card utterances (Content's text, never user data)


@dataclass(frozen=True)
class Choice:
    option_id: str | None      # None = the chooser says no candidate fits
    by_model: bool             # True only when a model actually made this choice
    fallback: bool = False     # True when the model failed and the deterministic top was used


class IntentChooser(Protocol):
    async def choose(self, text: str, language: str, options: list[ChoiceOption]) -> Choice: ...


class RetrievalChooser:
    """No model: the top retrieval candidate. Used when no key is configured, and in CI."""

    async def choose(self, text: str, language: str, options: list[ChoiceOption]) -> Choice:
        return Choice(options[0].id if options else None, by_model=False)


class ScriptedChooser:
    """Test double: returns a fixed id (or "none"), whether or not it is a candidate."""

    def __init__(self, answer: str | None):
        self.answer = answer
        self.calls: list[list[str]] = []

    async def choose(self, text: str, language: str, options: list[ChoiceOption]) -> Choice:
        self.calls.append([o.id for o in options])
        if self.answer == NONE:
            return Choice(None, by_model=True)
        return Choice(self.answer, by_model=True)


def _instruction(options: list[ChoiceOption]) -> str:
    lines = [
        "You route a spoken request to one screen of a newcomer-help app.",
        "The request may mix Spanish, English and Haitian Creole.",
        "Answer ONLY with the id of the one candidate whose card answers the request, or \"none\".",
        "Never answer the question yourself. Candidates:",
    ]
    for o in options:
        lines.append(json.dumps({"id": o.id, "title": o.title_en, "examples": list(o.examples)}, ensure_ascii=False))
    return "\n".join(lines)


class AdkChooser:
    """Gemini (or any ADK BaseLlm) as a constrained classifier via an ADK single-turn LlmAgent."""

    def __init__(self, model, timeout_s: float = 6.0):
        self.model = model
        self.timeout_s = timeout_s

    async def choose(self, text: str, language: str, options: list[ChoiceOption]) -> Choice:
        if not options:
            return Choice(None, by_model=False)
        try:
            picked = await asyncio.wait_for(self._run(text, options), timeout=self.timeout_s)
        except Exception:  # noqa: BLE001 - any model failure falls back; content is never logged
            return Choice(options[0].id, by_model=False, fallback=True)
        ids = {o.id for o in options}
        if picked == NONE:
            return Choice(None, by_model=True)
        if picked in ids:
            return Choice(picked, by_model=True)
        return Choice(options[0].id, by_model=False, fallback=True)

    async def _run(self, text: str, options: list[ChoiceOption]) -> str | None:
        from google.adk import Agent, Runner
        from google.adk.sessions import InMemorySessionService
        from google.genai import types

        ids = tuple([o.id for o in options] + [NONE])
        pick_model = create_model("IntentPick", choice=(Literal[ids], ...))  # type: ignore[valid-type]
        instruction = _instruction(options)
        agent = Agent(
            name="intent_chooser",
            model=self.model,
            instruction=lambda _ctx: instruction,  # a provider: no {state} templating of card text
            output_schema=pick_model,
            output_key="intent_pick",
            generate_content_config=types.GenerateContentConfig(temperature=0.0),
        )
        sessions = InMemorySessionService()
        runner = Runner(app_name="myad_ask", agent=agent, session_service=sessions)
        session = await sessions.create_session(app_name="myad_ask", user_id="anon", session_id=uuid.uuid4().hex)
        message = types.Content(role="user", parts=[types.Part(text=text)])
        async for _ in runner.run_async(user_id="anon", session_id=session.id, new_message=message):
            pass
        final = await sessions.get_session(app_name="myad_ask", user_id="anon", session_id=session.id)
        raw = (final.state if final else {}).get("intent_pick")
        if isinstance(raw, str):
            raw = json.loads(raw)
        return pick_model.model_validate(raw).choice if raw is not None else None
