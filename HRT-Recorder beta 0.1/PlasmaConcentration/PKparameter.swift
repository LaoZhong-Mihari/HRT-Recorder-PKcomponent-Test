//  HRT-Recorder
//    Created by mihari-zhong

//  EB / EV / EC / EN 注射油剂 + 贴片 + 凝胶 + 口服
//  所有速率常数单位：h⁻¹

import Foundation
import SwiftUI

// MARK: - Core
struct CorePK {
    static let vdPerKG: Double = 2.0   // L kg^-1
    /// 自由雌二醇清除速率常数 (k₃)
    static let kClear: Double = 0.41
    static let kClearInjection: Double = 0.041
    static let depotK1Corr: Double = 1.0   // 全局修正系数：乘到注射 k1_fast/k1_slow
}

// MARK: - Injection · Two-Part Depot Model
//
// Models the injection depot as two parallel first-order compartments
// to better control the peak (Tmax/Cmax) and tail of the curve.
// This provides a more stable profile and faster approach to steady-state.
//
struct TwoPartDepotPK {
    /// The fraction of the dose that goes into the "fast" absorption depot (0-1).
    /// The rest (1 - Frac_fast) goes into the "slow" depot.
    static let Frac_fast: [Ester: Double] = [
        .EB: 0.90,
        .EV: 0.40,
        .EC: 0.229164549,
        .EN: 0.05
    ]
    
    /// Absorption rate constant for the fast depot (h⁻¹).
    /// Primarily controls Tmax and Cmax.
    static let k1_fast: [Ester: Double] = [
        .EB: 0.144,
        .EV: 0.0216,
        .EC: 0.005035046,
        .EN: 0.0010
    ]
    
    /// Absorption rate constant for the slow depot (h⁻¹).
    /// Primarily controls the terminal half-life (the tail).
    static let k1_slow: [Ester: Double] = [
        .EB: 0.114,
        .EV: 0.0138,
        .EC: 0.004510574,
        .EN: 0.0050
    ]
}
struct InjectionPK {
    /// 形成游离 E2 的经验分数（本项目所有剂量已按 E2‑eq 输入）
    /// 最终 F = formationFraction
    static let formationFraction: [Ester: Double] = [
        .EB: 0.10922376473734707,
        .EV: 0.062258288229969413,
        .EC: 0.117255838,
        .EN: 0.12
    ]
}
// MARK: - Esters (水解速率 k₂)

// Conforms to Identifiable for easier use in SwiftUI Pickers.
enum Ester: String, CaseIterable, Identifiable, Codable, Sendable {
    case E2, EB, EV, EC, EN
    nonisolated var id: Self { self }

    /// Provides the full name for display in pickers.
    nonisolated var fullName: String { EsterInfo.by(ester: self).fullName }

    /// Localized full display name for UI pickers.
    nonisolated var localizedNameKey: LocalizedStringKey {
        LocalizedStringKey("ester.\(rawValue).name")
    }

    /// Localized abbreviation (e.g. "EV" → localized or transliterated).
    nonisolated var abbreviation: String {
        NSLocalizedString("ester.\(rawValue).abbr", comment: "Localized ester abbreviation")
    }
}

struct EsterInfo {
    let ester: Ester
    let fullName: String
    let molecularWeight: Double
    
    // Molecular weight of pure Estradiol (E2)
    static let e2MolecularWeight: Double = 272.38 // g/mol

    // Conversion factor from this ester to pure E2
    var toE2Factor: Double {
        // For E2 itself, the factor is 1.
        guard ester != .E2 else { return 1.0 }
        return EsterInfo.e2MolecularWeight / self.molecularWeight
    }

    // Static dictionary to access info for each ester
    private static let all: [Ester: EsterInfo] = [
        .E2: .init(ester: .E2, fullName: "Estradiol", molecularWeight: 272.38),
        .EB: .init(ester: .EB, fullName: "Estradiol Benzoate", molecularWeight: 376.50), // C25H28O2
        .EV: .init(ester: .EV, fullName: "Estradiol Valerate", molecularWeight: 356.50), // C23H32O3
        .EC: .init(ester: .EC, fullName: "Estradiol Cypionate", molecularWeight: 396.58),// C26H36O3
        .EN: .init(ester: .EN, fullName: "Estradiol Enanthate", molecularWeight: 384.56) // C25H36O3
    ]
    
    nonisolated static func by(ester: Ester) -> EsterInfo {
        return all[ester]!
    }
}

struct EsterPK {
    /// 血浆/肝酯酶水解速率常数 k₂
    static let k2: [Ester: Double] = [
        .EB: 0.090,   // t½ ≈ 7.7 h
        .EV: 0.070,   // t½ ≈ 9.9 h
        .EC: 0.045,   // t½ ≈ 15.4 h
        .EN: 0.015    // t½ ≈ 46.21 h
    ]
}

