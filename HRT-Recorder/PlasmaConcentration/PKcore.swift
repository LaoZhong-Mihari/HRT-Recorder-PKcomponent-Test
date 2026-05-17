//
//  PKcore.swift
//
//
//  Created by mihari-zhong on 2025/7/30.
//
//  This file is UI‑agnostic.  It exposes:
//      • DoseEvent               – single dosing event with typed extras
//      • ParameterResolver       – pulls k₁/k₂/k₃/F from parameter library
//      • ThreeCompartmentModel   – analytic 3‑C + helpers for gel/oral
//      • SimulationEngine        – adaptive‑step integrator → Result
//
//  The code assumes the existing PKparameter.swift is in target.
//  BW (body‑weight) and Vd per kg are user‑configurable.


import Foundation
import Accelerate

// MARK: – Public dose event -------------------------------------------------

struct DoseEvent: Equatable, Identifiable, Codable, Sendable {
    let id: UUID
    
    static func == (lhs: DoseEvent, rhs: DoseEvent) -> Bool {
        return lhs.id == rhs.id
    }
    
    enum Route: String, Codable {
        case injection, patchApply, patchRemove, gel, oral, sublingual
    }
    enum ExtraKey: String, Codable {
        case concentrationMGmL, areaCM2
        case rawCompoundDoseMG      // original compound dose entered by the user
        case releaseRateUGPerDay      // for zero‑order patch: µg day⁻¹
        case sublingualTheta
        case sublingualTier          // 0: quick, 1: casual, 2: standard, 3: strict
    }
    let category: MedicationCategory
    let route: Route
    let timeH: Double
    let doseMG: Double
    let compound: Compound
    let extras: [ExtraKey: Double]
    let recordOnlyOralMedication: RecordOnlyOralMedication?

    init(
        id: UUID,
        category: MedicationCategory? = nil,
        route: Route,
        timeH: Double,
        doseMG: Double,
        compound: Compound,
        extras: [ExtraKey: Double],
        recordOnlyOralMedication: RecordOnlyOralMedication?
    ) {
        let resolvedCategory = category
            ?? (recordOnlyOralMedication != nil ? .antiAndrogen : compound.medicationCategory)

        self.id = id
        self.category = resolvedCategory
        self.route = route
        self.timeH = timeH
        self.doseMG = doseMG
        self.compound = compound
        self.extras = extras
        self.recordOnlyOralMedication = recordOnlyOralMedication
    }

