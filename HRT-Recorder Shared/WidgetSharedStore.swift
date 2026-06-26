import Foundation

enum WidgetSharedStore {
    static let appGroupIdentifier = "group.mihari.HRT-Recorder-beta"

    private static let snapshotFileName = "widget_snapshot.json"
    private static let doseHandoffFileName = "widget_dose_handoff.json"
    private static let thresholdsKey = "widget.thresholds.v1"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func fileURL(named fileName: String) -> URL? {
        sharedContainerURL?.appendingPathComponent(fileName)
    }

    static func readSnapshot() -> WidgetSnapshot {
        guard let url = fileURL(named: snapshotFileName),
              let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot.empty()
        }
        return snapshot
    }

    static func writeSnapshot(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL(named: snapshotFileName),
              let data = try? encoder.encode(snapshot) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func threshold(for hormone: WidgetHormoneKind) -> WidgetThresholdRange {
        let stored = readThresholds()[hormone] ?? WidgetThresholdRange.defaultRange(for: hormone)
        return stored.isValid ? stored : WidgetThresholdRange.defaultRange(for: hormone)
    }

    static func readThresholds() -> [WidgetHormoneKind: WidgetThresholdRange] {
        var resolved = Dictionary(
            uniqueKeysWithValues: WidgetHormoneKind.allCases.map {
                ($0, WidgetThresholdRange.defaultRange(for: $0))
            }
        )

        guard let data = sharedDefaults.data(forKey: thresholdsKey),
              let raw = try? decoder.decode([String: WidgetThresholdRange].self, from: data) else {
            return resolved
        }

        for (key, range) in raw {
            guard let hormone = WidgetHormoneKind(rawValue: key), range.isValid else { continue }
            resolved[hormone] = range
        }
        return resolved
    }

    static func saveThresholds(_ thresholds: [WidgetHormoneKind: WidgetThresholdRange]) {
        let raw = thresholds.reduce(into: [String: WidgetThresholdRange]()) { partialResult, pair in
            guard pair.value.isValid else { return }
            partialResult[pair.key.rawValue] = pair.value
        }

        guard let data = try? encoder.encode(raw) else { return }
        sharedDefaults.set(data, forKey: thresholdsKey)
    }

    static func resetThresholdsToDefaults() {
        sharedDefaults.removeObject(forKey: thresholdsKey)
    }

    static func writeDoseHandoff(_ handoff: WidgetDoseHandoff) {
        guard let url = fileURL(named: doseHandoffFileName),
              let data = try? encoder.encode(handoff) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func consumeDoseHandoff() -> WidgetDoseHandoff? {
        guard let url = fileURL(named: doseHandoffFileName),
              let data = try? Data(contentsOf: url),
              let handoff = try? decoder.decode(WidgetDoseHandoff.self, from: data) else {
            return nil
        }

        try? FileManager.default.removeItem(at: url)
        return handoff
    }
}
