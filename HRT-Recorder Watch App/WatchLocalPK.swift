import Foundation
import Combine

private struct WatchHormoneCoreParams {
    let vdPerKG: Double
    let kClear: Double
    let kClearInjection: Double
    let depotK1Corr: Double
}

private enum WatchCorePK {
    static let byHormone: [WatchSimulatedHormone: WatchHormoneCoreParams] = Dictionary(
        uniqueKeysWithValues: WatchPKSharedCatalogResource.current.hormones.map { hormone, config in
            (
                hormone,
                WatchHormoneCoreParams(
                    vdPerKG: config.vdPerKG,
                    kClear: config.kClear,
                    kClearInjection: config.kClearInjection,
                    depotK1Corr: config.depotK1Corr
                )
            )
        }
    )

    static func params(for hormone: WatchSimulatedHormone) -> WatchHormoneCoreParams {
        byHormone[hormone] ?? byHormone[.estradiol]!
    }
}

enum WatchSublingualTier: String, CaseIterable {
    case quick
    case casual
    case standard
    case strict
}

enum WatchSublingualTheta {
    static let recommended = WatchPKSharedCatalogResource.current.sublingualRecommendedTheta
    static let holdMinutes = WatchPKSharedCatalogResource.current.sublingualHoldMinutes
    static let thetaRangeLow = WatchPKSharedCatalogResource.current.sublingualThetaRangeLow
    static let thetaRangeHigh = WatchPKSharedCatalogResource.current.sublingualThetaRangeHigh
}

private struct WatchTwoPartDepotParams {
    let fracFast: Double
    let k1Fast: Double
    let k1Slow: Double
}

private enum WatchTwoPartDepotPK {
    static let params: [WatchCompound: WatchTwoPartDepotParams] = Dictionary(
        uniqueKeysWithValues: WatchPKSharedCatalogResource.current.twoPartDepot.map { compound, config in
            (
                compound,
                WatchTwoPartDepotParams(
                    fracFast: config.fracFast,
                    k1Fast: config.k1Fast,
                    k1Slow: config.k1Slow
                )
            )
        }
    )
}

private enum WatchInjectionPK {
    static let formationFraction = WatchPKSharedCatalogResource.current.formationFraction
}

private enum WatchCompoundHydrolysisPK {
    static let k2 = WatchPKSharedCatalogResource.current.hydrolysisK2
}

private enum WatchOralPK {
    static let kAbs = WatchPKSharedCatalogResource.current.oralKAbs
    static let bioavailability = WatchPKSharedCatalogResource.current.oralBioavailability
    static let kAbsSL = WatchPKSharedCatalogResource.current.kAbsSL
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
        guard let hormone = event.simulatedHormone else {
            return WatchPKParams(fracFast: 0, k1Fast: 0, k1Slow: 0, k2: 0, k3: 0, rateMGh: 0, fFast: 0, fSlow: 0)
        }

        let core = WatchCorePK.params(for: hormone)
        let k3 = event.route == .injection ? core.kClearInjection : core.kClear

