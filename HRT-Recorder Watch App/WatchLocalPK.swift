import Foundation
import Combine

private enum WatchCorePK {
    static let vdPerKG: Double = 2.0
    static let kClear: Double = 0.41
    static let kClearInjection: Double = 0.041
    static let depotK1Corr: Double = 1.0
}

enum WatchSublingualTier: Int {
    case quick = 0
    case casual = 1
    case standard = 2
    case strict = 3
}

enum WatchSublingualTheta {
    static let recommended: [WatchSublingualTier: Double] = [
        .quick: 0.01,
        .casual: 0.04,
        .standard: 0.11,
        .strict: 0.18
    ]

    static let holdMinutes: [WatchSublingualTier: Double] = [
        .quick: 2,
        .casual: 5,
        .standard: 10,
        .strict: 15
    ]
}

private enum WatchTwoPartDepotPK {
    static let fracFast: [WatchDoseEvent.Ester: Double] = [.EB: 0.90, .EV: 0.40, .EC: 0.229164549, .EN: 0.05, .E2: 1.0]
    static let k1Fast: [WatchDoseEvent.Ester: Double] = [.EB: 0.144, .EV: 0.0216, .EC: 0.005035046, .EN: 0.0010, .E2: 0]
    static let k1Slow: [WatchDoseEvent.Ester: Double] = [.EB: 0.114, .EV: 0.0138, .EC: 0.004510574, .EN: 0.0050, .E2: 0]
}

private enum WatchInjectionPK {
    static let formationFraction: [WatchDoseEvent.Ester: Double] = [.EB: 0.10922376473734707, .EV: 0.062258288229969413, .EC: 0.117255838, .EN: 0.12, .E2: 1.0]
}

private enum WatchEsterPK {
    static let k2: [WatchDoseEvent.Ester: Double] = [.EB: 0.090, .EV: 0.070, .EC: 0.045, .EN: 0.015, .E2: 0]
}

private enum WatchOralPK {
    static let kAbsE2: Double = 0.32
    static let kAbsEV: Double = 0.05
    static let bioavailability: Double = 0.03
    static let kAbsSL: Double = 1.8
}

private struct WatchPKParams {
    let fracFast: Double
    let k1Fast: Double
    let k1Slow: Double
    let k2: Double
    let k3: Double
    let rateMGh: Double
    let fFast: Double
    let fSlow: Double
}

private enum WatchParameterResolver {
    static func resolve(event: WatchDoseEvent) -> WatchPKParams {
        let k3 = (event.route == .injection) ? WatchCorePK.kClearInjection : WatchCorePK.kClear

        switch event.route {
        case .injection:
            let k1corr = WatchCorePK.depotK1Corr
            let k1Fast = (WatchTwoPartDepotPK.k1Fast[event.ester] ?? 0) * k1corr
            let k1Slow = (WatchTwoPartDepotPK.k1Slow[event.ester] ?? 0) * k1corr
            let fracFast = WatchTwoPartDepotPK.fracFast[event.ester] ?? 1.0
            let f = WatchInjectionPK.formationFraction[event.ester] ?? 0.1
            return WatchPKParams(fracFast: fracFast, k1Fast: k1Fast, k1Slow: k1Slow, k2: WatchEsterPK.k2[event.ester] ?? 0, k3: k3, rateMGh: 0, fFast: f, fSlow: f)

        case .patchApply:
            if let rUG = event.extras[.releaseRateUGPerDay] {
                return WatchPKParams(fracFast: 1.0, k1Fast: 0, k1Slow: 0, k2: 0, k3: k3, rateMGh: rUG / 24_000.0, fFast: 1.0, fSlow: 1.0)
            }
            return WatchPKParams(fracFast: 1.0, k1Fast: 0.0075, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 1.0, fSlow: 1.0)

        case .patchRemove:
            return WatchPKParams(fracFast: 0, k1Fast: 0, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 0, fSlow: 0)

        case .gel:
            return WatchPKParams(fracFast: 1.0, k1Fast: 0.022, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 0.05, fSlow: 0.05)

        case .oral:
            let ka = (event.ester == .EV) ? WatchOralPK.kAbsEV : WatchOralPK.kAbsE2
            let k2 = (event.ester == .EV) ? (WatchEsterPK.k2[.EV] ?? 0) : 0
            return WatchPKParams(fracFast: 1.0, k1Fast: ka, k1Slow: 0, k2: k2, k3: k3, rateMGh: 0, fFast: WatchOralPK.bioavailability, fSlow: WatchOralPK.bioavailability)

        case .sublingual:
            let theta: Double
            if let explicit = event.extras[.sublingualTheta] {
                theta = max(0, min(1, explicit))
            } else {
                let idx = Int((event.extras[.sublingualTier] ?? 2).rounded())
                let tier = WatchSublingualTier(rawValue: min(max(idx, 0), 3)) ?? .standard
                theta = WatchSublingualTheta.recommended[tier] ?? 0.11
            }
            let k2 = (event.ester == .EV) ? (WatchEsterPK.k2[.EV] ?? 0) : 0
            return WatchPKParams(fracFast: theta, k1Fast: WatchOralPK.kAbsSL, k1Slow: (event.ester == .EV ? WatchOralPK.kAbsEV : WatchOralPK.kAbsE2), k2: k2, k3: k3, rateMGh: 0, fFast: 1.0, fSlow: WatchOralPK.bioavailability)
        }
    }
}

