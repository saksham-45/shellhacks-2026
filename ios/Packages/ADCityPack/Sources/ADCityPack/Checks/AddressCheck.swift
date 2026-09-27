import Foundation
import ADCore

// Who handles my address (FM-MYAD-ADDR, Discovery Batch 10 #1). One typed address; the county's no-key 311 map layers
// say which city (or unincorporated Miami-Dade) it is in, the trash days, the water and sewer utility, the zoned
// elementary school and the county police grid district. Police agency and Sheriff online-report coverage come from
// rules that ship `verified` only when Research's ledger quote names every area (address-rules.json, exported by
// server/regionpacks/myad_regions/address.py); otherwise the row says "ask 311".
// Rules: a row states only what a layer returned (or a verified rule derived from it); an empty or ambiguous layer
// becomes "not returned, ask 311". The school row always says "confirm with M-DCPS". Nothing is decided for the
// person: no school placement, no judgment on whether a crime can be reported online.
// Live path: the phone sends the typed address to the county locator and the resulting point to the 311 layers,
// through the transport the app injects (ParcelFetching). Nothing is stored. 4 s deadline, then the labeled cached
// county answer for a demo address, or "could not reach the county" for any other address.

// MARK: - Rules and layers (bundled)

public struct AddressRules: Sendable, Decodable {
    public struct LayerSpec: Sendable, Decodable, Hashable {
        public let key: String
        public let url: URL
        public let fields: [String]
        public let sourceID: String
        public let domainField: String?
        private enum CodingKeys: String, CodingKey { case key, url, fields, sourceID = "source_id", domainField = "domain_field" }

        /// Point-in-polygon (never identify). Same parameters, in the same order, as address.py Layer.query_url.
        public func queryURL(lat: Double, lon: Double) -> URL {
            var c = URLComponents(url: url.appendingPathComponent("query"), resolvingAgainstBaseURL: false)!
            c.queryItems = [
                URLQueryItem(name: "geometry", value: "\(lon),\(lat)"),
                URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
                URLQueryItem(name: "inSR", value: "4326"),
                URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
                URLQueryItem(name: "outFields", value: fields.joined(separator: ",")),
                URLQueryItem(name: "returnGeometry", value: "false"),
                URLQueryItem(name: "f", value: "json"),
            ]
            return c.url!
        }
        public var metadataURL: URL { URL(string: url.absoluteString + "?f=json")! }
    }

    public struct DomainSpec: Sendable, Decodable, Hashable {
        public let url: URL
        public let field: String
        public let sourceID: String
        private enum CodingKeys: String, CodingKey { case url, field, sourceID = "source_id" }
        public var metadataURL: URL { URL(string: url.absoluteString + "?f=json")! }
    }

    public struct Rule: Sendable, Decodable, Hashable {
        public let id: String
        public let fact: String
        public let status: String
        public let desk: String
        /// Areas the verified quote names (a partial quote confirms only these).
        public let municipalities: [String]
        /// Areas the rule is meant to cover that the quote does not name yet: never answered either way.
        public let unconfirmed: [String]
        public var isVerified: Bool { status == "verified" }
        private enum CodingKeys: String, CodingKey { case id, fact, status, desk, municipalities, unconfirmed }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); fact = try c.decode(String.self, forKey: .fact)
            status = try c.decode(String.self, forKey: .status); desk = try c.decode(String.self, forKey: .desk)
            municipalities = try c.decode([String].self, forKey: .municipalities)
            unconfirmed = try c.decodeIfPresent([String].self, forKey: .unconfirmed) ?? []
        }
    }

    public let layers: [LayerSpec]
    public let cityTrashDomain: DomainSpec
    public let rules: [Rule]
    public let onlineReportURLFact: String
    public let waterMeaningFact: String
    public let fallbackDesk: String
    public let schoolDesk: String
    private enum CodingKeys: String, CodingKey {
        case layers, rules
        case cityTrashDomain = "city_trash_domain", onlineReportURLFact = "online_report_url_fact"
        case waterMeaningFact = "water_meaning_fact", fallbackDesk = "fallback_desk", schoolDesk = "school_desk"
    }

    public func layer(_ key: AddressLayer) -> LayerSpec? { layers.first { $0.key == key.rawValue } }
    public func rule(_ id: String) -> Rule? { rules.first { $0.id == id } }

    public static func bundled() throws -> AddressRules {
        guard let u = Bundle.module.url(forResource: "address-rules", withExtension: "json", subdirectory: "Checks") else {
            throw BundledRegionData.LoadError.missing("Checks/address-rules.json")
        }
        return try JSONDecoder().decode(AddressRules.self, from: Data(contentsOf: u))
    }
}

