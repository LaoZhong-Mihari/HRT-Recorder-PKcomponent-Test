//  HRT-Recorder
//    Created by mihari-zhong
//
//  Shared PK metadata for estradiol / testosterone modeling in the iPhone app.

import Foundation
import SwiftUI

enum MedicationCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case estradiol
    case testosterone
    case antiAndrogen

    nonisolated var id: Self { self }

    nonisolated var simulatedHormone: SimulatedHormone? {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        case .antiAndrogen: return nil
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .estradiol: return SimulatedHormone.estradiol.displayName
        case .testosterone: return SimulatedHormone.testosterone.displayName
        case .antiAndrogen: return String(localized: "Anti-androgen")
        }
    }
}

enum SimulatedHormone: String, CaseIterable, Identifiable, Codable, Sendable {
    case estradiol
    case testosterone

    nonisolated var id: Self { self }

    nonisolated var category: MedicationCategory {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .estradiol:
            return String(localized: "Estradiol")
        case .testosterone:
            return String(localized: "Testosterone")
        }
    }

    nonisolated var concentrationUnit: ConcentrationUnit {
        switch self {
        case .estradiol: return .pgPerML
        case .testosterone: return .ngPerDL
        }
    }

    nonisolated var chartColor: Color {
        switch self {
        case .estradiol:
            return Color(red: 0.95, green: 0.50, blue: 0.74)
        case .testosterone:
            return .blue
        }
    }
}

enum ConcentrationUnit: String, Codable, Sendable {
    case pgPerML
    case ngPerDL

    nonisolated var symbol: String {
        switch self {
        case .pgPerML: return "pg/mL"
        case .ngPerDL: return "ng/dL"
        }
    }

    nonisolated var concentrationScale: Double {
        switch self {
        case .pgPerML: return 1e9
        case .ngPerDL: return 1e8
        }
    }

    nonisolated var aucSymbol: String {
        switch self {
        case .pgPerML: return "pg·h/mL"
        case .ngPerDL: return "ng·h/dL"
        }
    }
}

struct SimulationDisplayMetadata: Equatable, Codable, Sendable {
    let hormone: SimulatedHormone
    let concentrationUnit: ConcentrationUnit

    nonisolated var concentrationSymbol: String { concentrationUnit.symbol }
    nonisolated var aucSymbol: String { concentrationUnit.aucSymbol }
}

enum Compound: String, CaseIterable, Identifiable, Codable, Sendable {
    case E2, EB, EV, EC, EN
    case T, TC, TE, TU

    nonisolated var id: Self { self }

    nonisolated var info: CompoundInfo { CompoundInfo.by(compound: self) }

    nonisolated var fullName: String { info.fullName }

    nonisolated var hormone: SimulatedHormone { info.hormone }

    nonisolated var medicationCategory: MedicationCategory { hormone.category }

    nonisolated var localizedNameKey: LocalizedStringKey {
        LocalizedStringKey("compound.\(rawValue).name")
    }

    nonisolated var abbreviation: String {
        NSLocalizedString(
            "compound.\(rawValue).abbr",
            tableName: nil,
            bundle: .main,
            value: rawValue,
            comment: "Localized compound abbreviation"
        )
    }
}

typealias Ester = Compound
typealias EsterInfo = CompoundInfo

struct CompoundInfo: Sendable {
    let compound: Compound
    let fullName: String
    let hormone: SimulatedHormone
    let molecularWeight: Double
    let activeMolecularWeight: Double
    let isProdrug: Bool

    var toActiveFactor: Double {
        activeMolecularWeight / molecularWeight
    }

    var toE2Factor: Double {
        toActiveFactor
    }

    private static let all: [Compound: CompoundInfo] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.compounds.map { compound, config in
            (
                compound,
                CompoundInfo(
                    compound: compound,
                    fullName: config.fullName,
                    hormone: config.hormone,
                    molecularWeight: config.molecularWeight,
                    activeMolecularWeight: config.activeMolecularWeight,
                    isProdrug: config.isProdrug
                )
            )
        }
    )

    nonisolated static func by(compound: Compound) -> CompoundInfo {
        all[compound]!
    }

    nonisolated static func by(ester: Compound) -> CompoundInfo {
        by(compound: ester)
    }
}

struct HormoneCoreParams: Sendable {
    let vdPerKG: Double
    let kClear: Double
    let kClearInjection: Double
    let depotK1Corr: Double
}

