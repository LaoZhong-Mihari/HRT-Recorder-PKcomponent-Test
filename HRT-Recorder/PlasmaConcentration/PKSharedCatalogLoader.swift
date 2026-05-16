import Foundation

struct PKSharedCatalogResource: Sendable {
    struct HormoneConfig: Sendable {
        let displayName: String
        let concentrationUnit: ConcentrationUnit
        let vdPerKG: Double
        let kClear: Double
        let kClearInjection: Double
        let depotK1Corr: Double
        let patchFallbackK1: Double
        let patchReleaseScale: Double
        let gelK1: Double
        let gelFmax: Double
    }

    struct CompoundConfig: Sendable {
        let fullName: String
        let hormone: SimulatedHormone
        let molecularWeight: Double
        let activeMolecularWeight: Double
        let isProdrug: Bool
    }

    struct TwoPartDepotConfig: Sendable {
        let fracFast: Double
        let k1Fast: Double
        let k1Slow: Double
    }

    struct OralDualConfig: Sendable {
        let fracFast: Double
        let kAbsFast: Double
        let kAbsSlow: Double
        let bioavailabilityFast: Double
        let bioavailabilitySlow: Double
        let kClear: Double
        let lagHoursFast: Double
        let lagHoursSlow: Double
    }

    let hormones: [SimulatedHormone: HormoneConfig]
    let compounds: [Compound: CompoundConfig]
    let twoPartDepot: [Compound: TwoPartDepotConfig]
    let formationFraction: [Compound: Double]
    let hydrolysisK2: [Compound: Double]
    let oralKAbs: [Compound: Double]
    let oralBioavailability: [Compound: Double]
    let oralDualAbsorption: [Compound: OralDualConfig]
    let kAbsSL: Double
    let sublingualRecommendedTheta: [SublingualTier: Double]
    let sublingualHoldMinutes: [SublingualTier: Double]
    let sublingualThetaRangeLow: [SublingualTier: Double]
    let sublingualThetaRangeHigh: [SublingualTier: Double]

    static let current = load()
}

private extension PKSharedCatalogResource {
    struct Document: Decodable {
        struct HormoneDocument: Decodable {
            let displayName: String
            let concentrationUnit: String
            let vdPerKG: Double
            let kClear: Double
            let kClearInjection: Double
            let depotK1Corr: Double
            let patchFallbackK1: Double
            let patchReleaseScale: Double?
            let gelK1: Double
            let gelFmax: Double
        }

        struct CompoundDocument: Decodable {
            let fullName: String
            let hormone: String
            let molecularWeight: Double
            let activeMolecularWeight: Double
            let isProdrug: Bool
        }

        struct TwoPartDepotDocument: Decodable {
            let fracFast: Double
            let k1Fast: Double
            let k1Slow: Double
        }

        struct OralDocument: Decodable {
            struct DualAbsorptionDocument: Decodable {
                let fracFast: Double
                let kAbsFast: Double
                let kAbsSlow: Double
                let bioavailabilityFast: Double
                let bioavailabilitySlow: Double
                let kClear: Double
                let lagHoursFast: Double?
                let lagHoursSlow: Double?
            }

            let kAbs: [String: Double]
            let bioavailability: [String: Double]
            let dualAbsorption: [String: DualAbsorptionDocument]?
            let kAbsSL: Double
        }

        struct SublingualDocument: Decodable {
            let recommendedTheta: [String: Double]
            let holdMinutes: [String: Double]
            let thetaRangeLow: [String: Double]
            let thetaRangeHigh: [String: Double]
        }

        let hormones: [String: HormoneDocument]
        let compounds: [String: CompoundDocument]
        let twoPartDepot: [String: TwoPartDepotDocument]
        let formationFraction: [String: Double]
        let hydrolysisK2: [String: Double]
        let oral: OralDocument
        let sublingual: SublingualDocument
    }