        switch event.route {
        case .injection:
            let depot = WatchTwoPartDepotPK.params[event.compound]
            let k1corr = core.depotK1Corr
            let k1Fast = (depot?.k1Fast ?? 0) * k1corr
            let k1Slow = (depot?.k1Slow ?? 0) * k1corr
            let fracFast = depot?.fracFast ?? 1.0
            let formationFraction = WatchInjectionPK.formationFraction[event.compound] ?? 1.0
            return WatchPKParams(
                fracFast: fracFast,
                k1Fast: k1Fast,
                k1Slow: k1Slow,
                k2: WatchCompoundHydrolysisPK.k2[event.compound] ?? 0,
                k3: k3,
                rateMGh: 0,
                fFast: formationFraction,
                fSlow: formationFraction
            )

        case .patchApply:
            if let releaseRateUGPerDay = event.extras[.releaseRateUGPerDay] {
                return WatchPKParams(
                    fracFast: 1.0,
                    k1Fast: 0,
                    k1Slow: 0,
                    k2: 0,
                    k3: k3,
                    rateMGh: releaseRateUGPerDay / 24_000.0,
                    fFast: 1.0,
                    fSlow: 1.0
                )
            }
            let fallbackK1 = WatchPKSharedCatalogResource.current.hormones[hormone]?.patchFallbackK1 ?? 0
            return WatchPKParams(fracFast: 1.0, k1Fast: fallbackK1, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 1.0, fSlow: 1.0)

        case .patchRemove:
            return WatchPKParams(fracFast: 0, k1Fast: 0, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 0, fSlow: 0)

        case .gel:
            let config = WatchPKSharedCatalogResource.current.hormones[hormone]
            return WatchPKParams(
                fracFast: 1.0,
                k1Fast: config?.gelK1 ?? 0,
                k1Slow: 0,
                k2: 0,
                k3: k3,
                rateMGh: 0,
                fFast: config?.gelFmax ?? 0,
                fSlow: config?.gelFmax ?? 0
            )

        case .oral:
            let k1 = WatchOralPK.kAbs[event.compound] ?? 0
            let k2 = (hormone == .estradiol && event.compound == .EV) ? (WatchCompoundHydrolysisPK.k2[.EV] ?? 0) : 0
            let bioavailability = WatchOralPK.bioavailability[event.compound] ?? 0
            return WatchPKParams(fracFast: 1.0, k1Fast: k1, k1Slow: 0, k2: k2, k3: k3, rateMGh: 0, fFast: bioavailability, fSlow: bioavailability)

        case .sublingual:
            guard hormone == .estradiol else {
                return WatchPKParams(fracFast: 0, k1Fast: 0, k1Slow: 0, k2: 0, k3: k3, rateMGh: 0, fFast: 0, fSlow: 0)
            }
            let theta: Double
            if let explicit = event.extras[.sublingualTheta] {
                theta = max(0, min(1, explicit))
            } else {
                let index = Int((event.extras[.sublingualTier] ?? 2).rounded())
                let tier = WatchSublingualTier.allCases[safe: min(max(index, 0), WatchSublingualTier.allCases.count - 1)] ?? .standard
                theta = WatchSublingualTheta.recommended[tier] ?? 0.11
            }

            let k2 = event.compound == .EV ? (WatchCompoundHydrolysisPK.k2[.EV] ?? 0) : 0
            return WatchPKParams(
                fracFast: theta,
                k1Fast: WatchOralPK.kAbsSL,
                k1Slow: WatchOralPK.kAbs[event.compound] ?? 0,
                k2: k2,
                k3: k3,
                rateMGh: 0,
                fFast: 1.0,
                fSlow: WatchOralPK.bioavailability[event.compound] ?? 0
            )
        }
    }
}

private enum WatchPKModel {
    static func analytic3C(tau: Double, doseMG: Double, f: Double, k1: Double, k2: Double, k3: Double) -> Double {
        guard tau >= 0, doseMG > 0, f > 0, k1 > 0, k2 > 0, k3 > 0 else { return 0 }
        let k1k2 = k1 - k2
        let k1k3 = k1 - k3
        let k2k3 = k2 - k3
        if let repeatedRootAmount = analytic3CRepeatedRates(
            tau: tau,
            doseMG: doseMG,
            f: f,
            k1: k1,
            k2: k2,
            k3: k3,
            tolerance: 1e-9
        ) {
            return repeatedRootAmount
        }

        let t1 = exp(-k1 * tau) / (k1k2 * k1k3)
        let t2 = exp(-k2 * tau) / (-k1k2 * k2k3)
        let t3 = exp(-k3 * tau) / (k1k3 * k2k3)
        return doseMG * f * k1 * k2 * (t1 + t2 + t3)
    }