struct CorePK {
    static let byHormone: [SimulatedHormone: HormoneCoreParams] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.hormones.map { hormone, config in
            (
                hormone,
                HormoneCoreParams(
                    vdPerKG: config.vdPerKG,
                    kClear: config.kClear,
                    kClearInjection: config.kClearInjection,
                    depotK1Corr: config.depotK1Corr
                )
            )
        }
    )

    nonisolated static func params(for hormone: SimulatedHormone) -> HormoneCoreParams {
        byHormone[hormone] ?? byHormone[.estradiol]!
    }

    static let vdPerKG: Double = byHormone[.estradiol]!.vdPerKG
    static let kClear: Double = byHormone[.estradiol]!.kClear
    static let kClearInjection: Double = byHormone[.estradiol]!.kClearInjection
    static let depotK1Corr: Double = byHormone[.estradiol]!.depotK1Corr
}

struct TwoPartDepotParams: Sendable {
    let fracFast: Double
    let k1Fast: Double
    let k1Slow: Double
}

struct TwoPartDepotPK {
    static let params: [Compound: TwoPartDepotParams] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.twoPartDepot.map { compound, config in
            (compound, TwoPartDepotParams(fracFast: config.fracFast, k1Fast: config.k1Fast, k1Slow: config.k1Slow))
        }
    )

    nonisolated static func params(for compound: Compound) -> TwoPartDepotParams? {
        params[compound]
    }
}

struct InjectionPK {
    /// Effective formation / systemic fraction used by the simplified engine.
    static let formationFraction: [Compound: Double] = PKSharedCatalogResource.current.formationFraction
}

struct CompoundHydrolysisPK {
    static let k2: [Compound: Double] = PKSharedCatalogResource.current.hydrolysisK2
}

enum PatchRelease {
    case firstOrder(k1: Double)
    case zeroOrder(rateMGh: Double)
}

struct PatchPK {
    static let fallbackK1ByHormone: [SimulatedHormone: Double] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.hormones.map { ($0.key, $0.value.patchFallbackK1) }
    )

    nonisolated static func generic(for hormone: SimulatedHormone) -> PatchRelease {
        .firstOrder(k1: fallbackK1ByHormone[hormone] ?? 0.0075)
    }
}

struct TransdermalGelPK {
    static func parameters(doseMG: Double, areaCM2: Double, hormone: SimulatedHormone) -> (k1: Double, F: Double) {
        guard doseMG > 0 else { return (0, 0) }
        let config = PKSharedCatalogResource.current.hormones[hormone]
        return (config?.gelK1 ?? 0, config?.gelFmax ?? 0)
    }
}

struct OralPK {
    static let kAbsByCompound: [Compound: Double] = PKSharedCatalogResource.current.oralKAbs
    static let bioavailabilityByCompound: [Compound: Double] = PKSharedCatalogResource.current.oralBioavailability
    static let kAbsSL: Double = PKSharedCatalogResource.current.kAbsSL

    nonisolated static func kAbs(for compound: Compound) -> Double {
        kAbsByCompound[compound] ?? 0
    }

    nonisolated static func bioavailability(for compound: Compound) -> Double {
        bioavailabilityByCompound[compound] ?? 0
    }
}

enum SublingualTier: String, CaseIterable, Identifiable {
    case quick, casual, standard, strict
    var id: Self { self }
}

struct SublingualTheta {
    static let recommended: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualRecommendedTheta
    static let holdMinutes: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualHoldMinutes
    static let thetaRangeLow: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualThetaRangeLow
    static let thetaRangeHigh: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualThetaRangeHigh
}

enum CompoundSupport {
    static func availableCompounds(for category: MedicationCategory, route: DoseEvent.Route) -> [Compound] {
        switch category {
        case .antiAndrogen:
            return [.E2]
        case .estradiol:
            switch route {
            case .injection: return [.EB, .EV, .EC, .EN]
            case .patchApply, .patchRemove, .gel: return [.E2]
            case .oral, .sublingual: return [.E2, .EV]
            }
        case .testosterone:
            switch route {
            case .injection: return [.TC, .TE, .TU]
            case .patchApply, .patchRemove, .gel: return [.T]
            case .oral: return [.TU]
            case .sublingual: return []
            }
        }
    }
}
