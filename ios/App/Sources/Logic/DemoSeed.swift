import Foundation
import Synchronization
import ADCore
import ADRouter
import ADCityPack

/// `-myadSeed demoHousehold`: a clearly fake household on myAD Regions' two demo pins. No real
/// person, no invented value: every fact shown comes from ADCityPack's bundled demo answers
/// (status `demo`, labelled "Example" on screen), and card titles say "demo".
public enum DemoSeed {
    /// Access's pin option ids (`a11y.pin.option.<id>`) and the Regions fixture each maps to.
    public static let kendall: PinID = "kendall"
    public static let downtown: PinID = "downtown"
    static let regionPinIDs: [PinID: PinID] = [kendall: "pin-sw137", downtown: "pin-nw1st"]

    public static let desk311: DeskID = "us-fl-miamidade.311"
    public static let desk211: DeskID = "us-fl-miamidade.211"
    public static let deskLegalAid: DeskID = "us-fl-miamidade.legal-aid"
    public static let deskImmigrationLegal: DeskID = "us-fl-miamidade.immigration-legal-aid"
    /// Access's `A11ySeed.phoneCardID`, and the router's offline card.
    public static let officesCard: CardID = "offices"

    /// The two pins, with coordinates and addresses from Regions' fixtures (never typed here).
    public static func pins() -> [PinChoice] {
        let answers = (try? BundledRegionData.demoPins()) ?? []
        return [kendall, downtown].compactMap { id in
            guard let a = answers.first(where: { $0.pinID == regionPinIDs[id] }) else { return nil }
            return PinChoice(id: id, label: RouterText.verbatim(a.pin.address ?? id.rawValue), pin: a.asPin)
        }
    }

    /// Two people, student + parent, on the Kendall pin. Names say "Demo"; ages are round examples.
    public static func household(pins: [PinChoice]) -> Household? {
        guard let pin = pins.first(where: { $0.id == kendall })?.pin else { return nil }
        var student = Person(displayName: "Demo Student", age: 20, origin: Origin(countryCode: "IN"),
                             thinkIn: Locale.Language(identifier: "hi"), goal: .study)
        try? student.setStage(.schoolOrAllowedWork)
        var parent = Person(displayName: "Demo Parent", age: 58, origin: Origin(countryCode: "CU"),
                            thinkIn: Locale.Language(identifier: "es"), goal: .reunite)
        try? parent.setStage(.movement)
        return try? Household(name: "Demo household", pin: pin, people: [student, parent])
    }

