import Foundation
import ADCore

// Listing Check (wow-factors plan, first swap-in for the Fee Check beat): before a rental deposit, the person says the
// address and the "landlord's" name; the county parcel layer says whether the owner of record matches.
// Rules: the owner's name is never shown, spoken, stored or returned from this file. Only matches / does not match /
// owned by a company is shared, plus a link to the county record. A mismatch is never called a scam. A condo without
// a unit gets no verdict. Nothing about owners is cached. Desks: ReportFraud.ftc.gov (FTC) and 311.
//
// This is the one place ADCityPack reaches the county directly: the phone sends only the normalized street address
// to the county (the claimed name never leaves the device), through a transport the app injects.

public enum ListingVerdict: String, Hashable, Sendable, CaseIterable {
    case matches
    case doesNotMatch = "does-not-match"
    case ownedByCompany = "owned-by-company"
    /// A condo building without a unit number: no verdict.
    case condoNeedsUnit = "condo-needs-unit"
    case noRecord = "no-record"
    /// More than one record or a claim the cached replay cannot judge: no verdict.
    case noVerdict = "no-verdict"

    public var lineKey: String { "regions.listing.verdict.\(rawValue)" }
    /// The follow-up step, only for the two outcomes that need one.
    public var adviceKey: String? {
        switch self {
        case .doesNotMatch: "regions.listing.advice.proof"
        case .ownedByCompany: "regions.listing.advice.company"
        case .matches, .condoNeedsUnit, .noRecord, .noVerdict: nil
        }
    }
    /// Whether the FTC rental-scam lines are read after the verdict.
    public var readsFTC: Bool { self == .doesNotMatch || self == .ownedByCompany }
}

/// Owner category from the record, decided in memory. Mirrors server/regionpacks/myad_regions/checks.py owner_kind.
public enum OwnerKind: String, Hashable, Sendable, Decodable {
    case government, company, person, unknown
}

public struct ListingClaim: Hashable, Sendable {
    public var address: String
    public var claimedName: String
    public init(address: String, claimedName: String) {
        self.address = address
        self.claimedName = claimedName
    }
}

public struct ListingCheckResult: Hashable, Sendable {
    public let folio: String?
    public let siteAddress: String?
    public let verdict: ListingVerdict
    public let claimedName: String
    public let retrievedAt: Date
    public let sourceURL: URL
    /// The county's own Property Search, the human check.
    public let recordURL: URL
    public let origin: CheckOrigin

    /// Grouped folio for display and speech ("01-4137-023-0020").
    public var groupedFolio: String? { folio.flatMap(ListingCheck.groupFolio) }

    public func lines(_ language: CheckLanguage, strings: some CheckStrings, ledger: CheckLedger) -> [String] {
        var out = [strings.text(verdict.lineKey, language, [claimedName])]
        if let advice = verdict.adviceKey { out.append(strings.text(advice, language)) }
        if verdict.readsFTC, let quote = ListingCheck.ftcSigns(language, ledger: ledger) {
            out.append(strings.text("regions.listing.ftc-says", language, [quote]))
        }
        let names = [ListingCheck.ftcDesk, FeeCheckIDs.fallbackDesk].map { id in
            ledger.desk(id).map { $0.names[language.rawValue] ?? $0.names["en"] ?? id } ?? id
        }
        out.append(strings.text("regions.listing.desks", language, names))
        return out
    }
}

public protocol ParcelFetching: Sendable {
    func get(_ url: URL) async throws -> Data
}

public enum ListingCheck {
    public static let layer = URL(string: "https://gisweb.miamidade.gov/arcgis/rest/services/MD_LandInformation/MapServer/26")!
    public static let recordPage = URL(string: "https://apps.miamidadepa.gov/propertysearch/")!
    public static let ftcDesk = "us.ftc"
    static let ownerFields = ["TRUE_OWNER1", "TRUE_OWNER2", "TRUE_OWNER3"]
    static let fields = ["FOLIO", "TRUE_SITE_ADDR", "TRUE_SITE_ZIP_CODE", "CONDO_FLAG", "DOR_DESC"] + ownerFields

    // MARK: Address

