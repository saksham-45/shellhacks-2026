"""Deterministic confidence. The phone applies the policy (>= 0.75 act, 0.40-0.75 clarify, < 0.40 desk);
the server only reports a number and, inside the clarify band, a clarification.

    conf = q(chosen)
    if the chooser is a real model and agreed with the lexical top:     conf += 0.10 (capped at 1)
    if the chooser picked a lower-ranked candidate:                     conf *= 0.90
    if another candidate is close (q >= 0.30 and within 0.12):          conf  = min(conf, 0.70)  (ambiguous)
    if the chooser said "none":                                         conf  = min(q(top), 0.35)
"""
from __future__ import annotations

from .retrieval import Candidate

ACT = 0.75
CLARIFY = 0.40
AMBIGUOUS_MARGIN = 0.12
AMBIGUOUS_FLOOR = 0.30
AMBIGUOUS_CAP = 0.70
NONE_CAP = 0.35
OPTION_FLOOR = 0.25


def calibrate(candidates: list[Candidate], chosen: str | None, by_model: bool) -> float:
    if not candidates:
        return 0.0
    top = candidates[0]
    if chosen is None:
        return round(min(top.q, NONE_CAP), 3)
    pick = next((c for c in candidates if c.card_id == chosen), None)
    if pick is None:
        return 0.0
    conf = pick.q
    if pick.card_id == top.card_id:
        if by_model:
            conf = min(1.0, conf + 0.10)
    else:
        conf *= 0.90
    others = [c.q for c in candidates if c.card_id != pick.card_id]
    if others and max(others) >= AMBIGUOUS_FLOOR and pick.q - max(others) < AMBIGUOUS_MARGIN:
        conf = min(conf, AMBIGUOUS_CAP)
    return round(max(0.0, min(1.0, conf)), 3)


def band(conf: float) -> str:
    return "act" if conf >= ACT else "clarify" if conf >= CLARIFY else "desk"