    /// DEMO catalog, used only while the compiled content bundle has no cards. Fact ids are Regions'
    /// ledger ids; titles are in Cards.xcstrings ("… (demo)").
    public static let catalog: [Card] = [
        card("trash-week", .household, topic: .ordinaryWeek, facts: [
            "us-fl-miamidade.trash.garbage-days", "us-fl-miamidade.trash.recycling-day",
            "us-fl-miamidade.trash.recycling-week", "us-fl-miami.trash.day"]),
        card(officesCard, .household, topic: .whichCity, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.government.municipality", "us-fl-miamidade.government.municipality-id"]),
        card("building", .household, topic: .listingCheck, facts: [
            "us-fl-miamidade.parcel.year-built", "us-fl-miamidade.parcel.folio",
            "us-fl-miamidade.parcel.condo", "us-fl-miamidade.parcel.use"]),
        card("flood", .household, topic: .bed, modes: [.resident, .tourist], facts: [
            "us.fema.flood-zone", "us-fl-miamidade.storm.evacuation-zone"]),
        card("water", .household, facts: [
            "us-fl-miamidade.utility.water", "us-fl-miamidade.utility.sewer"]),
        card("street-week", .household, topic: .tolls, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.vision-zero.goal",
            "us-fl-miamidade.vision-zero.hin-share",
            "us-fl-miamidade.vision-zero.hub",
            "us-fl-miamidade.police.nearest.name",
            "us-fl-miamidade.police.nearest.phone"], desk: "us-fl-miamidade.dtpw"),
        card("transit", .household, topic: .transit, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.transit.nearest-stop.1", "us-fl-miamidade.transit.nearest-stop.1.routes",
            "us-fl-miamidade.transit.nearest-stop.2", "us-fl-miamidade.transit.nearest-stop.2.routes",
            "us-fl-miamidade.transit.nearest-stop.3", "us-fl-miamidade.transit.nearest-stop.3.routes",
            "us-fl-miamidade.311.traffic-signal"]),
        card("library-park", .household, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.library.nearest.1", "us-fl-miamidade.parks.nearest-county.1"]),
        card("taxi", .household, topic: .backToAirport, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.mia.taxi.stand-location",
            "us-fl-miamidade.mia.taxi.solicitor-warning",
            "us-fl-miamidade.mia.taxi.meter-rule",
            "us-fl-miamidade.mia.taxi.flat-rate-rule"], desk: "us-fl-miamidade.mia-information"),
        card("lights-311", .household, topic: .emergency911, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.311.phone",
            "us-fl-miamidade.311.phone-alt",
            "us-fl-miamidade.311.hours-languages",
            "us-fl-miamidade.311.traffic-signal"]),
        card("theft-map", .household, topic: .scam, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.crime-map.county",
            "us-fl-miami.police.crime-map",
            "us-fl-miamidade.police.nearest.name",
            "us-fl-miamidade.police.nearest.phone",
            "us-fl-miamidade.transit.parking.theft-disclaimer"], desk: "us-fl-miamidade.mdpd"),
        card("storm-walk", .household, topic: .bed, modes: [.resident, .tourist], facts: [
            "us.fema.flood-zone",
            "us-fl-miamidade.storm.evacuation-zone",
            "us-fl-miamidade.311.phone"]),
        card("night-walk", .household, topic: .emergency911, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.311.non-emergency",
            "us-fl-miamidade.311.hours-languages",
            "us-fl-miamidade.311.phone",
            "us-fl-miamidade.311.traffic-signal",
            "us-fl-miamidade.vision-zero.hub",
            "us-fl-miamidade.police.nearest.name"]),
        card("parking", .household, topic: .rentalCarTolls, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.parking.no-metrorail-government-center",
            "us-fl-miamidade.parking.hickman.name",
            "us-fl-miamidade.parking.hickman.rates",
            "us-fl-miamidade.transit.parking.dadeland-south",
            "us-fl-miamidade.transit.parking.daily-fee",
            "us-fl-miamidade.transit.parking.hours",
            "us-fl-miamidade.transit.parking.customers-only",
            "us-fl-miamidade.transit.parking.theft-disclaimer"], desk: "us-fl-miamidade.transit"),
        card("rideshare", .household, topic: .backToAirport, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.mia.rideshare.levels",
            "us-fl-miamidade.mia.taxi.solicitor-warning",
            "us-fl-miamidade.mia.taxi.stand-location"], desk: "us-fl-miamidade.mia-information"),
        card("school-zone", .household, topic: .schoolZone, facts: [
            "us-fl-miamidade.school.elementary", "us-fl-miamidade.school.elementary.phone",
            "us-fl-miamidade.school.elementary.grades",
            "us-fl-miamidade.school.middle", "us-fl-miamidade.school.middle.phone",
            "us-fl-miamidade.school.high", "us-fl-miamidade.school.high.phone"]),
        card("rent", .household, topic: .rentLine, facts: [
            "us-fl-miamidade.rent.line"]),
        card("license", .household, topic: .license, facts: [
            "us-fl.flhsmv.insurance.pip-pdl-required",
            "us-fl.flhsmv.insurance.minimums",
            "us-fl.flhsmv.fee.class-e-original", "us-fl.flhsmv.fee.class-e-renewal",
            "us-fl.flhsmv.fee.id-card-original"], desk: "us-fl.flhsmv"),
        card("bumper-tap", .household, topic: .insurance, modes: [.resident, .tourist], facts: [
            "us-fl.flhsmv.crash.notify-law",
            "us-fl.statute.316.062.exchange",
            "us-fl.statute.316.070.exchange-at-scene",
            "us-fl.statute.316.062.self-incrimination",
            "us-fl.flhsmv.crash.self-report",
            "us-fl.flhsmv.crash.customer-service",
            "us-fl.flhsmv.insurance.pip-pdl-required",
            "us-fl.flhsmv.insurance.minimums",
            "us-fl-miamidade.police.nearest.name",
            "us-fl-miamidade.police.nearest.phone"], desk: "us-fl.flhsmv"),
        card("house-damage", .household, topic: .bed, modes: [.resident, .tourist], facts: [
            "us-fl-miamidade.311.non-emergency",
            "us-fl-miamidade.311.phone",
            "us-fl-miamidade.311.phone-alt",
            "us.fema.flood-zone",
            "us-fl-miamidade.storm.evacuation-zone"], desk: "us-fl-miamidade.311"),
        card("vote", .household, facts: [
            "us-fl-miamidade.vote.polling-place", "us-fl-miamidade.vote.precinct",
            "us-fl-miamidade.rep.county-commission.member"]),
        card("scam", .household, topic: .scam, modes: [.resident, .tourist], facts: [
            "us.ftc.gift-card-payment-scam"]),
        card("uscis", .household, topic: .statusWord, facts: [
            "us.uscis.forms-free", "us.uscis.fee-payment-methods"]),
        card("landlord", .household, topic: .deadlines, facts: [
            "us-fl.landlord.deposit.return-days-no-claim",
            "us-fl.landlord.deposit.claim-notice-days",
            "us-fl.landlord.deposit.tenant-objection-days"]),
        card("benefits", .household, topic: .food, facts: [
            "us-fl-miamidade.211.name", "us-fl-miamidade.211.phone",
            "us-fl-miamidade.211.phone-alt", "us-fl-miamidade.211.text-number",
            "us-fl.wic.phone-state", "us-fl-miamidade.wic.phone",
            "us.wic.who", "us-fl-miamidade.wic.citizenship-not-required",
            "us-fl.dcf-access.name", "us-fl.dcf-access.url",
            "us.fns.snap-undocumented-not-eligible",
            "us.medicaid.hr1.noncitizen-eligibility.effective",
            "us-fl.kidcare.name", "us-fl.kidcare.phone", "us-fl.kidcare.url"], desk: desk211),
        card("health-help", .household, topic: .clinicDesk, modes: [.resident, .tourist], facts: [
            "us.hrsa.health-center.anyone", "us.hrsa.health-center.ability-to-pay",
            "us.hrsa.find-a-health-center.url",
            "us-fl-miamidade.jackson.phone",
            "us-fl-miamidade.jackson.financial-assistance.sliding-scale-max-fpl",
            "us-fl-miamidade.jackson.healthcare-advisors.phone",
            "us.988.phone", "us.poison-control.phone"], desk: "us-fl-miamidade.jackson"),
        card("school-access", .household, topic: .schoolZone, facts: [
            "us-fl.school.plyler-equal-access",
            "us-fl-miamidade.mdcps.ferpa-status",
            "us.fns.school-meals-immigration"], desk: "us-fl-miamidade.m-dcps-transportation"),
        card("power-help", .household, facts: [
            "us-fl.liheap.household-status-requirement",
            "us-fl-miamidade.liheap.status-requirement"], desk: "us-fl-miamidade.community-services"),
        card("shelter-help", .household, topic: .bed, facts: [
            "us-fl-miamidade.homeless-trust.phone"], desk: "us-fl-miamidade.homeless-trust"),
        card("legal-help", .household, facts: [
            "us-fl-miamidade.legal-aid.name", "us-fl-miamidade.legal-aid.phone",
            "us-fl-miamidade.legal-aid.address",
            "us-fl.florida-bar-lrs.name", "us-fl.florida-bar-lrs.phone"], desk: deskLegalAid),
        card("immigration-lawyer", .household, topic: .statusWord, immigration: true, facts: [
            "us-fl-miamidade.immigration-legal-aid.name",
            "us-fl-miamidade.immigration-legal-aid.phone",
            "us-fl-miamidade.immigration-legal-aid.address",
            "us.immigration.notario-not-authorized"], desk: deskImmigrationLegal),
    ]

    /// Spoken ways onto the walkthrough cards while the compiled bundle has no utterances.
    public static let utterances: [CardUtterances] = [
        CardUtterances(cardID: "bumper-tap", phrases: [
            "en": ["bumper tap", "fender bender", "someone hit my car", "I hit a bumper"],
            "es": ["toque de parachoques", "me pegaron el auto", "choqué el parachoques"],
            "ht": ["ti chòk", "yon machin frape m"],
        ]),
        CardUtterances(cardID: "house-damage", phrases: [
            "en": ["something is wrong with the house", "leak in the house", "ceiling stain", "house damage"],
            "es": ["algo anda mal en la casa", "gotera en la casa"],
            "ht": ["pwoblèm kay", "koule nan kay"],
        ]),
    ]

    static func card(_ id: CardID, _ subject: CardSubject, topic: HeroTopic? = nil, modes: Set<Mode> = [.resident],
                     immigration: Bool = false, facts: [FactID], desk: DeskID = desk311) -> Card {
        // Only fails on an empty desk or a key fact not on the card; neither can happen here.
        try! Card(id: id, regionPack: "us-fl-miamidade", subject: subject, titleKey: StringKey(key: "card.\(id.rawValue).title", table: "Cards"),
                  heroTopic: topic, modes: modes, isImmigrationContent: immigration, desk: desk, facts: facts)
    }
}

/// Facts for the household's current pin, from Regions' bundled demo answers. Thread-safe: the
/// router holds it for its lifetime and the pin changes underneath (`select`).
public final class PinFactStore: FactResolving, Sendable {
    private let answers: [RegionPinAnswers]
    private let current = Mutex<RegionPinAnswers?>(nil)

    public init(answers: [RegionPinAnswers] = (try? BundledRegionData.demoPins()) ?? []) {
        self.answers = answers
    }

    /// Follows the household pin: exact address match, else nearest fixture within ~50 m, else none.
    public func select(_ pin: Pin?) {
        let match: RegionPinAnswers? = pin.flatMap { pin in
            answers.first { $0.pin.address != nil && $0.pin.address == pin.address }
                ?? answers.first { abs($0.pin.lat - pin.latitude) < 0.0005 && abs($0.pin.lon - pin.longitude) < 0.0005 }
        }
        current.withLock { $0 = match }
    }

    public func outcome(for id: FactID) -> FactOutcome? {
        current.withLock { answers in
            answers?.results.first { $0.factID == id }.map(RegionOutcomeMapper.outcome(for:))
        }
    }

    public func result(for id: FactID) -> RegionFactResult? {
        current.withLock { $0?.results.first { $0.factID == id } }
    }
}
