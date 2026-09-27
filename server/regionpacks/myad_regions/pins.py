"""The two demo pins. Coordinates are the Miami-Dade County address locator's PointAddress candidate for each
address (saved in fixtures/<pin>/county-locator.json with its URL and retrieved_at); they are not invented.
Each point falls inside the address's own parcel (pin-sw137: folio 3059100230010; pin-nw1st: folio 0141370230020).
The earlier Census points were street-interpolated and could land off the parcel."""
from __future__ import annotations

from types import MappingProxyType

from .types import PinInput

DEMO_PINS = MappingProxyType({
    "pin-sw137": PinInput(address="11200 SW 137th Ave, Miami, FL 33186", lat=25.663194000003116, lon=-80.41646700000167),
    "pin-nw1st": PinInput(address="111 NW 1st St, Miami, FL 33128", lat=25.775604000003124, lon=-80.19666900000166),
})


def demo_pin_id(lat: float, lon: float) -> str | None:
    for pid, p in DEMO_PINS.items():
        if abs(p.lat - lat) < 1e-6 and abs(p.lon - lon) < 1e-6:
            return pid
    return None