    init(
        id: UUID,
        category: MedicationCategory? = nil,
        route: Route,
        timeH: Double,
        doseMG: Double,
        ester: Ester,
        extras: [ExtraKey: Double],
        recordOnlyOralMedication: RecordOnlyOralMedication?
    ) {
        self.init(
            id: id,
            category: category,
            route: route,
            timeH: timeH,
            doseMG: doseMG,
            compound: ester,
            extras: extras,
            recordOnlyOralMedication: recordOnlyOralMedication
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case route
        case timeH
        case doseMG
        case compound
        case ester
        case extras
        case recordOnlyOralMedication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let route = try container.decode(Route.self, forKey: .route)
        let timeH = try container.decode(Double.self, forKey: .timeH)
        let doseMG = try container.decode(Double.self, forKey: .doseMG)
        let compound = try container.decodeIfPresent(Compound.self, forKey: .compound)
            ?? container.decode(Compound.self, forKey: .ester)
        let extras = try container.decodeIfPresent([ExtraKey: Double].self, forKey: .extras) ?? [:]
        let recordOnly = try container.decodeIfPresent(RecordOnlyOralMedication.self, forKey: .recordOnlyOralMedication)
        let category = try container.decodeIfPresent(MedicationCategory.self, forKey: .category)

        self.init(
            id: id,
            category: category,
            route: route,
            timeH: timeH,
            doseMG: doseMG,
            compound: compound,
            extras: extras,
            recordOnlyOralMedication: recordOnly
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(category, forKey: .category)
        try container.encode(route, forKey: .route)
        try container.encode(timeH, forKey: .timeH)
        try container.encode(doseMG, forKey: .doseMG)
        try container.encode(compound, forKey: .compound)
        try container.encode(extras, forKey: .extras)
        try container.encodeIfPresent(recordOnlyOralMedication, forKey: .recordOnlyOralMedication)
    }
}

extension DoseEvent {
    nonisolated var ester: Ester { compound }

    nonisolated var rawDoseMG: Double {
        if recordOnlyOralMedication != nil || route == .patchApply {
            return doseMG
        }

        if let rawDose = extras[.rawCompoundDoseMG], rawDose > 0 {
            return rawDose
        }

        let factor = compound.info.toActiveFactor
        guard doseMG > 0, factor > 0 else { return doseMG }
        return doseMG / factor
    }

    nonisolated var simulatedHormone: SimulatedHormone? {
        category.simulatedHormone
    }

    nonisolated var participatesInSimulation: Bool {
        recordOnlyOralMedication == nil && simulatedHormone != nil
    }

    nonisolated func appearsInTimeline(for hormone: SimulatedHormone) -> Bool {
        switch category {
        case .estradiol:
            return hormone == .estradiol
        case .testosterone:
            return hormone == .testosterone
        case .antiAndrogen:
            return hormone == .estradiol
        }
    }
}

// MARK: – Parameter bundle after resolution ---------------------------------

// MODIFIED: Switched to Two-Part Depot model parameters.
struct PKParams: Sendable {
    let Frac_fast: Double
    let k1_fast: Double
    let k1_slow: Double
    let k2: Double
    let k3: Double
    let F: Double
    let rateMGh: Double    // zero‑order (patch); 0 otherwise
    
    let F_fast: Double
    let F_slow: Double
    let lagFastH: Double
    let lagSlowH: Double
}

// MARK: – Resolver -----------------------------------------------------------

struct ParameterResolver {
    public static func resolve(event: DoseEvent, bodyWeightKG: Double) -> PKParams {
        guard let hormone = event.simulatedHormone else {
            return PKParams(Frac_fast: 0, k1_fast: 0, k1_slow: 0, k2: 0, k3: 0, F: 0, rateMGh: 0, F_fast: 0, F_slow: 0, lagFastH: 0, lagSlowH: 0)
        }

        let core = CorePK.params(for: hormone)
        let k3 = (event.route == .injection) ? core.kClearInjection : core.kClear

        switch event.route {
        case .injection:
            let depot = TwoPartDepotPK.params(for: event.compound)
            let k1corr = core.depotK1Corr
            let k1_fast = (depot?.k1Fast ?? 0) * k1corr
            let k1_slow = (depot?.k1Slow ?? 0) * k1corr
            let fracFast = depot?.fracFast ?? 1.0
            let form = InjectionPK.formationFraction[event.compound] ?? 1.0
            let F = form

            return PKParams(
                Frac_fast: fracFast,
                k1_fast:   k1_fast,
                k1_slow:   k1_slow,
                k2:        CompoundHydrolysisPK.k2[event.compound] ?? 0,
                k3:        k3,
                F:         F,
                rateMGh:   0,
                F_fast:    F,
                F_slow:    F,
                lagFastH:  0,
                lagSlowH:  0
            )
        case .patchApply:
            if let rUG = event.extras[.releaseRateUGPerDay] {          // zero‑order
                let rateMGh = rUG / 24_000.0                           // µg/day → mg/h
                return PKParams(Frac_fast: 1.0, k1_fast: 0, k1_slow: 0,
                                k2: 0, k3: k3,
                                F: core.patchReleaseScale, rateMGh: rateMGh,
                                F_fast: core.patchReleaseScale, F_slow: core.patchReleaseScale,
                                lagFastH: 0, lagSlowH: 0)
            } else {                                                   // first‑order
                let k1: Double = {
                    if case let .firstOrder(k1Val) = PatchPK.generic(for: hormone) { return k1Val }
                    return 0
                }()
                return PKParams(Frac_fast: 1.0, k1_fast: k1, k1_slow: 0,
                                k2: 0, k3: k3,
                                F: 1.0, rateMGh: 0,
                                F_fast: 1.0, F_slow: 1.0,
                                lagFastH: 0, lagSlowH: 0)
            }
        case .gel:
            let area = event.extras[.areaCM2] ?? 750
            let tuple = TransdermalGelPK.parameters(doseMG: event.doseMG, areaCM2: area, hormone: hormone)
            return PKParams(Frac_fast: 1.0, k1_fast: tuple.k1, k1_slow: 0,
                            k2: 0, k3: k3,
                            F: tuple.F, rateMGh: 0,
                            F_fast: tuple.F, F_slow: tuple.F,
                            lagFastH: 0, lagSlowH: 0)
        case .oral:
            if let dual = OralPK.dualAbsorption(for: event.compound) {
                return PKParams(
                    Frac_fast: dual.fracFast,
                    k1_fast: dual.kAbsFast,
                    k1_slow: dual.kAbsSlow,
                    k2: 0,
                    k3: dual.kClear,
                    F: dual.bioavailabilityFast,
                    rateMGh: 0,
                    F_fast: dual.bioavailabilityFast,
                    F_slow: dual.bioavailabilitySlow,
                    lagFastH: dual.lagHoursFast,
                    lagSlowH: dual.lagHoursSlow
                )
            }
            let k1Value = OralPK.kAbs(for: event.compound)
            let k2Value = (hormone == .estradiol && event.compound == .EV) ? (CompoundHydrolysisPK.k2[.EV] ?? 0) : 0
            let bioavailability = OralPK.bioavailability(for: event.compound)
            return PKParams(Frac_fast: 1.0, k1_fast: k1Value, k1_slow: 0,
                            k2: k2Value, k3: k3,
                            F: bioavailability, rateMGh: 0,
                            F_fast: bioavailability, F_slow: bioavailability,
                            lagFastH: 0, lagSlowH: 0)
        case .patchRemove:
             return PKParams(Frac_fast: 0, k1_fast: 0, k1_slow: 0,
                             k2: 0, k3: k3,
                             F: 0, rateMGh: 0,
                             F_fast: 0, F_slow: 0,
                             lagFastH: 0, lagSlowH: 0)
        case .sublingual:
            guard hormone == .estradiol else {
                return PKParams(Frac_fast: 0, k1_fast: 0, k1_slow: 0, k2: 0, k3: k3, F: 0, rateMGh: 0, F_fast: 0, F_slow: 0, lagFastH: 0, lagSlowH: 0)
            }
            // θ resolver: prefer explicit theta; otherwise map from UI tier code.
            // UI should set one of:
            //   - extras[.sublingualTheta] = Double in [0,1]
            //   - extras[.sublingualTier]  = {0,1,2,3} → {quick,casual,standard,strict}
            let theta: Double = {
                if let th = event.extras[.sublingualTheta] {
                    return max(0.0, min(1.0, th))
                }
                if let code = event.extras[.sublingualTier] {
                    let idx = Int(code.rounded())
                    let tier: SublingualTier
                    switch idx {
                    case 0: tier = .quick
                    case 1: tier = .casual
                    case 2: tier = .standard
                    case 3: tier = .strict
                    default: tier = .standard
                    }
                    return max(0.0, min(1.0, SublingualTheta.recommended[tier] ?? 0.11))
                }
                // Fallback for robustness: if UI forgot to pass theta/tier, use Standard.
                return 0.11
            }()
            let k1_fast = OralPK.kAbsSL
            let k1_slow = OralPK.kAbs(for: event.compound)

            // 舌下快通路（黏膜）默认 F_fast = 1（剂量按 E2 当量输入）
            // 吞咽慢通路（相当于口服）F_slow = 口服生物利用度
            let F_fast = 1.0
            let F_slow = OralPK.bioavailability(for: event.compound)

            // 若为 EV，保留已标定的 k2（供舌下快支路/其他 3C 路径使用）；E2 则 k2 = 0。
            // 舌下慢支路（吞咽→胃肠）会按 oral 一室模型计算，不再额外水解。
            let k2Value = (event.compound == .EV) ? (CompoundHydrolysisPK.k2[.EV] ?? 0) : 0

            return PKParams(
                Frac_fast: max(0.0, min(1.0, theta)),
                k1_fast:   k1_fast,
                k1_slow:   k1_slow,
                k2:        k2Value,
                k3:        k3,
                F:         1.0,
                rateMGh:   0,
                F_fast:    F_fast,
                F_slow:    F_slow,
                lagFastH:  0,
                lagSlowH:  0
            )
        }
    }
}

// MARK: – Pre-computed Model for Performance --------------------------------

fileprivate struct PrecomputedEventModel: Sendable {
    private let model: @Sendable (Double) -> Double

    init(event: DoseEvent, allEvents: [DoseEvent], bodyWeightKG: Double) {
        let params = ParameterResolver.resolve(event: event, bodyWeightKG: bodyWeightKG)
        let startTime = event.timeH
        let dose = event.doseMG
        let oneCompParams = PKParams(
            Frac_fast: 1.0,
            k1_fast: params.k1_fast,
            k1_slow: 0,
            k2: params.k2,
            k3: params.k3,
            F: params.F,
            rateMGh: params.rateMGh,
            F_fast: params.F,
            F_slow: params.F,
            lagFastH: params.lagFastH,
            lagSlowH: params.lagSlowH
        )

        switch event.route {
        case .injection:
            self.model = { timeH in
                let tau = timeH - startTime
                guard tau >= 0 else { return 0 }
                return ThreeCompartmentModel.injAmount(tau: tau, doseMG: dose, p: params)
            }
        case .gel, .oral:
            self.model = { timeH in
                let tau = timeH - startTime
                guard tau >= 0 else { return 0 }
                if event.route == .oral, params.k1_slow > 0 {
                    return ThreeCompartmentModel.dualAbsAmount(tau: tau, doseMG: dose, p: params)
                }
                return ThreeCompartmentModel.oneCompAmount(tau: tau, doseMG: dose, p: oneCompParams)
            }
        case .sublingual:
            self.model = { timeH in
                let tau = timeH - startTime
                guard tau >= 0 else { return 0 }
                if params.k2 > 0 {
                    // EV 舌下：
                    //   快支路（黏膜）走 3C：吸收→水解→清除
                    //   慢支路（吞咽/胃肠）与 oral 完全一致：一室 Bateman（不再额外水解）
                    return ThreeCompartmentModel.dualAbsMixedAmount(tau: tau, doseMG: dose, p: params)
                } else {
                    // E2 舌下：无水解，沿用一室解析式
                    return ThreeCompartmentModel.dualAbsAmount(tau: tau, doseMG: dose, p: params)
                }
            }
        case .patchApply:
            let remove = allEvents.first { $0.route == .patchRemove && $0.timeH > startTime }
            let wearH  = (remove?.timeH ?? .greatestFiniteMagnitude) - startTime
            self.model = { timeH in
                let tau = timeH - startTime
                guard tau >= 0 else { return 0 }
                return ThreeCompartmentModel.patchAmount(tau: tau,
                                                         doseMG: dose,
                                                         wearH: wearH,
                                                         p: params)
            }
        case .patchRemove:
            self.model = { _ in 0 }
        }
    }

    func amount(at timeH: Double) -> Double {
        return model(timeH)
    }
}

// MARK: – Three‑compartment analytic model ----------------------------------

struct ThreeCompartmentModel {

    /// Dual‑path with hydrolysis on both branches: each branch follows 3‑comp chain (k1 → k2 → k3).
    static func dualAbs3CAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        guard doseMG > 0 else { return 0 }
        let f  = max(0.0, min(1.0, p.Frac_fast))
        let doseF = doseMG * f
        let doseS = doseMG * (1.0 - f)
        let amtF = _analytic3C(tau: tau - p.lagFastH, doseMG: doseF, F: p.F_fast, k1: p.k1_fast, k2: p.k2, k3: p.k3)
        let amtS = _analytic3C(tau: tau - p.lagSlowH, doseMG: doseS, F: p.F_slow, k1: p.k1_slow, k2: p.k2, k3: p.k3)
        return amtF + amtS
    }

    /// Dual‑path mixed model (EV sublingual):
    /// fast branch keeps hydrolysis (3C), slow swallowed branch follows oral one‑compartment directly.
    static func dualAbsMixedAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        guard doseMG > 0 else { return 0 }
        let f  = max(0.0, min(1.0, p.Frac_fast))
        let doseF = doseMG * f
        let doseS = doseMG * (1.0 - f)

        let amtF = _analytic3C(tau: tau - p.lagFastH, doseMG: doseF, F: p.F_fast, k1: p.k1_fast, k2: p.k2, k3: p.k3)
        let amtS = _batemanAmount(doseMG: doseS, F: p.F_slow, ka: p.k1_slow, ke: p.k3, t: tau - p.lagSlowH)
        return amtF + amtS
    }

