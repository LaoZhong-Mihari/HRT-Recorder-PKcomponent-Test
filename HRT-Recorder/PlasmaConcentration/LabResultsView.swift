//
//  LabResultsView.swift
//  HRT-Recorder
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

struct LabResultsView: View {
    @ObservedObject var vm: DoseTimelineVM

    @State private var activeSheet: LabResultSheet?
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isRecognizing = false
    @State private var statusMessage: String?

    private var sortedReports: [LabReport] {
        vm.labReports.sorted { $0.collectedAt > $1.collectedAt }
    }

    var body: some View {
        List {
            Section {
                if sortedReports.isEmpty {
                    EmptyLabResultsRow()
                } else {
                    ForEach(sortedReports) { report in
                        NavigationLink {
                            LabReportDetailView(
                                report: report,
                                predictedConcentration: predictedConcentration(for: report),
                                predictedHormone: vm.selectedHormone,
                                predictedUnit: vm.selectedConcentrationUnit
                            )
                        } label: {
                            LabReportRow(report: report)
                        }
                    }
                    .onDelete(perform: deleteReports)
                }
            } header: {
                Text("Saved Reports")
            } footer: {
                Text("Saved E2 and testosterone values are used to calibrate the PK curve against measured lab levels.")
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
                        isPhotoPickerPresented = true
                    } label: {
                        Label("Upload Images", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        activeSheet = .paste
                    } label: {
                        Label("Paste Text", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        activeSheet = .review(LabReportDraft(sourceKind: .manual, selectedHormone: vm.selectedHormone))
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
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: 8,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { items in
            guard !items.isEmpty else { return }
            selectedPhotoItems = []
            recognizePhotoItems(items)
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
                    activeSheet = nil
                    presentParsedText(text, sourceKind: .pastedText)
                }

            case .review(let draft):
                NavigationStack {
                    LabReportReviewView(initialDraft: draft) { report in
                        vm.saveLabReport(report)
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

    private func deleteReports(at offsets: IndexSet) {
        let ids = offsets.map { sortedReports[$0].id }
        vm.removeLabReports(withIDs: ids)
    }

    private func predictedConcentration(for report: LabReport) -> Double? {
        guard report.analytes.contains(where: { $0.simulatedHormone == vm.selectedHormone }) else {
            return nil
        }
        return vm.concentration(at: report.collectedAt)
    }

    private func recognizeScannedImages(_ images: [UIImage]) {
        activeSheet = nil
        recognizeImages(images, sourceKind: .scanner)
    }

    private func recognizePhotoItems(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }

            do {
                var images: [UIImage] = []
                images.reserveCapacity(items.count)

                for item in items {
                    if let data = try await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }

                guard !images.isEmpty else {
                    statusMessage = "No readable image was selected."
                    return
                }

                let text = try await LabResultOCRService.recognizeText(in: images)
                await presentReport(from: text, sourceKind: .imageUpload)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func recognizeImages(_ images: [UIImage], sourceKind: LabReportSourceKind) {
        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }

            do {
                let text = try await LabResultOCRService.recognizeText(in: images)
                await presentReport(from: text, sourceKind: sourceKind)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func presentParsedText(_ text: String, sourceKind: LabReportSourceKind) {
        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }
            await presentReport(from: text, sourceKind: sourceKind)
        }
    }

    @MainActor
    private func presentReport(from text: String, sourceKind: LabReportSourceKind) async {
        let outcome = await LabReportExtractionPipeline.extract(
            from: text,
            sourceKind: sourceKind,
            defaultHormone: vm.selectedHormone
        )

        guard !outcome.report.analytes.isEmpty else {
            statusMessage = "No hormone result was found. Apple AI may be unavailable on this device; OCR fallback did not find a supported table row."
            return
        }

        activeSheet = .review(LabReportDraft(report: outcome.report, extractionStatus: outcome.statusMessage))
    }
}

private enum LabResultSheet: Identifiable {
    case scanner
    case paste
    case review(LabReportDraft)

    var id: String {
        switch self {
        case .scanner: return "scanner"
        case .paste: return "paste"
        case .review(let draft): return "review-\(draft.id.uuidString)"
        }
    }
}

private struct LabReportDraft: Identifiable {
    var id: UUID
    var collectedAt: Date
    var reportedAt: Date?
    var hasReportedAt: Bool
    var institution: String
    var location: String
    var specimen: String
    var method: String
    var sourceKind: LabReportSourceKind
    var sourceText: String
    var analytes: [LabAnalyteDraft]
    var note: String
    var extractionStatus: String?

    init(report: LabReport, extractionStatus: String? = nil) {
        self.id = report.id
        self.collectedAt = report.collectedAt
        self.reportedAt = report.reportedAt
        self.hasReportedAt = report.reportedAt != nil
        self.institution = report.institution
        self.location = report.location
        self.specimen = report.specimen
        self.method = report.method
        self.sourceKind = report.sourceKind
        self.sourceText = report.sourceText
        self.analytes = report.analytes.map(LabAnalyteDraft.init(result:))
        self.note = report.note
        self.extractionStatus = extractionStatus
    }

    init(sourceKind: LabReportSourceKind, selectedHormone: SimulatedHormone) {
        self.id = UUID()
        self.collectedAt = Date()
        self.reportedAt = nil
        self.hasReportedAt = false
        self.institution = ""
        self.location = ""
        self.specimen = ""
        self.method = ""
        self.sourceKind = sourceKind
        self.sourceText = ""
        self.note = ""
        self.extractionStatus = nil

        let selectedKind: LabAnalyteKind = selectedHormone == .estradiol ? .estradiol : .testosterone
        let otherKind: LabAnalyteKind = selectedHormone == .estradiol ? .testosterone : .estradiol
        self.analytes = [
            LabAnalyteDraft(kind: selectedKind),
            LabAnalyteDraft(kind: otherKind)
        ]
    }

    var report: LabReport {
        LabReport(
            id: id,
            collectedAt: collectedAt,
            reportedAt: hasReportedAt ? reportedAt : nil,
            institution: institution.trimmed,
            location: location.trimmed,
            specimen: specimen.trimmed,
            method: method.trimmed,
            sourceKind: sourceKind,
            sourceText: sourceText,
            analytes: analytes.compactMap(\.result),
            note: note.trimmed
        )
    }
}

private struct LabAnalyteDraft: Identifiable {
    var id: UUID
    var kind: LabAnalyteKind
    var name: String
    var valueText: String
    var unitSymbol: String
    var concentrationUnit: ConcentrationUnit?
    var referenceRange: String
    var method: String
    var sourceLine: String
    var note: String

    init(kind: LabAnalyteKind) {
        self.id = UUID()
        self.kind = kind
        self.name = kind.defaultName
        self.valueText = ""
        self.concentrationUnit = kind.simulatedHormone?.concentrationUnit
        self.unitSymbol = kind.simulatedHormone?.concentrationUnit.symbol ?? ""
        self.referenceRange = ""
        self.method = ""
        self.sourceLine = ""
        self.note = ""
    }

    init(result: LabAnalyteResult) {
        self.id = result.id
        self.kind = result.kind
        self.name = result.name
        self.valueText = result.value.map { Self.formatValue($0) } ?? ""
        self.unitSymbol = result.unitSymbol
        self.concentrationUnit = result.concentrationUnit
        self.referenceRange = result.referenceRange ?? ""
        self.method = result.method ?? ""
        self.sourceLine = result.sourceLine ?? ""
        self.note = result.note ?? ""
    }

    var result: LabAnalyteResult? {
        let normalized = valueText
            .trimmed
            .replacingOccurrences(of: ",", with: ".")
        let value = Double(normalized)
        let hasDetails = value != nil
            || !referenceRange.trimmed.isEmpty
            || !method.trimmed.isEmpty
            || !sourceLine.trimmed.isEmpty
            || !note.trimmed.isEmpty
        guard hasDetails else { return nil }

        let resolvedUnit = concentrationUnit
        let resolvedUnitSymbol = resolvedUnit?.symbol ?? unitSymbol.trimmed

        return LabAnalyteResult(
            id: id,
            kind: kind,
            name: name.trimmed.isEmpty ? kind.defaultName : name.trimmed,
            value: value,
            unitSymbol: resolvedUnitSymbol,
            concentrationUnit: resolvedUnit,
            referenceRange: referenceRange.nilIfBlank,
            method: method.nilIfBlank,
            sourceLine: sourceLine.nilIfBlank,
            note: note.nilIfBlank
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale.current, value)
    }
}

private struct EmptyLabResultsRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No lab reports yet", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text("Scan, upload, paste OCR text, or add a report manually.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LabReportRow: View {
    let report: LabReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(reportTitle)
                    .font(.headline)
                Text(report.collectedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !report.hormoneSummary.isEmpty {
                    Text(report.hormoneSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Text("\(report.analytes.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var reportTitle: String {
        if !report.institution.trimmed.isEmpty {
            return report.institution
        }
        return report.sourceKind.localizedLabel
    }
}

private struct LabReportDetailView: View {
    let report: LabReport
    let predictedConcentration: Double?
    let predictedHormone: SimulatedHormone
    let predictedUnit: ConcentrationUnit

    var body: some View {
        List {
            Section("Results") {
                ForEach(report.analytes) { analyte in
                    LabAnalyteDetailRow(analyte: analyte)
                }
            }

            if let predictedConcentration {
                Section("Timeline") {
                    LabeledContent("\(predictedHormone.displayName) predicted") {
                        Text(formatConcentration(predictedConcentration, unit: predictedUnit))
                            .monospacedDigit()
                    }
                }
            }

            Section("Report") {
                LabeledContent("Collected") {
                    Text(report.collectedAt, format: .dateTime.year().month().day().hour().minute())
                }

                if let reportedAt = report.reportedAt {
                    LabeledContent("Reported") {
                        Text(reportedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }

                optionalContent("Institution", report.institution)
                optionalContent("Location", report.location)
                optionalContent("Specimen", report.specimen)
                optionalContent("Method", report.method)
                optionalContent("Notes", report.note)
            }

            if !report.sourceText.trimmed.isEmpty {
                Section("OCR Text") {
                    Text(report.sourceText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Report Detail")
    }

    @ViewBuilder
    private func optionalContent(_ title: String, _ value: String) -> some View {
        if !value.trimmed.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    private func formatConcentration(_ value: Double, unit: ConcentrationUnit) -> String {
        String(format: "%.1f %@", locale: Locale.current, value, unit.symbol)
    }
}

private struct LabAnalyteDetailRow: View {
    let analyte: LabAnalyteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(analyte.name)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(valueText)
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
            }

            if let referenceRange = analyte.referenceRange, !referenceRange.trimmed.isEmpty {
                Text("Reference \(referenceRange)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let method = analyte.method, !method.trimmed.isEmpty {
                Text(method)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = analyte.note, !note.trimmed.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var valueText: String {
        guard let value = analyte.value else { return "—" }
        let unit = analyte.concentrationUnit?.symbol ?? analyte.unitSymbol
        return String(format: "%.2f %@", locale: Locale.current, value, unit)
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
                        .disabled(text.trimmed.isEmpty)
                    }
                }
        }
    }
}

private struct LabReportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LabReportDraft

    let onSave: (LabReport) -> Void

    init(initialDraft: LabReportDraft, onSave: @escaping (LabReport) -> Void) {
        _draft = State(initialValue: initialDraft)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.report.analytes.isEmpty
    }

    var body: some View {
        Form {
            if let extractionStatus = draft.extractionStatus {
                Section {
                    Label(extractionStatus, systemImage: "wand.and.stars")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Report") {
                DatePicker("Collected", selection: $draft.collectedAt)

                Toggle("Reported time", isOn: $draft.hasReportedAt)
                if draft.hasReportedAt {
                    DatePicker(
                        "Reported",
                        selection: Binding(
                            get: { draft.reportedAt ?? draft.collectedAt },
                            set: { draft.reportedAt = $0 }
                        )
                    )
                }

                TextField("Institution", text: $draft.institution)
                TextField("Location", text: $draft.location)
                TextField("Specimen", text: $draft.specimen)
                TextField("Method", text: $draft.method)
                TextField("Notes", text: $draft.note, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("Hormones") {
                ForEach($draft.analytes) { $analyte in
                    LabAnalyteDraftRow(draft: $analyte)
                }
                .onDelete { offsets in
                    draft.analytes.remove(atOffsets: offsets)
                }

                Menu {
                    ForEach(LabAnalyteKind.allCases, id: \.self) { kind in
                        Button(kind.defaultName) {
                            draft.analytes.append(LabAnalyteDraft(kind: kind))
                        }
                    }
                } label: {
                    Label("Add Row", systemImage: "plus.circle")
                }
            }

            if !draft.sourceText.trimmed.isEmpty {
                Section("OCR Text") {
                    Text(draft.sourceText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Review Report")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") {
                    onSave(draft.report)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}

private struct LabAnalyteDraftRow: View {
    @Binding var draft: LabAnalyteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Hormone", selection: $draft.kind) {
                ForEach(LabAnalyteKind.allCases, id: \.self) { kind in
                    Text(kind.defaultName).tag(kind)
                }
            }
            .onChange(of: draft.kind) { kind in
                if draft.name.trimmed.isEmpty || LabAnalyteKind.allCases.map(\.defaultName).contains(draft.name) {
                    draft.name = kind.defaultName
                }
                if let hormone = kind.simulatedHormone {
                    let currentUnit = draft.concentrationUnit
                    if currentUnit?.isSupported(for: hormone) != true {
                        draft.concentrationUnit = hormone.concentrationUnit
                        draft.unitSymbol = hormone.concentrationUnit.symbol
                    }
                } else {
                    draft.concentrationUnit = nil
                }
            }

            TextField("Name", text: $draft.name)

            HStack(spacing: 12) {
                TextField("Value", text: $draft.valueText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)

                unitControl
            }

            TextField("Reference range", text: $draft.referenceRange)
            TextField("Method", text: $draft.method)
            TextField("Notes", text: $draft.note, axis: .vertical)
                .lineLimit(1...3)

            if !draft.sourceLine.trimmed.isEmpty {
                Text(draft.sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var unitControl: some View {
        if let hormone = draft.kind.simulatedHormone {
            Picker(
                "Unit",
                selection: Binding(
                    get: { draft.concentrationUnit ?? hormone.concentrationUnit },
                    set: { unit in
                        draft.concentrationUnit = unit
                        draft.unitSymbol = unit.symbol
                    }
                )
            ) {
                ForEach(hormone.supportedConcentrationUnits) { unit in
                    Text(unit.symbol).tag(unit)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        } else {
            TextField("Unit", text: $draft.unitSymbol)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
        }
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

private struct LabReportExtractionOutcome {
    var report: LabReport
    var statusMessage: String?
}

private enum LabReportExtractionPipeline {
    static func extract(
        from text: String,
        sourceKind: LabReportSourceKind,
        defaultHormone: SimulatedHormone
    ) async -> LabReportExtractionOutcome {
        let ruleReport = HormoneLabResultParser.parseReport(
            text,
            sourceKind: sourceKind,
            defaultHormone: defaultHormone
        )

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            if let aiReport = await LabReportAIExtractor.extract(
                from: text,
                sourceKind: sourceKind,
                fallback: ruleReport
            ), !aiReport.analytes.isEmpty {
                return LabReportExtractionOutcome(report: aiReport, statusMessage: nil)
            }

            return LabReportExtractionOutcome(
                report: ruleReport,
                statusMessage: "Apple AI was unavailable or could not structure this report; OCR table parsing was used."
            )
        }
        #endif

        return LabReportExtractionOutcome(
            report: ruleReport,
            statusMessage: "Apple AI requires iOS 27 and a supported Apple Intelligence device; OCR table parsing was used."
        )
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
private enum LabReportAIExtractor {
    static func extract(from text: String, sourceKind: LabReportSourceKind, fallback: LabReport) async -> LabReport? {
        let prompt = prompt(for: text)

        if let cloud = await generatedJSONUsingPrivateCloud(prompt: prompt),
           let report = decodeReport(from: cloud, sourceKind: sourceKind, sourceText: text, fallback: fallback) {
            return report
        }

        if let local = await generatedJSONUsingOnDeviceModel(prompt: prompt),
           let report = decodeReport(from: local, sourceKind: sourceKind, sourceText: text, fallback: fallback) {
            return report
        }

        return nil
    }

    private static func generatedJSONUsingPrivateCloud(prompt: String) async -> String? {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else { return nil }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "Extract structured hormone lab report data. Return only strict JSON."
            )
            return try await session.respond(to: prompt).content
        } catch {
            return nil
        }
    }

    private static func generatedJSONUsingOnDeviceModel(prompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "Extract structured hormone lab report data. Return only strict JSON."
            )
            return try await session.respond(to: prompt).content
        } catch {
            return nil
        }
    }

    private static func prompt(for text: String) -> String {
        """
        Read this OCR text from a hormone lab report and return JSON only.
        Do not use reference range numbers as result values. A result value must be the measured value in the table row.
        Preserve estradiol, testosterone, LH, FSH, prolactin, progesterone, SHBG, free testosterone, and other hormone rows when present.
        Use ISO-like dates when possible.

        JSON shape:
        {
          "collectedAt": "YYYY-MM-DD HH:mm",
          "reportedAt": "YYYY-MM-DD HH:mm",
          "institution": "",
          "location": "",
          "specimen": "",
          "method": "",
          "analytes": [
            {
              "kind": "estradiol|testosterone|luteinizingHormone|follicleStimulatingHormone|prolactin|progesterone|sexHormoneBindingGlobulin|freeTestosterone|other",
              "name": "",
              "value": 0,
              "unit": "",
              "referenceRange": "",
              "method": "",
              "sourceLine": "",
              "note": ""
            }
          ]
        }

        OCR text:
        \(text)
        """
    }

    private static func decodeReport(
        from jsonText: String,
        sourceKind: LabReportSourceKind,
        sourceText: String,
        fallback: LabReport
    ) -> LabReport? {
        guard let data = extractJSONObject(from: jsonText).data(using: .utf8),
              let payload = try? JSONDecoder().decode(AIReportPayload.self, from: data) else {
            return nil
        }

        let analytes = payload.analytes.compactMap { item -> LabAnalyteResult? in
            guard let kind = HormoneLabResultParser.kind(fromAIValue: item.kind ?? item.name),
                  item.value != nil || !(item.referenceRange ?? "").trimmed.isEmpty else {
                return nil
            }
            let unit = item.unit ?? ""
            let concentrationUnit = HormoneLabResultParser.concentrationUnit(from: unit, kind: kind)

            return LabAnalyteResult(
                kind: kind,
                name: (item.name ?? "").trimmed.isEmpty ? kind.defaultName : item.name?.trimmed,
                value: item.value,
                unitSymbol: concentrationUnit?.symbol ?? unit.trimmed,
                concentrationUnit: concentrationUnit,
                referenceRange: item.referenceRange?.nilIfBlank,
                method: item.method?.nilIfBlank,
                sourceLine: item.sourceLine?.nilIfBlank,
                note: item.note?.nilIfBlank
            )
        }

        guard !analytes.isEmpty else { return nil }

        return LabReport(
            collectedAt: payload.collectedAt.flatMap(HormoneLabResultParser.parseDate) ?? fallback.collectedAt,
            reportedAt: payload.reportedAt.flatMap(HormoneLabResultParser.parseDate) ?? fallback.reportedAt,
            institution: payload.institution?.trimmed ?? fallback.institution,
            location: payload.location?.trimmed ?? fallback.location,
            specimen: payload.specimen?.trimmed ?? fallback.specimen,
            method: payload.method?.trimmed ?? fallback.method,
            sourceKind: sourceKind,
            sourceText: sourceText,
            analytes: HormoneLabResultParser.uniqued(analytes),
            note: fallback.note
        )
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return text
        }
        return String(text[start...end])
    }

    private struct AIReportPayload: Decodable {
        var collectedAt: String?
        var reportedAt: String?
        var institution: String?
        var location: String?
        var specimen: String?
        var method: String?
        var analytes: [AIAnalytePayload]
    }

    private struct AIAnalytePayload: Decodable {
        var kind: String?
        var name: String?
        var value: Double?
        var unit: String?
        var referenceRange: String?
        var method: String?
        var sourceLine: String?
        var note: String?
    }
}
#endif

private enum HormoneLabResultParser {
    static func parseReport(
        _ text: String,
        sourceKind: LabReportSourceKind,
        defaultHormone: SimulatedHormone
    ) -> LabReport {
        let normalizedText = normalize(text)
        let lines = normalizedText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        let collectedAt = extractDate(
            from: lines,
            labels: ["标本采集时间", "采集时间", "采样时间", "抽血时间", "collection time", "sample collected", "collected"]
        ) ?? extractDate(from: normalizedText) ?? Date()
        let reportedAt = extractDate(
            from: lines,
            labels: ["报告时间", "审核时间", "检验时间", "reported", "report date", "result date"]
        )

        let parsedAnalytes = lines.compactMap(parseAnalyteLine)
        let analytes = parsedAnalytes.isEmpty
            ? parseUntitledResultLines(lines, collectedAt: collectedAt, defaultHormone: defaultHormone)
            : uniqued(parsedAnalytes)

        return LabReport(
            collectedAt: collectedAt,
            reportedAt: reportedAt,
            institution: extractField(from: lines, labels: ["检验机构", "检测机构", "医院", "实验室", "laboratory", "institution", "lab"]),
            location: extractField(from: lines, labels: ["地点", "地址", "location", "address"]),
            specimen: extractField(from: lines, labels: ["标本种类", "样本类型", "标本", "specimen", "sample type"]),
            method: extractField(from: lines, labels: ["检测方法", "检验方法", "方法", "method", "assay"]),
            sourceKind: sourceKind,
            sourceText: text,
            analytes: analytes,
            note: ""
        )
    }

    static func parseDate(_ text: String) -> Date? {
        extractDate(from: normalize(text))
    }

    static func kind(fromAIValue raw: String?) -> LabAnalyteKind? {
        guard let raw, !raw.trimmed.isEmpty else { return nil }
        let lower = raw.lowercased()
        if let exact = LabAnalyteKind(rawValue: lower) {
            return exact
        }
        return detectAnalyteKind(in: raw)
    }

    static func concentrationUnit(from raw: String, kind: LabAnalyteKind) -> ConcentrationUnit? {
        guard let hormone = kind.simulatedHormone else { return nil }
        let token = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "µ", with: "u")

        let unit: ConcentrationUnit?
        switch token {
        case "pg/ml": unit = .pgPerML
        case "pmol/l": unit = .pmolPerL
        case "ng/dl": unit = .ngPerDL
        case "ng/ml": unit = .ngPerML
        case "nmol/l": unit = .nmolPerL
        default: unit = nil
        }

        guard let unit, unit.isSupported(for: hormone) else { return nil }
        return unit
    }

    static func uniqued(_ analytes: [LabAnalyteResult]) -> [LabAnalyteResult] {
        var seen = Set<String>()
        return analytes.filter { analyte in
            let key = [
                analyte.kind.rawValue,
                analyte.name.lowercased(),
                analyte.value.map { String(format: "%.4f", $0) } ?? "",
                analyte.concentrationUnit?.rawValue ?? analyte.unitSymbol.lowercased(),
                analyte.sourceLine ?? ""
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "～", with: "~")
            .replacingOccurrences(of: "：", with: ":")
    }

    private static func parseAnalyteLine(_ line: String) -> LabAnalyteResult? {
        guard let kind = detectAnalyteKind(in: line),
              let value = extractMeasuredValue(from: line) else {
            return nil
        }

        let unitSymbol = extractUnitSymbol(from: line)
        let concentrationUnit = concentrationUnit(from: unitSymbol, kind: kind)
        let resolvedUnitSymbol = concentrationUnit?.symbol ?? unitSymbol

        if kind.simulatedHormone != nil, concentrationUnit == nil {
            return nil
        }

        return LabAnalyteResult(
            kind: kind,
            name: detectedName(for: kind, in: line),
            value: value,
            unitSymbol: resolvedUnitSymbol,
            concentrationUnit: concentrationUnit,
            referenceRange: extractReferenceRange(from: line),
            method: extractMethod(from: line),
            sourceLine: line
        )
    }

    private static func parseUntitledResultLines(
        _ lines: [String],
        collectedAt: Date,
        defaultHormone: SimulatedHormone
    ) -> [LabAnalyteResult] {
        let hasExplicitHormone = lines.contains { detectAnalyteKind(in: $0) != nil }
        guard !hasExplicitHormone else { return [] }

        let kind: LabAnalyteKind = defaultHormone == .estradiol ? .estradiol : .testosterone
        let analytes = lines.compactMap { line -> LabAnalyteResult? in
            guard let value = extractMeasuredValue(from: line) else { return nil }
            let unitSymbol = extractUnitSymbol(from: line)
            guard let concentrationUnit = concentrationUnit(from: unitSymbol, kind: kind) else {
                return nil
            }

            return LabAnalyteResult(
                kind: kind,
                name: kind.defaultName,
                value: value,
                unitSymbol: concentrationUnit.symbol,
                concentrationUnit: concentrationUnit,
                referenceRange: extractReferenceRange(from: line),
                sourceLine: line
            )
        }
        return uniqued(analytes)
    }

    private static func detectAnalyteKind(in line: String) -> LabAnalyteKind? {
        let patterns: [(LabAnalyteKind, String)] = [
            (.freeTestosterone, #"(?i)(游离睾酮|free\s+testosterone|\bfree\s+t\b)"#),
            (.sexHormoneBindingGlobulin, #"(?i)(性激素结合球蛋白|\bshbg\b)"#),
            (.estradiol, #"(?i)(雌二醇|\boestradiol\b|\bestradiol\b|\be2\b)"#),
            (.testosterone, #"(?i)(总睾酮|睾酮|睪酮|\btotal\s+t\b|\btestosterone\b|^\s*t\b|\bt\s*:)"#),
            (.luteinizingHormone, #"(?i)(促黄体生成素|黄体生成素|\blh\b)"#),
            (.follicleStimulatingHormone, #"(?i)(促卵泡生成素|卵泡刺激素|\bfsh\b)"#),
            (.prolactin, #"(?i)(泌乳素|\bprolactin\b|\bprl\b)"#),
            (.progesterone, #"(?i)(孕酮|\bprogesterone\b|^\s*p\b|\bp\s*:)"#)
        ]

        for (kind, pattern) in patterns where firstMatch(pattern: pattern, in: line) != nil {
            return kind
        }
        return nil
    }

    private static func detectedName(for kind: LabAnalyteKind, in line: String) -> String {
        let cleanLine = line.trimmed
        if cleanLine.contains("雌二醇") { return "Estradiol" }
        if cleanLine.contains("睾酮") || cleanLine.contains("睪酮") { return kind.defaultName }
        return kind.defaultName
    }

    private static func extractMeasuredValue(from line: String) -> Double? {
        let referenceRanges = referenceRangeMatches(in: line).map(\.range)
        let numberPattern = #"(?<![\d.])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: fullRange)

        for match in matches where !referenceRanges.contains(where: { rangesOverlap($0, match.range) }) {
            guard let valueText = stringCapture(1, in: line, match: match)?
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "≤", with: "")
                .replacingOccurrences(of: "≥", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ",", with: "."),
                let value = Double(valueText),
                value > 0 else {
                continue
            }
            return value
        }

        return nil
    }

    private static func extractReferenceRange(from line: String) -> String? {
        guard let match = referenceRangeMatches(in: line).first,
              let range = Range(match.range, in: line) else {
            return nil
        }
        return String(line[range]).trimmed
    }

    private static func referenceRangeMatches(in line: String) -> [NSTextCheckingResult] {
        let pattern = #"([<>≤≥]?\s*\d+(?:[\.,]\d+)?)\s*(?:-|~|至|到)\s*([<>≤≥]?\s*\d+(?:[\.,]\d+)?)\s*([a-zA-Zμµ/%]+(?:\s*/\s*[a-zA-Zμµ]+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
    }

    private static func extractUnitSymbol(from line: String) -> String {
        let pattern = #"(?i)(pg\s*/?\s*m[lL]|pmol\s*/?\s*[lL]|ng\s*/?\s*d[lL]|ng\s*/?\s*m[lL]|nmol\s*/?\s*[lL]|mIU\s*/?\s*m[lL]|uIU\s*/?\s*m[lL]|[µμ]IU\s*/?\s*m[lL]|IU\s*/?\s*[lL]|mIU\s*/?\s*[lL])"#
        guard let match = firstMatch(pattern: pattern, in: line),
              let unit = stringCapture(1, in: line, match: match) else {
            return ""
        }

        let compact = unit
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "／", with: "/")
        switch compact.lowercased() {
        case "pg/ml": return "pg/mL"
        case "pmol/l": return "pmol/L"
        case "ng/dl": return "ng/dL"
        case "ng/ml": return "ng/mL"
        case "nmol/l": return "nmol/L"
        case "miu/ml": return "mIU/mL"
        case "uiu/ml": return "uIU/mL"
        case "iu/l": return "IU/L"
        case "miu/l": return "mIU/L"
        default: return compact
        }
    }

    private static func extractMethod(from line: String) -> String? {
        let lower = line.lowercased()
        let tokens = ["lc-ms/ms", "eclia", "clia", "cmia", "elisa", "化学发光", "免疫", "质谱"]
        return tokens.first { lower.contains($0.lowercased()) }
    }

    private static func extractField(from lines: [String], labels: [String]) -> String {
        for line in lines {
            let lower = line.lowercased()
            guard let label = labels.first(where: { lower.contains($0.lowercased()) }) else { continue }
            if let colon = line.firstIndex(of: ":") {
                let value = String(line[line.index(after: colon)...]).trimmed
                if !value.isEmpty { return value }
            }
            let value = line.replacingOccurrences(of: label, with: "", options: [.caseInsensitive]).trimmed
            if !value.isEmpty, value != line {
                return value
            }
        }
        return ""
    }

    private static func extractDate(from lines: [String], labels: [String]) -> Date? {
        for line in lines {
            let lower = line.lowercased()
            guard labels.contains(where: { lower.contains($0.lowercased()) }) else { continue }
            if let date = extractDate(from: line) {
                return date
            }
        }
        return nil
    }

    private static func extractDate(from text: String) -> Date? {
        let normalized = text
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let patterns = [
            #"(\d{4})\s*-\s*(\d{1,2})\s*-\s*(\d{1,2})(?:\s+(\d{1,2})\s*[:时]\s*(\d{1,2}))?"#,
            #"(\d{1,2})\s*-\s*(\d{1,2})\s*-\s*(\d{4})(?:\s+(\d{1,2})\s*[:时]\s*(\d{1,2}))?"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: normalized) else { continue }
            let first = intCapture(1, in: normalized, match: match)
            let second = intCapture(2, in: normalized, match: match)
            let third = intCapture(3, in: normalized, match: match)
            let hour = intCapture(4, in: normalized, match: match) ?? 12
            let minute = intCapture(5, in: normalized, match: match) ?? 0

            let year: Int?
            let month: Int?
            let day: Int?
            if pattern.hasPrefix(#"(\d{4})"#) {
                year = first
                month = second
                day = third
            } else {
                year = third
                month = first
                day = second
            }

            guard let year, let month, let day else { continue }
            var components = DateComponents()
            components.calendar = Calendar.current
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            if let date = components.date {
                return date
            }
        }

        return nil
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
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

private extension LabReportSourceKind {
    var localizedLabel: String {
        switch self {
        case .scanner: return "Scanned Report"
        case .imageUpload: return "Uploaded Report"
        case .pastedText: return "Pasted Report"
        case .manual: return "Manual Report"
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
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
