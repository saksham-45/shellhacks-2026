# Onboarding gaps — us-fl-miamidade

Generated 2026-09-25T17:39:13-04:00 by `research.onboarding propose`.

Jurisdiction chain: United States (`us`, FIPS US) > Florida (`us-fl`, FIPS 12) > Miami-Dade County (`us-fl-miamidade`, FIPS 12086) > Miami city (`us-fl-miami`, FIPS 1245000)

Everything below was fetched in this run. Nothing is verified yet: each item needs a human/agent pass before it becomes a `verified` ledger fact.

## Florida (`us-fl`)

| need | status | best candidate |
| --- | --- | --- |
| desk: dmv | website only, phone not read | Florida Department of Highway Safety and Motor Vehicles: https://floridacrashportal.gov/, Florida Department of Highway Safety and Motor Vehicles: https://drivebakedgetbustedfl.gov/ |

## Miami-Dade County (`us-fl-miamidade`)

| need | status | best candidate |
| --- | --- | --- |
| municipal-boundary | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/MapCache/BaseMap/MapServer/36` Municipal |
| parcel | found (official, confidence 0.89) | `https://gis.miamidade.gov/arcgis/rest/services/AddressSearchMap_PropertiesWithZip/MapServer/1` Property |
| trash | found (official, confidence 1.0) | `https://gis.miamidade.gov/arcgis/rest/services/CommunityServices/MD_GarbageRecycle/MapServer/1` GarbagePickupRoute |
| recycling | found (official, confidence 1.0) | `https://gis.miamidade.gov/arcgis/rest/services/CommunityServices/MD_GarbageRecycle/MapServer/2` RecyclingRoute |
| school-attendance-elementary | found (official, confidence 0.78) | `https://services.arcgis.com/8Pc9XBTAsYuxx9Ny/arcgis/rest/services/ElementaryAttendanceBoundary_gdb/FeatureServer/0` ElementaryAttendanceBoundary |
| school-attendance-middle | found (official, confidence 0.78) | `https://services.arcgis.com/8Pc9XBTAsYuxx9Ny/arcgis/rest/services/MiddleAttendanceBoundary_gdb/FeatureServer/0` MiddleAttendanceBoundary |
| school-attendance-high | found (official, confidence 0.78) | `https://services.arcgis.com/8Pc9XBTAsYuxx9Ny/arcgis/rest/services/HighAttendanceBoundary_gdb/FeatureServer/0` HighAttendanceBoundary |
| school-sites | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/CommunityServices/MD_Educational/MapServer/1` Daycare |
| parks | found (official, confidence 0.56) | `https://gis.miamidade.gov/arcgis/rest/services/ParkFinder/MapServer/0` Parks |
| libraries | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/MD_Libraries/MapServer/3` MDC Libraries |
| voting | found (official, confidence 0.67) | `https://gis.miamidade.gov/arcgis/rest/services/MD_KnowWhereToVote/MapServer/3` Precinct |
| representatives | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/LandManagement/MD_CommissionDistrict/MapServer/0` CommissionDistrict |
| water-sewer | found (official, confidence 1.0) | `https://gis.miamidade.gov/arcgis/rest/services/Wasd/iMDCUtilityCoordination_1_v1/MapServer/11` Sewer |
| broadband | found (official, confidence 0.67) | `https://gis.miamidade.gov/arcgis/rest/services/CommunityServices/MD_RecreationCulture/MapServer/4` MDBroadbandProvider |
| public-safety | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/CommunityServices/MD_PublicSafety/MapServer/2` FireStation |
| zoning | found (official, confidence 0.78) | `https://gis.miamidade.gov/arcgis/rest/services/LandManagement/MD_ZoningLandManagementData/MapServer/0` Zoning Hearing |
| flood | found (official, confidence 0.56) | `https://gis.miamidade.gov/arcgis/rest/services/EnerGov/MD_LandMgtViewer/MapServer/64` FEMA Panels |
| 311-history | found (official, confidence 0.67) | `https://services.arcgis.com/8Pc9XBTAsYuxx9Ny/arcgis/rest/services/data_311_2023/FeatureServer/0` data_311_2023 |
| desk: 311 | found (phone candidate) | 311 phone on www.miamidade.gov: 311 https://www.miamidade.gov/global/home.page (+6 more) |
| desk: 211 | **missing** | - |
| desk: school-district | found (phone candidate) | MIAMI-DADE: 305-995-1000 https://nces.ed.gov/ccd/districtsearch/district_detail.asp?ID2=1200390 (+3 more) |
| desk: housing-authority | found (phone candidate) | HOUSING AUTHORITY OF THE CITY OF MIAMI BEACH: 305-532-6401 https://services.arcgis.com/VTyQ9soqVukalItT/arcgis/rest/services/Public_Housing_Authorities/FeatureServer/0 (+5 more) |
| desk: legal-aid | found (no phone) | Legal Services of Greater Miami, Inc. — Legal Services of Greater Miami Inc:  https://services3.arcgis.com/n7h3cEoHTyNCwjCf/arcgis/rest/services/LSC_offices_grantees_main_branch_(Public)/FeatureServer/0 |
| desk: license-and-tag-agent | found (phone candidate) | license-and-tag-agent phone on www.mdctaxcollector.gov: 305-375-5448 https://www.mdctaxcollector.gov/ (+3 more) |
| transit GTFS | found: 6 feed(s) | http://www.miamidade.gov/transit/googletransit/current/google_transit.zip, https://data.trilliumtransit.com/gtfs/miamibeach-fl-us/miamibeach-fl-us.zip, https://data.trilliumtransit.com/gtfs/miamigardens-fl-us/miamigardens-fl-us.zip, https://data.trilliumtransit.com/gtfs/brightline-fl-us/brightline-f |
| languages (ACS) | found | Spanish 67.0%, English only 24.3%, Haitian 3.7%, Portuguese 0.9%, French (incl. Cajun) 0.7% |

