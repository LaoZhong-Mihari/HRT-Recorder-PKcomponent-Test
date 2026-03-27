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
        case releaseRateUGPerDay      // for zero‑order patch: µg day⁻¹
        case sublingualTheta
        case sublingualTier          // 0: quick, 1: casual, 2: standard, 3: strict
    }
    let route: Route
    let timeH: Double
    let doseMG: Double
    let ester: Ester
    let extras: [ExtraKey: Double]
    let recordOnlyOralMedication: RecordOnlyOralMedication?
}

extension DoseEvent {
    nonisolated var participatesInSimulation: Bool {
        recordOnlyOralMedication == nil
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
}

// MARK: – Resolver -----------------------------------------------------------

struct ParameterResolver {
    public static func resolve(event: DoseEvent, bodyWeightKG: Double) -> PKParams {
        let k3 = (event.route == .injection) ? CorePK.kClearInjection : CorePK.kClear
        switch event.route {
        case .injection:
            // new two-part-depot params + formationFraction + global k1-correction
            let k1corr   = CorePK.depotK1Corr
            let k1_fast  = (TwoPartDepotPK.k1_fast[event.ester]  ?? 0) * k1corr
            let k1_slow  = (TwoPartDepotPK.k1_slow[event.ester]  ?? 0) * k1corr
            let fracFast =  TwoPartDepotPK.Frac_fast[event.ester] ?? 1.0

            // F = formationFraction × 分子量换算 toE2Factor
            let form = InjectionPK.formationFraction[event.ester] ?? 0.08
            let toE2 = EsterInfo.by(ester: event.ester).toE2Factor
            let F    = form * toE2

            return PKParams(
                Frac_fast: fracFast,
                k1_fast:   k1_fast,
                k1_slow:   k1_slow,
                k2:        EsterPK.k2[event.ester] ?? 0,
                k3:        k3,
                F:         F,
                rateMGh:   0,
                F_fast:    F,
                F_slow:    F
            )
        case .patchApply:
            if let rUG = event.extras[.releaseRateUGPerDay] {          // zero‑order
                let rateMGh = rUG / 24_000.0                           // µg/day → mg/h
                // MODIFIED: Adapt to new PKParams struct for constant-k model.
                return PKParams(Frac_fast: 1.0, k1_fast: 0, k1_slow: 0,
                                k2: 0, k3: k3,
                                F: 1.0, rateMGh: rateMGh,
                                F_fast: 1.0, F_slow: 1.0)
            } else {                                                   // first‑order
                let k1: Double = {
                    if case let .firstOrder(k1Val) = PatchPK.generic { return k1Val }
                    return 0
                }()
                // MODIFIED: Adapt to new PKParams struct for constant-k model.
                return PKParams(Frac_fast: 1.0, k1_fast: k1, k1_slow: 0,
                                k2: 0, k3: k3,
                                F: 1.0, rateMGh: 0,
                                F_fast: 1.0, F_slow: 1.0)
            }
        case .gel:
            let area = event.extras[.areaCM2] ?? 750
            let tuple = TransdermalGelPK.parameters(doseMG: event.doseMG, areaCM2: area)
            // MODIFIED: Adapt to new PKParams struct for constant-k model.
            return PKParams(Frac_fast: 1.0, k1_fast: tuple.k1, k1_slow: 0,
                            k2: 0, k3: k3,
                            F: tuple.F, rateMGh: 0,
                            F_fast: tuple.F, F_slow: tuple.F)
        case .oral:
            let k1Value = (event.ester == .EV) ? OralPK.kAbsEV : OralPK.kAbsE2
            let k2Value = (event.ester == .EV) ? (EsterPK.k2[.EV] ?? 0) : 0
            // MODIFIED: Adapt to new PKParams struct for constant-k model.
            return PKParams(Frac_fast: 1.0, k1_fast: k1Value, k1_slow: 0,
                            k2: k2Value, k3: k3,
                            F: OralPK.bioavailability, rateMGh: 0,
                            F_fast: OralPK.bioavailability, F_slow: OralPK.bioavailability)
        case .patchRemove:
             // MODIFIED: Adapt to new PKParams struct.
             return PKParams(Frac_fast: 0, k1_fast: 0, k1_slow: 0,
                             k2: 0, k3: k3,
                             F: 0, rateMGh: 0,
                             F_fast: 0, F_slow: 0)
        case .sublingual:
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
            let k1_slow = (event.ester == .EV) ? OralPK.kAbsEV : OralPK.kAbsE2

            // 舌下快通路（黏膜）默认 F_fast = 1（剂量按 E2 当量输入）
            // 吞咽慢通路（相当于口服）F_slow = 口服生物利用度
            let F_fast = 1.0
            let F_slow = OralPK.bioavailability

            // 若为 EV，保留已标定的 k2（供舌下快支路/其他 3C 路径使用）；E2 则 k2 = 0。
            // 舌下慢支路（吞咽→胃肠）会按 oral 一室模型计算，不再额外水解。
            let k2Value = (event.ester == .EV) ? (EsterPK.k2[.EV] ?? 0) : 0

            return PKParams(
                Frac_fast: max(0.0, min(1.0, theta)),
                k1_fast:   k1_fast,
                k1_slow:   k1_slow,
                k2:        k2Value,
                k3:        k3,
                F:         1.0,
                rateMGh:   0,
                F_fast:    F_fast,
                F_slow:    F_slow
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
            F_slow: params.F
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
        let amtF = _analytic3C(tau: tau, doseMG: doseF, F: p.F_fast, k1: p.k1_fast, k2: p.k2, k3: p.k3)
        let amtS = _analytic3C(tau: tau, doseMG: doseS, F: p.F_slow, k1: p.k1_slow, k2: p.k2, k3: p.k3)
        return amtF + amtS
    }

    /// Dual‑path mixed model (EV sublingual):
    /// fast branch keeps hydrolysis (3C), slow swallowed branch follows oral one‑compartment directly.
    static func dualAbsMixedAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        guard doseMG > 0 else { return 0 }
        let f  = max(0.0, min(1.0, p.Frac_fast))
        let doseF = doseMG * f
        let doseS = doseMG * (1.0 - f)

        let amtF = _analytic3C(tau: tau, doseMG: doseF, F: p.F_fast, k1: p.k1_fast, k2: p.k2, k3: p.k3)
        let amtS = _batemanAmount(doseMG: doseS, F: p.F_slow, ka: p.k1_slow, ke: p.k3, t: tau)
        return amtF + amtS
    }

    /// Dual‑path first‑order absorption WITHOUT hydrolysis (use for E2 sublingual).
    /// Fast branch: Frac_fast, k1_fast, F_fast; Slow branch: (1-Frac_fast), k1_slow, F_slow
    static func dualAbsAmount(tau: Double, doseMG: Double, p: PKParams) -> Double {
        guard doseMG > 0 else { return 0 }
        let f  = max(0.0, min(1.0, p.Frac_fast))
        let doseF = doseMG * f
        let doseS = doseMG * (1.0 - f)
        let amtF = _batemanAmount(doseMG: doseF, F: p.F_fast, ka: p.k1_fast, ke: p.k3, t: tau)
        let amtS = _batemanAmount(doseMG: doseS, F: p.F_slow, ka: p.k1_slow, ke: p.k3, t: tau)
        return amtF + amtS
    }
    
    /// Private helper for the analytic solution of a 3-compartment model with 1st-order absorption.
    private static func _analytic3C(tau: Double, doseMG: Double, F: Double, k1: Double, k2: Double, k3: Double) -> Double {
        // This function calculates the amount of drug in the central compartment (C) at time tau.
        // It assumes k1, k2, and k3 are distinct.
        // Note: In this codebase, non‑injection routes pass dose in E2‑equivalent mg. Keep F = 1 for SL‑EV fast branch; oral/slow branch uses F = bioavailability.
        
        // Handle edge case where k1 is zero.
        guard k1 > 0, doseMG > 0 else { return 0 }

        // To prevent division by zero or floating point instability, check if rates are too close.
        let k1_k2 = k1 - k2
        let k1_k3 = k1 - k3
        let k2_k3 = k2 - k3

        // A robust check for near-equality.
        if abs(k1_k2) < 1e-9 || abs(k1_k3) < 1e-9 || abs(k2_k3) < 1e-9 {
            // Fallback to a simpler model or a more complex Bateman equation for repeated roots.
            // For now, returning 0 for this unlikely degenerate case is safer than crashing.
            // A proper implementation would handle each case (k1=k2, k1=k3, k2=k3, k1=k2=k3).
            return 0
        }

        let term1 = exp(-k1 * tau) / (k1_k2 * k1_k3)
        let term2 = exp(-k2 * tau) / (-k1_k2 * k2_k3)
        let term3 = exp(-k3 * tau) / (k1_k3 * k2_k3)
        
        return doseMG * F * k1 * k2 * (term1 + term2 + term3)
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
            if tau <= wearH {
                let amt = p.rateMGh / p.k3 * (1 - exp(-p.k3 * tau))
                return amt
            } else {
                let amtAtRemoval = p.rateMGh / p.k3 * (1 - exp(-p.k3 * wearH))
                let dt = tau - wearH
                return amtAtRemoval * exp(-p.k3 * dt)
            }
        }
        // first‑order legacy (uses oneCompAmount)
        let oneCompParams = PKParams(Frac_fast: 1.0, k1_fast: p.k1_fast, k1_slow: 0, k2: p.k2, k3: p.k3, F: p.F, rateMGh: p.rateMGh, F_fast: p.F, F_slow: p.F)
        let amountUnderPatch = oneCompAmount(tau: tau, doseMG: doseMG, p: oneCompParams)
        if tau > wearH {
            let amountAtRemoval = oneCompAmount(tau: wearH, doseMG: doseMG, p: oneCompParams)
            let dt = tau - wearH
            return amountAtRemoval * exp(-p.k3 * dt)
        }
        return amountUnderPatch
    }

