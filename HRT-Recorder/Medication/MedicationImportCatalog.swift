import Foundation
import HealthKit

enum MedicationImportAlignmentStatus: String, Equatable, Sendable {
    case aligned
    case needsDoseConfirmation
    case needsRule
}

struct HealthMedicationSnapshot: Sendable {
    let displayName: String
    let nickname: String?
    let generalFormText: String
    let normalizedDisplayName: String
    let normalizedNickname: String
    let normalizedGeneralFormText: String

    nonisolated var combinedNormalizedText: String {
        [normalizedDisplayName, normalizedNickname, normalizedGeneralFormText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum MedicationDoseParsingMode: Sendable {
    case strengthInName
}

struct MedicationAlignmentRule: Sendable {
    let name: String
    let aliases: [String]
    let requiredTokens: [String]
    let allowedGeneralFormTokens: [String]
    let route: DoseEvent.Route
    let ester: Ester
    let doseParsingMode: MedicationDoseParsingMode
    let note: String?

    fileprivate func matches(_ snapshot: HealthMedicationSnapshot) -> Bool {
        let searchableText = snapshot.combinedNormalizedText

        if aliases.contains(snapshot.normalizedDisplayName) {
            return allowedGeneralFormTokens.isEmpty
                || allowedGeneralFormTokens.contains(where: snapshot.normalizedGeneralFormText.contains(_:))
        }

        let tokensMatch = requiredTokens.allSatisfy(searchableText.contains(_:))
        guard tokensMatch else { return false }

        if allowedGeneralFormTokens.isEmpty {
            return true
        }

        return allowedGeneralFormTokens.contains(where: snapshot.normalizedGeneralFormText.contains(_:))
            || allowedGeneralFormTokens.contains(where: snapshot.normalizedDisplayName.contains(_:))
    }
}

enum MedicationImportCatalog {
    static let rules: [MedicationAlignmentRule] = [
        MedicationAlignmentRule(
            name: "Estradiol valerate oral tablet",
            aliases: [],
            requiredTokens: ["estradiol", "valerate", "tablet"],
            allowedGeneralFormTokens: ["tablet", "caplet"],
            route: .oral,
            ester: .EV,
            doseParsingMode: .strengthInName,
            note: "Matched estradiol valerate tablets from Apple Health."
        ),
    ]

    static func match(snapshot: HealthMedicationSnapshot) -> MedicationAlignmentRule? {
        rules.first { $0.matches(snapshot) }
    }
}

enum MedicationImportNameNormalizer {
    static func normalize(_ text: String?) -> String {
        guard let text else { return "" }

        let lowercase = text.lowercased()
        let pluralNormalized = lowercase
            .replacingOccurrences(of: "tablets", with: "tablet")
            .replacingOccurrences(of: "capsules", with: "capsule")
            .replacingOccurrences(of: "caplets", with: "caplet")
            .replacingOccurrences(of: "softgels", with: "softgel")

        let pattern = #"[^a-z0-9\s]+"#
        let collapsed = pluralNormalized.replacingOccurrences(
            of: pattern,
            with: " ",
            options: .regularExpression
        )

        return collapsed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum MedicationStrengthParser {
    static func parseRawDoseMG(from text: String) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(mg|mcg|ug|μg|µg|g)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard matches.count == 1 else { return nil }
        guard let match = matches.first else { return nil }

        if isSlashSeparated(text: text, match: match) {
            return nil
        }

        guard let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let valueText = text[valueRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(valueText) else { return nil }

        switch text[unitRange].lowercased() {
        case "mg":
            return value
        case "g":
            return value * 1000
        case "mcg", "ug", "μg", "µg":
            return value / 1000
        default:
            return nil
        }
    }

    private static func isSlashSeparated(text: String, match: NSTextCheckingResult) -> Bool {
        guard let fullRange = Range(match.range, in: text) else { return true }

        let prefix = text[..<fullRange.lowerBound].trimmingCharacters(in: .whitespaces)
        if prefix.last == "/" {
            return true
        }

        let suffix = text[fullRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return suffix.first == "/"
    }
}
