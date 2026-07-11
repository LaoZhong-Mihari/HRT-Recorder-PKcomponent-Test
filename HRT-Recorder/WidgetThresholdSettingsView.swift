import SwiftUI

struct WidgetThresholdSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private let onSettingsChanged: () -> Void

    @State private var surroundingHours: Int
    @State private var estradiolLowText: String
    @State private var estradiolHighText: String
    @State private var testosteroneLowText: String
    @State private var testosteroneHighText: String

    init(onSettingsChanged: @escaping () -> Void) {
        self.onSettingsChanged = onSettingsChanged
        let displaySettings = WidgetSharedStore.displaySettings()
        let thresholds = WidgetSharedStore.readThresholds()
        let estradiol = thresholds[.estradiol] ?? WidgetThresholdRange.defaultRange(for: .estradiol)
        let testosterone = thresholds[.testosterone] ?? WidgetThresholdRange.defaultRange(for: .testosterone)
        _surroundingHours = State(initialValue: displaySettings.surroundingHours)
        _estradiolLowText = State(initialValue: Self.format(estradiol.low))
        _estradiolHighText = State(initialValue: Self.format(estradiol.high))
        _testosteroneLowText = State(initialValue: Self.format(testosterone.low))
        _testosteroneHighText = State(initialValue: Self.format(testosterone.high))
    }

    private var estradiolRange: WidgetThresholdRange? {
        parsedRange(lowText: estradiolLowText, highText: estradiolHighText)
    }

    private var testosteroneRange: WidgetThresholdRange? {
        parsedRange(lowText: testosteroneLowText, highText: testosteroneHighText)
    }

    private var canSave: Bool {
        estradiolRange?.isValid == true && testosteroneRange?.isValid == true
    }

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: $surroundingHours,
                    in: WidgetDisplaySettings.allowedSurroundingHours
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hours before and after now")
                        Text(verbatim: "±\(surroundingHours) h")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityValue(
                    Text("Hours shown on each side of now: \(surroundingHours)")
                )
            } header: {
                Text("Chart Window")
            } footer: {
                Text("The widget curve displays this many hours before and after the current time.")
            }

            Section {
                ThresholdEditorRows(
                    lowText: $estradiolLowText,
                    highText: $estradiolHighText,
                    unit: WidgetHormoneKind.estradiol.canonicalUnitSymbol
                )
                validationMessage(for: estradiolRange)
            } header: {
                Text("Estradiol")
            } footer: {
                Text("Low / medium / high colors are personal visual markers, not medical guidance.")
            }

            Section {
                ThresholdEditorRows(
                    lowText: $testosteroneLowText,
                    highText: $testosteroneHighText,
                    unit: WidgetHormoneKind.testosterone.canonicalUnitSymbol
                )
                validationMessage(for: testosteroneRange)
            } header: {
                Text("Testosterone")
            }

            Section {
                Button("Restore Defaults") {
                    restoreDefaults()
                }
            }
        }
        .navigationTitle("Widget Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("common.save") {
                    save()
                }
                .disabled(!canSave)
            }
        }
    }

    @ViewBuilder
    private func validationMessage(for range: WidgetThresholdRange?) -> some View {
        if range == nil || range?.isValid == false {
            Text("Low must be smaller than high.")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func parsedRange(lowText: String, highText: String) -> WidgetThresholdRange? {
        guard let low = Self.parse(lowText),
              let high = Self.parse(highText) else {
            return nil
        }
        return WidgetThresholdRange(low: low, high: high)
    }

    private func restoreDefaults() {
        surroundingHours = WidgetDisplaySettings.defaultValue.surroundingHours
        let estradiol = WidgetThresholdRange.defaultRange(for: .estradiol)
        let testosterone = WidgetThresholdRange.defaultRange(for: .testosterone)
        estradiolLowText = Self.format(estradiol.low)
        estradiolHighText = Self.format(estradiol.high)
        testosteroneLowText = Self.format(testosterone.low)
        testosteroneHighText = Self.format(testosterone.high)
    }

    private func save() {
        guard let estradiolRange, let testosteroneRange else { return }
        WidgetSharedStore.saveDisplaySettings(
            WidgetDisplaySettings(surroundingHours: surroundingHours)
        )
        WidgetSharedStore.saveThresholds([
            .estradiol: estradiolRange,
            .testosterone: testosteroneRange
        ])
        dismiss()
        onSettingsChanged()
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func format(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", value)
    }
}

private struct ThresholdEditorRows: View {
    @Binding var lowText: String
    @Binding var highText: String
    let unit: String

    var body: some View {
        HStack {
            Text("Low")
            Spacer()
            TextField("0", text: $lowText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 96)
            Text(unit)
                .foregroundStyle(.secondary)
        }

        HStack {
            Text("High")
            Spacer()
            TextField("0", text: $highText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 96)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }
}