public enum AddressLayer: String, CaseIterable, Sendable {
    case municipality
    case countyGarbage = "county-garbage", countyRecycling = "county-recycling", countyBulkyBook = "county-bulky-book"
    case water, sewer
    case cityGarbage = "city-garbage", cityRecycling = "city-recycling", cityBulky = "city-bulky"
    case elementary
    case policeGrid = "police-grid"
}

// MARK: - The county's raw answer (live or cached; one shape, one interpreter)

/// What the county returned for one address, minimized to the fields the card reads. The cached files
/// (Resources/Checks/address-pin-*.json) are this shape, recorded by scripts/refresh_address_fixtures.py.
public struct AddressRaw: Sendable, Codable, Hashable {
    public struct Located: Sendable, Codable, Hashable {
        public let url: URL
        public let retrievedAt: String
        public let matched: String
        public let addrType: String
        public let score: Double
        public let lat: Double
        public let lon: Double
        private enum CodingKeys: String, CodingKey {
            case url, matched, score, lat, lon
            case retrievedAt = "retrieved_at", addrType = "addr_type"
        }
    }
    public struct LayerAnswer: Sendable, Codable, Hashable {
        public let url: URL
        public let retrievedAt: String
        /// Attribute values as text (numbers are written without a fraction when whole).
        public let features: [[String: String]]
        private enum CodingKeys: String, CodingKey { case url, features, retrievedAt = "retrieved_at" }

        public init(url: URL, retrievedAt: String, features: [[String: String]]) {
            self.url = url; self.retrievedAt = retrievedAt; self.features = features
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(URL.self, forKey: .url)
            retrievedAt = try c.decode(String.self, forKey: .retrievedAt)
            features = try c.decode([[String: AttributeText]].self, forKey: .features).map { $0.mapValues(\.text) }
        }
    }
    public struct Domain: Sendable, Codable, Hashable {
        public let url: URL
        public let retrievedAt: String
        public let field: String
        public let codes: [String: String]
        private enum CodingKeys: String, CodingKey { case url, field, codes, retrievedAt = "retrieved_at" }
    }

    public let address: String
    public let locator: Located
    public let layers: [String: LayerAnswer]
    public let domains: [String: Domain]

    public func layer(_ key: AddressLayer) -> LayerAnswer? { layers[key.rawValue] }
}

/// An ArcGIS attribute value (string, number or bool) read as text; null is dropped by the caller.
struct AttributeText: Codable, Hashable {
    let text: String
    init(_ text: String) { self.text = text }
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d) }
        else if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported attribute value") }
    }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
}

