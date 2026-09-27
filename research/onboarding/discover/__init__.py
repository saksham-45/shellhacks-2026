"""Pluggable discoverers. Each is a class with name, needs, and run(ctx)."""
from .base import Context, Discoverer, run_all  # noqa: F401


def default_discoverers() -> list["Discoverer"]:
    from .arcgis import ArcGISOnlineDiscoverer, ArcGISProbeDiscoverer, ArcGISRestDiscoverer
    from .dotgov import DotGovDiscoverer
    from .federal import AcsLanguageDiscoverer, HudDiscoverer, LegalAidDiscoverer, NcesDistrictDiscoverer
    from .gtfs import MobilityDatabaseDiscoverer
    from .portals import SocrataDiscoverer
    from .website import WebsiteDiscoverer

    # cheap national catalogs first; the REST enumeration (the big spender) runs last
    return [DotGovDiscoverer(), WebsiteDiscoverer(), ArcGISProbeDiscoverer(), ArcGISOnlineDiscoverer(),
            SocrataDiscoverer(), MobilityDatabaseDiscoverer(), AcsLanguageDiscoverer(), HudDiscoverer(),
            NcesDistrictDiscoverer(), LegalAidDiscoverer(), ArcGISRestDiscoverer()]
