import Foundation

struct WatchPKSharedCatalogResource {
    struct HormoneConfig {
        let displayName: String
        let concentrationUnit: WatchConcentrationUnit
        let vdPerKG: Double
        let kClear: Double
        let kClearInjection: Double
        let depotK1Corr: Double
        let patchFallbackK1: Double
        let gelK1: Double
        let gelFmax: Double
    }

    struct CompoundConfig {
        let fullName: String
        let hormone: WatchSimulatedHormone
        let molecularWeight: Double
        let activeMolecularWeight: Double
        let isProdrug: Bool
    }

    struct TwoPartDepotConfig {
        let fracFast: Double
        let k1Fast: Double
        let k1Slow: Double
    }

    struct OralDualConfig {
        let fracFast: Double
        let kAbsFast: Double
        let kAbsSlow: Double
        let bioavailabilityFast: Double
        let bioavailabilitySlow: Double
        let kClear: Double
    }

    let hormones: [WatchSimulatedHormone: HormoneConfig]
    let compounds: [WatchCompound: CompoundConfig]
    let twoPartDepot: [WatchCompound: TwoPartDepotConfig]
    let formationFraction: [WatchCompound: Double]
    let hydrolysisK2: [WatchCompound: Double]
    let oralKAbs: [WatchCompound: Double]
    let oralBioavailability: [WatchCompound: Double]
    let oralDualAbsorption: [WatchCompound: OralDualConfig]
    let kAbsSL: Double
    let sublingualRecommendedTheta: [WatchSublingualTier: Double]
    let sublingualHoldMinutes: [WatchSublingualTier: Double]
    let sublingualThetaRangeLow: [WatchSublingualTier: Double]
    let sublingualThetaRangeHigh: [WatchSublingualTier: Double]

    static let current = load()
}

private extension WatchPKSharedCatalogResource {
    struct Document: Decodable {
        struct HormoneDocument: Decodable {
            let displayName: String
            let concentrationUnit: String
            let vdPerKG: Double
            let kClear: Double
            let kClearInjection: Double
            let depotK1Corr: Double
            let patchFallbackK1: Double
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

    static func load() -> WatchPKSharedCatalogResource {
        guard let url = resourceURL() else {
            fatalError("Missing PKSharedCatalog.json in watch bundle.")
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)
            return makeResource(from: document)
        } catch {
            fatalError("Failed to decode PKSharedCatalog.json for watch: \(error)")
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

    static func makeResource(from document: Document) -> WatchPKSharedCatalogResource {
        let hormones: [WatchSimulatedHormone: HormoneConfig] = Dictionary(uniqueKeysWithValues: document.hormones.compactMap { key, value in
            guard let hormone = WatchSimulatedHormone(rawValue: key),
                  let unit = WatchConcentrationUnit(rawValue: value.concentrationUnit) else {
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
                    gelK1: value.gelK1,
                    gelFmax: value.gelFmax
                )
            )
        })

        let compounds: [WatchCompound: CompoundConfig] = Dictionary(uniqueKeysWithValues: document.compounds.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key),
                  let hormone = WatchSimulatedHormone(rawValue: value.hormone) else {
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

        let twoPartDepot: [WatchCompound: TwoPartDepotConfig] = Dictionary(uniqueKeysWithValues: document.twoPartDepot.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (compound, TwoPartDepotConfig(fracFast: value.fracFast, k1Fast: value.k1Fast, k1Slow: value.k1Slow))
        })

        let formationFraction: [WatchCompound: Double] = Dictionary(uniqueKeysWithValues: document.formationFraction.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let hydrolysisK2: [WatchCompound: Double] = Dictionary(uniqueKeysWithValues: document.hydrolysisK2.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralKAbs: [WatchCompound: Double] = Dictionary(uniqueKeysWithValues: document.oral.kAbs.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralBioavailability: [WatchCompound: Double] = Dictionary(uniqueKeysWithValues: document.oral.bioavailability.compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (compound, value)
        })

        let oralDualAbsorption: [WatchCompound: OralDualConfig] = Dictionary(uniqueKeysWithValues: (document.oral.dualAbsorption ?? [:]).compactMap { key, value in
            guard let compound = WatchCompound(rawValue: key) else { return nil }
            return (
                compound,
                OralDualConfig(
                    fracFast: value.fracFast,
                    kAbsFast: value.kAbsFast,
                    kAbsSlow: value.kAbsSlow,
                    bioavailabilityFast: value.bioavailabilityFast,
                    bioavailabilitySlow: value.bioavailabilitySlow,
                    kClear: value.kClear
                )
            )
        })

        let sublingualRecommendedTheta: [WatchSublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.recommendedTheta.compactMap { key, value in
            guard let tier = WatchSublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualHoldMinutes: [WatchSublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.holdMinutes.compactMap { key, value in
            guard let tier = WatchSublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualThetaRangeLow: [WatchSublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.thetaRangeLow.compactMap { key, value in
            guard let tier = WatchSublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })
        let sublingualThetaRangeHigh: [WatchSublingualTier: Double] = Dictionary(uniqueKeysWithValues: document.sublingual.thetaRangeHigh.compactMap { key, value in
            guard let tier = WatchSublingualTier(rawValue: key) else { return nil }
            return (tier, value)
        })

        return WatchPKSharedCatalogResource(
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
