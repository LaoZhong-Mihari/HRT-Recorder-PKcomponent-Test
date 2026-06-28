//
//  LabResultsView.swift
//  HRT-Recorder
//

import Foundation
import ImageIO
import SwiftUI
import UIKit
import Vision
import VisionKit

struct LabResultsView: View {
    @ObservedObject var vm: DoseTimelineVM

    @State private var activeSheet: LabResultSheet?
    @State private var isRecognizing = false
    @State private var statusMessage: String?

    private var sortedSamples: [LabSample] {
        vm.labSamples.sorted { $0.timeH > $1.timeH }
    }

    var body: some View {
        List {
            Section {
                if sortedSamples.isEmpty {
                    EmptyLabResultsRow()
                } else {
                    ForEach(sortedSamples) { sample in
                        LabSampleRow(sample: sample)
                    }
                    .onDelete(perform: deleteSamples)
                }
            } header: {
                Text("Saved Results")
            } footer: {
                Text("Saved hormone lab results are used to calibrate the PK curve against your measured levels.")
            }

            Section("Calibration") {
                ForEach(SimulatedHormone.allCases) { hormone in
                    CalibrationSummaryRow(
                        hormone: hormone,
                        info: vm.calibrationResult.infoByHormone[hormone]
                    )
                }
            }
        }
        .navigationTitle("Lab Results")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        activeSheet = .scanner
                    } label: {
                        Label("Scan Report", systemImage: "doc.viewfinder")
                    }
                    .disabled(!VNDocumentCameraViewController.isSupported)

