import datetime as dt

import pytest

from research.freshness.schedule import is_due, parse_interval
from research.freshness.text import find_quote, fold, normalize
from research.freshness.values import find_value, pick, values_equal


def test_normalize_quotes_dashes_space():
    assert normalize("  “Tuesday”\u00a0and — Friday\n\n") == '"Tuesday" and - Friday'


def test_find_quote_exact_and_folded():
    text = "Garbage is collected   Tuesday and Friday in the service area."
    assert find_quote(text, "collected Tuesday and Friday").how == "exact"
    assert find_quote(text, "COLLECTED \"tuesday\" and friday").found


def test_find_quote_missing_gives_best_snippet():
    text = "Intro text. One person at 50 percent AMI is $49,100 effective May 1. Footer."
    m = find_quote(text, "One person at 50 percent AMI is $47,700")
    assert not m.found
    assert "$49,100" in m.snippet
    assert m.similarity > 0.8


@pytest.mark.parametrize("s,days", [("P7D", 7), ("P1Y", 365), ("P2W", 14), ("P1M", 30), ("30d", 30), ("weekly", 7)])
def test_parse_interval(s, days):
    assert parse_interval(s) == dt.timedelta(days=days)


def test_parse_interval_rejects_garbage():
    with pytest.raises(ValueError):
        parse_interval("soon")


def test_is_due():
    now = dt.datetime(2026, 9, 25, tzinfo=dt.timezone.utc)
    assert is_due(["P7D"], None, now)
    assert not is_due(["P7D"], "2026-09-20T00:00:00+00:00", now)
    assert is_due(["P30D", "P1D"], "2026-09-23T00:00:00+00:00", now)


def test_values_equal_money_and_strings():
    assert values_equal(0.66, "$0.66")
    assert values_equal("47,700", 47700)
    assert values_equal("Tuesday  Friday", "tuesday friday")
    assert not values_equal(0.66, 0.67)


def test_pick_and_find_value():
    obj = {"features": [{"attributes": {"WEEKDAYS": "Tuesday Friday"}}]}
    assert pick(obj, "features.0.attributes.weekdays") == "Tuesday Friday"
    assert find_value(obj, "tuesday friday") == "features.0.attributes.WEEKDAYS"
    assert fold("A,  B") == "a, b"