    private static let suffixes = ["AVENUE": "AVE", "AV": "AVE", "STREET": "ST", "ROAD": "RD", "COURT": "CT",
                                   "LANE": "LN", "PLACE": "PL", "TERRACE": "TER", "DRIVE": "DR", "BOULEVARD": "BLVD",
                                   "HIGHWAY": "HWY", "CIRCLE": "CIR", "PARKWAY": "PKWY"]
    private static let directions = ["NORTHWEST": "NW", "NORTHEAST": "NE", "SOUTHWEST": "SW", "SOUTHEAST": "SE",
                                     "NORTH": "N", "SOUTH": "S", "EAST": "E", "WEST": "W"]
    private static let unitWords: Set<String> = ["APT", "APARTMENT", "UNIT", "STE", "SUITE", "NO", "NUMBER", "NUMERO", "APTO", "PH"]

    /// Uppercase ASCII words (accents folded).
    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    public struct AddressKey: Hashable, Sendable {
        /// County TRUE_SITE_ADDR form: "111 NW 1 ST". Only [A-Z0-9 ], so it is safe inside the query.
        public let street: String
        public let zip: String?
        public let unit: String?
    }

    /// "111 Northwest 1st Street, Miami, FL 33128" -> street "111 NW 1 ST", zip "33128". Same rules as the server's
    /// street_key. Nil when there is no house number.
    public static func addressKey(_ address: String) -> AddressKey? {
        let parts = address.split(separator: ",", maxSplits: 1).map(String.init)
        var ws = words(parts.first ?? "")
        var unit: String?
        if let hash = (parts.first ?? "").firstIndex(of: "#") {
            unit = words(String((parts.first ?? "")[hash...])).first
            ws = words(String((parts.first ?? "")[..<hash]))
        } else if let i = ws.firstIndex(where: { unitWords.contains($0) }), i > 0 {
            unit = ws.count > i + 1 ? ws[i + 1] : nil
            ws = Array(ws[..<i])
        }
        ws = ws.map { w in
            var w = w
            if let r = w.range(of: #"^([0-9]+)(ST|ND|RD|TH)$"#, options: .regularExpression) { w = String(w[r].dropLast(2)) }
            return suffixes[w] ?? directions[w] ?? w
        }
        guard let first = ws.first, first.allSatisfy(\.isNumber) else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        let zip = rest.range(of: #"\b[0-9]{5}\b"#, options: .regularExpression).map { String(rest[$0]) }
        return AddressKey(street: ws.joined(separator: " "), zip: zip, unit: unit)
    }

    /// The layer query for an address. Reads owner fields so the verdict can be decided on the device.
    public static func queryURL(_ key: AddressKey) -> URL {
        var clauses = ["TRUE_SITE_ADDR LIKE '\(key.street)%'"]
        if let zip = key.zip { clauses.append("TRUE_SITE_ZIP_CODE LIKE '\(zip)%'") }
        var c = URLComponents(url: layer.appendingPathComponent("query"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "where", value: clauses.joined(separator: " AND ")),
            URLQueryItem(name: "outFields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json"),
        ]
        return c.url!
    }

    /// The same query without owner fields: the source link a person may open or share.
    public static func publicSourceURL(_ key: AddressKey) -> URL {
        var c = URLComponents(url: queryURL(key), resolvingAgainstBaseURL: false)!
        c.queryItems = c.queryItems?.map { $0.name == "outFields" ? URLQueryItem(name: "outFields", value: "FOLIO,TRUE_SITE_ADDR,CONDO_FLAG,DOR_DESC") : $0 }
        return c.url!
    }

    public static func groupFolio(_ folio: String) -> String? {
        let d = folio.filter(\.isNumber)
        guard d.count == 13 else { return nil }
        let a = d.prefix(2), b = d.dropFirst(2).prefix(4), c = d.dropFirst(6).prefix(3), e = d.suffix(4)
        return "\(a)-\(b)-\(c)-\(e)"
    }

    // MARK: Owner matching (in memory only)

    private static let company: Set<String> = ["LLC", "INC", "CORP", "CORPORATION", "CO", "COMPANY", "LP", "LLP", "LTD",
        "PA", "PLLC", "TRUST", "TR", "TRS", "TRUSTEE", "HOLDINGS", "PROPERTIES", "PROPERTY", "INVESTMENTS", "INVESTMENT",
        "GROUP", "PARTNERS", "PARTNERSHIP", "ASSOCIATION", "ASSN", "BANK", "FUND", "REALTY", "VENTURES", "ENTERPRISES",
        "MANAGEMENT", "MGMT", "CAPITAL", "ASSOCIATES", "FOUNDATION", "CHURCH", "MINISTRIES"]
    private static let government = ["COUNTY", "CITY OF", "STATE OF", "UNITED STATES", "SCHOOL BOARD", "HOUSING AUTHORITY",
        "BOARD OF", "DEPARTMENT OF", "DEPT OF", "TOWN OF", "VILLAGE OF", "INTERNAL IMPROVEMENT"]
    private static let governmentLandUse: Set<String> = ["COUNTY", "MUNICIPAL", "STATE", "FEDERAL"]
    /// Name particles that never count as a match on their own.
    private static let particles: Set<String> = ["DE", "DEL", "LA", "LAS", "LOS", "Y", "DA", "DOS", "DI", "VAN", "VON", "MR", "MRS", "MS", "SR", "SRA", "JR"]

    public static func ownerKind(owners: [String], landUse: String?) -> OwnerKind {
        let lines = owners.map { words($0) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .unknown }
        let joined = lines.map { " " + $0.joined(separator: " ") + " " }
        if joined.contains(where: { l in government.contains { l.contains(" \($0) ") } })
            || governmentLandUse.contains(words(landUse ?? "").first ?? "") { return .government }
        if lines.contains(where: { !Set($0).isDisjoint(with: company) }) { return .company }
        return .person
    }

    /// Tokens of the claimed name that count for matching.
    static func nameTokens(_ name: String) -> [String] {
        words(name).filter { $0.count >= 2 && !particles.contains($0) }
    }

    /// True when one owner line holds at least two of the claimed name's tokens (or the only one, for a one-word
    /// claim): "Carlos Pérez García" matches "PEREZ CARLOS"; "Carlos" alone matches a line containing CARLOS.
    static func nameMatches(_ claimed: String, owners: [String]) -> Bool {
        let tokens = Set(nameTokens(claimed))
        guard !tokens.isEmpty else { return false }
        let need = min(2, tokens.count)
        return owners.contains { tokens.intersection(words($0)).count >= need }
    }

    static func verdict(claimedName: String, owners: [String], kind: OwnerKind) -> ListingVerdict {
        switch kind {
        case .company: .ownedByCompany
        case .unknown: .noVerdict
        case .government, .person: nameMatches(claimedName, owners: owners) ? .matches : .doesNotMatch
        }
    }

    // MARK: Live

    /// Queries the county layer, decides the verdict in memory, and returns it without any owner text.
    public static func live(_ claim: ListingClaim, fetch: some ParcelFetching, now: @Sendable () -> Date = { Date() }) async throws -> ListingCheckResult {
        guard let key = addressKey(claim.address) else {
            return ListingCheckResult(folio: nil, siteAddress: nil, verdict: .noRecord, claimedName: claim.claimedName,
                                      retrievedAt: now(), sourceURL: layer, recordURL: recordPage, origin: .live)
        }
        let data = try await fetch.get(queryURL(key))
        let retrievedAt = now()
        let response = try JSONDecoder().decode(ParcelResponse.self, from: data)
        if response.error != nil { throw ListingCheckError.layerError }
        let exact = response.features.map(\.attributes).filter { words($0.site ?? "").joined(separator: " ") == key.street }
        let source = publicSourceURL(key)
        func result(_ a: ParcelAttributes?, _ v: ListingVerdict) -> ListingCheckResult {
            ListingCheckResult(folio: a?.folio, siteAddress: a?.site, verdict: v, claimedName: claim.claimedName,
                               retrievedAt: retrievedAt, sourceURL: source, recordURL: recordPage, origin: .live)
        }
        guard let first = exact.first else { return result(nil, .noRecord) }
        if exact.count > 1 || first.condo == "Y" && key.unit == nil {
            return result(exact.count == 1 ? first : nil, first.condo == "Y" ? .condoNeedsUnit : .noVerdict)
        }
        let owners = first.owners
        return result(first, verdict(claimedName: claim.claimedName, owners: owners, kind: ownerKind(owners: owners, landUse: first.landUse)))
    }

    public enum ListingCheckError: Error, Hashable, Sendable { case layerError }

    // Owner text lives only in these private values, inside `live`, and is dropped when it returns.
    private struct ParcelResponse: Decodable {
        struct Feature: Decodable { let attributes: ParcelAttributes }
        let features: [Feature]
        let error: ErrorBody?
        struct ErrorBody: Decodable { let code: Int? }
        private enum CodingKeys: String, CodingKey { case features, error }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
            error = try c.decodeIfPresent(ErrorBody.self, forKey: .error)
        }
    }

    private struct ParcelAttributes: Decodable {
        let folio: String?
        let site: String?
        let condo: String?
        let landUse: String?
        let owners: [String]
        private enum CodingKeys: String, CodingKey {
            case folio = "FOLIO", site = "TRUE_SITE_ADDR", condo = "CONDO_FLAG", landUse = "DOR_DESC"
            case o1 = "TRUE_OWNER1", o2 = "TRUE_OWNER2", o3 = "TRUE_OWNER3"
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            folio = try c.decodeIfPresent(String.self, forKey: .folio)
            site = try c.decodeIfPresent(String.self, forKey: .site)
            condo = try c.decodeIfPresent(String.self, forKey: .condo)
            landUse = try c.decodeIfPresent(String.self, forKey: .landUse)
            owners = try [CodingKeys.o1, .o2, .o3].compactMap { try c.decodeIfPresent(String.self, forKey: $0) }
        }
    }

    // MARK: Cached replay

    /// The bundled county-building response (folio 0141370230020), owner-free: it keeps the owner KIND only.
    public struct CachedParcel: Hashable, Sendable, Decodable {
        public let folio: String
        public let siteAddress: String
        public let siteZip: String?
        public let condo: Bool
        public let landUse: String?
        public let ownerKind: OwnerKind
        public let sourceID: String
        public let url: URL
        public let recordURL: URL
        public let retrievedAt: String
        private enum CodingKeys: String, CodingKey {
            case folio, condo, url
            case siteAddress = "site_address", siteZip = "site_zip", landUse = "land_use", ownerKind = "owner_kind"
            case sourceID = "source_id", recordURL = "record_url", retrievedAt = "retrieved_at"
        }

        public static func bundled() throws -> CachedParcel {
            guard let u = Bundle.module.url(forResource: "listing-county-building", withExtension: "json", subdirectory: "Checks") else {
                throw BundledRegionData.LoadError.missing("Checks/listing-county-building.json")
            }
            return try JSONDecoder().decode(CachedParcel.self, from: Data(contentsOf: u))
        }

        /// The replay verdict for a claim, from the owner kind alone. A company owner is "owned by a company"; a
        /// government owner does not match a person's name. Anything the kind cannot settle (a person owner, or a
        /// claim that is itself an agency name) gets no verdict rather than a guess.
        public func replay(_ claim: ListingClaim, because reason: CheckOrigin.FallbackReason) -> ListingCheckResult {
            let claimKind = ListingCheck.ownerKind(owners: [claim.claimedName], landUse: nil)
            let v: ListingVerdict = switch (ownerKind, claimKind) {
            case (.company, _): .ownedByCompany
            case (.government, .person): .doesNotMatch
            default: .noVerdict
            }
            return ListingCheckResult(folio: folio, siteAddress: siteAddress, verdict: v, claimedName: claim.claimedName,
                                      retrievedAt: RegionDates.timestamp(retrievedAt) ?? .distantPast, sourceURL: url,
                                      recordURL: recordURL, origin: .cachedReplay(because: reason))
        }
    }

    /// The saved county building is one demo address. Any other address gets no record rather than that building.
    public static func matchesCachedBuilding(_ claim: ListingClaim, _ cached: CachedParcel) -> Bool {
        guard let key = addressKey(claim.address) else { return false }
        let site = addressKey(cached.siteAddress)?.street ?? cached.siteAddress
        guard key.street == site else { return false }
        if let zip = key.zip, let cachedZip = cached.siteZip, zip != cachedZip { return false }
        return true
    }

    /// Live with the stage deadline. The labeled replay is only for the cached demo building.
    public static func run(_ claim: ListingClaim, fetch: some ParcelFetching, cached: CachedParcel,
                           deadline: Duration = FeeCheckRun.stageDeadline) async -> ListingCheckResult {
        let live = await CheckRace.live(deadline: deadline) { try await Self.live(claim, fetch: fetch) }
        switch live {
        case .success(let r): return r
        case .failure(let reason):
            guard matchesCachedBuilding(claim, cached) else {
                return ListingCheckResult(folio: nil, siteAddress: nil, verdict: .noRecord, claimedName: claim.claimedName,
                                          retrievedAt: Date(), sourceURL: recordPage, recordURL: recordPage,
                                          origin: .cachedReplay(because: reason))
            }
            return cached.replay(claim, because: reason)
        }
    }

    /// The FTC's rental-scam lines in the answer language when the ledger has that language, else English.
    public static func ftcSigns(_ language: CheckLanguage, ledger: CheckLedger) -> String? {
        let ids = language == .es ? ["us.ftc.rental-scam-signs.es", "us.ftc.rental-scam-signs"] : ["us.ftc.rental-scam-signs"]
        for id in ids { if case let .text(t, _)? = ledger.value(id) { return t } }
        return nil
    }
}
