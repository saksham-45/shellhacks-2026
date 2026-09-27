import Foundation

/// The one versioned JSON payload every store adapter persists, so the schema lives in one place.
///
/// - v1 (current): `{"schemaVersion":1,"household":{...}}`, languages as BCP-47 strings.
/// - v0 (legacy): the unversioned skeleton-stub household object (no envelope): `displayName`,
///   `surfaceLanguageTag`/`thinkInLanguageTag`, `homeLanguageTag`, `origin.lenses`,
///   `sharesPapersWithHousehold`. Migrated on read.
/// - anything newer: `unsupportedSchema(version)`, decided from the header alone.
public enum HouseholdCodec {
    public static let schemaVersion = 1

    public enum CodecError: Error, Equatable, Sendable {
        case unsupportedSchema(Int)
    }

    private struct Header: Decodable { let schemaVersion: Int? }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let household: Household
    }

    public static func encode(_ household: Household) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(schemaVersion: schemaVersion, household: household))
    }

    public static func decode(_ data: Data) throws -> Household {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version = try decoder.decode(Header.self, from: data).schemaVersion ?? 0
        switch version {
        case schemaVersion: return try decoder.decode(Envelope.self, from: data).household
        case 0: return try decoder.decode(LegacyV0Household.self, from: data).migrated()
        default: throw CodecError.unsupportedSchema(version)
        }
    }
}

// MARK: - v0 (skeleton stub shape)

private struct LegacyV0Household: Decodable {
    struct LegacyOrigin: Decodable { let countryCode: String? }
    struct LegacyPerson: Decodable {
        let id: UUID
        let displayName: String
        let age: Int?
        let origin: LegacyOrigin?
        let surfaceLanguageTag: String
        let thinkInLanguageTag: String?
        let stage: Stage
        let mode: Mode
        let goal: Goal
        let statusWord: String?
        let sharesPapersWithHousehold: Bool?
    }

    let id: UUID
    let name: String?
    let pin: Pin?
    let people: [LegacyPerson]
    let homeLanguageTag: String?

    struct MigrationError: Error, CustomStringConvertible {
        let description: String
    }

    func migrated() throws -> Household {
        let persons = try people.map { p -> Person in
            var person = Person(
                id: PersonID(p.id), displayName: p.displayName, age: p.age,
                origin: p.origin?.countryCode.map(Origin.init(countryCode:)),
                thinkIn: Locale.Language(identifier: p.thinkInLanguageTag ?? p.surfaceLanguageTag),
                surfaceLanguage: Locale.Language(identifier: p.surfaceLanguageTag),
                goal: p.goal, statusWord: p.statusWord.map(StatusWord.init(rawValue:)))
            // v0 lenses are dropped: content's OriginLensResolving recomputes them from the origin.
            person.statusWordSharedWithHousehold = p.sharesPapersWithHousehold ?? false
            if p.mode == .tourist { person.becomeTourist() } else { person.iLiveHereNow(goal: p.goal) }
            do { try person.setStage(p.stage) } catch {
                throw MigrationError(description: "v0 person \(p.id): tourist at stage \(p.stage.number)")
            }
            return person
        }
        do {
            return try Household(id: HouseholdID(id), name: name, pin: pin,
                                 homeLanguage: homeLanguageTag.map(Locale.Language.init(identifier:)), people: persons)
        } catch {
            throw MigrationError(description: "v0 household \(id): \(error)")
        }
    }
}