// MARK: - Transdermal Patch 还没想好要怎么写

/// Defines the release model for a transdermal patch.
enum PatchRelease {
    /// First‑order depot → skin flux with one parameter k₁ (h⁻¹)
    case firstOrder(k1: Double)

    /// Zero‑order constant infusion rate directly into skin (mg h⁻¹)
    case zeroOrder(rateMGh: Double)
}

struct PatchPK {
    /// General-purpose patch: high payload, approximated by first‑order release
    static let generic: PatchRelease = .firstOrder(k1: 0.0075)   // k₁ ≈ 3.8 d t½
}

// MARK: - Transdermal Gel (dose & area dependent)

struct TransdermalGelPK {
    // Baseline parameters from EstroGel 0.75 mg on 750 cm²
    private static let baseK1: Double = 0.022      // h⁻¹  (t½ ≈ 36 h)
    private static let sigmaSat: Double = 0.0080      // mg / cm²  (0.8 µg cm⁻²) slightly <0.75/750
    private static let Fmax: Double = 0.05

    /// Compute k1 and F for a given daily dose (mg) and spread area (cm²)
    static func parameters(doseMG: Double, areaCM2: Double)
         -> (k1: Double, F: Double) {
        // NOTE: Temporary simple model that ignores spread area.
        // Always returns the baseline k1 and a fixed F (Fmax).
        // This is for quick testing; restore dose‑ and area‑dependent logic later if needed.
        guard doseMG > 0 else { return (0, 0) }

        let k1 = baseK1       // constant absorption rate
        let F  = Fmax         // constant systemic fraction
        return (k1, F)
    }
}

// MARK: - Oral Tablets (free E2 vs. ester) / Sublingual

struct OralPK {
    /// Absorption rate constants (ka) in h⁻¹
    static let kAbsE2: Double = 0.32   // free micronised estradiol (Tmax ≈ 2–3 h)
    static let kAbsEV: Double = 0.05   // estradiol valerate tablet (Tmax ≈ 6–7 h)
    
    /// Systemic bioavailability (first‑pass) – similar for E2 and EV
    static let bioavailability: Double = 0.03
    
    /// Sublingual absorption (1st-order) – tuned for ~1 h Tmax under current kClear
    static let kAbsSL: Double = 1.8   // h⁻¹  (与 CorePK.kClear=0.41 配合 → Tmax ≈ 1 h)
    
    /// 注意：
    /// - 舌下的分流系数 θ 不再由 RF 反推，也不再有全局默认值。
    /// - θ 由 UI 档位（Quick/Casual/Standard/Strict）或每次剂量的 extras 指定（.sublingualTheta）。
}

// MARK: - Sublingual behavior tiers (UI → θ 映射)
//
// 依据“溶解 + 黏膜吸收 + 吞咽清除”的最小口腔模型数值积分（kSL=1.8 h^-1，k_sw=1.8 h^-1，t1/2,diss=5 min 的中档场景），
// 给出四档档位的推荐 θ，并附上在低/中/高吞咽清除与不同溶解半衰期下的参考区间。
//
enum SublingualTier: String, CaseIterable, Identifiable {
    case quick, casual, standard, strict
    var id: Self { self }
}

struct SublingualTheta {
    /// 推荐 θ（中档场景）
    static let recommended: [SublingualTier: Double] = [
        .quick:   0.01,   // ≈ 2 min 含服
        .casual:  0.04,   // ≈ 5 min 含服
        .standard:0.11,   // ≈ 10 min 含服
        .strict:  0.18    // ≈ 15 min 含服
    ]
    /// 建议含服时长（分钟），用于 UI 提示
    static let holdMinutes: [SublingualTier: Double] = [
        .quick:   2,
        .casual:  5,
        .standard:10,
        .strict:  15
    ]
    /// 参考区间（跨不同 k_sw 与 k_diss 的数值积分范围）
    static let thetaRangeLow: [SublingualTier: Double] = [
        .quick:   0.004,
        .casual:  0.021,
        .standard:0.064,
        .strict:  0.115
    ]
    static let thetaRangeHigh: [SublingualTier: Double] = [
        .quick:   0.012,
        .casual:  0.057,
        .standard:0.156,
        .strict:  0.253
    ]
}

// MARK: - Notes on injection-specific kClear
// The kClearInjection parameter is an effective parameter used only for injection routes.
// It preserves flip-flop kinetics (absorption-limited) to match literature Tmax/Cmax for oil-based IM esters.
// It must not be interpreted as the physiological clearance rate of free E2.

// Note: All doses are provided as E2‑equivalents; do not multiply F by toE2Factor in any route.
