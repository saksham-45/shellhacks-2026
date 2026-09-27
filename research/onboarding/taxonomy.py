"""Generic topic taxonomy for GIS layers. Nothing place-specific: words any US county/city uses."""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

# topic -> (name regex, field regex or None, needs polygon?, desk to name when the lookup has no answer)
TOPICS: dict[str, tuple[str, str | None, bool | None, str]] = {
    "municipal-boundary": (r"municipal|municipalit|city ?limit|incorporated|jurisdiction(al)? boundar|corporate limit", r"munic|city|name", True, "county government / 311"),
    "parcel": (r"parcel|propert(y|ies)|land ?info|cadastr|tax ?lot", r"folio|parcel|pin|apn|year_?built|site_?addr", None, "property appraiser"),
    "trash": (r"garbage|trash|refuse|solid ?waste|sanitation|waste ?collection|trashroute", r"day|week|route", True, "311"),
    "recycling": (r"recycl", r"day|week|route", True, "311"),
    "bulky-waste": (r"bulky", None, True, "311"),
    "school-attendance": (r"(attendance|boundar|zone|zoned).*(school|elementary|middle|high)|(elementary|middle|high|school).*(attendance|boundar|zone)", None, True, "school district"),
    "school-sites": (r"school ?site|^schools?$|charter|private ?school|public ?school|college|daycare|head ?start|educat", None, None, "school district"),
    "parks": (r"\bparks?\b|recreation", None, None, "parks department"),
    "libraries": (r"librar", None, None, "library system"),
    "voting": (r"poll(ing)?|precinct|vote|election|early ?voting", None, None, "supervisor of elections"),
    "representatives": (r"commission ?district|congress|senate|house ?district|council ?district|school ?board ?district|legislat", None, True, "supervisor of elections"),
    "water-sewer": (r"water|sewer|wasd|wastewater", r"util|name|provider|service", True, "water utility"),
    "broadband": (r"broadband|internet", r"provider|download|tech", None, "FCC broadband map"),
    "public-safety": (r"fire ?station|police|sheriff|public ?safety|district ?station|\bfire\b", None, None, "911 / non-emergency line"),
    "zoning": (r"zoning|land ?use", None, True, "planning and zoning department"),
    "flood": (r"flood|fema|storm ?surge|evacuation", None, True, "emergency management"),
    "mosquito": (r"mosquito", None, None, "311"),
    "transit": (r"\bbus\b|transit|\brail\b|metro(rail|mover|bus)?|stops?\b|routes?\b|trolley", None, None, "transit agency"),
    "311-history": (r"\b311\b|service ?request", None, None, "311"),
}
ADDRESS_DEPENDENT_POLYGON = {"school-attendance-elementary", "school-attendance-middle", "school-attendance-high", "school-attendance-k8",
                             "municipal-boundary", "trash", "recycling", "bulky-waste", "school-attendance", "water-sewer",
                             "representatives", "zoning", "flood", "voting", "broadband", "parcel"}
NEAREST = {"school-sites", "parks", "libraries", "public-safety", "transit"}
# names that look topical but are not the everyday layer (projects, copies, buffers, drafts)
NEGATIVE = re.compile(r"annexation|\btest|backup|copy|_old\b|\bold\b|pilot|draft|proposed|buffer|minute ?walk|historic|archive|"
                      r"sample|temp\b|scratch|demo\b|design and|overlay|study", re.I)
SCHOOL_LEVEL = re.compile(r"elementary|middle|high|k-?8", re.I)
SERVICE_HINT = re.compile("|".join(v[0] for v in TOPICS.values()), re.I)


@dataclass
class TopicMatch:
    topic: str
    score: float
    reason: str


def _geom_kind(g: str | None) -> str:
    g = (g or "").lower()
    return "polygon" if "polygon" in g else "point" if "point" in g else "line" if "line" in g else "table" if not g else g