                    Button {
                        activeSheet = .paste
                    } label: {
                        Label("Paste Text", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        activeSheet = .review([LabSampleDraft(hormone: vm.selectedHormone)])
                    } label: {
                        Label("Add Manually", systemImage: "plus.circle")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 19, weight: .bold))
                }
                .accessibilityLabel(Text("Add lab result"))
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .scanner:
                DocumentScannerView(
                    onCancel: { activeSheet = nil },
                    onFinish: recognizeScannedImages
                )

            case .paste:
                PasteLabResultTextView { text in
                    presentParsedText(text)
                }

            case .review(let drafts):
                NavigationStack {
                    LabSampleReviewView(initialDrafts: drafts) { samples in
                        vm.saveLabSamples(samples)
                    }
                }
            }
        }
        .overlay {
            if isRecognizing {
                ZStack {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()

                    ProgressView("Reading lab report...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .alert("Lab Results", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func deleteSamples(at offsets: IndexSet) {
        let ids = offsets.map { sortedSamples[$0].id }
        vm.removeLabSamples(withIDs: ids)
    }

    private func recognizeScannedImages(_ images: [UIImage]) {
        activeSheet = nil

        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }

            do {
                let text = try await LabResultOCRService.recognizeText(in: images)
                presentParsedText(text)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func presentParsedText(_ text: String) {
        let drafts = HormoneLabResultParser.parse(text, defaultHormone: vm.selectedHormone)
        guard !drafts.isEmpty else {
            activeSheet = nil
            statusMessage = "No estradiol or testosterone result with a supported unit was found."
            return
        }
        activeSheet = .review(drafts)
    }
}

private enum LabResultSheet: Identifiable {
    case scanner
    case paste
    case review([LabSampleDraft])

    var id: String {
        switch self {
        case .scanner: return "scanner"
        case .paste: return "paste"
        case .review: return "review"
        }
    }
}

private struct LabSampleDraft: Identifiable {
    let id: UUID
    var hormone: SimulatedHormone
    var collectedAt: Date
    var valueText: String
    var unit: ConcentrationUnit
    var sourceLine: String

    init(
        id: UUID = UUID(),
        hormone: SimulatedHormone,
        collectedAt: Date = Date(),
        value: Double? = nil,
        unit: ConcentrationUnit? = nil,
        sourceLine: String = ""
    ) {
        self.id = id
        self.hormone = hormone
        self.collectedAt = collectedAt
        self.valueText = value.map { Self.formatValue($0) } ?? ""
        self.unit = unit ?? hormone.concentrationUnit
        self.sourceLine = sourceLine
    }

    init(sample: LabSample, sourceLine: String = "") {
        self.init(
            id: sample.id,
            hormone: sample.hormone,
            collectedAt: sample.collectedAt,
            value: sample.concentration,
            unit: sample.unit,
            sourceLine: sourceLine
        )
    }

    var labSample: LabSample? {
        let normalized = valueText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return LabSample(
            id: id,
            hormone: hormone,
            collectedAt: collectedAt,
            concentration: value,
            unit: unit
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale.current, value)
    }
}

private struct EmptyLabResultsRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No lab results yet", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text("Scan a report, paste OCR text, or add a value manually.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LabSampleRow: View {
    let sample: LabSample

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sample.hormone == .estradiol ? "drop.fill" : "bolt.heart.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(sample.hormone.chartColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(sample.hormone.displayName)
                    .font(.headline)
                Text(sample.collectedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(formattedValue)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }

    private var formattedValue: String {
        String(format: "%.2f %@", locale: Locale.current, sample.concentration, sample.unit.symbol)
    }
}

private struct CalibrationSummaryRow: View {
    let hormone: SimulatedHormone
    let info: CalibrationInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(hormone.chartColor)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(hormone.displayName)
                    .font(.headline)

                if let info {
                    Text(summary(for: info))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(info.latestLabDate, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No usable calibration samples yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(for info: CalibrationInfo) -> String {
        String(
            format: "Vd x %.2f · curve x %.2f · absorption x %.2f · %d sample(s)",
            locale: Locale.current,
            info.vdScale,
            info.curveFactor,
            info.kaMultiplier,
            info.sampleCount
        )
    }
}

private struct PasteLabResultTextView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    let onParse: (String) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(12)
                .navigationTitle("Paste Lab Text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Parse") {
                            onParse(text)
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct LabSampleReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [LabSampleDraft]

    let onSave: ([LabSample]) -> Void

    init(initialDrafts: [LabSampleDraft], onSave: @escaping ([LabSample]) -> Void) {
        _drafts = State(initialValue: initialDrafts)
        self.onSave = onSave
    }

    private var validSamples: [LabSample] {
        drafts.compactMap { $0.labSample }
    }

    var body: some View {
        Form {
            Section {
                ForEach($drafts) { $draft in
                    LabSampleDraftRow(draft: $draft)
                }
                .onDelete { offsets in
                    drafts.remove(atOffsets: offsets)
                }

                Button {
                    drafts.append(LabSampleDraft(hormone: drafts.last?.hormone ?? .estradiol))
                } label: {
                    Label("Add Row", systemImage: "plus.circle")
                }
            } footer: {
                Text("Review values before saving. Saved results immediately recalibrate the visible PK curve.")
            }
        }
        .navigationTitle("Review Results")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") {
                    onSave(validSamples)
                    dismiss()
                }
                .disabled(validSamples.isEmpty)
            }
        }
    }
}

private struct LabSampleDraftRow: View {
    @Binding var draft: LabSampleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Collected", selection: $draft.collectedAt)

            Picker("Hormone", selection: $draft.hormone) {
                ForEach(SimulatedHormone.allCases) { hormone in
                    Text(hormone.displayName).tag(hormone)
                }
            }
            .onChange(of: draft.hormone) { hormone in
                if !draft.unit.isSupported(for: hormone) {
                    draft.unit = hormone.concentrationUnit
                }
            }

            HStack(spacing: 12) {
                TextField("Value", text: $draft.valueText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)

                Picker("Unit", selection: $draft.unit) {
                    ForEach(draft.hormone.supportedConcentrationUnits) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if !draft.sourceLine.isEmpty {
                Text(draft.sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct DocumentScannerView: UIViewControllerRepresentable {
    let onCancel: () -> Void
    let onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScannerView

        init(parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true) {
                self.parent.onFinish(images)
            }
        }
    }
}

private enum LabResultOCRService {
    static func recognizeText(in images: [UIImage]) async throws -> String {
        var pages: [String] = []
        pages.reserveCapacity(images.count)

        for image in images {
            pages.append(try await recognizeText(in: image))
        }

        return pages.joined(separator: "\n")
    }

    private static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.missingImageData
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]

                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: orientation,
                        options: [:]
                    )
                    try handler.perform([request])

                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum OCRError: LocalizedError {
        case missingImageData

        var errorDescription: String? {
            switch self {
            case .missingImageData:
                return "The scanned page could not be converted for text recognition."
            }
        }
    }
}

private enum HormoneLabResultParser {
    static func parse(_ text: String, defaultHormone: SimulatedHormone) -> [LabSampleDraft] {
        let normalizedText = normalize(text)
        let collectedAt = extractDate(from: normalizedText) ?? Date()
        let lines = normalizedText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasExplicitHormone = lines.contains { detectHormone(in: $0) != nil }

        var drafts: [LabSampleDraft] = []
        for line in lines {
            let hormone = detectHormone(in: line) ?? (!hasExplicitHormone && lineContainsSupportedUnit(line) ? defaultHormone : nil)
            guard let hormone,
                  let value = extractValueAndUnit(from: line, hormone: hormone) else {
                continue
            }

            drafts.append(
                LabSampleDraft(
                    hormone: hormone,
                    collectedAt: collectedAt,
                    value: value.amount,
                    unit: value.unit,
                    sourceLine: line
                )
            )
        }

        return uniqued(drafts)
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: " ")
    }

    private static func detectHormone(in line: String) -> SimulatedHormone? {
        let lower = line.lowercased()
        if lower.contains("estradiol")
            || lower.contains("oestradiol")
            || lower.contains(" e2")
            || lower.hasPrefix("e2")
            || line.contains("雌二醇") {
            return .estradiol
        }

        if lower.contains("testosterone")
            || lower.contains("total t")
            || line.contains("睾酮")
            || line.contains("睪酮") {
            return .testosterone
        }

        return nil
    }

    private static func extractDate(from text: String) -> Date? {
        let pattern = #"(\d{4})\s*[-./]\s*(\d{1,2})\s*[-./]\s*(\d{1,2})"#
        guard let match = firstMatch(pattern: pattern, in: text),
              let year = intCapture(1, in: text, match: match),
              let month = intCapture(2, in: text, match: match),
              let day = intCapture(3, in: text, match: match) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date
    }

    private static func extractValueAndUnit(
        from line: String,
        hormone: SimulatedHormone
    ) -> (amount: Double, unit: ConcentrationUnit)? {
        let pattern = #"([0-9]+(?:[\.,][0-9]+)?)\s*(pg\s*/?\s*m[lL]|pmol\s*/?\s*[lL]|ng\s*/?\s*d[lL]|ng\s*/?\s*m[lL]|nmol\s*/?\s*[lL])"#
        guard let match = firstMatch(pattern: pattern, in: line),
              let valueText = stringCapture(1, in: line, match: match)?
                .replacingOccurrences(of: ",", with: "."),
              let amount = Double(valueText),
              let unitText = stringCapture(2, in: line, match: match),
              let unit = unit(from: unitText),
              unit.isSupported(for: hormone) else {
            return nil
        }

        return (amount, unit)
    }

    private static func lineContainsSupportedUnit(_ line: String) -> Bool {
        extractValueAndUnit(from: line, hormone: .estradiol) != nil
            || extractValueAndUnit(from: line, hormone: .testosterone) != nil
    }

    private static func unit(from raw: String) -> ConcentrationUnit? {
        let token = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        switch token {
        case "pg/ml": return .pgPerML
        case "pmol/l": return .pmolPerL
        case "ng/dl": return .ngPerDL
        case "ng/ml": return .ngPerML
        case "nmol/l": return .nmolPerL
        default: return nil
        }
    }

    private static func uniqued(_ drafts: [LabSampleDraft]) -> [LabSampleDraft] {
        var seen = Set<String>()
        return drafts.filter { draft in
            let key = [
                draft.hormone.rawValue,
                draft.valueText,
                draft.unit.rawValue,
                String(Int(draft.collectedAt.timeIntervalSince1970 / 60))
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private static func stringCapture(
        _ index: Int,
        in text: String,
        match: NSTextCheckingResult
    ) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func intCapture(
        _ index: Int,
        in text: String,
        match: NSTextCheckingResult
    ) -> Int? {
        stringCapture(index, in: text, match: match).flatMap(Int.init)
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