private enum WatchPKModel {
    static func analytic3C(tau: Double, doseMG: Double, f: Double, k1: Double, k2: Double, k3: Double) -> Double {
        guard tau >= 0, doseMG > 0, k1 > 0 else { return 0 }
        let k1k2 = k1 - k2
        let k1k3 = k1 - k3
        let k2k3 = k2 - k3
        if abs(k1k2) < 1e-9 || abs(k1k3) < 1e-9 || abs(k2k3) < 1e-9 { return 0 }

        let t1 = exp(-k1 * tau) / (k1k2 * k1k3)
        let t2 = exp(-k2 * tau) / (-k1k2 * k2k3)
        let t3 = exp(-k3 * tau) / (k1k3 * k2k3)
        return doseMG * f * k1 * k2 * (t1 + t2 + t3)
    }

    static func oneComp(tau: Double, doseMG: Double, f: Double, ka: Double, ke: Double) -> Double {
        guard tau >= 0, doseMG > 0, ka > 0 else { return 0 }
        if abs(ka - ke) < 1e-9 {
            return doseMG * f * ka * tau * exp(-ke * tau)
        }
        return doseMG * f * ka / (ka - ke) * (exp(-ke * tau) - exp(-ka * tau))
    }

    static func concentrationAt(timeH: Double, events: [WatchDoseEvent], bodyWeightKG: Double) -> Double {
        let plasmaVolumeML = WatchCorePK.vdPerKG * bodyWeightKG * 1000
        guard plasmaVolumeML > 0 else { return 0 }

        var totalAmountMG = 0.0

        for event in events {
            if event.route == .patchRemove { continue }
            let p = WatchParameterResolver.resolve(event: event)
            let tau = timeH - event.timeH
            if tau < 0 { continue }

            switch event.route {
            case .injection:
                let doseF = event.doseMG * p.fracFast
                let doseS = event.doseMG * (1.0 - p.fracFast)
                totalAmountMG += analytic3C(tau: tau, doseMG: doseF, f: p.fFast, k1: p.k1Fast, k2: p.k2, k3: p.k3)
                totalAmountMG += analytic3C(tau: tau, doseMG: doseS, f: p.fSlow, k1: p.k1Slow, k2: p.k2, k3: p.k3)

            case .patchApply:
                if p.rateMGh > 0 {
                    if tau <= 24 * 7 {
                        totalAmountMG += p.rateMGh / p.k3 * (1 - exp(-p.k3 * tau))
                    } else {
                        let amountAtRemoval = p.rateMGh / p.k3 * (1 - exp(-p.k3 * 24 * 7))
                        totalAmountMG += amountAtRemoval * exp(-p.k3 * (tau - 24 * 7))
                    }
                } else {
                    totalAmountMG += oneComp(tau: tau, doseMG: event.doseMG, f: p.fFast, ka: p.k1Fast, ke: p.k3)
                }

            case .gel, .oral:
                totalAmountMG += oneComp(tau: tau, doseMG: event.doseMG, f: p.fFast, ka: p.k1Fast, ke: p.k3)

            case .sublingual:
                if p.k2 > 0 {
                    let doseF = event.doseMG * p.fracFast
                    let doseS = event.doseMG * (1.0 - p.fracFast)
                    totalAmountMG += analytic3C(tau: tau, doseMG: doseF, f: p.fFast, k1: p.k1Fast, k2: p.k2, k3: p.k3)
                    totalAmountMG += analytic3C(tau: tau, doseMG: doseS, f: p.fSlow, k1: p.k1Slow, k2: p.k2, k3: p.k3)
                } else {
                    let fast = oneComp(tau: tau, doseMG: event.doseMG * p.fracFast, f: p.fFast, ka: p.k1Fast, ke: p.k3)
                    let slow = oneComp(tau: tau, doseMG: event.doseMG * (1 - p.fracFast), f: p.fSlow, ka: p.k1Slow, ke: p.k3)
                    totalAmountMG += fast + slow
                }

            case .patchRemove:
                break
            }
        }

        return totalAmountMG * (1e9 / plasmaVolumeML)
    }
}

@MainActor
final class WatchDoseTimelineVM: ObservableObject {
    @Published var bodyWeightKG: Double {
        didSet {
            UserDefaults.standard.set(bodyWeightKG, forKey: weightKey)
            runSimulation()
        }
    }
    @Published private(set) var localChartPoints: [WatchChartPoint] = []
    @Published private(set) var currentConcentration: Double?

    private let store: WatchDoseStore
    private var cancellables = Set<AnyCancellable>()
    private let weightKey = "watch.user.weightKg"

    init(store: WatchDoseStore) {
        self.store = store
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0

        store.$events
            .sink { [weak self] _ in
                self?.runSimulation()
            }
            .store(in: &cancellables)

        runSimulation()
    }

    func runSimulation() {
        let events = store.events.sorted { $0.timeH < $1.timeH }
        guard !events.isEmpty else {
            localChartPoints = []
            currentConcentration = nil
            return
        }

        let nowH = Date().timeIntervalSince1970 / 3600.0
        let startH = (events.first?.timeH ?? nowH) - 24.0
        let endH = (events.last?.timeH ?? nowH) + 24.0 * 14.0
        let steps = 1000
        let stepH = (endH - startH) / Double(steps - 1)

        var points: [WatchChartPoint] = []
        points.reserveCapacity(steps)

        for i in 0..<steps {
            let t = startH + Double(i) * stepH
            let c = WatchPKModel.concentrationAt(timeH: t, events: events, bodyWeightKG: bodyWeightKG)
            points.append(WatchChartPoint(timeH: t, concentration: c))
        }

        localChartPoints = points
        currentConcentration = WatchPKModel.concentrationAt(timeH: nowH, events: events, bodyWeightKG: bodyWeightKG)
    }
}
