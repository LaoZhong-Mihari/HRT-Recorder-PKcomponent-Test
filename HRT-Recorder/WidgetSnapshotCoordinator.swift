import Foundation
import WidgetKit

nonisolated struct WidgetSnapshotWriteTicket: Sendable {
    fileprivate let sequence: UInt64
}

enum WidgetSnapshotCoordinator {
    private struct CommitWaiter {
        let minimumSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private nonisolated static let widgetTimelineHorizonHours = 12.0
    private nonisolated static let chartPointIntervalHours = 0.125
    private nonisolated static let writeDebounceNanoseconds: UInt64 = 200_000_000
    private static var latestWriteSequence: UInt64 = 0
    private static var latestCommittedSequence: UInt64 = 0
    private static var pendingTimelineReload = false
    private static var scheduledWriteTask: Task<Void, Never>?
    private static var commitWaiters: [UUID: CommitWaiter] = [:]

    private nonisolated static func chartPointCount(visibleWindowHours: Double) -> Int {
        Int(ceil((visibleWindowHours * 2 + widgetTimelineHorizonHours) / chartPointIntervalHours)) + 1
    }

    private nonisolated static func isCurrentTaskCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private nonisolated static func buildSnapshot(
        events: [DoseEvent],
        bodyWeightKG: Double,
        labSamples: [LabSample],
        doseOptions: [WidgetDoseOption],
        at date: Date,
        visibleWindowHours: Double,
        units: [SimulatedHormone: ConcentrationUnit],
        thresholds: [SimulatedHormone: WidgetThresholdRange],
        cancellationCheck: @Sendable () -> Bool
    ) -> WidgetSnapshot {
        guard !cancellationCheck() else {
            return WidgetSnapshot(
                schemaVersion: 1,
                generatedAt: date,
                hormones: [],
                doseOptions: doseOptions
            )
        }

        let participatingEvents = events.filter(\.participatesInSimulation)
        let calibration = bodyWeightKG > 0
            && !participatingEvents.isEmpty
            && !labSamples.isEmpty
            ? PKCalibrator.fit(
                events: participatingEvents,
                labs: labSamples,
                bodyWeightKG: bodyWeightKG,
                cancellationCheck: cancellationCheck
            )
            : CalibrationResult()

        guard !cancellationCheck() else {
            return WidgetSnapshot(
                schemaVersion: 1,
                generatedAt: date,
                hormones: [],
                doseOptions: doseOptions
            )
        }

        var hormoneSnapshots: [WidgetHormoneSnapshot] = []
        hormoneSnapshots.reserveCapacity(2)
        for hormone in [SimulatedHormone.estradiol, .testosterone] {
            guard !cancellationCheck() else { break }
            let kind: WidgetHormoneKind = hormone == .estradiol ? .estradiol : .testosterone
            let unit = units[hormone] ?? hormone.concentrationUnit
            let threshold = thresholds[hormone]
                ?? WidgetThresholdRange.defaultRange(for: kind)
            hormoneSnapshots.append(
                makeHormoneSnapshot(
                    hormone: hormone,
                    kind: kind,
                    unit: unit,
                    threshold: threshold,
                    events: participatingEvents,
                    bodyWeightKG: bodyWeightKG,
                    calibration: calibration,
                    at: date,
                    visibleWindowHours: visibleWindowHours,
                    cancellationCheck: cancellationCheck
                )
            )
        }

        return WidgetSnapshot(
            schemaVersion: 1,
            generatedAt: date,
            hormones: hormoneSnapshots,
            doseOptions: doseOptions
        )
    }