    /// Dual‑path first‑order absorption WITHOUT hydrolysis (use for E2 sublingual).
    /// Fast branch: Frac_fast, k1_fast, F_fast; Slow branch: (1-Frac_fast), k1_slow, F_slow
    static func dualAbsAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        guard doseMG > 0 else { return 0 }
        let f  = max(0.0, min(1.0, p.Frac_fast))
        let doseF = doseMG * f
        let doseS = doseMG * (1.0 - f)
        let amtF = _batemanAmount(doseMG: doseF, F: p.F_fast, ka: p.k1_fast, ke: p.k3, t: tau - p.lagFastH)
        let amtS = _batemanAmount(doseMG: doseS, F: p.F_slow, ka: p.k1_slow, ke: p.k3, t: tau - p.lagSlowH)
        return amtF + amtS
    }
    
    /// Private helper for the analytic solution of a 3-compartment model with 1st-order absorption.
    private static func _analytic3C(tau: Double, doseMG: Double, F: Double, k1: Double, k2: Double, k3: Double) -> Double {
        // This function calculates the amount of drug in the central compartment (C) at time tau.
        // It assumes k1, k2, and k3 are distinct.
        // Note: In this codebase, non‑injection routes pass dose in E2‑equivalent mg. Keep F = 1 for SL‑EV fast branch; oral/slow branch uses F = bioavailability.

        guard tau >= 0, k1 > 0, k2 > 0, k3 > 0, doseMG > 0, F > 0 else { return 0 }

        // To prevent division by zero or floating point instability, check if rates are too close.
        let k1_k2 = k1 - k2
        let k1_k3 = k1 - k3
        let k2_k3 = k2 - k3

        if let repeatedRootAmount = _analytic3CRepeatedRates(
            tau: tau,
            doseMG: doseMG,
            F: F,
            k1: k1,
            k2: k2,
            k3: k3,
            tolerance: 1e-9
        ) {
            return repeatedRootAmount
        }

        let term1 = exp(-k1 * tau) / (k1_k2 * k1_k3)
        let term2 = exp(-k2 * tau) / (-k1_k2 * k2_k3)
        let term3 = exp(-k3 * tau) / (k1_k3 * k2_k3)
        
        return doseMG * F * k1 * k2 * (term1 + term2 + term3)
    }

    /// Handles the repeated-root cases of the A -> B -> C chain analytically.
    private static func _analytic3CRepeatedRates(
        tau: Double,
        doseMG: Double,
        F: Double,
        k1: Double,
        k2: Double,
        k3: Double,
        tolerance: Double
    ) -> Double? {
        let scaledDose = doseMG * F
        let k1EqualsK2 = abs(k1 - k2) < tolerance
        let k1EqualsK3 = abs(k1 - k3) < tolerance
        let k2EqualsK3 = abs(k2 - k3) < tolerance

        if k1EqualsK2 && k1EqualsK3 {
            return scaledDose * k1 * k1 * tau * tau * 0.5 * exp(-k1 * tau)
        }

        if k2EqualsK3 {
            let delta = k1 - k2
            guard abs(delta) >= tolerance else { return nil }
            return scaledDose * k1 * k2
                * (exp(-k1 * tau) + exp(-k2 * tau) * (delta * tau - 1))
                / (delta * delta)
        }

        if k1EqualsK2 {
            let delta = k1 - k3
            guard abs(delta) >= tolerance else { return nil }
            return scaledDose * k1 * k1
                * (exp(-k3 * tau) - exp(-k1 * tau) * (1 + delta * tau))
                / (delta * delta)
        }

        if k1EqualsK3 {
            let delta = k2 - k1
            guard abs(delta) >= tolerance else { return nil }
            return scaledDose * k1 * k2
                * (exp(-k2 * tau) + exp(-k1 * tau) * (delta * tau - 1))
                / (delta * delta)
        }

        return nil
    }

    static func injAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        let dose_fast = doseMG * p.Frac_fast
        let dose_slow = doseMG * (1.0 - p.Frac_fast)

        let amount_from_fast = _analytic3C(tau: tau, doseMG: dose_fast, F: p.F, k1: p.k1_fast, k2: p.k2, k3: p.k3)
        let amount_from_slow = _analytic3C(tau: tau, doseMG: dose_slow, F: p.F, k1: p.k1_slow, k2: p.k2, k3: p.k3)

        return amount_from_fast + amount_from_slow
    }

    static func oneCompAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        // This model is for oral/gel, which uses a single absorption rate, now mapped to k1_fast.
        return _batemanAmount(doseMG: doseMG, F: p.F, ka: p.k1_fast, ke: p.k3, t: tau)
    }
    
    static func patchAmount(tau: Double, doseMG: Double, wearH: Double, p: PKParams) -> Double {
        // zero‑order input
        if p.rateMGh > 0 {
            let effectiveRateMGh = p.rateMGh * p.F
            if tau <= wearH {
                let amt = effectiveRateMGh / p.k3 * (1 - exp(-p.k3 * tau))
                return amt
            } else {
                let amtAtRemoval = effectiveRateMGh / p.k3 * (1 - exp(-p.k3 * wearH))
                let dt = tau - wearH
                return amtAtRemoval * exp(-p.k3 * dt)
            }
        }
        // first‑order legacy (uses oneCompAmount)
        let oneCompParams = PKParams(Frac_fast: 1.0, k1_fast: p.k1_fast, k1_slow: 0, k2: p.k2, k3: p.k3, F: p.F, rateMGh: p.rateMGh, F_fast: p.F, F_slow: p.F, lagFastH: p.lagFastH, lagSlowH: p.lagSlowH)
        let amountUnderPatch = oneCompAmount(tau: tau, doseMG: doseMG, p: oneCompParams)
        if tau > wearH {
            let amountAtRemoval = oneCompAmount(tau: wearH, doseMG: doseMG, p: oneCompParams)
            let dt = tau - wearH
            return amountAtRemoval * exp(-p.k3 * dt)
        }
        return amountUnderPatch
    }

    private static func _batemanAmount(doseMG: Double, F: Double, ka: Double, ke: Double, t: Double) -> Double {
        guard t >= 0, doseMG > 0, ka > 0 else { return 0 }
        if abs(ka - ke) < 1e-9 {
            return doseMG * F * ka * t * exp(-ke * t)
        }
        return doseMG * F * ka / (ka - ke) * (exp(-ke * t) - exp(-ka * t))
    }
}