    static func load() -> PKSharedCatalogResource {
        guard let url = resourceURL() else {
            fatalError("Missing PKSharedCatalog.json in app bundle.")
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)
            return makeResource(from: document)
        } catch {
            fatalError("Failed to decode PKSharedCatalog.json: \(error)")
        }
    }

    static func resourceURL() -> URL? {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "PKSharedCatalog", withExtension: "json") {
                return url
            }
        }
        return nil
    }

    static func makeResource(from document: Document) -> PKSharedCatalogResource {
        let hormones: [SimulatedHormone: HormoneConfig] = Dictionary(uniqueKeysWithValues: document.hormones.compactMap { key, value in
            guard let hormone = SimulatedHormone(rawValue: key),
                  let unit = ConcentrationUnit(rawValue: value.concentrationUnit) else {
                return nil
            }
            return (
                hormone,
                HormoneConfig(
                    displayName: value.displayName,
                    concentrationUnit: unit,
                    vdPerKG: value.vdPerKG,
                    kClear: value.kClear,
                    kClearInjection: value.kClearInjection,
                    depotK1Corr: value.depotK1Corr,
                    patchFallbackK1: value.patchFallbackK1,
                    patchReleaseScale: value.patchReleaseScale ?? 1.0,
                    gelK1: value.gelK1,
                    gelFmax: value.gelFmax
                )
            )
        })

        let compounds: [Compound: CompoundConfig] = Dictionary(uniqueKeysWithValues: document.compounds.compactMap { key, value in
            guard let compound = Compound(rawValue: key),
                  let hormone = SimulatedHormone(rawValue: value.hormone) else {
                return nil
            }
            return (
                compound,
                CompoundConfig(
                    fullName: value.fullName,
                    hormone: hormone,
                    molecularWeight: value.molecularWeight,
                    activeMolecularWeight: value.activeMolecularWeight,
                    isProdrug: value.isProdrug
                )
            )
        })

        let twoPartDepot: [Compound: TwoPartDepotConfig] = Dictionary(uniqueKeysWithValues: document.twoPartDepot.compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (compound, TwoPartDepotConfig(fracFast: value.fracFast, k1Fast: value.k1Fast, k1Slow: value.k1Slow))
        })

        let formationFraction: [Compound: Double] = Dictionary(uniqueKeysWithValues: document.formationFraction.compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let hydrolysisK2: [Compound: Double] = Dictionary(uniqueKeysWithValues: document.hydrolysisK2.compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralKAbs: [Compound: Double] = Dictionary(uniqueKeysWithValues: document.oral.kAbs.compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralBioavailability: [Compound: Double] = Dictionary(uniqueKeysWithValues: document.oral.bioavailability.compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralDualAbsorption: [Compound: OralDualConfig] = Dictionary(uniqueKeysWithValues: (document.oral.dualAbsorption ?? [:]).compactMap { key, value in
            guard let compound = Compound(rawValue: key) else { return nil }
            return (
                compound,
                OralDualConfig(
                    fracFast: value.fracFast,
                    kAbsFast: value.kAbsFast,
                    kAbsSlow: value.kAbsSlow,
                    bioavailabilityFast: value.bioavailabilityFast,
                    bioavailabilitySlow: value.bioavailabilitySlow,
                    kClear: value.kClear,
                    lagHoursFast: value.lagHoursFast ?? 0,
                    lagHoursSlow: value.lagHoursSlow ?? 0
                )
            )
        })

        let sublingualRecommendedTheta: [SublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.recommendedTheta.compactMap { key, value in
            guard let tier = SublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualHoldMinutes: [SublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.holdMinutes.compactMap { key, value in
            guard let tier = SublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualThetaRangeLow: [SublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.thetaRangeLow.compactMap { key, value in
            guard let tier = SublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualThetaRangeHigh: [SublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.thetaRangeHigh.compactMap { key, value in
            guard let tier = SublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })

        return PKSharedCatalogResource(
            hormones: hormones,
            compounds: compounds,
            twoPartDepot: twoPartDepot,
            formationFraction: formationFraction,
            hydrolysisK2: hydrolysisK2,
            oralKAbs: oralKAbs,
            oralBioavailability: oralBioavailability,
            oralDualAbsorption: oralDualAbsorption,
            kAbsSL: document.oral.kAbsSL,
            sublingualRecommendedTheta: sublingualRecommendedTheta,
            sublingualHoldMinutes: sublingualHoldMinutes,
            sublingualThetaRangeLow: sublingualThetaRangeLow,
            sublingualThetaRangeHigh: sublingualThetaRangeHigh
        )
    }
}
