import Foundation

/// Stores the user's explicit HRT focus separately from the legacy timeline
/// selection. A feature revision is used instead of the app build number so
/// ordinary updates do not repeatedly show setup.
nonisolated struct HRTProfilePreferences {
    static let currentPromptVersion = 1
    static let hormoneKey = "hrt.profile.type.v1"
    static let promptVersionKey = "hrt.profile.promptVersion"
    static let legacyTimelineHormoneKey = "timeline.selectedHormone"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var confirmedHormone: SimulatedHormone? {
        guard let rawValue = defaults.string(forKey: Self.hormoneKey) else {
            return nil
        }
        return SimulatedHormone(rawValue: rawValue)
    }

    var suggestedHormone: SimulatedHormone {
        if let confirmedHormone {
            return confirmedHormone
        }
        if let legacyValue = defaults.string(forKey: Self.legacyTimelineHormoneKey),
           let legacyHormone = SimulatedHormone(rawValue: legacyValue) {
            return legacyHormone
        }
        return .estradiol
    }

    var requiresSelectionPrompt: Bool {
        guard confirmedHormone != nil else { return true }
        return defaults.integer(forKey: Self.promptVersionKey) < Self.currentPromptVersion
    }

    func confirm(_ hormone: SimulatedHormone) {
        defaults.set(hormone.rawValue, forKey: Self.hormoneKey)
        defaults.set(hormone.rawValue, forKey: Self.legacyTimelineHormoneKey)
        defaults.set(Self.currentPromptVersion, forKey: Self.promptVersionKey)
    }
}