// MARK: – Simulation Engine

struct SimulationResult: Equatable, Sendable {
    let timeH: [Double]
    let concentrations: [Double]
    let auc: Double
    let displayMetadata: SimulationDisplayMetadata

    nonisolated var concPGmL: [Double] { concentrations }
    nonisolated var concentrationUnit: ConcentrationUnit { displayMetadata.concentrationUnit }
}

extension SimulationResult {
    func concentration(at hour: Double) -> Double? {
        guard !timeH.isEmpty, timeH.count == concentrations.count else { return nil }
        if hour <= timeH.first! { return concentrations.first }
        if hour >= timeH.last! { return concentrations.last }

        var low = 0
        var high = timeH.count - 1

        while high - low > 1 {
            let mid = (low + high) / 2
            if timeH[mid] == hour {
                return concentrations[mid]
            } else if timeH[mid] < hour {
                low = mid
            } else {
                high = mid
            }
        }

        let t0 = timeH[low]
        let t1 = timeH[high]
        let c0 = concentrations[low]
        let c1 = concentrations[high]
        guard t1 > t0 else { return c0 }
        let ratio = (hour - t0) / (t1 - t0)
        return c0 + (c1 - c0) * ratio
    }

    func converted(to unit: ConcentrationUnit) -> SimulationResult {
        guard unit != concentrationUnit else { return self }

        let hormone = displayMetadata.hormone
        let convertedConcentrations = concentrations.map {
            ConcentrationUnit.convert($0, from: concentrationUnit, to: unit, hormone: hormone)
        }
        let convertedAUC = ConcentrationUnit.convertAUC(
            auc,
            from: concentrationUnit,
            to: unit,
            hormone: hormone
        )

        return SimulationResult(
            timeH: timeH,
            concentrations: convertedConcentrations,
            auc: convertedAUC,
            displayMetadata: displayMetadata.withUnit(unit)
        )
    }
}

