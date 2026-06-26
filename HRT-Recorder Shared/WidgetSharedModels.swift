import Foundation

enum WidgetHormoneKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case estradiol
    case testosterone

    var id: String { rawValue }

    var fallbackDisplayName: String {
        switch self {
        case .estradiol:
            return String(localized: "Estradiol")
        case .testosterone:
            return String(localized: "Testosterone")
        }
    }

    var canonicalUnitSymbol: String {
        switch self {
        case .estradiol:
            return "pg/mL"
        case .testosterone:
            return "ng/dL"
        }
    }
}

struct WidgetThresholdRange: Codable, Equatable, Sendable {
    var low: Double
    var high: Double

    var isValid: Bool {
        low.isFinite && high.isFinite && low < high
    }

    static func defaultRange(for hormone: WidgetHormoneKind) -> WidgetThresholdRange {
        switch hormone {
        case .estradiol:
            return WidgetThresholdRange(low: 50, high: 300)
        case .testosterone:
            return WidgetThresholdRange(low: 200, high: 1200)
        }
    }
}

struct WidgetChartPoint: Codable, Equatable, Sendable {
    let timeH: Double
    let concentration: Double
}

struct WidgetHormoneSnapshot: Codable, Equatable, Sendable {
    let hormone: WidgetHormoneKind
    let displayName: String
    let unitSymbol: String
    let currentValue: Double?
    let currentTimeH: Double
    let points: [WidgetChartPoint]
    let threshold: WidgetThresholdRange
    let updatedAt: Date

    var hasData: Bool {
        currentValue != nil && !points.isEmpty
    }

    func resolved(at date: Date, visibleWindowHours: Double = 6) -> WidgetHormoneSnapshot {
        let timeH = date.timeIntervalSince1970 / 3600.0
        let visibleStart = timeH - visibleWindowHours
        let visibleEnd = timeH + visibleWindowHours
        let visiblePoints = points.filter { point in
            point.timeH >= visibleStart && point.timeH <= visibleEnd
        }

        return WidgetHormoneSnapshot(
            hormone: hormone,
            displayName: displayName,
            unitSymbol: unitSymbol,
            currentValue: concentration(at: timeH),
            currentTimeH: timeH,
            points: visiblePoints.isEmpty ? points : visiblePoints,
            threshold: threshold,
            updatedAt: updatedAt
        )
    }

    func isExpired(
        at date: Date,
        visibleWindowHours: Double = 6,
        maxAge: TimeInterval = 12 * 60 * 60
    ) -> Bool {
        guard hasData else { return false }

        if date.timeIntervalSince(updatedAt) > maxAge {
            return true
        }

        let timeH = date.timeIntervalSince1970 / 3600.0
        guard let first = points.first?.timeH,
              let last = points.last?.timeH else {
            return true
        }

        return timeH - visibleWindowHours < first || timeH + visibleWindowHours > last
    }

    func concentration(at timeH: Double) -> Double? {
        guard timeH.isFinite, points.count >= 2 else {
            return currentValue
        }

        if let exact = points.first(where: { abs($0.timeH - timeH) < 0.000_001 }) {
            return exact.concentration
        }

        guard let first = points.first,
              let last = points.last,
              timeH >= first.timeH,
              timeH <= last.timeH else {
            return nil
        }

        for (previous, next) in zip(points, points.dropFirst()) where previous.timeH <= timeH && timeH <= next.timeH {
            let span = next.timeH - previous.timeH
            guard span > 0 else {
                return previous.concentration
            }
            let ratio = (timeH - previous.timeH) / span
            return previous.concentration + (next.concentration - previous.concentration) * ratio
        }

        return nil
    }

    static func empty(
        hormone: WidgetHormoneKind,
        threshold: WidgetThresholdRange? = nil,
        updatedAt: Date = Date()
    ) -> WidgetHormoneSnapshot {
        let resolvedThreshold = threshold ?? WidgetThresholdRange.defaultRange(for: hormone)
        return WidgetHormoneSnapshot(
            hormone: hormone,
            displayName: hormone.fallbackDisplayName,
            unitSymbol: hormone.canonicalUnitSymbol,
            currentValue: nil,
            currentTimeH: updatedAt.timeIntervalSince1970 / 3600.0,
            points: [],
            threshold: resolvedThreshold,
            updatedAt: updatedAt
        )
    }
}

struct WidgetDoseOption: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let planID: UUID
    let doseSlotID: UUID?
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let sortOrder: Int

    static func makeID(planID: UUID, doseSlotID: UUID?) -> String {
        if let doseSlotID {
            return "plan|\(planID.uuidString)|slot|\(doseSlotID.uuidString)"
        }
        return "plan|\(planID.uuidString)"
    }

    static func parseID(_ id: String) -> (planID: UUID, doseSlotID: UUID?)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 4,
              parts.first == "plan",
              let planID = UUID(uuidString: parts[1]) else {
            return nil
        }

        if parts.count == 4 {
            guard parts[2] == "slot",
                  let doseSlotID = UUID(uuidString: parts[3]) else {
                return nil
            }
            return (planID, doseSlotID)
        }

        return (planID, nil)
    }
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let hormones: [WidgetHormoneSnapshot]
    let doseOptions: [WidgetDoseOption]

    func hormoneSnapshot(for hormone: WidgetHormoneKind) -> WidgetHormoneSnapshot? {
        hormones.first { $0.hormone == hormone }
    }

    static func empty(generatedAt: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            hormones: WidgetHormoneKind.allCases.map {
                WidgetHormoneSnapshot.empty(hormone: $0, updatedAt: generatedAt)
            },
            doseOptions: []
        )
    }
}

struct WidgetDoseHandoff: Codable, Equatable, Sendable {
    let id: UUID
    let optionID: String
    let requestedAt: Date

    init(id: UUID = UUID(), optionID: String, requestedAt: Date = Date()) {
        self.id = id
        self.optionID = optionID
        self.requestedAt = requestedAt
    }
}