/// A cached county answer for a demo pin.
public struct AddressCached: Sendable, Decodable, Hashable {
    public let pinID: String
    public let raw: AddressRaw
    private enum CodingKeys: String, CodingKey { case pinID = "pin_id", address, locator, layers, domains }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinID = try c.decode(String.self, forKey: .pinID)
        raw = AddressRaw(address: try c.decode(String.self, forKey: .address),
                         locator: try c.decode(AddressRaw.Located.self, forKey: .locator),
                         layers: try c.decode([String: AddressRaw.LayerAnswer].self, forKey: .layers),
                         domains: try c.decode([String: AddressRaw.Domain].self, forKey: .domains))
    }

    public static let demoPins = ["pin-sw137", "pin-nw1st"]

    public static func bundled() throws -> [AddressCached] {
        try demoPins.map { pin in
            guard let u = Bundle.module.url(forResource: "address-\(pin)", withExtension: "json", subdirectory: "Checks") else {
                throw BundledRegionData.LoadError.missing("Checks/address-\(pin).json")
            }
            return try JSONDecoder().decode(AddressCached.self, from: Data(contentsOf: u))
        }
    }

    /// Whether a typed address is this demo address (same street key and ZIP as ListingCheck uses).
    public func matches(_ typed: String) -> Bool {
        guard let a = ListingCheck.addressKey(typed), let b = ListingCheck.addressKey(raw.address) else { return false }
        return a.street == b.street && (a.zip == nil || a.zip == b.zip)
    }
}

// MARK: - The answer

public struct AddressSource: Sendable, Hashable {
    public let url: URL
    public let retrievedAt: Date
    /// The field(s) as the layer returned them ("NAME: MIAMI"), for the source chip.
    public let quote: String
}

public enum AddressTopic: String, Sendable, Hashable, CaseIterable {
    case government, police, onlineReport = "online-report", garbage, recycling, bulky, water, sewer, school
}

public enum AddressFinding: Sendable, Hashable {
    /// The Municipality Name layer's NAME ("MIAMI", "UNINCORPORATED MIAMI-DADE", ...).
    case municipality(String)
    /// A verified rule names the agency for this municipality.
    case policeAgency(desk: String)
    /// The county police grid district (shown only under a Sheriff answer).
    case policeDistrict(String)
    /// No verified rule for this municipality (or the rule is not verified yet).
    case policeAskFallback
    case onlineReport(covered: Bool)
    case garbage(days: [Weekday], label: String)
    case recycling(day: Weekday?, week: String?, label: String)
    case bulkyDays([Weekday], code: String)
    case bulkyBook(String)
    /// `name` is the layer's own coded-value name when it has one, else the code as returned.
    case utility(name: String, desk: String?)
    case school(name: String, address: String?, phone: String?, grades: String?)
    /// The layer returned nothing, more than one answer, or a value the card cannot read without guessing.
    case notReturned
}

public struct AddressRow: Sendable, Hashable {
    public let topic: AddressTopic
    public let finding: AddressFinding
    /// The layer answer (and rule, when one was used) behind this row; nil for "not returned".
    public let source: AddressSource?
    /// Verified rule fact used, if any (its quote is in the check ledger).
    public let ruleFact: String?
}

public struct AddressCheckResult: Sendable, Hashable {
    public let typedAddress: String
    /// The county locator's matched address ("111 NW 1ST ST, MIAMI, 33128").
    public let matchedAddress: String
    public let rows: [AddressRow]
    public let origin: CheckOrigin
    /// When the county answered (the oldest layer time); a replay shows this date.
    public let retrievedAt: Date

    public func row(_ topic: AddressTopic) -> [AddressRow] { rows.filter { $0.topic == topic } }
}

public enum AddressRunOutcome: Sendable, Hashable {
    case answer(AddressCheckResult)
    /// The address has no 5-digit ZIP; the county locator returns equal-score matches in other cities without one.
    case needsZIP
    /// The county locator has no PointAddress match at score 95 or more.
    case notFound
    /// The live path failed or timed out and this address has no cached answer. The replay chip still offers the demos.
    case unavailable(because: CheckOrigin.FallbackReason)
}

// MARK: - Interpretation (pure)

public enum AddressCheck {
    public static let minimumScore = 95.0
    public static let locator = URL(string: "https://gisws.miamidade.gov/arcgis/rest/services/MDC_LocatorsPro/MD_Locator/GeocodeServer/findAddressCandidates")!

