import Foundation
import WidgetKit

enum WidgetSnapshotCoordinator {
    private static let windowPaddingHours = 6.0
    private static let widgetTimelineHorizonHours = 12.0
    private static let chartPointIntervalHours = 0.125
    private static var chartPointCount: Int {
        Int(((windowPaddingHours * 2 + widgetTimelineHorizonHours) / chartPointIntervalHours).rounded()) + 1
    }

    static func makeSnapshot(
        events: [DoseEvent],
        bodyWeightKG: Double,
        plans: [MedicationPlan],
        at date: Date = Date()
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: 1,
            generatedAt: date,
            hormones: SimulatedHormone.allCases.map {
                makeHormoneSnapshot(
                    hormone: $0,
                    events: events,
                    bodyWeightKG: bodyWeightKG,
                    at: date
                )
            },
            doseOptions: makeDoseOptions(from: plans)
        )
    }

    static func writeSnapshot(
        events: [DoseEvent],
        bodyWeightKG: Double,
        plans: [MedicationPlan],
        reloadTimelines: Bool = true
    ) {
        let snapshot = makeSnapshot(events: events, bodyWeightKG: bodyWeightKG, plans: plans)
        WidgetSharedStore.writeSnapshot(snapshot)

        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func makeHormoneSnapshot(
        hormone: SimulatedHormone,
        events: [DoseEvent],
        bodyWeightKG: Double,
        at date: Date
    ) -> WidgetHormoneSnapshot {
        let kind = WidgetHormoneKind(rawValue: hormone.rawValue) ?? .estradiol
        let unit = preferredUnit(for: hormone)
        let threshold = convertedThreshold(for: hormone, to: unit)
        let nowH = date.timeIntervalSince1970 / 3600.0
        let simulatedEvents = events
            .filter { $0.participatesInSimulation && $0.simulatedHormone == hormone }
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
            startTimeH: nowH - windowPaddingHours,
            endTimeH: nowH + widgetTimelineHorizonHours + windowPaddingHours,
            numberOfSteps: chartPointCount
        )
        let result = engine.run().converted(to: unit)
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