    static func analytic3CRepeatedRates(
        tau: Double,
        doseMG: Double,
        f: Double,
        k1: Double,
        k2: Double,
        k3: Double,
        tolerance: Double
    ) -> Double? {
        let scaledDose = doseMG * f
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

    static func oneComp(tau: Double, doseMG: Double, f: Double, ka: Double, ke: Double) -> Double {
        guard tau >= 0, doseMG > 0, ka > 0 else { return 0 }
        if abs(ka - ke) < 1e-9 {
            return doseMG * f * ka * tau * exp(-ke * tau)
        }
        return doseMG * f * ka / (ka - ke) * (exp(-ke * tau) - exp(-ka * tau))
    }

    static func concentrationAt(timeH: Double, events: [WatchDoseEvent], hormone: WatchSimulatedHormone, bodyWeightKG: Double) -> Double {
        let core = WatchCorePK.params(for: hormone)
        let plasmaVolumeML = core.vdPerKG * bodyWeightKG * 1000
        guard plasmaVolumeML > 0 else { return 0 }

        var totalAmountMG = 0.0

        for event in events where event.route != .patchRemove {
            let p = WatchParameterResolver.resolve(event: event)
            let tau = timeH - event.timeH
            if tau < 0 { continue }

            switch event.route {
            case .injection:
                let doseFast = event.doseMG * p.fracFast
                let doseSlow = event.doseMG * (1.0 - p.fracFast)
                totalAmountMG += analytic3C(tau: tau, doseMG: doseFast, f: p.fFast, k1: p.k1Fast, k2: p.k2, k3: p.k3)
                totalAmountMG += analytic3C(tau: tau, doseMG: doseSlow, f: p.fSlow, k1: p.k1Slow, k2: p.k2, k3: p.k3)

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
                    let doseFast = event.doseMG * p.fracFast
                    let doseSlow = event.doseMG * (1.0 - p.fracFast)
                    totalAmountMG += analytic3C(tau: tau, doseMG: doseFast, f: p.fFast, k1: p.k1Fast, k2: p.k2, k3: p.k3)
                    totalAmountMG += oneComp(tau: tau, doseMG: doseSlow, f: p.fSlow, ka: p.k1Slow, ke: p.k3)
                } else {
                    totalAmountMG += oneComp(tau: tau, doseMG: event.doseMG * p.fracFast, f: p.fFast, ka: p.k1Fast, ke: p.k3)
                    totalAmountMG += oneComp(tau: tau, doseMG: event.doseMG * (1 - p.fracFast), f: p.fSlow, ka: p.k1Slow, ke: p.k3)
                }

            case .patchRemove:
                break
            }
        }

        return totalAmountMG * (hormone.concentrationUnit.concentrationScale(for: hormone) / plasmaVolumeML)
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
    @Published var selectedHormone: WatchSimulatedHormone = .estradiol {
        didSet {
            UserDefaults.standard.set(selectedHormone.rawValue, forKey: selectedHormoneKey)
            let preferredUnit = preferredConcentrationUnit(for: selectedHormone)
            if selectedConcentrationUnit != preferredUnit {
                selectedConcentrationUnit = preferredUnit
            } else {
                runSimulation()
            }
        }
    }
    @Published private(set) var selectedConcentrationUnit: WatchConcentrationUnit
    @Published private(set) var localChartPoints: [WatchChartPoint] = []
    @Published private(set) var currentConcentration: Double?
    @Published private(set) var displayMetadata: WatchSimulationDisplayMetadata

    private let store: WatchDoseStore
    private var cancellables = Set<AnyCancellable>()
    private let weightKey = "watch.user.weightKg"
    private let selectedHormoneKey = "watch.timeline.selectedHormone"

    init(store: WatchDoseStore) {
        self.store = store
        let savedWeight = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = savedWeight > 0 ? savedWeight : 70.0

        let initialSelectedHormone: WatchSimulatedHormone
        if let savedHormoneRawValue = UserDefaults.standard.string(forKey: selectedHormoneKey),
           let savedHormone = WatchSimulatedHormone(rawValue: savedHormoneRawValue) {
            initialSelectedHormone = savedHormone
        } else {
            initialSelectedHormone = .estradiol
        }
        self.selectedHormone = initialSelectedHormone
        let initialSelectedConcentrationUnit = initialSelectedHormone.preferredUnit(
            from: UserDefaults.standard.string(forKey: Self.concentrationUnitKey(for: initialSelectedHormone))
        )
        self.selectedConcentrationUnit = initialSelectedConcentrationUnit

        self.displayMetadata = WatchSimulationDisplayMetadata(
            hormone: initialSelectedHormone,
            concentrationUnit: initialSelectedConcentrationUnit
        )

        store.$events
            .sink { [weak self] _ in
                self?.runSimulation()
            }
            .store(in: &cancellables)

        $selectedConcentrationUnit
            .dropFirst()
            .sink { [weak self] unit in
                self?.applySelectedConcentrationUnit(unit)
            }
            .store(in: &cancellables)

        runSimulation()
    }

    var visibleEvents: [WatchDoseEvent] {
        store.events.filter { $0.appearsInTimeline(for: selectedHormone) }
    }

    var availableConcentrationUnits: [WatchConcentrationUnit] {
        selectedHormone.supportedConcentrationUnits
    }

    func setSelectedConcentrationUnit(_ unit: WatchConcentrationUnit) {
        guard unit.isSupported(for: selectedHormone), selectedConcentrationUnit != unit else { return }
        selectedConcentrationUnit = unit
    }

    func runSimulation() {
        let selectedUnit = selectedConcentrationUnit
        displayMetadata = WatchSimulationDisplayMetadata(
            hormone: selectedHormone,
            concentrationUnit: selectedUnit
        )

        let simulationEvents = store.events
            .filter { $0.participatesInSimulation && $0.simulatedHormone == selectedHormone }
            .sorted { $0.timeH < $1.timeH }

        guard !simulationEvents.isEmpty else {
            localChartPoints = []
            currentConcentration = nil
            return
        }

        let nowH = Date().timeIntervalSince1970 / 3600.0
        let startH = (simulationEvents.first?.timeH ?? nowH) - 24.0
        let endH = (simulationEvents.last?.timeH ?? nowH) + 24.0 * 14.0
        let steps = 1000
        let stepH = (endH - startH) / Double(steps - 1)
        let sourceUnit = selectedHormone.concentrationUnit

        var points: [WatchChartPoint] = []
        points.reserveCapacity(steps)

        for index in 0..<steps {
            let timeH = startH + Double(index) * stepH
            let concentration = WatchPKModel.concentrationAt(
                timeH: timeH,
                events: simulationEvents,
                hormone: selectedHormone,
                bodyWeightKG: bodyWeightKG
            )
            let convertedConcentration = WatchConcentrationUnit.convert(
                concentration,
                from: sourceUnit,
                to: selectedUnit,
                hormone: selectedHormone
            )
            points.append(WatchChartPoint(timeH: timeH, concentration: convertedConcentration))
        }

        localChartPoints = points
        let nativeCurrentConcentration = WatchPKModel.concentrationAt(
            timeH: nowH,
            events: simulationEvents,
            hormone: selectedHormone,
            bodyWeightKG: bodyWeightKG
        )
        currentConcentration = WatchConcentrationUnit.convert(
            nativeCurrentConcentration,
            from: sourceUnit,
            to: selectedUnit,
            hormone: selectedHormone
        )
    }

    private func applySelectedConcentrationUnit(_ unit: WatchConcentrationUnit) {
        guard unit.isSupported(for: selectedHormone) else {
            let fallback = selectedHormone.concentrationUnit
            if selectedConcentrationUnit != fallback {
                selectedConcentrationUnit = fallback
            }
            return
        }

        UserDefaults.standard.set(unit.rawValue, forKey: Self.concentrationUnitKey(for: selectedHormone))
        runSimulation()
    }

    private func preferredConcentrationUnit(for hormone: WatchSimulatedHormone) -> WatchConcentrationUnit {
        hormone.preferredUnit(from: UserDefaults.standard.string(forKey: Self.concentrationUnitKey(for: hormone)))
    }

    private static func concentrationUnitKey(for hormone: WatchSimulatedHormone) -> String {
        "watch.timeline.selectedConcentrationUnit.\(hormone.rawValue)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