func simulateTimelineResult(
    events: [DoseEvent],
    hormone: SimulatedHormone,
    bodyWeightKG: Double,
    historyPaddingHours: Double = 24.0,
    forecastHours: Double = 24.0 * 14.0,
    numberOfSteps: Int = 1000
) -> SimulationResult {
    let simulatedEvents = events.filter { $0.participatesInSimulation && $0.simulatedHormone == hormone }
    let startTime = (simulatedEvents.first?.timeH ?? 0) - historyPaddingHours
    let endTime = (simulatedEvents.last?.timeH ?? startTime) + forecastHours

    let engine = SimulationEngine(
        events: simulatedEvents,
        hormone: hormone,
        bodyWeightKG: bodyWeightKG,
        startTimeH: startTime,
        endTimeH: endTime,
        numberOfSteps: numberOfSteps
    )

    return engine.run()
}

struct SimulationEngine: Sendable {
    private let precomputedModels: [PrecomputedEventModel]
    private let plasmaVolumeML: Double
    private let displayMetadata: SimulationDisplayMetadata
    let startTimeH: Double
    let endTimeH: Double
    let numberOfSteps: Int

    init(events: [DoseEvent], hormone: SimulatedHormone, bodyWeightKG: Double, startTimeH: Double, endTimeH: Double, numberOfSteps: Int) {
        self.precomputedModels = events.compactMap { event -> PrecomputedEventModel? in
            guard event.route != .patchRemove else { return nil }
            return PrecomputedEventModel(event: event, allEvents: events, bodyWeightKG: bodyWeightKG)
        }

        let core = CorePK.params(for: hormone)
        self.plasmaVolumeML = core.vdPerKG * bodyWeightKG * 1000
        self.displayMetadata = SimulationDisplayMetadata(hormone: hormone, concentrationUnit: hormone.concentrationUnit)
        self.startTimeH = startTimeH
        self.endTimeH = endTimeH
        self.numberOfSteps = numberOfSteps
    }