## Miami city (`us-fl-miami`)

| need | status | best candidate |
| --- | --- | --- |
| trash | found (official, confidence 1.0) | `https://services1.arcgis.com/CvuPhqcTQpZPT9qY/ArcGIS/rest/services/Trash_Routes/FeatureServer/0` Trash_Routes |
| parks | found (official, confidence 0.67) | `https://services1.arcgis.com/CvuPhqcTQpZPT9qY/ArcGIS/rest/services/City_Parks/FeatureServer/0` City_Parks |
| zoning | found (official, confidence 0.78) | `https://services1.arcgis.com/CvuPhqcTQpZPT9qY/ArcGIS/rest/services/M21_Zoning/FeatureServer/0` M21_Zoning |
| desk: 311 | found (phone candidate) | 311 phone on www.miami.gov: 305-468-5900 https://www.miami.gov/Home (+13 more) |

## Gaps reported by discoverers

- **languages** (`us-fl-miami`): city-level ACS languages need the Census API, which now requires a key (set CENSUS_API_KEY in the environment); county figures used instead Tried: https://api.census.gov/data/2024/acs/acs5
- **income-limits** (`us-fl-miamidade`): HUD income limits / FMR API needs a free token (HUD_API_TOKEN); not called by onboarding. Local program tables (city/state housing pages) must be read by a human or html-quote. Tried: https://www.huduser.gov/portal/dataset/fmr-api.html

## Run notes

- socrata domain datahub.transportation.gov matched 'Miami-Dade' but is not one of this chain's official domains; ignored
- socrata domain miami.demo.socrata.com matched 'Miami' but is not one of this chain's official domains; ignored
- socrata domain data.bayareametro.gov matched 'Miami' but is not one of this chain's official domains; ignored
- socrata domain data.cityofnewyork.us matched 'Miami' but is not one of this chain's official domains; ignored
- socrata domain opendata.maryland.gov matched 'Miami' but is not one of this chain's official domains; ignored
- socrata domain datahub.transportation.gov matched 'Miami' but is not one of this chain's official domains; ignored
- socrata domain www.datahub.va.gov matched 'Miami' but is not one of this chain's official domains; ignored
- https://gisweb.miamidade.gov/arcgis/rest/services serves the same directory as https://gis.miamidade.gov/arcgis/rest/services; not enumerated twice

## Rules this proposal followed

- Only URLs that were fetched in this run are recorded. Phones are recorded only with the text they were read from.
- Official = .gov/.mil host, a domain in the CISA .gov registry for this jurisdiction (or its registry contact domain), or a federal data host. Everything else is marked secondary.
- Every fact skeleton is `status: unsourced` with `value: null`; candidates are in `x-candidate`.