    static let weekdayNames: [String: Weekday] = [
        "MONDAY": .monday, "TUESDAY": .tuesday, "WEDNESDAY": .wednesday, "THURSDAY": .thursday, "FRIDAY": .friday,
        "SATURDAY": .saturday, "SUNDAY": .sunday,
        "MON": .monday, "TUE": .tuesday, "WED": .wednesday, "THU": .thursday, "FRI": .friday, "SAT": .saturday, "SUN": .sunday,
    ]

    /// "Tuesday Friday", "MON/THU", "Mon and Thu" -> days, only when every other word is a weekday name; else nil.
    static func weekdays(_ label: String) -> [Weekday]? {
        let ws = ListingCheck.words(label).filter { $0 != "AND" }
        let days = ws.compactMap { weekdayNames[$0] }
        return !ws.isEmpty && days.count == ws.count ? days : nil
    }

    /// The one distinct value set a layer returned for `fields`; nil when empty or when features disagree.
    static func single(_ answer: AddressRaw.LayerAnswer?, _ fields: [String]) -> [String: String]? {
        guard let answer else { return nil }
        let distinct = Set(answer.features.map { f in fields.compactMap { k in f[k].map { "\(k)=\($0)" } } })
        guard distinct.count == 1, let f = answer.features.first, fields.contains(where: { f[$0] != nil }) else { return nil }
        return f.filter { fields.contains($0.key) }
    }

    static func source(_ answer: AddressRaw.LayerAnswer, _ values: [String: String], fields: [String], extra: String? = nil) -> AddressSource {
        let quote = fields.compactMap { k in values[k].map { "\(k): \($0)" } }.joined(separator: "; ") + (extra.map { " (\($0))" } ?? "")
        return AddressSource(url: answer.url, retrievedAt: RegionDates.timestamp(answer.retrievedAt) ?? .distantPast, quote: quote)
    }