    @discardableResult
    static func enqueueSnapshotWrite(
        events: [DoseEvent],
        bodyWeightKG: Double,
        labSamples: [LabSample] = [],
        plans: [MedicationPlan],
        reloadTimelines: Bool = true,
        debounce: Bool = true
    ) -> WidgetSnapshotWriteTicket {
        latestWriteSequence &+= 1
        let sequence = latestWriteSequence
        pendingTimelineReload = pendingTimelineReload || reloadTimelines
        scheduledWriteTask?.cancel()

        let date = Date()
        let visibleWindowHours = Double(WidgetSharedStore.displaySettings().surroundingHours)
        let units = preferredUnits()
        let thresholds = convertedThresholds(for: units)
        let doseOptions = makeDoseOptions(from: plans)
        let scheduledTask = Task { @MainActor in
            if debounce {
                do {
                    try await Task.sleep(nanoseconds: writeDebounceNanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, latestWriteSequence == sequence else { return }
            let worker = Task.detached(priority: .utility) {
                buildSnapshot(
                    events: events,
                    bodyWeightKG: bodyWeightKG,
                    labSamples: labSamples,
                    doseOptions: doseOptions,
                    at: date,
                    visibleWindowHours: visibleWindowHours,
                    units: units,
                    thresholds: thresholds,
                    cancellationCheck: isCurrentTaskCancelled
                )
            }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, latestWriteSequence == sequence else { return }
            commit(snapshot, for: sequence)
        }
        scheduledWriteTask = scheduledTask
        return WidgetSnapshotWriteTicket(sequence: sequence)
    }

    static func waitForCommit(of ticket: WidgetSnapshotWriteTicket) async {
        guard latestCommittedSequence < ticket.sequence else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if latestCommittedSequence >= ticket.sequence {
                    continuation.resume()
                } else {
                    commitWaiters[waiterID] = CommitWaiter(
                        minimumSequence: ticket.sequence,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancelWaiter(waiterID, for: ticket.sequence)
            }
        }
    }

    private static func cancelWaiter(_ waiterID: UUID, for sequence: UInt64) {
        guard let waiter = commitWaiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume()
        if latestWriteSequence == sequence {
            scheduledWriteTask?.cancel()
        }
    }

    private static func commit(_ snapshot: WidgetSnapshot, for sequence: UInt64) {
        guard latestWriteSequence == sequence else { return }

        WidgetSharedStore.writeSnapshot(snapshot)
        scheduledWriteTask = nil
        latestCommittedSequence = max(latestCommittedSequence, sequence)
        resumeSatisfiedWaiters()
        let shouldReloadTimelines = pendingTimelineReload
        pendingTimelineReload = false
        if shouldReloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func resumeSatisfiedWaiters() {
        let readyIDs = commitWaiters.compactMap { id, waiter in
            waiter.minimumSequence <= latestCommittedSequence ? id : nil
        }
        for id in readyIDs {
            commitWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private nonisolated static func makeHormoneSnapshot(
        hormone: SimulatedHormone,
        kind: WidgetHormoneKind,
        unit: ConcentrationUnit,
        threshold: WidgetThresholdRange,
        events: [DoseEvent],
        bodyWeightKG: Double,
        calibration: CalibrationResult,
        at date: Date,
        visibleWindowHours: Double,
        cancellationCheck: @Sendable () -> Bool
    ) -> WidgetHormoneSnapshot {
        let nowH = date.timeIntervalSince1970 / 3600.0
        let simulatedEvents = events
            .filter { $0.simulatedHormone == hormone }
            .sorted { $0.timeH < $1.timeH }

        guard !simulatedEvents.isEmpty, bodyWeightKG > 0 else {
            return WidgetHormoneSnapshot.empty(
                hormone: kind,
                threshold: threshold,
                updatedAt: date
            )
        }

        let engine = SimulationEngine(
            events: simulatedEvents,
            hormone: hormone,
            bodyWeightKG: bodyWeightKG,
            startTimeH: nowH - visibleWindowHours,
            endTimeH: nowH + widgetTimelineHorizonHours + visibleWindowHours,
            numberOfSteps: chartPointCount(visibleWindowHours: visibleWindowHours),
            vdPerKGOverride: calibration.vdPerKGOverride(for: hormone),
            kaMultiplier: calibration.kaMultiplier(for: hormone),
            cancellationCheck: cancellationCheck
        )
        let result = engine.run(cancellationCheck: cancellationCheck).converted(to: unit)
        let points = zip(result.timeH, result.concentrations).map {
            WidgetChartPoint(timeH: $0.0, concentration: $0.1)
        }

        return WidgetHormoneSnapshot(
            hormone: kind,
            displayName: hormone.displayName,
            unitSymbol: unit.symbol,
            currentValue: result.concentration(at: nowH),
            currentTimeH: nowH,
            points: points,
            threshold: threshold,
            updatedAt: date
        )
    }

    static func makeDoseOptions(from plans: [MedicationPlan]) -> [WidgetDoseOption] {
        var options: [WidgetDoseOption] = []

        for (planIndex, plan) in plans.enumerated() {
            // Paused plans remain visible in the medication editor, but are not
            // valid recordable options for widgets, Siri, or Shortcuts.
            guard plan.isEnabled, plan.primaryTemplate.hasConfiguredDose else { continue }

            if plan.recurrence.kind == .daily, !plan.resolvedDailyDoseSlots.isEmpty {
                for (slotIndex, slot) in plan.resolvedDailyDoseSlots.enumerated() where slot.template.hasConfiguredDose {
                    options.append(
                        WidgetDoseOption(
                            id: WidgetDoseOption.makeID(planID: plan.id, doseSlotID: slot.id),
                            planID: plan.id,
                            doseSlotID: slot.id,
                            title: plan.displayName,
                            subtitle: "\(slot.time.formattedText) · \(slot.template.planSummaryText)",
                            isEnabled: true,
                            sortOrder: planIndex * 1000 + slotIndex
                        )
                    )
                }
            } else {
                options.append(
                    WidgetDoseOption(
                        id: WidgetDoseOption.makeID(planID: plan.id, doseSlotID: nil),
                        planID: plan.id,
                        doseSlotID: nil,
                        title: plan.displayName,
                        subtitle: plan.primaryTemplate.planSummaryText,
                        isEnabled: true,
                        sortOrder: planIndex * 1000
                    )
                )
            }
        }

        return options.sorted { $0.sortOrder < $1.sortOrder }
    }

    private static func preferredUnits() -> [SimulatedHormone: ConcentrationUnit] {
        Dictionary(
            uniqueKeysWithValues: SimulatedHormone.allCases.map { hormone in
                (hormone, preferredUnit(for: hormone))
            }
        )
    }

    private static func convertedThresholds(
        for units: [SimulatedHormone: ConcentrationUnit]
    ) -> [SimulatedHormone: WidgetThresholdRange] {
        Dictionary(
            uniqueKeysWithValues: SimulatedHormone.allCases.map { hormone in
                let unit = units[hormone] ?? hormone.concentrationUnit
                return (hormone, convertedThreshold(for: hormone, to: unit))
            }
        )
    }

    private static func preferredUnit(for hormone: SimulatedHormone) -> ConcentrationUnit {
        hormone.preferredUnit(
            from: UserDefaults.standard.string(
                forKey: "timeline.selectedConcentrationUnit.\(hormone.rawValue)"
            )
        )
    }

    private static func convertedThreshold(
        for hormone: SimulatedHormone,
        to targetUnit: ConcentrationUnit
    ) -> WidgetThresholdRange {
        let kind = WidgetHormoneKind(rawValue: hormone.rawValue) ?? .estradiol
        let stored = WidgetSharedStore.threshold(for: kind)
        let sourceUnit = hormone.concentrationUnit

        return WidgetThresholdRange(
            low: ConcentrationUnit.convert(stored.low, from: sourceUnit, to: targetUnit, hormone: hormone),
            high: ConcentrationUnit.convert(stored.high, from: sourceUnit, to: targetUnit, hormone: hormone)
        )
    }
}
