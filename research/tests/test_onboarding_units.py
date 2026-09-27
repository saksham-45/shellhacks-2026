"""Pure unit tests for onboarding pieces (no network)."""
from pathlib import Path

from research.onboarding.compare import parse_plan
from research.onboarding.model import base_name, slug
from research.onboarding.taxonomy import classify_layer, lookup_method, pick_fields


def test_slug_and_base_name():
    assert base_name("Miami-Dade County") == "Miami-Dade"
    assert slug("Miami-Dade County") == "miamidade"
    assert slug("Miami city") == "miami"
    assert slug("Travis County") == "travis"


def test_classify_generic_layers():
    top = classify_layer("CommunityServices/MD_GarbageRecycle", "GarbagePickupRoute", ["WEEKDAYS", "ROUTE"], "esriGeometryPolygon")
    assert top[0].topic == "trash"
    rec = classify_layer("CommunityServices/MD_GarbageRecycle", "RecyclingRoute", ["WEEKDAY", "PICKUPWEEK"], "esriGeometryPolygon")
    assert rec[0].topic == "recycling"
    sch = classify_layer("Schools", "Elementary School Attendance Boundary", ["NAME", "PHONE", "GRADES"], "esriGeometryPolygon")
    assert sch[0].topic == "school-attendance-elementary"
    muni = classify_layer("Boundaries", "Municipality", ["NAME", "MUNICID"], "esriGeometryPolygon")
    assert muni[0].topic == "municipal-boundary"
    assert classify_layer("Misc", "Tree canopy 2016", ["PCT"], "esriGeometryPolygon") == []


def test_lookup_method_and_fields():
    assert "point-in-polygon" in lookup_method("trash", "esriGeometryPolygon")
    assert "buffered" in lookup_method("parcel", "esriGeometryPoint")
    fields = [{"name": "OBJECTID", "type": "esriFieldTypeOID"}, {"name": "WEEKDAYS", "type": "esriFieldTypeString"},
              {"name": "SHAPE", "type": "esriFieldTypeGeometry"}, {"name": "ROUTE", "type": "esriFieldTypeString"}]
    assert pick_fields("trash", fields) == ["WEEKDAYS", "ROUTE"]


def test_parse_plan_extracts_services_layers_and_urls(tmp_path):
    md = tmp_path / "plan.md"
    md.write_text(
        "| Which city | `MD_MDPDViewer/MapServer` | 8 Municipality polygons. `NAME` |\n"
        "| Trash | `CommunityServices/MD_GarbageRecycle/MapServer` | 1 GarbagePickupRoute. 2 RecyclingRoute |\n"
        "| Transit realtime | `BusMetro_RealTime/BusRealTime` | Listed. |\n"
        "- GMX toll PDF: `https://gmx-way.com/pdf/Toll_Rate_Schedule.pdf`\n")
    items = parse_plan(md.read_text())
    refs = {i.ref: i for i in items}
    assert refs["MD_MDPDViewer/MapServer"].layers == [8]
    assert refs["CommunityServices/MD_GarbageRecycle/MapServer"].layers == [1, 2]
    assert "BusMetro_RealTime/BusRealTime" in refs
    assert "https://gmx-way.com/pdf/Toll_Rate_Schedule.pdf" in refs


def test_negative_names_are_penalized():
    good = classify_layer("Parks", "City_Parks", ["NAME"], "esriGeometryPolygon")
    bad = classify_layer("Palmer_Lake_and_Melrose_Park_Annexation_Area", "Palmer_Lake_and_Melrose_Park_Annexation_Area", ["NAME"], "esriGeometryPolygon")
    assert good and good[0].topic == "parks"
    assert not bad or bad[0].score < good[0].score