    public static func interpret(_ raw: AddressRaw, typed: String, rules: AddressRules, ledger: CheckLedger,
                                 origin: CheckOrigin) -> AddressCheckResult {
        var rows: [AddressRow] = []
        func add(_ t: AddressTopic, _ f: AddressFinding, _ s: AddressSource? = nil, rule: String? = nil) {
            rows.append(AddressRow(topic: t, finding: f, source: s, ruleFact: rule))
        }

        // Government
        let muniAnswer = raw.layer(.municipality)
        let muni = single(muniAnswer, ["NAME"])?["NAME"]
        if let muni, let muniAnswer { add(.government, .municipality(muni), source(muniAnswer, ["NAME": muni], fields: ["NAME"])) }
        else { add(.government, .notReturned) }

        // Police agency, district, online report
        let policeRule = muni.flatMap { m in rules.rules.first { $0.id.hasPrefix("police.") && $0.isVerified && $0.municipalities.contains(m) } }
        if let muni, let muniAnswer, let policeRule {
            add(.police, .policeAgency(desk: policeRule.desk), source(muniAnswer, ["NAME": muni], fields: ["NAME"]), rule: policeRule.fact)
            if policeRule.id == "police.sheriff", let grid = raw.layer(.policeGrid), let d = single(grid, ["DISTNAME"])?["DISTNAME"] {
                add(.police, .policeDistrict(d), source(grid, ["DISTNAME": d], fields: ["DISTNAME"]))
            }
        } else {
            add(.police, .policeAskFallback)
        }
        if let muni, let muniAnswer, let online = rules.rule("online-report"), online.isVerified, !online.unconfirmed.contains(muni) {
            add(.onlineReport, .onlineReport(covered: online.municipalities.contains(muni)),
                source(muniAnswer, ["NAME": muni], fields: ["NAME"]), rule: online.fact)
        } else {
            add(.onlineReport, .notReturned)
        }

        // Trash: the City of Miami layers for a MIAMI address, the county layers otherwise; whichever answered.
        let cityAnswered = [AddressLayer.cityGarbage, .cityRecycling, .cityBulky].contains { !(raw.layer($0)?.features.isEmpty ?? true) }
        let countyAnswered = [AddressLayer.countyGarbage, .countyRecycling, .countyBulkyBook].contains { !(raw.layer($0)?.features.isEmpty ?? true) }
        let useCity = cityAnswered && (muni == "MIAMI" || !countyAnswered)
        if useCity {
            if let a = raw.layer(.cityGarbage), let v = single(a, ["GRAPCKDAYS"]), let label = v["GRAPCKDAYS"], let days = weekdays(label) {
                add(.garbage, .garbage(days: days, label: label), source(a, v, fields: ["GRAPCKDAYS"]))
            } else { add(.garbage, .notReturned) }
            if let a = raw.layer(.cityRecycling), let v = single(a, ["RECYROUTE"]), let label = v["RECYROUTE"] {
                let day = ListingCheck.words(label).first.flatMap { weekdayNames[$0] }
                add(.recycling, .recycling(day: day, week: nil, label: label), source(a, v, fields: ["RECYROUTE"]))
            } else { add(.recycling, .notReturned) }
            if let a = raw.layer(.cityBulky), let v = single(a, ["TRASHDAY"]), let code = v["TRASHDAY"],
               let domain = raw.domains[AddressLayer.cityBulky.rawValue], let name = domain.codes[code],
               let days = weekdays(name) {
                add(.bulky, .bulkyDays(days, code: code), source(a, v, fields: ["TRASHDAY"], extra: "City of Miami code list: \(name)"))
            } else { add(.bulky, .notReturned) }
        } else if countyAnswered {
            if let a = raw.layer(.countyGarbage), let v = single(a, ["WEEKDAYS"]), let label = v["WEEKDAYS"], let days = weekdays(label) {
                add(.garbage, .garbage(days: days, label: label), source(a, v, fields: ["WEEKDAYS"]))
            } else { add(.garbage, .notReturned) }
            if let a = raw.layer(.countyRecycling), let v = single(a, ["WEEKDAY", "PICKUPWEEK"]), let label = v["WEEKDAY"],
               let day = weekdayNames[label.uppercased()] {
                add(.recycling, .recycling(day: day, week: v["PICKUPWEEK"], label: label), source(a, v, fields: ["WEEKDAY", "PICKUPWEEK"]))
            } else { add(.recycling, .notReturned) }
            if let a = raw.layer(.countyBulkyBook), let v = single(a, ["LABEL"]), let book = v["LABEL"] {
                add(.bulky, .bulkyBook(book), source(a, v, fields: ["LABEL"]))
            } else { add(.bulky, .notReturned) }
        } else {
            for t in [AddressTopic.garbage, .recycling, .bulky] { add(t, .notReturned) }
        }

        // Water and sewer: the layer's own code list names the utility; MDWS maps to the WASD desk by a verified fact.
        let mdwsVerified = ledger.fact(rules.waterMeaningFact)?.status == .verified
        for (topic, key) in [(AddressTopic.water, AddressLayer.water), (.sewer, .sewer)] {
            if let a = raw.layer(key), let v = single(a, ["UTILITYNAME"]), let code = v["UTILITYNAME"] {
                let name = raw.domains[key.rawValue]?.codes[code] ?? code
                add(topic, .utility(name: name, desk: code == "MDWS" && mdwsVerified ? "us-fl-miamidade.wasd" : nil),
                    source(a, v, fields: ["UTILITYNAME"], extra: name == code ? nil : "layer code list: \(name)"),
                    rule: code == "MDWS" && mdwsVerified ? rules.waterMeaningFact : nil)
            } else { add(topic, .notReturned) }
        }

        // School (always "confirm with M-DCPS")
        let schoolFields = ["DISPLAYNAME", "ADDRESS", "CITY", "ZIPCODE", "PHONE", "GRADES"]
        if let a = raw.layer(.elementary), let v = single(a, schoolFields), let name = v["DISPLAYNAME"] {
            let addr = [v["ADDRESS"], v["CITY"], v["ZIPCODE"]].compactMap { $0 }.joined(separator: ", ")
            add(.school, .school(name: name, address: addr.isEmpty ? nil : addr, phone: v["PHONE"], grades: v["GRADES"]),
                source(a, v, fields: schoolFields))
        } else { add(.school, .notReturned) }

        let dates = raw.layers.values.compactMap { RegionDates.timestamp($0.retrievedAt) }
        return AddressCheckResult(typedAddress: typed, matchedAddress: raw.locator.matched, rows: rows, origin: origin,
                                  retrievedAt: dates.min() ?? RegionDates.timestamp(raw.locator.retrievedAt) ?? .distantPast)
    }
}

