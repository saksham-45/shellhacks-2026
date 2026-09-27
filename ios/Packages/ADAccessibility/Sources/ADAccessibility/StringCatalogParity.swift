// String Catalog (.xcstrings) parity checker: every key must have a non-empty, translated value in
// every required language (es, en, ht by default), including every plural/device variation (each
// variation group must have an `other` case), and every leaf's format arguments must agree with the
// source string, position by position. Rules A11Y-L10N-01/-03.
// Pure Swift + Foundation JSON; runs on Linux (`swift run xcstrings-parity <file>...`).
// Reference implementation: the CI gate is Lead's tools/check_string_parity.py (docs A11Y-L10N-03).

import Foundation

public struct StringCatalogParity: Sendable {
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Kind: String, Sendable {
            case missing, empty, notTranslated, formatMismatch, rawKeyAsSource, missingOther
        }
        public let key: String
        public let language: String
        public let path: String          // e.g. "stringUnit" or "variations.plural.one.stringUnit"
        public let kind: Kind
        public let detail: String

        public var description: String {
            "[\(kind.rawValue)] key=\"\(key)\" lang=\(language) at \(path)\(detail.isEmpty ? "" : ": " + detail)"
        }
    }

    public let requiredLanguages: [String]
    /// States accepted as shippable. Xcode uses "translated", "needs_review", "new", "stale".
    public let acceptedStates: Set<String>

    public init(requiredLanguages: [String] = ["es", "en", "ht"], acceptedStates: Set<String> = ["translated"]) {
        self.requiredLanguages = requiredLanguages
        self.acceptedStates = acceptedStates
    }

    public enum LoadError: Error, CustomStringConvertible {
        case notACatalog(String)
        public var description: String {
            switch self { case .notACatalog(let why): return "not a String Catalog: \(why)" }
        }
    }

    /// Parses a `--languages` value ("es,en,ht"). Nil when the list is empty or has an empty entry
    /// ("", ",", "es,,ht", "es, "): the CLI exits 2 instead of silently checking nothing.
    public static func parseLanguages(_ value: String) -> [String]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        return parts
    }

    public func check(fileAt url: URL) throws -> [Issue] {
        try check(data: Data(contentsOf: url))
    }

    // MARK: - Leaves

    struct Leaf {
        let path: String
        let unit: [String: Any]
        /// Substitution name when the leaf lives under `substitutions.<name>`.
        let substitution: String?
        /// True when every variation case on the path is `other` (or there are no variations):
        /// such a leaf must carry exactly the reference arguments.
        let isFull: Bool
        var value: String { unit["value"] as? String ?? "" }
    }

    public func check(data: Data) throws -> [Issue] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.notACatalog("top level is not an object")
        }
        guard let strings = root["strings"] as? [String: Any] else {
            throw LoadError.notACatalog("missing \"strings\"")
        }
        let sourceLanguage = root["sourceLanguage"] as? String ?? "en"
        var issues: [Issue] = []
        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any] else { continue }
            if entry["shouldTranslate"] as? Bool == false { continue }        // verbatim (proper names, numbers)
            if entry["extractionState"] as? String == "stale" { continue }    // no longer referenced by code
            let localizations = entry["localizations"] as? [String: Any] ?? [:]

            var leavesByLanguage: [(lang: String, node: [String: Any], leaves: [Leaf])] = []
            var keyIsSource = false
            for lang in requiredLanguages {
                guard let loc = localizations[lang] as? [String: Any] else {
                    // Xcode omits the source-language localization when the key IS the source text.
                    // Accept that only for natural-language keys; a semantic key would ship raw.
                    if lang == sourceLanguage {
                        if A11yLabelLint.looksLikeRawKey(key) {
                            issues.append(Issue(key: key, language: lang, path: "-", kind: .rawKeyAsSource,
                                                detail: "source value missing and key looks like a raw key"))
                        } else {
                            keyIsSource = true
                        }
                    } else {
                        issues.append(Issue(key: key, language: lang, path: "-", kind: .missing, detail: ""))
                    }
                    continue
                }
                var leaves: [Leaf] = []
                collectLeaves(loc, path: "", substitution: nil, isFull: true, key: key, language: lang,
                              leaves: &leaves, issues: &issues)
                if leaves.isEmpty {
                    issues.append(Issue(key: key, language: lang, path: "-", kind: .missing, detail: "no stringUnit"))
                    continue
                }
                for leaf in leaves {
                    let state = leaf.unit["state"] as? String ?? ""
                    if leaf.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        issues.append(Issue(key: key, language: lang, path: leaf.path, kind: .empty, detail: ""))
                    } else if !acceptedStates.contains(state) {
                        issues.append(Issue(key: key, language: lang, path: leaf.path, kind: .notTranslated,
                                            detail: "state=\(state.isEmpty ? "<none>" : state)"))
                    }
                }
                leavesByLanguage.append((lang, loc, leaves))
            }

            // Reference argument signature: the source language's full leaf, else the key when the key
            // is the source text, else the first language that has a non-empty full leaf.
            let reference: (lang: String, signature: Set<String>)?
            func fullLeaf(_ leaves: [Leaf]) -> Leaf? {
                leaves.first { $0.substitution == nil && $0.isFull && !$0.value.isEmpty }
            }
            if let src = leavesByLanguage.first(where: { $0.lang == sourceLanguage }), let leaf = fullLeaf(src.leaves) {
                reference = (sourceLanguage, Set(Self.formatSignature(in: leaf.value)))
            } else if keyIsSource {
                reference = ("key", Set(Self.formatSignature(in: key)))
            } else if let first = leavesByLanguage.lazy.compactMap({ l in fullLeaf(l.leaves).map { (l.lang, $0) } }).first {
                reference = (first.0, Set(Self.formatSignature(in: first.1.value)))
            } else {
                reference = nil
            }
            guard let reference else { continue }
            let refList = reference.signature.sorted()

            for (lang, node, leaves) in leavesByLanguage {
                let substitutions = node["substitutions"] as? [String: Any] ?? [:]
                for leaf in leaves where !leaf.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let signature = Self.formatSignature(in: leaf.value)
                    let set = Set(signature)
                    if leaf.substitution != nil {
                        // Inside a substitution: `%arg` is the substitution's own argument; anything else
                        // must be one of the reference arguments.
                        let extra = set.subtracting(reference.signature).subtracting(["arg"])
                        if !extra.isEmpty {
                            issues.append(Issue(key: key, language: lang, path: leaf.path, kind: .formatMismatch,
                                                detail: "unexpected \(extra.sorted()) vs \(reference.lang) \(refList)"))
                        }
                        continue
                    }
                    let ok = leaf.isFull ? set == reference.signature : set.isSubset(of: reference.signature)
                    if !ok {
                        issues.append(Issue(key: key, language: lang, path: leaf.path, kind: .formatMismatch,
                                            detail: "\(set.sorted()) vs \(reference.lang) \(refList)"
                                                + (leaf.isFull ? "" : " (a variation may drop arguments, not add or retype them)")))
                    }
                    for token in signature where token.contains("#@") {
                        let name = String(token.split(separator: "@")[1])
                        if substitutions[name] == nil {
                            issues.append(Issue(key: key, language: lang, path: leaf.path, kind: .formatMismatch,
                                                detail: "\(token) has no substitutions.\(name)"))
                        }
                    }
                }
            }
        }
        return issues
    }

    /// Walks `stringUnit`, nested `variations` (plural/device/width), and `substitutions`.
    /// Reports a variation group without an `other` case (the fallback every group needs).
    private func collectLeaves(_ node: [String: Any], path: String, substitution: String?, isFull: Bool,
                               key: String, language: String, leaves: inout [Leaf], issues: inout [Issue]) {
        let prefix = path.isEmpty ? "" : path + "."
        if let unit = node["stringUnit"] as? [String: Any] {
            leaves.append(Leaf(path: prefix + "stringUnit", unit: unit, substitution: substitution, isFull: isFull))
        }
        if let variations = node["variations"] as? [String: Any] {
            for (kind, cases) in variations.sorted(by: { $0.key < $1.key }) {
                guard let cases = cases as? [String: Any] else { continue }
                if cases["other"] == nil {
                    issues.append(Issue(key: key, language: language, path: prefix + "variations.\(kind)",
                                        kind: .missingOther, detail: "cases \(cases.keys.sorted()) have no 'other'"))
                }
                for (name, sub) in cases.sorted(by: { $0.key < $1.key }) {
                    guard let sub = sub as? [String: Any] else { continue }
                    collectLeaves(sub, path: prefix + "variations.\(kind).\(name)", substitution: substitution,
                                  isFull: isFull && name == "other", key: key, language: language,
                                  leaves: &leaves, issues: &issues)
                }
            }
        }
        if let substitutions = node["substitutions"] as? [String: Any] {
            for (name, sub) in substitutions.sorted(by: { $0.key < $1.key }) {
                guard let sub = sub as? [String: Any] else { continue }
                collectLeaves(sub, path: prefix + "substitutions.\(name)", substitution: name, isFull: true,
                              key: key, language: language, leaves: &leaves, issues: &issues)
            }
        }
    }

    // MARK: - Format specifiers

    /// `%%` (skipped) | `%arg` (substitution argument) | `%[N$]#@name@` (substitution token) |
    /// `%[N$][flags][width][.precision][length]conversion`. Flags exclude space, so "50% off" is text.
    /// A `*` width/precision is accepted but not counted as an argument.
    private static let pattern = #"%%|%arg(?![A-Za-z0-9_])|%(?:(\d+)\$)?(?:#@([A-Za-z0-9_]+)@|[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*)?)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA]))"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// Raw specifiers in order, e.g. "%.2f of %1$@ (100%%)" -> ["%.2f", "%1$@"]. `%%` is not a specifier.
    public static func formatSpecifiers(in s: String) -> [String] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { $0 != "%%" }
    }

    /// Position-aware normalized arguments: "<position>$<length><class>" for printf arguments,
    /// "<position>$#@name@" for substitution tokens, "arg" for `%arg`. Non-positional arguments take
    /// positions 1, 2, ... in order, so "%@ %lld" and "%2$lld %1$@" have the same signature.
    /// Flags, width, and precision do not matter ("%.2f" == "%f"); the argument type does
    /// ("%d" != "%lld" != "%@"). Classes: d,i -> d; u,x,X,o -> u; f,F,e,E,g,G,a,A -> f; D -> ld; U,O -> lu.
    public static func formatSignature(in s: String) -> [String] {
        let ns = s as NSString
        var next = 1
        var out: [String] = []
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range)
            if whole == "%%" { continue }
            if whole == "%arg" { out.append("arg"); continue }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let position: Int
            if let explicit = group(1).flatMap({ Int($0) }) { position = explicit } else { position = next; next += 1 }
            if let name = group(2) {
                out.append("\(position)$#@\(name)@")
                continue
            }
            let length = group(3) ?? ""
            let conversion = group(4) ?? ""
            let cls: String
            switch conversion {
            case "d", "i": cls = length + "d"
            case "u", "x", "X", "o": cls = length + "u"
            case "D": cls = "ld"
            case "U", "O": cls = "lu"
            case "f", "F", "e", "E", "g", "G", "a", "A": cls = length + "f"
            default: cls = length + conversion
            }
            out.append("\(position)$\(cls)")
        }
        return out
    }
}
