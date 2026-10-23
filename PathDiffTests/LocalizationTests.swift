//
//  LocalizationTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Localization")
struct LocalizationTests {
    /// Every language offered in Settings besides English, the source language.
    private static let languages = AppLanguage.allCases.filter { $0 != .system && $0 != .english }.map(\.rawValue)

    /// Plural categories each language needs (CLDR), so counts read right in all of them.
    private static let requiredPluralCategories: [String: Set<String>] = [
        "en": ["one", "other"],
        "de": ["one", "other"], "es": ["one", "other"], "fr": ["one", "other"], "pt-BR": ["one", "other"],
        "tr": ["one", "other"], "ja": ["other"], "ko": ["other"],
        "ru": ["one", "few", "many", "other"], "ar": ["zero", "one", "two", "few", "many", "other"],
        "zh-Hans": ["other"], "zh-Hant": ["other"], "it": ["one", "other"], "nl": ["one", "other"],
        "pl": ["one", "few", "many", "other"], "sv": ["one", "other"], "nb": ["one", "other"],
        "da": ["one", "other"], "fi": ["one", "other"],
        "hi": ["one", "other"], "vi": ["other"], "th": ["other"], "id": ["other"],
    ]

    /// The String Catalog, read from the source tree.
    private func catalog() throws -> [String: [String: Any]] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "PathDiff/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try #require(json?["strings"] as? [String: [String: Any]])
    }

    /// Format arguments a string consumes (`%@`, `%lld`, positional forms, plural substitutions).
    private func argumentCount(_ text: String) -> Int {
        let cleaned = text.replacingOccurrences(of: "%%", with: "")
        return cleaned.matches(of: /%(?:\d+\$)?(?:lld|@|#@\w+@)/).count
    }

    /// Every value a localization can show: the plain one, a plural template, or plural cases.
    private func values(of localization: [String: Any]) -> [String] {
        var result: [String] = []
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            result.append(value)
        }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
            for variant in plural.values {
                if let value = (variant["stringUnit"] as? [String: Any])?["value"] as? String { result.append(value) }
            }
        }
        return result
    }

    private func argumentKinds(_ text: String) -> [String] {
        text.replacingOccurrences(of: "%%", with: "")
            .matches(of: /%(?:\d+\$)?(lld|@)/).map { String($0.1) }
    }

    /// Check argument identity and type, including the arguments hidden behind plural
    /// substitutions. Counting placeholders alone misses `%1$@ %1$@` and `%lld` → `%@`.
    private func formatProblems(reference: String, localization: [String: Any], mayOmitSingularCount: Bool = true) -> [String] {
        let kinds = argumentKinds(reference)
        let substitutions = localization["substitutions"] as? [String: [String: Any]] ?? [:]
        var problems: [String] = []
        var referencedSubstitutions: Set<String> = []

        func check(_ text: String, mayOmitCount: Bool = false) {
            let matches = text.replacingOccurrences(of: "%%", with: "")
                .matches(of: /%(?:(\d+)\$)?(lld|@|#@\w+@)/)
            let plainMatches = matches.filter { !$0.2.hasPrefix("#@") }
            if plainMatches.contains(where: { $0.1 != nil }) && plainMatches.contains(where: { $0.1 == nil }) {
                problems.append("Mixed positional and implicit arguments: \(text)")
            }
            var used: Set<Int> = []
            var implicitPosition = 0
            for match in matches {
                let kind = String(match.2)
                let position: Int
                let consumedKind: String
                if kind.hasPrefix("#@") {
                    let name = String(kind.dropFirst(2).dropLast())
                    referencedSubstitutions.insert(name)
                    guard let sub = substitutions[name], let argNum = sub["argNum"] as? Int,
                          let format = sub["formatSpecifier"] as? String else {
                        problems.append("Undefined plural substitution: \(name)")
                        continue
                    }
                    position = argNum
                    consumedKind = format
                } else {
                    implicitPosition += 1
                    position = match.1.flatMap { Int($0) } ?? implicitPosition
                    consumedKind = kind
                }
                guard position > 0, position <= kinds.count else {
                    problems.append("Argument \(position) is out of range: \(text)")
                    continue
                }
                used.insert(position)
                if kinds[position - 1] != consumedKind {
                    problems.append("Wrong type for argument \(position): \(text)")
                }
            }
            let expected = Set(kinds.indices.map { $0 + 1 })
            let omittedCount = mayOmitCount && kinds == ["lld"] && used.isEmpty
            if used != expected && !omittedCount {
                problems.append("Missing arguments: \(text)")
            }
        }

        if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
            check(value)
        }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
            for (category, variant) in plural {
                if let value = (variant["stringUnit"] as? [String: Any])?["value"] as? String {
                    check(value, mayOmitCount: ["zero", "two"].contains(category) || (category == "one" && mayOmitSingularCount))
                }
            }
        }
        if referencedSubstitutions != Set(substitutions.keys) {
            problems.append("Plural substitutions do not match the template")
        }
        for (name, substitution) in substitutions {
            let plural = (substitution["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]
            if plural.isEmpty { problems.append("Empty plural substitution: \(name)") }
            for (category, variant) in plural {
                let value = (variant["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                let count = value.components(separatedBy: "%arg").count - 1
                // A substitution may inflect only a noun while the template (or
                // another substitution for this argument) already displays the count.
                if value.isEmpty || count > 1 ||
                    argumentCount(value.replacingOccurrences(of: "%arg", with: "")) != 0 {
                    problems.append("Invalid plural substitution \(name).\(category): \(value)")
                }
            }
        }
        return problems
    }

    @Test func everyStringIsTranslated() throws {
        var missing: [String] = []
        for (key, entry) in try catalog() where entry["shouldTranslate"] as? Bool != false && entry["extractionState"] as? String != "stale" {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let localization = localizations[language] ?? [:]
                let translated = values(of: localization)
                if translated.isEmpty || translated.contains(where: \.isEmpty) {
                    missing.append("\(language): \(key)")
                }
            }
        }
        #expect(missing.isEmpty, "Untranslated: \(missing.sorted().joined(separator: ", "))")
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        var mismatched: [String] = []
        for (key, entry) in try catalog() where entry["shouldTranslate"] as? Bool != false {
            // Keys like "tile.missing.subtitle" are IDs; their English value holds the placeholders.
            let englishValue = ((entry["localizations"] as? [String: [String: Any]])?["en"]?["stringUnit"] as? [String: Any])?["value"] as? String
            let expected = argumentCount(key.contains("%") ? key : englishValue ?? key)
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                guard let localization = localizations[language] else { continue }
                let isPlural = localization["variations"] != nil
                for value in values(of: localization) where !value.contains("%#@") {
                    let count = argumentCount(value)
                    // A plural "one" case may leave out the count ("The compared file is identical.").
                    if count != expected && !(isPlural && count == expected - 1) {
                        mismatched.append("\(language): \(key) → \(value)")
                    }
                }
            }
        }
        #expect(mismatched.isEmpty, "Placeholder mismatch: \(mismatched.joined(separator: "; "))")
    }

    @Test func translationsKeepArgumentTypesAndPluralSubstitutions() throws {
        var problems: [String] = []
        for (key, entry) in try catalog() where entry["shouldTranslate"] as? Bool != false && entry["extractionState"] as? String != "stale" {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let english = (localizations["en"]?["stringUnit"] as? [String: Any])?["value"] as? String
            let reference = key.contains("%") ? key : english ?? key
            for (language, localization) in localizations {
                // CLDR "one" includes 0 in fr/pt-BR/hi and 21, 31… in ru.
                let mayOmit = !["fr", "pt-BR", "hi", "ru"].contains(language)
                problems += formatProblems(reference: reference, localization: localization, mayOmitSingularCount: mayOmit)
                    .map { "\(language): \(key): \($0)" }
            }
        }
        #expect(problems.isEmpty, "Invalid format arguments: \(problems.joined(separator: "; "))")
    }

    @Test func argumentValidationDetectsErrorsThatKeepTheSamePlaceholderCount() {
        func unit(_ value: String) -> [String: Any] { ["stringUnit": ["value": value]] }
        #expect(!formatProblems(reference: "%lld %@", localization: unit("%@ %@")).isEmpty)
        #expect(!formatProblems(reference: "%@ %@", localization: unit("%1$@ %1$@")).isEmpty)
        #expect(!formatProblems(reference: "%lld %@", localization: unit("%2$@ %1$@")).isEmpty)
        #expect(formatProblems(reference: "%lld %@", localization: unit("%2$@ %1$lld")).isEmpty)

        let valid: [String: Any] = [
            "stringUnit": ["value": "%#@files@ (%2$@)"],
            "substitutions": ["files": [
                "argNum": 1, "formatSpecifier": "lld",
                "variations": ["plural": ["one": unit("one file"), "other": unit("%arg files")]],
            ]],
        ]
        #expect(formatProblems(reference: "%lld files (%@)", localization: valid).isEmpty)
        #expect(!formatProblems(reference: "%@ files (%lld)", localization: valid).isEmpty)
        #expect(!formatProblems(reference: "%lld files (%@)", localization: unit("%#@missing@ (%2$@)")).isEmpty)
        let nounOnly: [String: Any] = [
            "stringUnit": ["value": "%1$lld %#@items@"],
            "substitutions": ["items": [
                "argNum": 1, "formatSpecifier": "lld",
                "variations": ["plural": ["one": unit("item"), "other": unit("items")]],
            ]],
        ]
        #expect(formatProblems(reference: "%lld items", localization: nounOnly).isEmpty)
        let implicitOne: [String: Any] = ["variations": ["plural": [
            "one": unit("The file matches."), "other": unit("%lld files match."),
        ]]]
        #expect(formatProblems(reference: "%lld files match.", localization: implicitOne).isEmpty)
        #expect(!formatProblems(reference: "%lld files match.", localization: implicitOne, mayOmitSingularCount: false).isEmpty)
    }

    @Test func pluralsCoverEveryCategoryOfTheLanguage() throws {
        var incomplete: [String] = []
        for (key, entry) in try catalog() {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in ["en"] + Self.languages {
                guard let localization = localizations[language], let required = Self.requiredPluralCategories[language] else { continue }
                var pluralSets: [Set<String>] = []
                if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                    pluralSets.append(Set(plural.keys))
                }
                for substitution in (localization["substitutions"] as? [String: [String: Any]] ?? [:]).values {
                    if let plural = (substitution["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                        pluralSets.append(Set(plural.keys))
                    }
                }
                if pluralSets.contains(where: { !required.isSubset(of: $0) }) {
                    incomplete.append("\(language): \(key)")
                }
            }
        }
        #expect(incomplete.isEmpty, "Missing plural categories: \(incomplete.sorted().joined(separator: ", "))")
    }

    @Test func languageSettingTakesEffectAtTheNextLaunch() {
        let suiteName = "PathDiffTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.language == .system)
        #expect(!settings.needsRelaunchForLanguage)

        settings.language = .turkish
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["tr"])
        #expect(settings.needsRelaunchForLanguage)

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.language == .turkish)
        #expect(!relaunched.needsRelaunchForLanguage)

        relaunched.language = .system
        // Removed from the app's own domain, so the system's language list applies again.
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
        #expect(relaunched.needsRelaunchForLanguage)
    }
}