def classify_layer(service: str, layer_name: str, fields: list[str], geometry: str | None) -> list[TopicMatch]:
    """Rank topics for one layer. Score: layer-name hit 2, service-name hit 1, field hit 1, geometry fit 0.5."""
    out = []
    lname = re.sub(r"[_]+", " ", layer_name)
    sname = re.sub(r"[_/]+", " ", service)
    fjoin = " ".join(fields)
    gk = _geom_kind(geometry)
    for topic, (nrx, frx, poly, _desk) in TOPICS.items():
        score, why = 0.0, []
        if re.search(nrx, lname, re.I):
            score += 2
            why.append("layer name")
        if re.search(nrx, sname, re.I):
            score += 1
            why.append("service name")
        if score == 0:
            continue
        if frx and re.search(frx, fjoin, re.I):
            score += 1
            why.append("fields")
        if poly is True:
            score += 0.5 if gk == "polygon" else -1
        elif topic in NEAREST and gk == "point":
            score += 0.5
        if NEGATIVE.search(lname) or NEGATIVE.search(sname):
            score -= 1.5
            why.append("penalized: project/copy/draft-like name")
        if score >= 2:
            t = topic
            if topic == "school-attendance":
                lv = SCHOOL_LEVEL.search(lname)
                if lv:
                    t = f"school-attendance-{lv.group(0).lower().replace('-', '')}"
            out.append(TopicMatch(t, score, ", ".join(why) + f", geometry {gk}"))
    return sorted(out, key=lambda m: -m.score)


def base_topic(topic: str) -> str:
    return "school-attendance" if topic.startswith("school-attendance") else topic


def lookup_method(topic: str, geometry: str | None) -> str:
    gk = _geom_kind(geometry)
    if gk == "polygon":
        return "arcgis-query point-in-polygon esriSpatialRelIntersects"
    if topic == "parcel":
        return "arcgis-query buffered point (distance 30 m) then closest feature"
    if gk == "point":
        return "arcgis-query nearest: buffered point search, sort by distance"
    return "arcgis-query attribute where-clause"


def desk_for(topic: str) -> str:
    """Human label of the office a card for this topic hands off to."""
    return TOPICS[base_topic(topic)][3]


# Generic desk slugs. The ledger's desk field is a pack-scoped id "<pack>.<slug>" (e.g. us-fl-miamidade.311) and desk
# contact facts are "<desk-id>.name/.phone/...". Local names (Miami's "dswm", "wasd") are a human renaming step.
DESK_SLUG = {"municipal-boundary": "311", "parcel": "property-appraiser", "trash": "solid-waste", "recycling": "solid-waste",
             "bulky-waste": "solid-waste", "school-attendance": "school-district", "school-sites": "school-district",
             "parks": "parks", "libraries": "library", "voting": "elections", "representatives": "elections",
             "water-sewer": "water-utility", "public-safety": "police", "zoning": "planning", "flood": "emergency-management",
             "mosquito": "311", "transit": "transit", "311-history": "311"}
NATIONAL_DESKS = {"broadband": "us.fcc"}


def desk_id(pack: str, topic: str) -> str:
    """Pack-scoped desk id for a lookup topic, e.g. desk_id('us-zz-example', 'trash') -> 'us-zz-example.solid-waste'."""
    t = base_topic(topic)
    if t in NATIONAL_DESKS:
        return NATIONAL_DESKS[t]
    return f"{pack}.{DESK_SLUG.get(t, '311')}"


def pick_fields(topic: str, fields: list[dict[str, Any]]) -> list[str]:
    """The fields a lookup should read: those matching the topic's field regex plus name-like fields."""
    names = [f.get("name", "") for f in fields if f.get("type") not in ("esriFieldTypeGeometry", "esriFieldTypeOID", "esriFieldTypeGlobalID")]
    frx = TOPICS[base_topic(topic)][1]
    chosen = [n for n in names if (frx and re.search(frx, n, re.I)) or re.search(r"^name$|_name$|^name_|address|phone|grade|day|week|haul|provider|operator|agency|utility", n, re.I)]
    chosen = [n for n in chosen if not re.search(r"shape|objectid|globalid", n, re.I)]
    return (chosen or names[:6])[:10]