    private static func _batemanAmount(doseMG: Double, F: Double, ka: Double, ke: Double, t: Double) -> Double {
        guard doseMG > 0, ka > 0 else { return 0 }
        if abs(ka - ke) < 1e-9 {
            return doseMG * F * ka * t * exp(-ke * t)
        }
        return doseMG * F * ka / (ka - ke) * (exp(-ke * t) - exp(-ka * t))
    }
}

// MARK: – Simulation Engine

struct SimulationResult: Equatable, Sendable {
    let timeH: [Double]
    let concPGmL: [Double]
    let auc: Double
}

extension SimulationResult {
    func concentration(at hour: Double) -> Double? {
        guard !timeH.isEmpty, timeH.count == concPGmL.count else { return nil }
        if hour <= timeH.first! { return concPGmL.first }
        if hour >= timeH.last! { return concPGmL.last }

        var low = 0
        var high = timeH.count - 1

        while high - low > 1 {
            let mid = (low + high) / 2
            if timeH[mid] == hour {
                return concPGmL[mid]
            } else if timeH[mid] < hour {
                low = mid
            } else {
                high = mid
            }
        }

        let t0 = timeH[low]
        let t1 = timeH[high]
        let c0 = concPGmL[low]
        let c1 = concPGmL[high]
        guard t1 > t0 else { return c0 }
        let ratio = (hour - t0) / (t1 - t0)
        return c0 + (c1 - c0) * ratio
    }
}

func simulateTimelineResult(
    events: [DoseEvent],
    bodyWeightKG: Double,
    historyPaddingHours: Double = 24.0,
    forecastHours: Double = 24.0 * 14.0,
    numberOfSteps: Int = 1000
) -> SimulationResult {
    let simulatedEvents = events.filter(\.participatesInSimulation)
    let startTime = (simulatedEvents.first?.timeH ?? 0) - historyPaddingHours
    let endTime = (simulatedEvents.last?.timeH ?? startTime) + forecastHours

    let engine = SimulationEngine(
        events: simulatedEvents,
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
    let startTimeH: Double
    let endTimeH: Double
    let numberOfSteps: Int

    init(events: [DoseEvent], bodyWeightKG: Double, startTimeH: Double, endTimeH: Double, numberOfSteps: Int) {
        self.precomputedModels = events.compactMap { event -> PrecomputedEventModel? in
            guard event.route != .patchRemove else { return nil }
            return PrecomputedEventModel(event: event, allEvents: events, bodyWeightKG: bodyWeightKG)
        }
        
        // Literature values for estradiol are typically in the 10-15 L/kg range due to tissue binding.
        self.plasmaVolumeML = CorePK.vdPerKG * bodyWeightKG * 1000
        self.startTimeH = startTimeH
        self.endTimeH = endTimeH
        self.numberOfSteps = numberOfSteps
    }

    func run() -> SimulationResult {
        guard startTimeH < endTimeH, numberOfSteps > 1, plasmaVolumeML > 0 else {
            return SimulationResult(timeH: [], concPGmL: [], auc: 0)
        }

        let stepSize = (endTimeH - startTimeH) / Double(numberOfSteps - 1)
        var timeArr = [Double]()
        var concArr = [Double]()
        timeArr.reserveCapacity(numberOfSteps)
        concArr.reserveCapacity(numberOfSteps)
        var auc = 0.0
        let concentrationScale = 1e9 / plasmaVolumeML
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
        
        return SimulationResult(timeH: timeArr, concPGmL: concArr, auc: auc)
    }
}