// MARK: - Live and run

extension AddressCheck {
    public enum LiveError: Error, Hashable, Sendable { case layerError(String), badLocatorResponse }

    enum LiveOutcome: Sendable { case raw(AddressRaw), needsZIP, notFound }

    public static func locatorURL(_ address: String) -> URL {
        var c = URLComponents(url: locator, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "SingleLine", value: address), URLQueryItem(name: "outFields", value: "Addr_type,Score"),
                        URLQueryItem(name: "maxLocations", value: "5"), URLQueryItem(name: "outSR", value: "4326"),
                        URLQueryItem(name: "f", value: "json")]
        return c.url!
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    static func live(_ typed: String, rules: AddressRules, fetch: some ParcelFetching,
                     now: @escaping @Sendable () -> Date) async throws -> LiveOutcome {
        guard ListingCheck.addressKey(typed)?.zip != nil else { return .needsZIP }
        let locURL = locatorURL(typed)
        let locData = try await fetch.get(locURL)
        guard let cands = try? JSONDecoder().decode(ArcCandidates.self, from: locData).candidates else { throw LiveError.badLocatorResponse }
        guard let best = cands.filter({ $0.attributes.Addr_type == "PointAddress" }).max(by: { $0.score < $1.score }),
              best.score >= minimumScore else { return .notFound }
        let located = AddressRaw.Located(url: locURL, retrievedAt: stamp(now()), matched: best.address, addrType: "PointAddress",
                                         score: best.score, lat: best.location.y, lon: best.location.x)

        let answers = try await withThrowingTaskGroup(of: (String, AddressRaw.LayerAnswer).self) { group in
            for spec in rules.layers {
                group.addTask {
                    let url = spec.queryURL(lat: located.lat, lon: located.lon)
                    let body = try JSONDecoder().decode(ArcLayerBody.self, from: try await fetch.get(url))
                    if body.error != nil { throw LiveError.layerError(spec.key) }
                    let feats = (body.features ?? []).map { f in
                        var kept: [String: String] = [:]
                        for k in spec.fields { if let v = f.attributes[k] ?? nil, !v.text.trimmingCharacters(in: .whitespaces).isEmpty { kept[k] = v.text } }
                        return kept
                    }
                    return (spec.key, AddressRaw.LayerAnswer(url: url, retrievedAt: stamp(now()), features: feats))
                }
            }
            var out: [String: AddressRaw.LayerAnswer] = [:]
            for try await (k, a) in group { out[k] = a }
            return out
        }

        // Code lists: the layer's own metadata; for City bulky trash, the City trash layer's list for the same field.
        var wanted: [(key: String, url: URL, field: String)] = rules.layers.compactMap { spec in
            guard let field = spec.domainField, !(answers[spec.key]?.features.isEmpty ?? true) else { return nil }
            return (spec.key, spec.metadataURL, field)
        }
        if !(answers[AddressLayer.cityBulky.rawValue]?.features.isEmpty ?? true) {
            wanted.append((AddressLayer.cityBulky.rawValue, rules.cityTrashDomain.metadataURL, rules.cityTrashDomain.field))
        }
        var domains: [String: AddressRaw.Domain] = [:]
        await withTaskGroup(of: (String, AddressRaw.Domain)?.self) { group in
            for w in wanted {
                group.addTask {
                    // A code list that fails to load leaves the code unread ("not returned"), never guessed.
                    guard let data = try? await fetch.get(w.url), let meta = try? JSONDecoder().decode(ArcMeta.self, from: data),
                          let cvs = meta.fields?.first(where: { $0.name == w.field })?.domain?.codedValues else { return nil }
                    let codes = Dictionary(cvs.map { ($0.code.text, $0.name.text) }, uniquingKeysWith: { a, _ in a })
                    return (w.key, AddressRaw.Domain(url: w.url, retrievedAt: stamp(now()), field: w.field, codes: codes))
                }
            }
            for await d in group { if let d { domains[d.0] = d.1 } }
        }
        return .raw(AddressRaw(address: typed, locator: located, layers: answers, domains: domains))
    }

