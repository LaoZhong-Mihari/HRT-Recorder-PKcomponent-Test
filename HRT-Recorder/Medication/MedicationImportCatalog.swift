import Foundation

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
    let ester: Ester?
    let recordOnlyOralMedication: RecordOnlyOralMedication?
    let doseParsingMode: MedicationDoseParsingMode
    let defaultUnitStrengthMG: Double?
    let note: String?

    fileprivate func matches(_ snapshot: HealthMedicationSnapshot) -> Bool {
        let searchableText = snapshot.combinedNormalizedText

        let aliasMatched = aliases.contains(snapshot.normalizedDisplayName)
            || aliases.contains(snapshot.normalizedNickname)
            || aliases.contains(where: searchableText.contains(_:))

        if aliasMatched {
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
    private static let oralForms = ["tablet", "capsule", "caplet", "liquid", "powder"]
    private static let injectionForms = ["injection", "injector", "auto injector", "device", "liquid"]
    private static let patchForms = ["patch"]
    private static let topicalForms = ["gel", "cream", "lotion", "ointment", "topical", "foam", "spray"]

    private static func compoundRule(
        name: String,
        aliases: [String] = [],
        requiredTokens: [String],
        allowedGeneralFormTokens: [String],
        route: DoseEvent.Route,
        compound: Compound,
        defaultUnitStrengthMG: Double? = nil,
        note: String? = nil
    ) -> MedicationAlignmentRule {
        MedicationAlignmentRule(
            name: name,
            aliases: aliases,
            requiredTokens: requiredTokens,
            allowedGeneralFormTokens: allowedGeneralFormTokens,
            route: route,
            ester: compound,
            recordOnlyOralMedication: nil,
            doseParsingMode: .strengthInName,
            defaultUnitStrengthMG: defaultUnitStrengthMG,
            note: note
        )
    }

    private static func recordOnlyRule(
        name: String,
        aliases: [String] = [],
        requiredTokens: [String],
        medication: RecordOnlyOralMedication,
        note: String? = nil
    ) -> MedicationAlignmentRule {
        MedicationAlignmentRule(
            name: name,
            aliases: aliases,
            requiredTokens: requiredTokens,
            allowedGeneralFormTokens: [],
            route: .oral,
            ester: nil,
            recordOnlyOralMedication: medication,
            doseParsingMode: .strengthInName,
            defaultUnitStrengthMG: nil,
            note: note
        )
    }

    static let rules: [MedicationAlignmentRule] = [
        compoundRule(
            name: "Estradiol oral tablet",
            aliases: ["estrace"],
            requiredTokens: ["estradiol"],
            allowedGeneralFormTokens: ["tablet", "caplet"],
            route: .oral,
            compound: .E2,
            defaultUnitStrengthMG: 2,
            note: "Matched estradiol tablets from Apple Health."
        ),
        MedicationAlignmentRule(
            name: String(localized: "medimport.rule.estradiol_valerate_oral_tablet"),
            aliases: ["progynova"],
            requiredTokens: ["estradiol", "valerate", "tablet"],
            allowedGeneralFormTokens: ["tablet", "caplet"],
            route: .oral,
            ester: .EV,
            recordOnlyOralMedication: nil,
            doseParsingMode: .strengthInName,
            defaultUnitStrengthMG: 2,
            note: "Matched estradiol valerate tablets from Apple Health."
        ),
        compoundRule(
            name: "Estradiol transdermal patch",
            aliases: ["climara", "vivelle", "vivelle dot", "dotti", "minivelle", "lyllana", "alora", "menostar"],
            requiredTokens: ["estradiol"],
            allowedGeneralFormTokens: patchForms,
            route: .patchApply,
            compound: .E2,
            note: "Matched estradiol patches from Apple Health."
        ),
        compoundRule(
            name: "Estradiol topical",
            aliases: ["divigel", "estrogel", "elestrin", "evamist"],
            requiredTokens: ["estradiol"],
            allowedGeneralFormTokens: topicalForms,
            route: .gel,
            compound: .E2,
            note: "Matched estradiol topical preparations from Apple Health."
        ),
        compoundRule(
            name: "Estradiol valerate injection",
            aliases: ["delestrogen"],
            requiredTokens: ["estradiol", "valerate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .EV,
            note: "Matched estradiol valerate injections from Apple Health."
        ),
        compoundRule(
            name: "Estradiol benzoate injection",
            requiredTokens: ["estradiol", "benzoate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .EB,
            note: "Matched estradiol benzoate injections from Apple Health."
        ),
        compoundRule(
            name: "Estradiol cypionate injection",
            requiredTokens: ["estradiol", "cypionate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .EC,
            note: "Matched estradiol cypionate injections from Apple Health."
        ),
        compoundRule(
            name: "Estradiol enanthate injection",
            requiredTokens: ["estradiol", "enanthate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .EN,
            note: "Matched estradiol enanthate injections from Apple Health."
        ),
        compoundRule(
            name: "Testosterone cypionate injection",
            aliases: ["depo testosterone", "depotestosterone"],
            requiredTokens: ["testosterone", "cypionate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .TC,
            note: "Matched testosterone cypionate injections from Apple Health."
        ),
        compoundRule(
            name: "Testosterone enanthate injection",
            aliases: ["delatestryl", "xyosted", "testoviron depot"],
            requiredTokens: ["testosterone", "enanthate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .TE,
            note: "Matched testosterone enanthate injections from Apple Health."
        ),
        compoundRule(
            name: "Testosterone undecanoate injection",
            aliases: ["aveed", "nebido", "reandron"],
            requiredTokens: ["testosterone", "undecanoate"],
            allowedGeneralFormTokens: injectionForms,
            route: .injection,
            compound: .TU,
            note: "Matched testosterone undecanoate injections from Apple Health."
        ),
        compoundRule(
            name: "Testosterone transdermal patch",
            aliases: ["androderm"],
            requiredTokens: ["testosterone"],
            allowedGeneralFormTokens: patchForms,
            route: .patchApply,
            compound: .T,
            note: "Matched testosterone patches from Apple Health."
        ),
        compoundRule(
            name: "Testosterone gel",
            aliases: ["androgel", "testim", "fortesta", "vogelxo", "testogel"],
            requiredTokens: ["testosterone", "gel"],
            allowedGeneralFormTokens: topicalForms,
            route: .gel,
            compound: .T,
            note: "Matched testosterone gel from Apple Health."
        ),
        compoundRule(
            name: "Testosterone topical",
            aliases: ["androgel", "testim", "fortesta", "vogelxo", "testogel"],
            requiredTokens: ["testosterone"],
            allowedGeneralFormTokens: topicalForms,
            route: .gel,
            compound: .T,
            note: "Matched testosterone topical preparations from Apple Health."
        ),
        compoundRule(
            name: "Testosterone undecanoate oral",
            aliases: ["jatenzo", "tlando", "kyzatrex"],
            requiredTokens: ["testosterone", "undecanoate"],
            allowedGeneralFormTokens: oralForms,
            route: .oral,
            compound: .TU,
            note: "Matched oral testosterone undecanoate from Apple Health."
        ),
        recordOnlyRule(
            name: String(localized: "medimport.rule.cyproterone_acetate_oral"),
            aliases: ["cpa"],
            requiredTokens: ["cyproterone", "acetate"],
            medication: .cyproteroneAcetate,
            note: "Matched cyproterone acetate from Apple Health."
        ),
        recordOnlyRule(
            name: String(localized: "medimport.rule.spironolactone_oral"),
            aliases: ["spiro"],
            requiredTokens: ["spironolactone"],
            medication: .spironolactone,
            note: "Matched spironolactone from Apple Health."
        ),
        recordOnlyRule(
            name: String(localized: "medimport.rule.bicalutamide_oral"),
            aliases: ["bica"],
            requiredTokens: ["bicalutamide"],
            medication: .bicalutamide,
            note: "Matched bicalutamide from Apple Health."
        ),
        recordOnlyRule(
            name: String(localized: "medimport.rule.finasteride_oral"),
            aliases: [],
            requiredTokens: ["finasteride"],
            medication: .finasteride,
            note: "Matched finasteride from Apple Health."
        ),
        recordOnlyRule(
            name: String(localized: "medimport.rule.dutasteride_oral"),
            aliases: [],
            requiredTokens: ["dutasteride"],
            medication: .dutasteride,
            note: "Matched dutasteride from Apple Health."
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

        return convertMassToMG(value: value, unit: String(text[unitRange]))
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

    static func parseConcentrationMGPerML(from text: String) -> Double? {
        parseStrengthPerUnit(from: text)
            .first { $0.denominatorUnit == "ml" && $0.denominatorQuantity > 0 }
            .map { $0.massMG / $0.denominatorQuantity }
    }

    static func parseStrengthPerUnit(from text: String) -> [MedicationStrengthPerUnit] {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(mg|mcg|ug|μg|µg|g)\s*/\s*(?:(\d+(?:[.,]\d+)?)\s*)?(ml|milliliters?|millilitres?|tablet(?:s)?|capsule(?:s)?|caplet(?:s)?|patch(?:es)?|pump(?:s)?|actuation(?:s)?|application(?:s)?|packet(?:s)?|sachet(?:s)?|dose(?:s)?|softgel(?:s)?|vial(?:s)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let massValueRange = Range(match.range(at: 1), in: text),
                  let massUnitRange = Range(match.range(at: 2), in: text),
                  let denominatorUnitRange = Range(match.range(at: 4), in: text) else {
                return nil
            }

            let valueText = text[massValueRange].replacingOccurrences(of: ",", with: ".")
            guard let massValue = Double(valueText),
                  let massMG = convertMassToMG(value: massValue, unit: String(text[massUnitRange])) else {
                return nil
            }

            let denominatorQuantity: Double
            if let explicitRange = Range(match.range(at: 3), in: text) {
                denominatorQuantity = Double(text[explicitRange].replacingOccurrences(of: ",", with: ".")) ?? 1
            } else {
                denominatorQuantity = 1
            }

            return MedicationStrengthPerUnit(
                massMG: massMG,
                denominatorQuantity: denominatorQuantity,
                denominatorUnit: normalizeUnit(String(text[denominatorUnitRange]))
            )
        }
    }

    static func parseReleaseRateUGPerDay(from text: String) -> Double? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        let pattern = #"(\d+(?:[.,]\d+)?)(mg|mcg|ug|μg|µg)/(day|24h|24hr|24hours|24hrs)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: normalized),
              let unitRange = Range(match.range(at: 2), in: normalized) else {
            return nil
        }

        let valueText = normalized[valueRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(valueText) else { return nil }
        let unit = String(normalized[unitRange])

        switch unit {
        case "mg":
            return value * 1000
        case "mcg", "ug", "μg", "µg":
            return value
        default:
            return nil
        }
    }

    private static func convertMassToMG(value: Double, unit: String) -> Double? {
        switch unit.lowercased() {
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

    private static func normalizeUnit(_ unit: String) -> String {
        unit.lowercased()
            .replacingOccurrences(of: "milliliters", with: "ml")
            .replacingOccurrences(of: "milliliter", with: "ml")
            .replacingOccurrences(of: "millilitres", with: "ml")
            .replacingOccurrences(of: "millilitre", with: "ml")
            .replacingOccurrences(of: "tablets", with: "tablet")
            .replacingOccurrences(of: "capsules", with: "capsule")
            .replacingOccurrences(of: "caplets", with: "caplet")
            .replacingOccurrences(of: "patches", with: "patch")
            .replacingOccurrences(of: "pumps", with: "pump")
            .replacingOccurrences(of: "actuations", with: "actuation")
            .replacingOccurrences(of: "applications", with: "application")
            .replacingOccurrences(of: "packets", with: "packet")
            .replacingOccurrences(of: "sachets", with: "sachet")
            .replacingOccurrences(of: "doses", with: "dose")
            .replacingOccurrences(of: "softgels", with: "softgel")
            .replacingOccurrences(of: "vials", with: "vial")
    }
}

struct MedicationStrengthPerUnit: Sendable {
    let massMG: Double
    let denominatorQuantity: Double
    let denominatorUnit: String
}
