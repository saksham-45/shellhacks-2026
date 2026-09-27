"""Region pack adapters (owner: myAD Regions).

Deterministic adapters that turn a resolved pin into sourced fact results. Adapters run on the
server only; the phone never calls ArcGIS (ARCHITECTURE.md §12). Stdlib only. The public entry
point is `server/regionpacks/runtime.py`.
"""