    /// Live with the stage deadline. A demo address falls back to its labeled cached county answer.
    public static func run(_ typed: String, rules: AddressRules, ledger: CheckLedger, fetch: some ParcelFetching,
                           cached: [AddressCached], deadline: Duration = FeeCheckRun.stageDeadline,
                           now: @escaping @Sendable () -> Date = { Date() }) async -> AddressRunOutcome {
        let result = await CheckRace.live(deadline: deadline) { try await live(typed, rules: rules, fetch: fetch, now: now) }
        switch result {
        case .success(.raw(let raw)):
            return .answer(interpret(raw, typed: typed, rules: rules, ledger: ledger, origin: .live))
        case .success(.needsZIP): return .needsZIP
        case .success(.notFound): return .notFound
        case .failure(let reason):
            guard let hit = cached.first(where: { $0.matches(typed) }) else { return .unavailable(because: reason) }
            return .answer(interpret(hit.raw, typed: typed, rules: rules, ledger: ledger, origin: .cachedReplay(because: reason)))
        }
    }

    /// The replay chip: the presenter picks a demo address; no network.
    public static func replay(_ cached: AddressCached, rules: AddressRules, ledger: CheckLedger) -> AddressCheckResult {
        interpret(cached.raw, typed: cached.raw.address, rules: rules, ledger: ledger, origin: .cachedReplay(because: .chosen))
    }
}


// ArcGIS JSON bodies read by the live path.
struct ArcCandidates: Decodable {
    struct C: Decodable {
        struct L: Decodable { let x: Double; let y: Double }
        struct A: Decodable { let Addr_type: String? }
        let address: String; let location: L; let score: Double; let attributes: A
    }
    let candidates: [C]?
}
struct ArcLayerBody: Decodable {
    struct F: Decodable { let attributes: [String: AttributeText?] }
    let features: [F]?
    let error: [String: AttributeText?]?
}
struct ArcMeta: Decodable {
    struct Field: Decodable {
        struct D: Decodable { struct CV: Decodable { let name: AttributeText; let code: AttributeText }; let codedValues: [CV]? }
        let name: String; let domain: D?
    }
    let fields: [Field]?
}

// MARK: - Lines (screen and speech)