    func run() -> SimulationResult {
        guard startTimeH < endTimeH, numberOfSteps > 1, plasmaVolumeML > 0 else {
            return SimulationResult(timeH: [], concentrations: [], auc: 0, displayMetadata: displayMetadata)
        }

        let stepSize = (endTimeH - startTimeH) / Double(numberOfSteps - 1)
        var timeArr = [Double]()
        var concArr = [Double]()
        timeArr.reserveCapacity(numberOfSteps)
        concArr.reserveCapacity(numberOfSteps)
        var auc = 0.0
        let concentrationScale = displayMetadata.concentrationUnit.concentrationScale(for: displayMetadata.hormone) / plasmaVolumeML
        var previousConc = 0.0

        for i in 0..<numberOfSteps {
            let t = startTimeH + Double(i) * stepSize
            var totalAmountMG = 0.0
            
            for model in precomputedModels {
                totalAmountMG += model.amount(at: t)
            }
            
            let currentConc = totalAmountMG * concentrationScale
            
            timeArr.append(t)
            concArr.append(currentConc)
            
            if i > 0 {
                auc += 0.5 * (currentConc + previousConc) * stepSize
            }
            previousConc = currentConc
        }
        
        return SimulationResult(timeH: timeArr, concentrations: concArr, auc: auc, displayMetadata: displayMetadata)
    }
}
