"""Shared domain-facing contract types for the phase-1 harness boundary.

The wire schemas remain in :mod:`models` and :mod:`intent`; this module gives
internal callers a stable import for the ADCore-aligned typed fact vocabulary.
"""
from .models import FactOutcome
from .values import FactRef, FactValue, VALUE_TYPES, Weekday

__all__ = ["FactOutcome", "FactRef", "FactValue", "VALUE_TYPES", "Weekday"]