extension AddressCheckResult {
    public func lines(_ language: CheckLanguage, strings: some CheckStrings, ledger: CheckLedger, rules: AddressRules) -> [String] {
        func deskName(_ id: String) -> String {
            ledger.desk(id).map { $0.names[language.rawValue] ?? $0.names["en"] ?? id } ?? id
        }
        func deskPhone(_ id: String) -> String? {
            guard let entry = ledger.desk(id),
                  let f = entry.desk.contactFacts.first(where: { $0.rawValue.hasSuffix(".phone") }).flatMap({ ledger.facts[$0] }),
                  case let .phone(d)? = f.displayValue else { return nil }
            return CheckPhone.spaced(d)
        }
        func desk(_ id: String) -> String {
            deskPhone(id).map { strings.text("regions.address.desk-phone", language, [deskName(id), $0]) } ?? deskName(id)
        }
        func day(_ d: Weekday) -> String { strings.text("regions.address.day.\(d.rawValue)", language) }
        func days(_ ds: [Weekday]) -> String {
            guard ds.count > 1, let last = ds.last else { return ds.first.map(day) ?? "" }
            return strings.text("regions.address.days-and", language, [ds.dropLast().map(day).joined(separator: ", "), day(last)])
        }
        let fallback = desk(rules.fallbackDesk)

        var out: [String] = []
        for row in rows {
            switch (row.topic, row.finding) {
            case let (_, .municipality(name)):
                out.append(name == "UNINCORPORATED MIAMI-DADE"
                           ? strings.text("regions.address.unincorporated", language)
                           : strings.text("regions.address.municipality", language, [AddressFormat.title(name)]))
            case let (_, .policeAgency(id)):
                out.append(strings.text("regions.address.police", language, [desk(id)]))
            case let (_, .policeDistrict(d)):
                out.append(strings.text("regions.address.police-district", language, [AddressFormat.title(d)]))
            case (_, .policeAskFallback):
                out.append(strings.text("regions.address.police-ask", language, [fallback]))
            case let (_, .onlineReport(covered)):
                if covered {
                    let url: String = { if case let .code(u)? = ledger.value(rules.onlineReportURLFact) { return u }; return deskName("us-fl-miamidade.sheriff") }()
                    out.append(strings.text("regions.address.online-report.yes", language, [url]))
                } else {
                    out.append(strings.text("regions.address.online-report.no", language))
                }
            case let (_, .garbage(ds, _)):
                out.append(strings.text("regions.address.garbage", language, [days(ds)]))
            case let (_, .recycling(d, week, label)):
                if let d, let week { out.append(strings.text("regions.address.recycling-week", language, [day(d), week])) }
                else if let d { out.append(strings.text("regions.address.recycling-route", language, [day(d), label])) }
                else { out.append(strings.text("regions.address.recycling-label", language, [label])) }
            case let (_, .bulkyDays(ds, _)):
                out.append(strings.text("regions.address.bulky-day", language, [days(ds)]))
            case let (_, .bulkyBook(book)):
                out.append(strings.text("regions.address.bulky-book", language, [book, fallback]))
            case let (topic, .utility(name, deskID)):
                let key = topic == .water ? "regions.address.water" : "regions.address.sewer"
                out.append(strings.text(key, language, [deskID.map(desk) ?? name]))
            case let (_, .school(name, addr, phone, grades)):
                let detail = [addr, phone, grades.map { strings.text("regions.address.grades", language, [$0]) }].compactMap { $0 }.joined(separator: ", ")
                out.append(detail.isEmpty ? strings.text("regions.address.school-name", language, [name])
                                          : strings.text("regions.address.school", language, [name, detail]))
                out.append(strings.text("regions.address.school-confirm", language, [desk(rules.schoolDesk)]))
            case let (topic, .notReturned):
                out.append(strings.text("regions.address.not-returned.\(topic.rawValue)", language, [fallback]))
            }
        }
        if case .cachedReplay = origin {
            out.append(strings.text("regions.address.cached", language, [AddressFormat.day(retrievedAt)]))
        }
        return out
    }
}

public enum AddressFormat {
    /// "UNINCORPORATED MIAMI-DADE" -> "Unincorporated Miami-Dade"; "HAMMOCKS" -> "Hammocks". Letters only change case.
    public static func title(_ s: String) -> String {
        s.lowercased().split(separator: " ", omittingEmptySubsequences: false).map { w in
            w.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
    }
    /// "2026-09-25" in the device's zone, for the replay label.
    public static func day(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}
