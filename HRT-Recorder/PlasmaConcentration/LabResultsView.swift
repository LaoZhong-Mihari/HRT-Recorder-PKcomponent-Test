//
//  LabResultsView.swift
//  HRT-Recorder
//

import CoreImage
import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private func labGreedyGenerationOptions(maximumResponseTokens: Int) -> GenerationOptions {
    #if FOUNDATION_MODELS_IOS27
    return GenerationOptions(
        samplingMode: .greedy,
        temperature: 0,
        maximumResponseTokens: maximumResponseTokens
    )
    #else
    return GenerationOptions(
        sampling: .greedy,
        temperature: 0,
        maximumResponseTokens: maximumResponseTokens
    )
    #endif
}
#endif
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

// iOS 27-only Foundation Models symbols are enabled only when compiling against
// the iOS 27 SDK. Runtime gates below keep iOS 16–26 and ineligible devices on
// the Vision OCR + deterministic review path.

struct LabResultsView: View {
    @ObservedObject var vm: DoseTimelineVM

    @State private var activeSheet: LabResultSheet?
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isRecognizing = false
    #if DEBUG && canImport(FoundationModels)
    @State private var isRunningAIDiagnostics = false
    @State private var aiDiagnosticReport: AIDiagnosticReport?
    #endif
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

                    #if DEBUG && canImport(FoundationModels)
                    Button {
                        runAIDiagnostics()
                    } label: {
                        Label {
                            Text(verbatim: "Apple AI Diagnostics")
                        } icon: {
                            Image(systemName: "waveform.path.ecg")
                        }
                    }
                    .disabled(isRunningAIDiagnostics)
                    #endif
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
            maxSelectionCount: 4,
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
        #if DEBUG && canImport(FoundationModels)
        .sheet(item: $aiDiagnosticReport) { report in
            NavigationStack {
                AIDiagnosticsReportView(report: report.text)
            }
        }
        #endif
        .overlay {
            #if DEBUG && canImport(FoundationModels)
            if isRecognizing || isRunningAIDiagnostics {
                ZStack {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()

                    ProgressView {
                        Text(verbatim: isRunningAIDiagnostics ? "Testing Apple Intelligence..." : "Reading lab report...")
                    }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            #else
            if isRecognizing {
                ZStack {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()

                    ProgressView("Reading lab report...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            #endif
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
                       let image = LabImageDownsampler.image(from: data) {
                        images.append(image)
                    }
                }

                guard !images.isEmpty else {
                    statusMessage = "No readable image was selected."
                    return
                }

                await presentReport(from: images, sourceKind: .imageUpload)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func recognizeImages(_ images: [UIImage], sourceKind: LabReportSourceKind) {
        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }

            await presentReport(from: images, sourceKind: sourceKind)
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
            statusMessage = "No hormone result was found. Apple AI did not return a structured report, and OCR fallback did not find a supported table row."
            return
        }

        activeSheet = .review(LabReportDraft(report: outcome.report, extractionStatus: outcome.statusMessage))
    }

    @MainActor
    private func presentReport(from images: [UIImage], sourceKind: LabReportSourceKind) async {
        let outcome = await LabReportExtractionPipeline.extract(
            from: images,
            sourceKind: sourceKind,
            defaultHormone: vm.selectedHormone
        )

        guard !outcome.report.analytes.isEmpty else {
            statusMessage = "No hormone result was found. Apple AI did not return a structured report, and OCR fallback did not find a supported table row."
            return
        }

        activeSheet = .review(LabReportDraft(report: outcome.report, extractionStatus: outcome.statusMessage))
    }

    #if DEBUG && canImport(FoundationModels)
    private func runAIDiagnostics() {
        Task { @MainActor in
            guard #available(iOS 27.0, *) else {
                statusMessage = "Apple AI diagnostics require iOS 27 on this build."
                return
            }

            isRunningAIDiagnostics = true
            defer { isRunningAIDiagnostics = false }
            aiDiagnosticReport = AIDiagnosticReport(text: await LabReportAIDiagnostics.run())
        }
    }
    #endif
}

#if DEBUG && canImport(FoundationModels)
private struct AIDiagnosticReport: Identifiable {
    let id = UUID()
    var text: String
}
#endif

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
        self.specimen = LabReportFieldSanitizer.reviewSpecimen(report.specimen)
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
            specimen: LabReportFieldSanitizer.reviewSpecimen(specimen),
            method: method.trimmed,
            sourceKind: sourceKind,
            sourceText: LabReportPrivacySanitizer.redactedSourceText(sourceText),
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
        self.name = kind == .other ? "" : kind.defaultName
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
        self.name = result.kind == .other ? result.name : result.kind.defaultName
        self.valueText = result.value.map { Self.formatValue($0) } ?? ""
        self.unitSymbol = result.unitSymbol
        self.concentrationUnit = result.concentrationUnit
        self.referenceRange = ""
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
            || !method.trimmed.isEmpty
            || !sourceLine.trimmed.isEmpty
            || !note.trimmed.isEmpty
        guard hasDetails else { return nil }

        let resolvedUnit = concentrationUnit
        let resolvedUnitSymbol = resolvedUnit?.symbol ?? unitSymbol.trimmed

        return LabAnalyteResult(
            id: id,
            kind: kind,
            name: kind == .other ? name.nilIfBlank : nil,
            value: value,
            unitSymbol: resolvedUnitSymbol,
            concentrationUnit: resolvedUnit,
            referenceRange: nil,
            method: method.nilIfBlank,
            sourceLine: sourceLine.nilIfBlank,
            note: note.nilIfBlank
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale.current, value)
    }
}

private enum LabReportFieldSanitizer {
    static func reviewSpecimen(_ rawValue: String) -> String {
        let value = rawValue.trimmed
        guard !value.isEmpty else { return "" }
        if plausibleSpecimenTokens.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
            return value
        }
        return ""
    }

    private static let plausibleSpecimenTokens = [
        "血清", "血浆", "血漿", "全血", "血液", "尿", "唾液", "拭子",
        "serum", "plasma", "whole blood", "blood", "urine", "saliva", "swab"
    ]
}

private enum LabReportPrivacySanitizer {
    static func redactedSourceText(_ sourceText: String) -> String {
        let sensitiveLabels = [
            "姓名", "性别", "年龄", "出生", "身份证", "电话", "地址", "病历号",
            "住院号", "门诊号", "样本编号", "条形码", "申请医生", "临床诊断",
            "patient", "name:", "sex:", "gender", "date of birth", "dob", "mrn",
            "medical record", "accession", "barcode", "phone", "address", "diagnosis",
            "provider", "doctor"
        ]
        return sourceText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                !sensitiveLabels.contains { line.localizedCaseInsensitiveContains($0) }
            }
            .joined(separator: "\n")
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

#if DEBUG && canImport(FoundationModels)
private struct AIDiagnosticsReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: String

    var body: some View {
        ScrollView {
            Text(report)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(Text(verbatim: "AI Diagnostics"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.done") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy") {
                    UIPasteboard.general.string = report
                }
            }
        }
    }
}
#endif

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
                optionalContent("Specimen", LabReportFieldSanitizer.reviewSpecimen(report.specimen))
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
                Text(analyte.displayName)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(valueText)
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
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
                if kind == .other {
                    if LabAnalyteKind.allCases.map(\.defaultName).contains(draft.name) {
                        draft.name = ""
                    }
                } else {
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

            if draft.kind == .other {
                TextField("Name", text: $draft.name)
            }

            HStack(spacing: 12) {
                TextField("Value", text: $draft.valueText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)

                unitControl
            }

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

private enum LabImageDownsampler {
    static func image(from data: Data, maximumPixelDimension: Int = 1_800) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

private enum LabNumericEvidence {
    static func containsMeasuredValue(_ value: Double, in sourceLine: String) -> Bool {
        guard value.isFinite else { return false }
        var resultRegion = sourceLine
        resultRegion = resultRegion.replacingOccurrences(
            of: #"[<>≤≥]?\s*\d+(?:[\.,]\d+)?\s*(?:-|~|至|到)\s*[<>≤≥]?\s*\d+(?:[\.,]\d+)?"#,
            with: " ",
            options: .regularExpression
        )
        resultRegion = resultRegion.replacingOccurrences(
            of: #"(?i)Tanner\s*\d+"#,
            with: " ",
            options: .regularExpression
        )
        resultRegion = resultRegion.replacingOccurrences(
            of: #"^\s*\d+\s+(?=[A-Za-z\p{Han}])"#,
            with: "",
            options: .regularExpression
        )

        guard let regex = try? NSRegularExpression(
            pattern: #"[<>≤≥]?\s*[-+]?\d+(?:[\.,]\d+)?(?:[eE][-+]?\d+)?"#
        ) else {
            return false
        }
        let range = NSRange(resultRegion.startIndex..<resultRegion.endIndex, in: resultRegion)
        return regex.matches(in: resultRegion, range: range).contains { match in
            guard let matchRange = Range(match.range, in: resultRegion) else { return false }
            let token = resultRegion[matchRange]
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: #"[<>≤≥\s]"#, with: "", options: .regularExpression)
            guard let visibleValue = Double(token) else { return false }
            return abs(visibleValue - value) <= max(1e-9, abs(value) * 1e-6)
        }
    }
}

private enum LabResultOCRService {
    private static let recognitionLanguages = [
        "zh-Hans", "zh-Hant",
        "en-US", "en-GB",
        "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR",
        "ja-JP", "ko-KR"
    ]
    private static let customWords = [
        "雌二醇", "睾酮", "泌乳素", "促卵泡刺激素", "促黄体生成素", "孕酮",
        "垂体泌乳素", "硫酸脱氢表雄酮", "采集时间", "接收时间", "报告时间", "打印时间",
        "Estradiol", "Oestradiol", "Testosterone", "Prolactin", "Progesterone",
        "Follicle Stimulating Hormone", "Luteinising Hormone", "Luteinizing Hormone",
        "SHBG", "Free Testosterone", "DHEA-S", "TSH", "HbA1c", "Ferritin",
        "Glucose", "Creatinine", "eGFR", "Cholesterol", "Triglycerides",
        "E2", "PRL", "FSH", "LH", "T", "P", "DHEA-S",
        "pg", "ng", "pmol", "nmol", "µmol", "μmol", "umol",
        "mmol", "mg", "g", "IU", "mIU", "uIU", "mEq", "mL", "ml", "L", "dL", "dl"
    ]

    static func recognizeText(in images: [UIImage]) async throws -> String {
        var pages: [String] = []
        pages.reserveCapacity(images.count)

        for image in images {
            pages.append(try await recognizeText(in: image))
        }

        return pages.joined(separator: "\n")
    }

    private static func recognizeText(in image: UIImage) async throws -> String {
        guard let preparedImage = preparedImageForOCR(image),
              let cgImage = preparedImage.cgImage else {
            throw OCRError.missingImageData
        }

        let orientation = CGImagePropertyOrientation(preparedImage.imageOrientation)
        var candidates: [String] = []

        if #available(iOS 26.0, *) {
            if let documentText = try? await recognizeDocumentText(in: cgImage, orientation: orientation),
               !documentText.isEmpty {
                candidates.append(documentText)
            }
        }

        let legacyText = try await recognizeLegacyText(in: cgImage, orientation: orientation)
        if !legacyText.isEmpty {
            candidates.append(legacyText)
        }

        return mergeOCRCandidates(candidates)
    }

    private static func preparedImageForOCR(_ image: UIImage) -> UIImage? {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return image.cgImage == nil ? nil : image
        }

        let shortestSide = min(pixelSize.width, pixelSize.height)
        let longestSide = max(pixelSize.width, pixelSize.height)
        let minShortSide: CGFloat = 1_300
        let maxLongSide: CGFloat = 2_600

        var scale: CGFloat = 1
        if shortestSide < minShortSide {
            scale = minShortSide / shortestSide
        }
        if longestSide * scale > maxLongSide {
            scale = maxLongSide / longestSide
        }

        let needsRedraw = image.imageOrientation != .up || abs(scale - 1) > 0.01
        guard needsRedraw else { return image }

        let targetSize = CGSize(
            width: max(1, pixelSize.width * scale),
            height: max(1, pixelSize.height * scale)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    @available(iOS 26.0, *)
    private static func recognizeDocumentText(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.recognitionLanguages = recognitionLanguages.map(Locale.Language.init(identifier:))
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.customWords = customWords
        request.textRecognitionOptions.maximumCandidateCount = 1

        let observations = try await request.perform(on: cgImage, orientation: orientation)
        return documentText(from: observations)
    }

    @available(iOS 26.0, *)
    private static func documentText(from observations: [DocumentObservation]) -> String {
        observations.map(documentText(from:)).joined(separator: "\n")
    }

    @available(iOS 26.0, *)
    private static func documentText(from observation: DocumentObservation) -> String {
        var blocks: [String] = []

        for table in observation.document.tables {
            for row in table.rows {
                let rowText = row.map { cell in
                    cell.content.text.transcript.trimmed
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\t")
                if !rowText.isEmpty {
                    blocks.append(rowText)
                }
            }
        }

        for paragraph in observation.document.paragraphs {
            let paragraphText = paragraph.transcript.trimmed
            if !paragraphText.isEmpty {
                blocks.append(paragraphText)
            }
        }

        let fullText = observation.document.text.transcript.trimmed
        if !fullText.isEmpty {
            blocks.append(fullText)
        }

        return blocks.joined(separator: "\n")
    }

    private static func recognizeLegacyText(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if #available(iOS 16.0, *) {
                        request.automaticallyDetectsLanguage = true
                    }
                    request.recognitionLanguages = supportedLegacyRecognitionLanguages(for: request)
                    request.customWords = customWords

                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: orientation,
                        options: [:]
                    )
                    try handler.perform([request])

                    let lines = Self.groupRecognizedRows(from: request.results ?? [])
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func supportedLegacyRecognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        guard let supported = try? request.supportedRecognitionLanguages() else {
            return recognitionLanguages
        }
        let filtered = recognitionLanguages.filter { supported.contains($0) }
        return filtered.isEmpty ? recognitionLanguages : filtered
    }

    private static func mergeOCRCandidates(_ candidates: [String]) -> String {
        var seen = Set<String>()
        var lines: [String] = []

        for candidate in candidates {
            for line in candidate.split(whereSeparator: \.isNewline).map({ String($0).trimmed }) where !line.isEmpty {
                let key = line
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\t", with: "")
                if seen.insert(key).inserted {
                    lines.append(line)
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func groupRecognizedRows(from observations: [VNRecognizedTextObservation]) -> [String] {
        struct OCRToken {
            let text: String
            let x: CGFloat
            let midY: CGFloat
            let height: CGFloat
        }

        let tokens = observations.compactMap { observation -> OCRToken? in
            guard let text = observation.topCandidates(1).first?.string.trimmed,
                  !text.isEmpty else {
                return nil
            }
            return OCRToken(
                text: text,
                x: observation.boundingBox.minX,
                midY: observation.boundingBox.midY,
                height: observation.boundingBox.height
            )
        }

        var rows: [[OCRToken]] = []
        for token in tokens.sorted(by: { $0.midY > $1.midY }) {
            let threshold = max(token.height * 0.55, 0.008)
            if let index = rows.firstIndex(where: { row in
                guard let baseline = row.first?.midY else { return false }
                return abs(baseline - token.midY) <= threshold
            }) {
                rows[index].append(token)
            } else {
                rows.append([token])
            }
        }

        return rows
            .map { row in
                row.sorted { $0.x < $1.x }
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmed
            }
            .filter { !$0.isEmpty }
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

struct LabReportExtractionOutcome {
    var report: LabReport
    var statusMessage: String?
}

enum LabReportExtractionPipeline {
    static func extract(
        from images: [UIImage],
        sourceKind: LabReportSourceKind,
        defaultHormone: SimulatedHormone
    ) async -> LabReportExtractionOutcome {
        var fallbackSummary = "Apple Intelligence did not return a verified structured result."
        let ocrText = (try? await LabResultOCRService.recognizeText(in: images)) ?? ""

        // Keep the parser as a deterministic fallback/grounding source. On
        // eligible iOS 27 devices the universal model receives the raw OCR so
        // it can understand the report as a whole instead of consuming
        // dictionary-injected label hints.
        let ocrReport = ocrText.isEmpty
            ? LabReport(collectedAt: Date(), sourceKind: sourceKind, sourceText: "", analytes: [])
            : HormoneLabResultParser.parseReport(
                ocrText,
                sourceKind: sourceKind,
                defaultHormone: defaultHormone
            )

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *), LabReportAIExtractor.isAvailableForCurrentLocale {
            if let aiOutcome = await LabReportAIExtractor.extract(
                from: images,
                sourceKind: sourceKind,
                ocrText: ocrText,
                fallback: ocrReport
            ) {
                return aiOutcome
            }
            LabReportAIExtractor.logImageDiagnosticSummary()
            fallbackSummary = LabReportAIExtractor.imageUserFacingFallbackSummary()
        }
        #endif

        if !ocrText.isEmpty {
            let status = ocrReport.analytes.isEmpty
                ? "\(fallbackSummary) No supported hormone rows were found in OCR."
                : "\(fallbackSummary) Values were filled from OCR table parsing."
            return LabReportExtractionOutcome(report: ocrReport, statusMessage: status)
        }

        let emptyReport = LabReport(
            collectedAt: Date(),
            sourceKind: sourceKind,
            sourceText: "",
            analytes: []
        )
        return LabReportExtractionOutcome(
            report: emptyReport,
            statusMessage: "\(fallbackSummary) OCR also failed."
        )
    }

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
        if #available(iOS 27.0, *), LabReportAIExtractor.isAvailableForCurrentLocale {
            if let aiOutcome = await LabReportAIExtractor.extract(
                from: text,
                sourceKind: sourceKind,
                fallback: ruleReport
            ) {
                return aiOutcome
            }

            let fallbackStatus = ruleReport.analytes.isEmpty
                ? LabReportAIExtractor.textUserFacingFallbackSummary()
                : "\(LabReportAIExtractor.textUserFacingFallbackSummary()) Values were filled from OCR table parsing."
            LabReportAIExtractor.logTextDiagnosticSummary()
            return LabReportExtractionOutcome(report: ruleReport, statusMessage: fallbackStatus)
        }
        #endif

        return LabReportExtractionOutcome(
            report: ruleReport,
            statusMessage: "Apple Intelligence semantic extraction requires a supported iOS 27 device and locale; OCR table parsing was used."
        )
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
private func appHasPrivateCloudComputeEntitlement() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) else {
        return false
    }
    return text.contains("<key>com.apple.developer.private-cloud-compute</key>")
        && text.contains("<true/>")
    #endif
}

@available(iOS 27.0, *)
fileprivate enum LabReportAIExtractor {
    private static let activeAttemptKey = "labResults.activeFoundationModelAttempt"
    private static let activeAttemptStartedAtKey = "labResults.activeFoundationModelAttemptStartedAt"
    private static let crashDisabledUntilPrefix = "labResults.foundationModelAttemptDisabledUntil."
    private static let lastAttemptErrorPrefix = "labResults.foundationModelAttemptLastError."
    private static let attemptStaleInterval: TimeInterval = 15 * 60
    private static let crashDisableInterval: TimeInterval = 10 * 60

    static var isAvailableForCurrentLocale: Bool {
        isUsable(localContentTransformModel)
    }

    private enum ModelAttempt: String {
        case privateCloudVision
        case onDeviceVision
        case privateCloudUniversal
        case onDeviceUniversal
        case privateCloudMetadata
        case onDeviceMetadata
    }

    static func extract(
        from images: [UIImage],
        sourceKind: LabReportSourceKind,
        ocrText: String,
        fallback: LabReport
    ) async -> LabReportExtractionOutcome? {
        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *),
           let payload = await generatedPayloadUsingPrivateCloudVision(
                images: images,
                ocrText: ocrText,
                fallback: fallback
           ),
           let report = decodeReport(from: payload, sourceKind: sourceKind, sourceText: ocrText, fallback: fallback) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus(
                    "Private Cloud Compute read the report image; table values were verified against OCR anchors.",
                    fallback: fallback
                )
            )
        }

        if #available(iOS 27.0, *),
           let payload = await generatedPayloadUsingOnDeviceVision(
                images: images,
                ocrText: ocrText,
                fallback: fallback
           ),
           let report = decodeReport(from: payload, sourceKind: sourceKind, sourceText: ocrText, fallback: fallback) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus(
                    "On-device Apple Intelligence read the report image; table values were verified against OCR anchors.",
                    fallback: fallback
                )
            )
        }
        #endif

        guard !ocrText.trimmed.isEmpty else { return nil }
        guard let outcome = await extract(from: ocrText, sourceKind: sourceKind, fallback: fallback) else {
            return nil
        }

        return LabReportExtractionOutcome(
            report: outcome.report,
            statusMessage: anchoredStatus(
                "OCR read the image; Apple Intelligence organized verified OCR metadata.",
                fallback: fallback
            )
        )
    }

    static func extract(
        from text: String,
        sourceKind: LabReportSourceKind,
        fallback: LabReport
    ) async -> LabReportExtractionOutcome? {
        // On iOS 27 the universal schema is the primary semantic pass for
        // every non-empty report. The deterministic parser remains the anchor
        // and fallback, rather than deciding whether the LLM is allowed to
        // understand a report based on a hard-coded row-count threshold.
        if let outcome = await universalExtractionOutcome(
            from: text,
            sourceKind: sourceKind,
            fallback: fallback
        ) {
            return outcome
        }

        guard !fallback.analytes.isEmpty else { return nil }
        guard metadataNeedsModel(fallback) else {
            clearAttemptError(.privateCloudMetadata)
            clearAttemptError(.onDeviceMetadata)
            return nil
        }
        let prompt = metadataPrompt(for: metadataEvidenceText(sourceText: text, fallback: fallback))

        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *),
           let payload = await metadataPayloadUsingPrivateCloud(prompt: prompt),
           let report = decodeReport(from: payload, sourceKind: sourceKind, sourceText: text, fallback: fallback) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus("Private Cloud Compute filled verified report metadata.", fallback: fallback)
            )
        }
        #endif

        if let payload = await metadataPayloadUsingOnDeviceModel(prompt: prompt),
           let report = decodeReport(from: payload, sourceKind: sourceKind, sourceText: text, fallback: fallback) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus("On-device Apple Intelligence filled verified report metadata.", fallback: fallback)
            )
        }

        return nil
    }

    static func logImageDiagnosticSummary() {
        #if DEBUG
        NSLog("LAB_FOUNDATION_MODEL_SUMMARY %@", detailedImageDiagnosticSummary())
        #endif
    }

    static func logTextDiagnosticSummary() {
        #if DEBUG
        NSLog("LAB_FOUNDATION_MODEL_SUMMARY %@", detailedTextDiagnosticSummary())
        #endif
    }

    static func imageUserFacingFallbackSummary() -> String {
        userFacingFallbackSummary(kind: "image OCR evidence")
    }

    static func textUserFacingFallbackSummary() -> String {
        userFacingFallbackSummary(kind: "OCR text")
    }

    static func detailedTextDiagnosticSummary() -> String {
        detailedDiagnosticSummary(for: [
            .privateCloudUniversal,
            .onDeviceUniversal,
            .privateCloudMetadata,
            .onDeviceMetadata
        ])
    }

    static func detailedImageDiagnosticSummary() -> String {
        detailedDiagnosticSummary(for: [
            .privateCloudVision,
            .onDeviceVision,
            .privateCloudUniversal,
            .onDeviceUniversal,
            .privateCloudMetadata,
            .onDeviceMetadata
        ])
    }

    private static var localContentTransformModel: SystemLanguageModel {
        SystemLanguageModel(
            useCase: .contentTagging,
            guardrails: .permissiveContentTransformations
        )
    }

    private static func isUsable(_ model: SystemLanguageModel) -> Bool {
        model.isAvailable && model.supportsLocale(Locale.current)
    }

    private static var metadataGenerationOptions: GenerationOptions {
        labGreedyGenerationOptions(maximumResponseTokens: 520)
    }

    private static var universalGenerationOptions: GenerationOptions {
        labGreedyGenerationOptions(maximumResponseTokens: 1_200)
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func generatedPayloadUsingPrivateCloudVision(
        images: [UIImage],
        ocrText: String,
        fallback: LabReport
    ) async -> AIReportPayload? {
        let attempt = ModelAttempt.privateCloudVision
        guard shouldAttempt(attempt) else { return nil }
        guard appHasPrivateCloudComputeEntitlement() else {
            recordAttemptError("missing com.apple.developer.private-cloud-compute entitlement", attempt: attempt)
            return nil
        }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable, model.supportsLocale(Locale.current) else {
            recordAttemptError("availability=\(privateCloudAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }
        guard let prompt = visionPrompt(images: images, ocrText: ocrText, fallback: fallback) else {
            recordAttemptError("image prompt could not be built", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: visionInstructionsText())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedAIReportPayload.self,
                includeSchemaInPrompt: true,
                options: textGenerationOptions
            )
            return AIReportPayload(generated: response.content)
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }

    @available(iOS 27.0, *)
    private static func generatedPayloadUsingOnDeviceVision(
        images: [UIImage],
        ocrText: String,
        fallback: LabReport
    ) async -> AIReportPayload? {
        let attempt = ModelAttempt.onDeviceVision
        guard shouldAttempt(attempt) else { return nil }
        let model = localContentTransformModel
        guard isUsable(model) else {
            recordAttemptError("availability=\(systemAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }
        guard let prompt = visionPrompt(images: images, ocrText: ocrText, fallback: fallback) else {
            recordAttemptError("image prompt could not be built", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: visionInstructionsText())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedAIReportPayload.self,
                includeSchemaInPrompt: true,
                options: textGenerationOptions
            )
            return AIReportPayload(generated: response.content)
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }
    #endif

    private static func visionInstructionsText() -> String {
        """
        Extract visible lab report data from the attached image.
        Use OCR anchors when they are clearer than the image.
        Copy measured result values only, never reference range numbers.
        Classify known HRT-related hormone rows with their item code; preserve other clearly visible measurement rows as other with their visible label.
        Do not include patient identity, IDs, billing fields, or medical interpretation.
        Leave uncertain fields empty.
        """
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func visionPrompt(
        images: [UIImage],
        ocrText: String,
        fallback: LabReport
    ) -> FoundationModels.Prompt? {
        guard let image = images.first,
              let cgImage = cgImageForModel(from: image) else {
            return nil
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let attachment = FoundationModels.Attachment(cgImage, orientation: orientation)
            .label("hormone lab report image")
        let anchors = evidenceTextForAI(sourceText: ocrText, fallback: fallback)

        return FoundationModels.Prompt {
            """
            Extract a lab report from the image.
            Preserve only visible institution, location, specimen, method, collection/report times, known HRT-related hormone rows, and other clearly visible measurement rows.
            If OCR anchors list table rows, treat those rows as the value/unit anchors.
            For specimen, return a normalized plausible lab specimen/material term rather than raw OCR noise; leave it empty when uncertain.
            OCR anchors:
            \(anchors)
            """
            attachment
        }
    }
    #endif

    private static func cgImageForModel(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }
        guard let ciImage = image.ciImage else {
            return nil
        }
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func metadataPayloadUsingPrivateCloud(prompt: String) async -> AIMetadataPayload? {
        let attempt = ModelAttempt.privateCloudMetadata
        guard shouldAttempt(attempt) else { return nil }
        guard appHasPrivateCloudComputeEntitlement() else {
            recordAttemptError("missing com.apple.developer.private-cloud-compute entitlement", attempt: attempt)
            return nil
        }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable, model.supportsLocale(Locale.current) else {
            recordAttemptError("availability=\(privateCloudAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: metadataInstructionsText())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedAIMetadataPayload.self,
                includeSchemaInPrompt: true,
                options: metadataGenerationOptions
            )
            return AIMetadataPayload(generated: response.content)
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }
    #endif

    private static func metadataPayloadUsingOnDeviceModel(prompt: String) async -> AIMetadataPayload? {
        let attempt = ModelAttempt.onDeviceMetadata
        guard shouldAttempt(attempt) else { return nil }
        let model = localContentTransformModel
        guard isUsable(model) else {
            recordAttemptError("availability=\(systemAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: metadataInstructionsText())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedAIMetadataPayload.self,
                includeSchemaInPrompt: true,
                options: metadataGenerationOptions
            )
            return AIMetadataPayload(generated: response.content)
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }

    private static func metadataInstructionsText() -> String {
        """
        Extract document header metadata from OCR evidence.
        Fill collection time, report time, institution, location, specimen, and method when visible.
        For specimen, return a normalized plausible lab specimen/material term, not raw OCR characters. Use the document language when confident.
        If a specimen value looks like OCR noise or is not a plausible biological specimen/material, return an empty string.
        Normalize obvious OCR confusions only when the field context makes the intended medical/lab term clear.
        Ignore names, IDs, billing fields, reviewers, and diagnoses.
        Use empty strings for unknown fields.
        """
    }

    private static func universalExtractionOutcome(
        from text: String,
        sourceKind: LabReportSourceKind,
        fallback: LabReport
    ) async -> LabReportExtractionOutcome? {
        let evidenceLines = universalEvidenceLines(from: text)
        guard !evidenceLines.isEmpty else {
            clearAttemptError(.privateCloudUniversal)
            clearAttemptError(.onDeviceUniversal)
            return nil
        }
        let prompt = universalExtractionPrompt(for: evidenceLines, fallback: fallback)

        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *),
           let payload = await universalPayloadUsingPrivateCloud(prompt: prompt),
           let report = decodeReport(
                from: payload,
                evidenceLines: evidenceLines,
                sourceKind: sourceKind,
                sourceText: text,
                fallback: fallback
           ) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus("Private Cloud Compute extracted verified OCR measurement rows.", fallback: report)
            )
        }
        #endif

        if let payload = await universalPayloadUsingOnDeviceModel(prompt: prompt),
           let report = decodeReport(
                from: payload,
                evidenceLines: evidenceLines,
                sourceKind: sourceKind,
                sourceText: text,
                fallback: fallback
           ) {
            return LabReportExtractionOutcome(
                report: report,
                statusMessage: anchoredStatus("On-device Apple Intelligence extracted verified OCR measurement rows.", fallback: report)
            )
        }

        return nil
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func universalPayloadUsingPrivateCloud(prompt: String) async -> GeneratedUniversalReportPayload? {
        let attempt = ModelAttempt.privateCloudUniversal
        guard shouldAttempt(attempt) else { return nil }
        guard appHasPrivateCloudComputeEntitlement() else {
            recordAttemptError("missing com.apple.developer.private-cloud-compute entitlement", attempt: attempt)
            return nil
        }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable, model.supportsLocale(Locale.current) else {
            recordAttemptError("availability=\(privateCloudAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: universalExtractionInstructions())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedUniversalReportPayload.self,
                includeSchemaInPrompt: true,
                options: universalGenerationOptions
            )
            return response.content
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }
    #endif

    private static func universalPayloadUsingOnDeviceModel(prompt: String) async -> GeneratedUniversalReportPayload? {
        let attempt = ModelAttempt.onDeviceUniversal
        guard shouldAttempt(attempt) else { return nil }
        let model = localContentTransformModel
        guard isUsable(model) else {
            recordAttemptError("availability=\(systemAvailabilityDescription(model.availability))", attempt: attempt)
            return nil
        }

        markAttemptStarted(attempt)
        defer { markAttemptFinished(attempt) }

        do {
            let session = LanguageModelSession(model: model, instructions: universalExtractionInstructions())
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedUniversalReportPayload.self,
                includeSchemaInPrompt: true,
                options: universalGenerationOptions
            )
            return response.content
        } catch {
            logModelError(error, attempt: attempt)
            return nil
        }
    }

    private static var textGenerationOptions: GenerationOptions {
        labGreedyGenerationOptions(maximumResponseTokens: 1_800)
    }

    private static func evidenceTextForAI(sourceText: String, fallback: LabReport) -> String {
        var lines: [String] = [
            "OCR evidence prepared for structured lab-result extraction.",
            "Patient identity fields, visit IDs, sample IDs, and billing fields are intentionally omitted."
        ]

        if !fallback.institution.trimmed.isEmpty {
            lines.append("Institution: \(fallback.institution.trimmed)")
        }
        if !fallback.location.trimmed.isEmpty {
            lines.append("Location: \(fallback.location.trimmed)")
        }
        let specimen = LabReportFieldSanitizer.reviewSpecimen(fallback.specimen)
        if !specimen.isEmpty {
            lines.append("Specimen: \(specimen)")
        }
        if !fallback.method.trimmed.isEmpty {
            lines.append("Report method: \(fallback.method.trimmed)")
        }

        lines.append("Collected at: \(aiDateString(fallback.collectedAt))")
        if let reportedAt = fallback.reportedAt {
            lines.append("Reported at: \(aiDateString(reportedAt))")
        }

        for analyte in fallback.analytes {
            let name = analyte.displayName
            var parts = [
                "Analyte row",
                "kind=\(analyte.kind.rawValue)",
                "name=\(name)"
            ]
            if let value = analyte.value {
                parts.append("value=\(aiNumberString(value))")
            }
            if !analyte.unitSymbol.trimmed.isEmpty {
                parts.append("unit=\(analyte.unitSymbol.trimmed)")
            }
            if let method = analyte.method?.trimmed, !method.isEmpty {
                parts.append("method=\(method)")
            }
            if let sourceLine = analyte.sourceLine?.trimmed, !sourceLine.isEmpty {
                parts.append("sourceLine=\(sourceLine)")
            }
            if let note = analyte.note?.trimmed, !note.isEmpty {
                parts.append("note=\(note)")
            }
            lines.append(parts.joined(separator: " | "))
        }

        if fallback.analytes.isEmpty {
            let usefulLines = LabReportPrivacySanitizer.redactedSourceText(sourceText)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmed }
                .filter { !$0.isEmpty && $0.count <= 180 }
                .prefix(80)
            lines.append(contentsOf: usefulLines.map { "OCR line: \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private static func metadataEvidenceText(sourceText: String, fallback: LabReport) -> String {
        var lines: [String] = [
            "OCR lines prepared for document header metadata extraction.",
            "Personal identifiers, billing fields, reviewer names, and diagnoses are omitted."
        ]

        if !fallback.institution.trimmed.isEmpty {
            lines.append("Existing institution candidate: \(fallback.institution.trimmed)")
        }
        if !fallback.location.trimmed.isEmpty {
            lines.append("Existing location candidate: \(fallback.location.trimmed)")
        }
        let specimen = LabReportFieldSanitizer.reviewSpecimen(fallback.specimen)
        if !specimen.isEmpty {
            lines.append("Existing specimen candidate: \(specimen)")
        }
        if !fallback.method.trimmed.isEmpty {
            lines.append("Existing method candidate: \(fallback.method.trimmed)")
        }

        lines.append("Existing collectedAt candidate: \(aiDateString(fallback.collectedAt))")
        if let reportedAt = fallback.reportedAt {
            lines.append("Existing reportedAt candidate: \(aiDateString(reportedAt))")
        }

        let metadataLines = LabReportPrivacySanitizer.redactedSourceText(sourceText)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && $0.count <= 180 }
            .prefix(48)
        lines.append(contentsOf: metadataLines.map { "OCR metadata line: \($0)" })

        return lines.joined(separator: "\n")
    }

    private static func metadataPrompt(for evidence: String) -> String {
        """
        Extract document metadata fields from this OCR evidence.
        Use exact visible dates and names when possible.
        Method must be copied or normalized only from an explicit assay-method or analyzer/platform line, such as a method label or analyzer token.
        Do not use report titles, department names, specimen types, diagnoses, interpretation phrases, or generic analysis/result text as method.
        For specimen, prefer the narrowest plausible material visible in a specimen/sample field. If an OCR-corrupted specimen can be confidently normalized, use the normalized material; otherwise leave it empty.
        Do not broaden a corrupted specimen to generic blood unless blood is explicitly visible.
        Leave unknown fields empty.

        Evidence:
        \(evidence)
        """
    }

    private struct UniversalEvidenceLine {
        var id: Int
        var text: String
    }

    private static func universalEvidenceLines(from sourceText: String) -> [UniversalEvidenceLine] {
        let rawLines = LabReportPrivacySanitizer.redactedSourceText(sourceText)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && $0.count <= 180 }
            .prefix(80)

        return rawLines.enumerated().map { index, line in
            UniversalEvidenceLine(id: index, text: line)
        }
    }

    private static func universalExtractionPrompt(
        for evidenceLines: [UniversalEvidenceLine],
        fallback: LabReport
    ) -> String {
        let lineText = evidenceLines
            .map { "\($0.id): \($0.text)" }
            .joined(separator: "\n")
        let anchorText = fallback.analytes.isEmpty ? "No verified rows yet." : evidenceTextForAI(sourceText: "", fallback: fallback)

        return """
        Extract visible measurement rows from OCR lines.
        Use itemCode E2, T, PRL, FSH, LH, P, SHBG, freeT, DHEAS, or other.
        Use other for non-HRT lab measurements only when the source line visibly contains a label, measured value, and unit; put the visible label in label.
        Resolve OCR confusions, visually similar characters, split rows, and common abbreviations using row context.
        For each row, copy the measured result value from the result field, not from a reference interval.
        Return sourceLineID and exact sourceLine text for every row.
        Omit rows when the item label, value, or source line is uncertain after context review.
        Leave method empty unless the same row or a visible method/analyzer column explicitly contains a method or analyzer token.
        Existing verified anchors:
        \(anchorText)

        OCR lines:
        \(lineText)
        """
    }

    private static func universalExtractionInstructions() -> String {
        """
        Extract structured rows from OCR text. Return only rows that are directly visible.
        Use item codes for known HRT-related hormone rows and other for directly visible non-HRT lab measurements. Resolve OCR confusions from context, but do not infer missing rows.
        Copy measured values exactly from source lines. Do not use reference interval numbers as measured values.
        For other rows, include the visible test name/label; omit rows whose label is only a header, unit, patient field, or administrative field.
        Leave method empty unless a source line explicitly contains an assay method or analyzer/platform token.
        Ignore patient identity, order IDs, billing fields, reviewer names, and diagnoses.
        """
    }

    private static func decodeReport(
        from payload: AIReportPayload,
        sourceKind: LabReportSourceKind,
        sourceText: String,
        fallback: LabReport
    ) -> LabReport? {
        let decodedAnalytes = payload.analytes.compactMap { item -> LabAnalyteResult? in
            guard let kind = HormoneLabResultParser.kind(fromAIValue: item.kind ?? item.name),
                  item.value != nil else {
                return nil
            }
            let sourceLine = cleanAITextField(item.sourceLine)?.nilIfBlank
            let otherName = kind == .other
                ? otherAnalyteName(from: item.name, sourceLine: sourceLine)
                : nil
            guard kind != .other || otherName != nil else {
                return nil
            }
            let unit = HormoneLabResultParser.normalizedUnitSymbol(from: item.unit ?? "", kind: kind)
            let concentrationUnit = HormoneLabResultParser.concentrationUnit(from: unit, kind: kind)

            return LabAnalyteResult(
                kind: kind,
                name: otherName,
                value: item.value,
                unitSymbol: concentrationUnit?.symbol ?? unit.trimmed,
                concentrationUnit: concentrationUnit,
                referenceRange: nil,
                method: verifiedAIMethod(item.method, sourceText: sourceText, sourceLine: item.sourceLine),
                sourceLine: sourceLine,
                note: visibleFlagNote(cleanAITextField(item.note), sourceLine: cleanAITextField(item.sourceLine))
            )
        }
        let analytes = sourceText.trimmed.isEmpty
            ? decodedAnalytes
            : decodedAnalytes.filter { hasVisibleEvidence(for: $0, in: sourceText) }

        let mergedAnalytes = merge(analytes, withAnchorsFrom: fallback)
        guard !mergedAnalytes.isEmpty else { return nil }

        return LabReport(
            collectedAt: verifiedAIDate(payload.collectedAt, sourceText: sourceText) ?? fallback.collectedAt,
            reportedAt: verifiedAIDate(payload.reportedAt, sourceText: sourceText) ?? fallback.reportedAt,
            institution: verifiedAIText(payload.institution, sourceText: sourceText) ?? fallback.institution,
            location: verifiedAIText(payload.location, sourceText: sourceText) ?? fallback.location,
            specimen: verifiedAISpecimen(payload.specimen, sourceText: sourceText, fallback: fallback.specimen),
            method: verifiedAIMethod(payload.method, sourceText: sourceText) ?? fallback.method,
            sourceKind: sourceKind,
            sourceText: sourceText,
            analytes: HormoneLabResultParser.uniqued(mergedAnalytes),
            note: fallback.note
        )
    }

    private static func decodeReport(
        from payload: GeneratedUniversalReportPayload,
        evidenceLines: [UniversalEvidenceLine],
        sourceKind: LabReportSourceKind,
        sourceText: String,
        fallback: LabReport
    ) -> LabReport? {
        let linesByID = Dictionary(uniqueKeysWithValues: evidenceLines.map { ($0.id, $0.text) })
        let analytes = payload.rows.compactMap { row -> AIAnalytePayload? in
            let kind = HormoneLabResultParser.kind(fromAIValue: row.itemCode) ?? .other
            let sourceLine = universalSourceLine(for: row, linesByID: linesByID)
            guard !sourceLine.trimmed.isEmpty else { return nil }
            let otherName = kind == .other
                ? otherAnalyteName(from: row.label, sourceLine: sourceLine)
                : nil
            guard kind != .other || otherName != nil else {
                return nil
            }

            return AIAnalytePayload(
                kind: kind.rawValue,
                name: otherName,
                value: parseAIValueText(row.valueText),
                unit: row.unit.nilIfBlank,
                referenceRange: nil,
                method: verifiedAIMethod(row.method, sourceText: sourceText, sourceLine: sourceLine),
                sourceLine: cleanAITextField(sourceLine),
                note: cleanAITextField(row.note)?.nilIfBlank
            )
        }

        let reportPayload = AIReportPayload(
            collectedAt: payload.collectedAt.nilIfBlank,
            reportedAt: payload.reportedAt.nilIfBlank,
            institution: payload.institution.nilIfBlank,
            location: payload.location.nilIfBlank,
            specimen: payload.specimen.nilIfBlank,
            method: payload.method.nilIfBlank,
            analytes: analytes
        )
        return decodeReport(from: reportPayload, sourceKind: sourceKind, sourceText: sourceText, fallback: fallback)
    }

    private static func universalSourceLine(
        for row: GeneratedUniversalAnalyteRow,
        linesByID: [Int: String]
    ) -> String {
        if let id = row.sourceLineID,
           let sourceLine = linesByID[id]?.trimmed,
           !sourceLine.isEmpty {
            return sourceLine
        }
        let modelLine = row.sourceLine.trimmed
        if !modelLine.isEmpty,
           let sourceLine = linesByID.values.first(where: {
               compactEvidenceText($0) == compactEvidenceText(modelLine)
           }) {
            return sourceLine
        }
        return ""
    }

    private static func decodeReport(
        from metadata: AIMetadataPayload,
        sourceKind: LabReportSourceKind,
        sourceText: String,
        fallback: LabReport
    ) -> LabReport? {
        let report = LabReport(
            collectedAt: verifiedAIDate(metadata.collectedAt, sourceText: sourceText) ?? fallback.collectedAt,
            reportedAt: verifiedAIDate(metadata.reportedAt, sourceText: sourceText) ?? fallback.reportedAt,
            institution: verifiedAIText(metadata.institution, sourceText: sourceText) ?? fallback.institution,
            location: verifiedAIText(metadata.location, sourceText: sourceText) ?? fallback.location,
            specimen: verifiedAISpecimen(metadata.specimen, sourceText: sourceText, fallback: fallback.specimen),
            method: verifiedAIMethod(metadata.method, sourceText: sourceText) ?? fallback.method,
            sourceKind: sourceKind,
            sourceText: sourceText,
            analytes: fallback.analytes,
            note: fallback.note
        )
        guard metadataChanged(report, from: fallback) else {
            return nil
        }
        return report
    }

    private static func cleanAITextField(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.trimmed
    }

    private static func verifiedAIText(_ candidate: String?, sourceText: String) -> String? {
        guard let candidate = cleanAITextField(candidate)?.nilIfBlank else { return nil }
        let normalizedCandidate = normalizedGroundingText(candidate)
        guard normalizedCandidate.count >= 3,
              normalizedGroundingText(sourceText).contains(normalizedCandidate) else {
            return nil
        }
        return candidate
    }

    private static func verifiedAIDate(_ candidate: String?, sourceText: String) -> Date? {
        guard let candidate = cleanAITextField(candidate)?.nilIfBlank,
              let parsed = HormoneLabResultParser.parseDate(candidate) else {
            return nil
        }

        let normalizedCandidate = normalizedGroundingText(candidate)
        if normalizedCandidate.count >= 6,
           normalizedGroundingText(sourceText).contains(normalizedCandidate) {
            return parsed
        }

        let isVisibleDate = sourceText
            .split(whereSeparator: \.isNewline)
            .compactMap { HormoneLabResultParser.parseDate(String($0)) }
            .contains { abs($0.timeIntervalSince(parsed)) <= 1 }
        return isVisibleDate ? parsed : nil
    }

    private static func normalizedGroundingText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private static func otherAnalyteName(from label: String?, sourceLine: String?) -> String? {
        [label, sourceLine]
            .compactMap { cleanAITextField($0)?.nilIfBlank }
            .compactMap(sanitizedOtherAnalyteName)
            .first
    }

    private static func sanitizedOtherAnalyteName(_ raw: String) -> String? {
        var value = raw
        value = value.replacingOccurrences(
            of: #"[<>≤≥]?\s*\d+(?:[\.,]\d+)?\s*(?:-|~|至|到)\s*[<>≤≥]?\s*\d+(?:[\.,]\d+)?(?:\s*[A-Za-z0-9μµ/%]+(?:\s*/\s*[A-Za-z0-9μµ]+)?)?"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: measurementUnitPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"(?<![A-Za-z])\d+(?:[\.,]\d+)?"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^[\s#•·↑↓+\-¥￥\.\):]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed

        guard isPlausibleOtherAnalyteName(value) else { return nil }
        return value
    }

    private static func isPlausibleOtherAnalyteName(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 80 else { return false }
        let lower = value.lowercased()
        let noise = [
            "result", "results", "unit", "units", "reference", "range", "interval",
            "patient", "specimen", "sample", "collected", "reported", "date",
            "项目", "结果", "单位", "参考", "范围", "标本", "样本", "报告", "时间"
        ]
        guard !noise.contains(where: { lower == $0 || lower.contains($0) }) else {
            return false
        }
        return value.rangeOfCharacter(from: .letters) != nil
    }

    private static func verifiedAISpecimen(
        _ specimen: String?,
        sourceText: String,
        fallback: String
    ) -> String {
        let fallbackValue = LabReportFieldSanitizer.reviewSpecimen(fallback)
        guard let rawValue = cleanAITextField(specimen)?.nilIfBlank else {
            return fallbackValue
        }
        let value = LabReportFieldSanitizer.reviewSpecimen(rawValue)
        guard !value.isEmpty else {
            return fallbackValue
        }

        if sourceTextContains(value, in: sourceText) {
            return value
        }
        if isGenericBloodSpecimen(value) {
            return fallbackValue
        }
        if hasSpecimenEvidenceLabel(in: sourceText) {
            return value
        }
        return fallbackValue
    }

    private static func isGenericBloodSpecimen(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == "血液" || lower == "blood"
    }

    private static func hasSpecimenEvidenceLabel(in sourceText: String) -> Bool {
        sourceText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .contains { line in
                [
                    "标本", "樣本", "样本", "sample", "specimen", "material"
                ].contains { line.localizedCaseInsensitiveContains($0) }
            }
    }

    private static func verifiedAIMethod(
        _ method: String?,
        sourceText: String,
        sourceLine: String? = nil
    ) -> String? {
        guard let value = cleanAITextField(method)?.nilIfBlank,
              value.count <= 48,
              isPlausibleAssayMethod(value) else {
            return nil
        }

        let evidence = [sourceLine, sourceText]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "\n")
        guard sourceTextContains(value, in: evidence) else {
            return nil
        }
        return normalizedAssayMethod(value)
    }

    private static func isPlausibleAssayMethod(_ value: String) -> Bool {
        let lower = value.lowercased()
        let tokens = [
            "i2000", "architect", "cobas", "abbott", "roche", "beckman", "siemens",
            "lc-ms", "lc/ms", "lc ms", "ms/ms", "eclia", "clia", "cmia", "elisa",
            "免疫", "化学发光", "化學發光", "质谱", "質譜", "放射免疫", "电化学发光", "電化學發光"
        ]
        return tokens.contains { lower.contains($0.lowercased()) }
    }

    private static func normalizedAssayMethod(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("i2000") || lower.contains("12000sr") || lower.contains("l2000sr") {
            return "i2000SR"
        }
        return value
    }

    private static func metadataChanged(_ report: LabReport, from fallback: LabReport) -> Bool {
        if abs(report.collectedAt.timeIntervalSince(fallback.collectedAt)) > 1 {
            return true
        }
        switch (report.reportedAt, fallback.reportedAt) {
        case let (lhs?, rhs?):
            if abs(lhs.timeIntervalSince(rhs)) > 1 { return true }
        case (.some, .none):
            return true
        case (.none, .some), (.none, .none):
            break
        }

        return report.institution != fallback.institution
            || report.location != fallback.location
            || report.specimen != fallback.specimen
            || report.method != fallback.method
    }

    private static func metadataNeedsModel(_ fallback: LabReport) -> Bool {
        !fallback.analytes.isEmpty
            || fallback.institution.trimmed.isEmpty
            || fallback.reportedAt == nil
    }

    private static func merge(
        _ aiAnalytes: [LabAnalyteResult],
        withAnchorsFrom fallback: LabReport
    ) -> [LabAnalyteResult] {
        let anchors = fallback.analytes
        guard !anchors.isEmpty else {
            return HormoneLabResultParser.uniqued(aiAnalytes)
        }

        var usedAIIDs = Set<UUID>()
        let anchoredRows = anchors.map { anchor -> LabAnalyteResult in
            guard let ai = aiAnalytes.first(where: { candidate in
                candidate.kind == anchor.kind && !usedAIIDs.contains(candidate.id)
            }) else {
                return LabAnalyteResult(
                    id: anchor.id,
                    kind: anchor.kind,
                    name: anchor.kind == .other ? anchor.name.nilIfBlank : nil,
                    value: anchor.value,
                    unitSymbol: anchor.unitSymbol,
                    concentrationUnit: anchor.concentrationUnit,
                    referenceRange: nil,
                    method: anchor.method,
                    sourceLine: anchor.sourceLine,
                    note: visibleFlagNote(anchor.note, sourceLine: anchor.sourceLine)
                )
            }
            usedAIIDs.insert(ai.id)

            return LabAnalyteResult(
                id: anchor.id,
                kind: anchor.kind,
                name: anchor.kind == .other ? (anchor.name.nilIfBlank ?? ai.name.nilIfBlank) : nil,
                value: anchor.value,
                unitSymbol: anchor.unitSymbol.isEmpty ? ai.unitSymbol : anchor.unitSymbol,
                concentrationUnit: anchor.concentrationUnit ?? ai.concentrationUnit,
                referenceRange: nil,
                method: anchor.method ?? ai.method,
                sourceLine: anchor.sourceLine ?? ai.sourceLine,
                note: visibleFlagNote(anchor.note, sourceLine: anchor.sourceLine)
                    ?? visibleFlagNote(ai.note, sourceLine: ai.sourceLine)
            )
        }

        guard anchors.count < 7 else {
            return anchoredRows
        }

        let extraAIRows = aiAnalytes.filter { ai in
            guard !usedAIIDs.contains(ai.id),
                  ai.value != nil,
                  !anchors.contains(where: { $0.kind == ai.kind }),
                  let sourceLine = ai.sourceLine else {
                return false
            }
            return LabNumericEvidence.containsMeasuredValue(ai.value ?? -1, in: sourceLine)
        }

        return anchoredRows + extraAIRows
    }

    private static func visibleFlagNote(_ note: String?, sourceLine: String?) -> String? {
        guard let note = note?.trimmed, !note.isEmpty else { return nil }
        guard note.count <= 12 else { return nil }
        let evidence = [note, sourceLine ?? ""].joined(separator: " ")
        if evidence.contains("↑") { return "↑" }
        if evidence.contains("↓") { return "↓" }
        let lower = note.lowercased()
        if ["h", "high", "above"].contains(lower) { return "↑" }
        if ["l", "low", "below"].contains(lower) { return "↓" }
        return nil
    }

    private static func hasVisibleEvidence(for analyte: LabAnalyteResult, in sourceText: String) -> Bool {
        guard let sourceLine = analyte.sourceLine?.trimmed, !sourceLine.isEmpty else {
            return false
        }
        guard sourceTextContains(sourceLine, in: sourceText) else {
            return false
        }
        guard let value = analyte.value else {
            return !(analyte.referenceRange ?? "").trimmed.isEmpty
                && hasKindEvidence(analyte.kind, in: sourceLine)
        }

        guard LabNumericEvidence.containsMeasuredValue(value, in: sourceLine) else { return false }

        if hasKindEvidence(analyte.kind, in: sourceLine) {
            return true
        }

        return isLikelyMeasurementEvidenceLine(sourceLine)
    }

    private static func sourceTextContains(_ sourceLine: String, in sourceText: String) -> Bool {
        sourceText.localizedCaseInsensitiveContains(sourceLine)
            || compactEvidenceText(sourceText).localizedCaseInsensitiveContains(compactEvidenceText(sourceLine))
    }

    private static func isLikelyMeasurementEvidenceLine(_ line: String) -> Bool {
        containsReferenceRangeText(line)
            || line.range(of: measurementUnitPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsReferenceRangeText(_ line: String) -> Bool {
        line.range(
            of: #"[<>≤≥]?\s*\d+(?:[\.,]\d+)?\s*(?:-|~|至|到)\s*[<>≤≥]?\s*\d+(?:[\.,]\d+)?"#,
            options: .regularExpression
        ) != nil
    }

    private static var measurementUnitPattern: String {
        #"(?i)(?<![A-Za-z])(?:(?:p\s*g|n\s*g|u\s*g|µ\s*g|μ\s*g|m\s*g|g|p\s*mol|n\s*mol|u\s*mol|µ\s*mol|μ\s*mol|m\s*mol|mol|m\s*IU|u\s*IU|µ\s*IU|μ\s*IU|IU|IV|U)\s*/?\s*(?:m\s*[lL1]|d\s*[lL1]|[lL1])|%|mm\s*Hg|f\s*L|p\s*g|m\s*Eq\s*/?\s*[lL1]|m\s*[lL1]\s*/\s*min(?:\s*/\s*1\.?\s*73\s*m2)?|m\s*mol\s*/\s*mol|[x×]?\s*10\s*\^?\s*\d+\s*/\s*[lL1])(?![A-Za-z])"#
    }

    private static func hasKindEvidence(_ kind: LabAnalyteKind, in line: String) -> Bool {
        if kindNeedles(for: kind).contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let pattern: String?
        switch kind {
        case .estradiol:
            pattern = #"(?i)(?:\(|\b)E2(?:\)|\b)"#
        case .testosterone:
            pattern = #"(?i)(?:\(|\b)T(?:\)|\b)"#
        case .progesterone:
            pattern = #"(?i)(?:\(|\b)P(?:\)|\b)"#
        case .luteinizingHormone:
            pattern = #"(?i)(?:\(|\b)LH(?:\)|\b)"#
        case .follicleStimulatingHormone:
            pattern = #"(?i)(?:\(|\b)FSH(?:\)|\b)"#
        case .prolactin:
            pattern = #"(?i)(?:\(|\b)PRL(?:\)|\b)"#
        case .dehydroepiandrosteroneSulfate:
            pattern = #"(?i)(?:\(|\b)DHEA\s*-?\s*S(?:\)|\b)"#
        case .sexHormoneBindingGlobulin:
            pattern = #"(?i)(?:\(|\b)SHBG(?:\)|\b)"#
        case .freeTestosterone, .other:
            pattern = nil
        }

        guard let pattern,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
    }

    private static func kindNeedles(for kind: LabAnalyteKind) -> [String] {
        switch kind {
        case .estradiol:
            return ["雌二醇", "estradiol", "oestradiol", "estrogen e2"]
        case .testosterone:
            return ["睾酮", "睪酮", "testosterone", "testo", "total t"]
        case .luteinizingHormone:
            return ["促黄体", "黄体生成素", "luteinizing", "luteinising"]
        case .follicleStimulatingHormone:
            return ["促卵泡", "卵泡刺激素", "follicle stimulating", "follicle-stimulating"]
        case .prolactin:
            return ["泌乳素", "prolactin"]
        case .progesterone:
            return ["孕酮", "progesterone"]
        case .sexHormoneBindingGlobulin:
            return ["性激素结合球蛋白", "sex hormone binding", "binding globulin"]
        case .freeTestosterone:
            return ["游离睾酮", "free testosterone", "free T", "free testo"]
        case .dehydroepiandrosteroneSulfate:
            return ["硫酸脱氢表雄酮", "脱氢表雄酮", "dhea-s", "dheas", "dehydroepiandrosterone"]
        case .other:
            return []
        }
    }

    private static func compactEvidenceText(_ text: String) -> String {
        text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    private static func aiDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func aiNumberString(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func parseAIValueText(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: "↑", with: "")
            .replacingOccurrences(of: "↓", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "≤", with: "")
            .replacingOccurrences(of: "≥", with: "")
            .trimmed
        if let value = Double(normalized) {
            return value
        }
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[\.,]\d+)?"#),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
              let range = Range(match.range, in: normalized) else {
            return nil
        }
        return Double(normalized[range].replacingOccurrences(of: ",", with: "."))
    }

    private static func anchoredStatus(_ status: String, fallback: LabReport) -> String {
        guard !fallback.analytes.isEmpty else { return status }
        return "\(status) Table values were cross-checked against OCR anchors."
    }

    private static func userFacingFallbackSummary(kind: String) -> String {
        let model = localContentTransformModel
        guard isUsable(model) else {
            return "Apple Intelligence is unavailable for this device or language; OCR will be used."
        }
        if shouldStopTextAttemptsAfterPolicyRejection() {
            return "Apple Intelligence is available, but iOS rejected the model request for this report; verified OCR table parsing was used."
        }
        return "Apple Intelligence did not add verified \(kind) metadata; verified OCR table parsing was used."
    }

    private static func shouldAttempt(_ attempt: ModelAttempt) -> Bool {
        let defaults = UserDefaults.standard
        if isAttemptCrashDisabled(attempt) {
            return false
        }

        guard defaults.string(forKey: activeAttemptKey) == attempt.rawValue else {
            return true
        }

        let startedAt = defaults.object(forKey: activeAttemptStartedAtKey) as? Date
        if let startedAt, Date().timeIntervalSince(startedAt) > attemptStaleInterval {
            defaults.removeObject(forKey: activeAttemptKey)
            defaults.removeObject(forKey: activeAttemptStartedAtKey)
            return true
        }

        markAttemptCrashDisabled(attempt)
        defaults.removeObject(forKey: activeAttemptKey)
        defaults.removeObject(forKey: activeAttemptStartedAtKey)
        defaults.synchronize()
        return false
    }

    private static func isAttemptCrashDisabled(_ attempt: ModelAttempt) -> Bool {
        let defaults = UserDefaults.standard
        let untilKey = crashDisabledUntilPrefix + attempt.rawValue

        if let disabledUntil = defaults.object(forKey: untilKey) as? Date {
            if disabledUntil > Date() { return true }
            defaults.removeObject(forKey: untilKey)
        }
        return false
    }

    private static func markAttemptCrashDisabled(_ attempt: ModelAttempt) {
        UserDefaults.standard.set(Date().addingTimeInterval(crashDisableInterval), forKey: crashDisabledUntilPrefix + attempt.rawValue)
    }

    private static func markAttemptStarted(_ attempt: ModelAttempt) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastAttemptErrorPrefix + attempt.rawValue)
        defaults.set(attempt.rawValue, forKey: activeAttemptKey)
        defaults.set(Date(), forKey: activeAttemptStartedAtKey)
        defaults.synchronize()
    }

    private static func markAttemptFinished(_ attempt: ModelAttempt) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: activeAttemptKey) == attempt.rawValue else { return }
        defaults.removeObject(forKey: activeAttemptKey)
        defaults.removeObject(forKey: activeAttemptStartedAtKey)
        defaults.synchronize()
    }

    private static func detailedDiagnosticSummary(for attempts: [ModelAttempt]) -> String {
        let model = SystemLanguageModel.default
        let transformModel = localContentTransformModel
        var parts = [
            "SystemLanguageModel availability=\(systemAvailabilityDescription(model.availability))",
            "ContentTransformModel availability=\(systemAvailabilityDescription(transformModel.availability))",
            "supportsCurrentLocale=\(model.supportsLocale(Locale.current))",
            "supportsEnUS=\(model.supportsLocale(Locale(identifier: "en_US")))",
            "supportsZhHans=\(model.supportsLocale(Locale(identifier: "zh_Hans")))"
        ]
        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *) {
            if appHasPrivateCloudComputeEntitlement() {
                let privateCloudModel = PrivateCloudComputeLanguageModel()
                parts.append("PrivateCloudCompute availability=\(privateCloudAvailabilityDescription(privateCloudModel.availability))")
                parts.append("PrivateCloudCompute supportsCurrentLocale=\(privateCloudModel.supportsLocale(Locale.current))")
                parts.append("PrivateCloudCompute supportsZhHans=\(privateCloudModel.supportsLocale(Locale(identifier: "zh_Hans")))")
            } else {
                parts.append("PrivateCloudCompute availability=unavailable.missingEntitlement")
            }
        } else {
            parts.append("PrivateCloudCompute availability=unavailable.requiresIOS27")
        }
        #else
        parts.append("PrivateCloudCompute availability=unavailable.notCompiledWithIOS27SDK")
        #endif
        parts.append(contentsOf: attempts.compactMap { attempt in
            guard let error = lastAttemptError(attempt), !error.isEmpty else { return nil }
            return "\(attempt.rawValue) error: \(error)"
        })
        return parts.joined(separator: " | ")
    }

    private static func shouldStopTextAttemptsAfterPolicyRejection() -> Bool {
        [
            lastAttemptError(.privateCloudVision),
            lastAttemptError(.onDeviceVision),
            lastAttemptError(.privateCloudUniversal),
            lastAttemptError(.onDeviceUniversal),
            lastAttemptError(.privateCloudMetadata),
            lastAttemptError(.onDeviceMetadata)
        ]
            .compactMap { $0 }
            .contains { error in
                error.contains("guardrailViolation")
                    || error.contains("refusal")
                    || error.contains("SensitiveContentAnalysisML")
                    || error.contains("CombinedTextSanitizerBackend")
                    || error.contains("GenerativeFunctionsFoundation")
            }
    }

    private static func lastAttemptError(_ attempt: ModelAttempt) -> String? {
        UserDefaults.standard.string(forKey: lastAttemptErrorPrefix + attempt.rawValue)
    }

    private static func logModelError(_ error: any Error, attempt: ModelAttempt) {
        recordAttemptError(describeModelError(error), attempt: attempt)
        #if DEBUG
        NSLog("LAB_FOUNDATION_MODEL_ATTEMPT_ERROR attempt=%@ error=%@", attempt.rawValue, String(describing: error))
        #endif
    }

    private static func recordAttemptError(_ message: String, attempt: ModelAttempt) {
        UserDefaults.standard.set(message, forKey: lastAttemptErrorPrefix + attempt.rawValue)
    }

    private static func clearAttemptError(_ attempt: ModelAttempt) {
        UserDefaults.standard.removeObject(forKey: lastAttemptErrorPrefix + attempt.rawValue)
    }

    private static func describeModelError(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)")
        }
        parts.append("raw=\(String(describing: error))")
        return parts.joined(separator: " | ")
    }

    private static func systemAvailabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable.deviceNotEligible"
            case .appleIntelligenceNotEnabled:
                return "unavailable.appleIntelligenceNotEnabled"
            case .modelNotReady:
                return "unavailable.modelNotReady"
            @unknown default:
                return "unavailable.unknown"
            }
        }
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func privateCloudAvailabilityDescription(_ availability: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable.deviceNotEligible"
            case .systemNotReady:
                return "unavailable.systemNotReady"
            @unknown default:
                return "unavailable.unknown"
            }
        }
    }
    #endif

    private struct AIMetadataPayload {
        var collectedAt: String?
        var reportedAt: String?
        var institution: String?
        var location: String?
        var specimen: String?
        var method: String?

        init(generated: GeneratedAIMetadataPayload) {
            self.collectedAt = generated.collectedAt.nilIfBlank
            self.reportedAt = generated.reportedAt.nilIfBlank
            self.institution = generated.institution.nilIfBlank
            self.location = generated.location.nilIfBlank
            self.specimen = generated.specimen.nilIfBlank
            self.method = generated.method.nilIfBlank
        }
    }

    @Generable(description: "Document header metadata.")
    struct GeneratedAIMetadataPayload {
        @Guide(description: "Collection or sample time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var collectedAt: String
        @Guide(description: "Report issue time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var reportedAt: String
        @Guide(description: "Institution or organization name. Empty when unavailable.")
        var institution: String
        @Guide(description: "Testing location or site. Empty when unavailable.")
        var location: String
        @Guide(description: "Narrow normalized lab specimen/material type from a specimen/sample field. Empty when unavailable, implausible, or only generic blood can be guessed.")
        var specimen: String
        @Guide(description: "Overall assay method, analyzer, or platform only when explicitly visible. Empty for report titles, departments, specimen types, diagnoses, or analysis/result phrases.")
        var method: String
    }

    @Generable(description: "Universal structured OCR measurement extraction.")
    struct GeneratedUniversalReportPayload {
        @Guide(description: "Collection or sample time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var collectedAt: String
        @Guide(description: "Report issue time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var reportedAt: String
        @Guide(description: "Institution or organization name. Empty when unavailable.")
        var institution: String
        @Guide(description: "Testing location or site. Empty when unavailable.")
        var location: String
        @Guide(description: "Narrow normalized lab specimen/material type from a specimen/sample field. Empty when unavailable, implausible, or only generic blood can be guessed.")
        var specimen: String
        @Guide(description: "Overall assay method, analyzer, or platform only when explicitly visible. Empty for report titles, departments, specimen types, diagnoses, or analysis/result phrases.")
        var method: String
        @Guide(description: "Visible measurement rows anchored to OCR lines, including known HRT-related rows and other explicit lab measurements.", .maximumCount(24))
        var rows: [GeneratedUniversalAnalyteRow]
    }

    @Generable(description: "One OCR measurement row anchored to source text.")
    struct GeneratedUniversalAnalyteRow {
        @Guide(
            description: "Measurement item code.",
            .anyOf([
                "E2",
                "T",
                "PRL",
                "FSH",
                "LH",
                "P",
                "SHBG",
                "freeT",
                "DHEAS",
                "other"
            ])
        )
        var itemCode: String
        @Guide(description: "Visible row label when itemCode is other; otherwise empty.")
        var label: String
        @Guide(description: "Measured result text copied from the result field. Empty when unavailable.")
        var valueText: String
        @Guide(description: "Unit text for the measured value. Empty when unavailable.")
        var unit: String
        @Guide(description: "Leave empty; sex-assigned reference intervals are not stored for HRT review.")
        var referenceRange: String
        @Guide(description: "OCR line number used as evidence when available.")
        var sourceLineID: Int?
        @Guide(description: "Exact OCR source line text used as evidence.")
        var sourceLine: String
        @Guide(description: "Row-level assay method, analyzer, or platform only when explicitly visible on the source row or method column. Empty otherwise.")
        var method: String
        @Guide(description: "Only include visible abnormal flag or uncertainty. Empty otherwise.")
        var note: String
    }

    private struct AIReportPayload: Decodable {
        var collectedAt: String?
        var reportedAt: String?
        var institution: String?
        var location: String?
        var specimen: String?
        var method: String?
        var analytes: [AIAnalytePayload]

        init(
            collectedAt: String?,
            reportedAt: String?,
            institution: String?,
            location: String?,
            specimen: String?,
            method: String?,
            analytes: [AIAnalytePayload]
        ) {
            self.collectedAt = collectedAt
            self.reportedAt = reportedAt
            self.institution = institution
            self.location = location
            self.specimen = specimen
            self.method = method
            self.analytes = analytes
        }

        init(generated: GeneratedAIReportPayload) {
            self.init(
                collectedAt: generated.collectedAt.nilIfBlank,
                reportedAt: generated.reportedAt.nilIfBlank,
                institution: generated.institution.nilIfBlank,
                location: generated.location.nilIfBlank,
                specimen: generated.specimen.nilIfBlank,
                method: generated.method.nilIfBlank,
                analytes: generated.analytes.map(AIAnalytePayload.init(generated:))
            )
        }
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

        enum CodingKeys: String, CodingKey {
            case kind
            case name
            case value
            case unit
            case referenceRange
            case method
            case sourceLine
            case note
        }

        init(
            kind: String?,
            name: String?,
            value: Double?,
            unit: String?,
            referenceRange: String?,
            method: String?,
            sourceLine: String?,
            note: String?
        ) {
            self.kind = kind
            self.name = name
            self.value = value
            self.unit = unit
            self.referenceRange = referenceRange
            self.method = method
            self.sourceLine = sourceLine
            self.note = note
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
            self.value = Self.decodeFlexibleDouble(from: container, forKey: .value)
            self.unit = try container.decodeIfPresent(String.self, forKey: .unit)
            self.referenceRange = try container.decodeIfPresent(String.self, forKey: .referenceRange)
            self.method = try container.decodeIfPresent(String.self, forKey: .method)
            self.sourceLine = try container.decodeIfPresent(String.self, forKey: .sourceLine)
            self.note = try container.decodeIfPresent(String.self, forKey: .note)
        }

        private static func decodeFlexibleDouble(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let text = try? container.decodeIfPresent(String.self, forKey: key) {
                let normalized = text
                    .trimmed
                    .replacingOccurrences(of: ",", with: ".")
                return Double(normalized)
            }
            return nil
        }

        init(generated: GeneratedAIAnalytePayload) {
            self.init(
                kind: generated.kind.nilIfBlank,
                name: generated.name.nilIfBlank,
                value: generated.value,
                unit: generated.unit.nilIfBlank,
                referenceRange: generated.referenceRange.nilIfBlank,
                method: generated.method.nilIfBlank,
                sourceLine: generated.sourceLine.nilIfBlank,
                note: generated.note.nilIfBlank
            )
        }
    }

    @Generable(description: "Structured lab report with collection metadata, known HRT-related hormone rows, and other visible measurement rows.")
    struct GeneratedAIReportPayload {
        @Guide(description: "Collection or sample time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var collectedAt: String
        @Guide(description: "Report issue time, preferably YYYY-MM-DD HH:mm:ss. Empty when unavailable.")
        var reportedAt: String
        @Guide(description: "Testing institution, hospital, or lab name. Empty when unavailable.")
        var institution: String
        @Guide(description: "Testing location or site. Empty when unavailable.")
        var location: String
        @Guide(description: "Narrow normalized lab specimen/material type from a specimen/sample field. Empty when unavailable, implausible, or only generic blood can be guessed.")
        var specimen: String
        @Guide(description: "Overall assay method, analyzer, or platform only when explicitly visible. Empty for report titles, departments, specimen types, diagnoses, or analysis/result phrases.")
        var method: String
        @Guide(description: "All visible known HRT-related hormone rows and other explicit lab measurement rows from the report table.", .maximumCount(24))
        var analytes: [GeneratedAIAnalytePayload]
    }

    @Generable(description: "One lab analyte row from a report table.")
    struct GeneratedAIAnalytePayload {
        @Guide(
            description: "Canonical kind for known HRT-related hormone rows, or other for another visible lab measurement.",
            .anyOf([
                "estradiol",
                "testosterone",
                "luteinizingHormone",
                "follicleStimulatingHormone",
                "prolactin",
                "progesterone",
                "sexHormoneBindingGlobulin",
                "freeTestosterone",
                "dehydroepiandrosteroneSulfate",
                "other"
            ])
        )
        var kind: String
        @Guide(description: "Visible test name only for kind other; leave empty for known hormone kinds.")
        var name: String
        @Guide(description: "Measured result value from the result column, not a reference range number.")
        var value: Double?
        @Guide(description: "Unit for the measured value, for example pmol/L, nmol/L, mIU/L, IU/L, or µmol/L.")
        var unit: String
        @Guide(description: "Leave empty; sex-assigned reference intervals are not stored for HRT review.")
        var referenceRange: String
        @Guide(description: "Row-level assay method, analyzer, or platform only when explicitly visible on the source row or method column. Empty otherwise.")
        var method: String
        @Guide(description: "Visible source row text from the table. Empty when unavailable.")
        var sourceLine: String
        @Guide(description: "Only include uncertainty or abnormal flag information. Empty otherwise.")
        var note: String
    }
}
#endif

enum HormoneLabResultParser {
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
        let displayLines = lines.map(stripInternalParserHints)

        let detectedDates = extractDates(from: normalizedText)
        let collectedAt = extractDate(
            from: lines,
            labels: [
                "标本采集时间", "采集时间", "采样时间", "抽血时间",
                "collection time", "collection date", "date collected", "sample collected", "sample date", "collected",
                "abnahme", "entnahme", "prélèvement", "prelevement", "fecha de toma", "fecha muestra", "data da coleta"
            ]
        ) ?? detectedDates.first ?? Date()
        let reportedAt = extractDate(
            from: lines,
            labels: [
                "报告时间", "审核时间", "检验时间",
                "reported", "date reported", "report date", "result date", "issued",
                "befunddatum", "bericht", "résultat", "resultat", "fecha informe", "fecha resultado", "data do resultado"
            ]
        ) ?? (detectedDates.count >= 3 ? detectedDates[2] : (detectedDates.count >= 2 ? detectedDates[1] : nil))

        let parsedAnalytes = lines.compactMap(parseAnalyteLine)
        let multilineAnalytes = parseMultilineAnalyteBlocks(lines)
        let panelAnalytes = parseHormonePanelTableRows(lines)
        let genericAnalytes = parseGenericMeasurementRows(lines)
        let fallbackAnalytes = parsedAnalytes.isEmpty && multilineAnalytes.isEmpty && panelAnalytes.isEmpty
            ? parseUntitledResultLines(lines, collectedAt: collectedAt, defaultHormone: defaultHormone)
            : []
        let analytes = uniqued(panelAnalytes + parsedAnalytes + multilineAnalytes + fallbackAnalytes + genericAnalytes)

        return LabReport(
            collectedAt: collectedAt,
            reportedAt: reportedAt,
            institution: extractInstitution(from: displayLines),
            location: extractField(from: displayLines, labels: ["地点", "地址", "location", "address"]),
            specimen: extractSpecimen(from: displayLines),
            method: extractReportMethod(from: lines, analytes: analytes),
            sourceKind: sourceKind,
            sourceText: stripInternalParserHints(text),
            analytes: analytes,
            note: ""
        )
    }

    static func parseDate(_ text: String) -> Date? {
        extractDate(from: normalize(text))
    }

    static func kind(fromAIValue raw: String?) -> LabAnalyteKind? {
        guard let raw, !raw.trimmed.isEmpty else { return nil }
        let value = raw.trimmed
        if let exact = LabAnalyteKind(rawValue: value) {
            return exact
        }
        let lower = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch lower {
        case "e2", "estradiol", "oestradiol":
            return .estradiol
        case "t", "testosterone", "totaltestosterone", "totaltesto":
            return .testosterone
        case "lh", "luteinizinghormone", "luteinisinghormone":
            return .luteinizingHormone
        case "fsh", "folliclestimulatinghormone":
            return .follicleStimulatingHormone
        case "prl", "prolactin":
            return .prolactin
        case "p", "progesterone":
            return .progesterone
        case "shbg", "sexhormonebindingglobulin":
            return .sexHormoneBindingGlobulin
        case "freet", "freetestosterone":
            return .freeTestosterone
        case "dheas", "dheasulfate", "dehydroepiandrosteronesulfate":
            return .dehydroepiandrosteroneSulfate
        case "other":
            return .other
        default:
            return detectAnalyteKind(in: value)
        }
    }

    static func concentrationUnit(from raw: String, kind: LabAnalyteKind) -> ConcentrationUnit? {
        guard let hormone = kind.simulatedHormone else { return nil }
        let token = normalizedUnitSymbol(from: raw, kind: kind)
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

    static func normalizedUnitSymbol(from raw: String, kind: LabAnalyteKind) -> String {
        resolvedUnitSymbol(normalizedUnitToken(raw), kind: kind)
    }

    static func uniqued(_ analytes: [LabAnalyteResult]) -> [LabAnalyteResult] {
        var selectedByKey: [String: (index: Int, score: Int, analyte: LabAnalyteResult)] = [:]
        var keyOrder: [String] = []

        for (index, analyte) in analytes.enumerated() {
            let key = uniquenessKey(for: analyte)
            let score = analyteEvidenceScore(analyte)

            if let current = selectedByKey[key] {
                if score > current.score {
                    selectedByKey[key] = (current.index, score, analyte)
                }
            } else {
                selectedByKey[key] = (index, score, analyte)
                keyOrder.append(key)
            }
        }

        return keyOrder
            .compactMap { selectedByKey[$0] }
            .sorted { $0.index < $1.index }
            .map(\.analyte)
    }

    private static func uniquenessKey(for analyte: LabAnalyteResult) -> String {
        if analyte.kind == .other {
            return [
                analyte.kind.rawValue,
                analyte.name.lowercased(),
                analyte.sourceLine ?? UUID().uuidString
            ].joined(separator: "|")
        }
        return analyte.kind.rawValue
    }

    private static func analyteEvidenceScore(_ analyte: LabAnalyteResult) -> Int {
        var score = 0
        if analyte.value != nil { score += 3 }
        if !analyte.unitSymbol.trimmed.isEmpty { score += 2 }
        if analyte.concentrationUnit != nil { score += 2 }
        if !(analyte.referenceRange ?? "").trimmed.isEmpty { score += 2 }
        if !(analyte.method ?? "").trimmed.isEmpty { score += 1 }

        if let sourceLine = analyte.sourceLine {
            if let detectedKind = detectAnalyteKind(in: sourceLine) {
                score += detectedKind == analyte.kind ? 6 : -8
            }
            if let value = analyte.value,
               LabNumericEvidence.containsMeasuredValue(value, in: sourceLine) {
                score += 2
            }
        }

        if analyte.kind.simulatedHormone != nil, analyte.concentrationUnit == nil {
            score -= 6
        }
        return score
    }

    private static func normalize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "～", with: "~")
            .replacingOccurrences(of: "：", with: ":")

        return normalizeOCRDecimalSpacing(normalized)
    }

    private static func stripInternalParserHints(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s*\[(?:label|analyte):[^\]]+\]"#,
                with: "",
                options: .regularExpression
            )
            .trimmed
    }

    private static func normalizeOCRDecimalSpacing(_ text: String) -> String {
        let pattern = #"(\d)\s*[\.,]\s+(\d{1,3})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1.$2")
    }

    private static func parseAnalyteLine(_ line: String) -> LabAnalyteResult? {
        guard !isLikelyUnrelatedMetadataLine(line) else { return nil }
        guard let kind = detectAnalyteKind(in: line),
              let value = extractMeasuredValue(from: line, kind: kind) else {
            return nil
        }

        let referenceRange = extractReferenceRange(from: line, kind: kind)
        let unitSymbol = resolvedUnitSymbol(
            extractUnitSymbol(from: line, fallbackReferenceRange: referenceRange),
            referenceRange: referenceRange,
            kind: kind
        )
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
            referenceRange: referenceRange,
            method: extractMethod(from: line),
            sourceLine: stripInternalParserHints(line)
        )
    }

    private static func parseMultilineAnalyteBlocks(_ lines: [String]) -> [LabAnalyteResult] {
        lines.indices.compactMap { index in
            guard !isLikelyUnrelatedMetadataLine(lines[index]) else { return nil }
            guard let kind = detectAnalyteKind(in: lines[index]) else { return nil }
            let blockLines = analyteBlockLines(startingAt: index, in: lines)
            guard blockLines.count > 1 else { return nil }

            let blockText = blockLines.joined(separator: " ")
            guard measuredValueCandidateCountBeforeFirstReference(in: blockText, kind: kind) <= 2 else {
                // A columnar OCR block can place several result values after
                // one label. Pairing the last value with that label is not
                // grounded; the table-row parser will resolve the individual
                // value/reference/unit row instead.
                return nil
            }
            guard let value = extractMeasuredValue(from: blockText, kind: kind) else {
                return nil
            }

            let referenceRange = extractReferenceRange(from: blockText, kind: kind)
            let unitSymbol = resolvedUnitSymbol(
                extractUnitSymbol(from: blockText, fallbackReferenceRange: referenceRange),
                referenceRange: referenceRange,
                kind: kind
            )
            let concentrationUnit = concentrationUnit(from: unitSymbol, kind: kind)
            if kind.simulatedHormone != nil, concentrationUnit == nil {
                return nil
            }

            return LabAnalyteResult(
                kind: kind,
                name: detectedName(for: kind, in: blockText),
                value: value,
                unitSymbol: concentrationUnit?.symbol ?? unitSymbol,
                concentrationUnit: concentrationUnit,
                referenceRange: referenceRange,
                method: extractMethod(from: blockText),
                sourceLine: stripInternalParserHints(blockText)
            )
        }
    }

    private static func measuredValueCandidateCountBeforeFirstReference(
        in text: String,
        kind: LabAnalyteKind
    ) -> Int {
        guard let referenceRange = referenceRangeMatches(in: text).first,
              let prefixRange = Range(
                NSRange(location: 0, length: referenceRange.range.location),
                in: text
              ) else {
            return 0
        }
        let prefix = String(text[prefixRange])
        let numberPattern = #"(?<![\d.A-Za-z])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else {
            return 0
        }
        let analyteRanges = analyteCodeMatches(in: prefix, kind: kind).map(\.range)
        let fullRange = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        return regex.matches(in: prefix, range: fullRange)
            .filter { match in
                !analyteRanges.contains { rangesOverlap($0, match.range) }
            }
            .count
    }

    private static func analyteBlockLines(startingAt index: Int, in lines: [String]) -> [String] {
        var block = [lines[index]]
        let maxEnd = min(lines.count, index + 8)
        guard index + 1 < maxEnd else { return block }

        for nextIndex in (index + 1)..<maxEnd {
            let line = lines[nextIndex]
            if detectAnalyteKind(in: line) != nil, blockContainsResultEvidence(block) {
                break
            }
            if isLikelyUnrelatedMetadataLine(line), blockContainsResultEvidence(block) {
                break
            }
            block.append(line)
            if blockContainsCompleteResultEvidence(block) {
                break
            }
        }
        return block
    }

    private static func blockContainsResultEvidence(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: " ")
        return text.rangeOfCharacter(from: .decimalDigits) != nil
            && firstUnitSymbol(in: text) != nil
    }

    private static func blockContainsCompleteResultEvidence(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: " ")
        return blockContainsResultEvidence(lines) && !referenceRangeMatches(in: text).isEmpty
    }

    private static func isLikelyUnrelatedMetadataLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let metadataSignals = [
            "collected", "collection", "reported", "result date", "provider", "doctor",
            "specimen", "sample", "accession", "patient", "dob", "mrn", "医院", "报告时间",
            "采集时间", "样本编号", "标本编号", "病历号", "病员号", "姓名",
            "临床诊断", "床号", "送检医生", "送检科室"
        ]
        return metadataSignals.contains { lower.contains($0) || line.contains($0) }
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
            guard let value = extractMeasuredValue(from: line, kind: kind) else { return nil }
            let referenceRange = extractReferenceRange(from: line, kind: kind)
            let unitSymbol = resolvedUnitSymbol(
                extractUnitSymbol(from: line, fallbackReferenceRange: referenceRange),
                referenceRange: referenceRange,
                kind: kind
            )
            guard let concentrationUnit = concentrationUnit(from: unitSymbol, kind: kind) else {
                return nil
            }

            return LabAnalyteResult(
                kind: kind,
                name: kind.defaultName,
                value: value,
                unitSymbol: concentrationUnit.symbol,
                concentrationUnit: concentrationUnit,
                referenceRange: referenceRange,
                sourceLine: stripInternalParserHints(line)
            )
        }
        return uniqued(analytes)
    }

    private static func parseGenericMeasurementRows(_ lines: [String]) -> [LabAnalyteResult] {
        uniqued(lines.compactMap(parseGenericMeasurementLine))
    }

    private static func parseGenericMeasurementLine(_ line: String) -> LabAnalyteResult? {
        let displayLine = stripInternalParserHints(line)
        guard !isLikelyUnrelatedMetadataLine(displayLine),
              detectAnalyteKind(in: line) == nil,
              let measurement = genericMeasurement(in: displayLine),
              let label = genericAnalyteLabel(in: displayLine, valueRange: measurement.valueRange) else {
            return nil
        }

        return LabAnalyteResult(
            kind: .other,
            name: label,
            value: measurement.value,
            unitSymbol: measurement.unitSymbol,
            concentrationUnit: nil,
            referenceRange: measurement.referenceRange,
            method: extractMethod(from: line),
            sourceLine: displayLine
        )
    }

    private struct GenericMeasurement {
        var value: Double
        var valueRange: NSRange
        var unitSymbol: String
        var referenceRange: String?
    }

    private static func genericMeasurement(in line: String) -> GenericMeasurement? {
        let pattern = #"(?<![\d.A-Za-z])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)\s*(?:[↑↓HhLl*•·\.\-–—:]|\([HhLl]\))*\s*"# + unitSymbolPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let referenceMatches = referenceRangeMatches(in: line)
        let referenceRanges = referenceMatches.map(\.range)

        for match in regex.matches(in: line, range: fullRange)
            where !referenceRanges.contains(where: { rangesOverlap($0, match.range(at: 1)) }) {
            guard let valueText = stringCapture(1, in: line, match: match),
                  let value = correctedMeasuredValue(from: valueText, referenceBounds: referenceBounds(from: line), kind: nil),
                  let unit = stringCapture(2, in: line, match: match).map(normalizedUnitToken),
                  !unit.isEmpty else {
                continue
            }

            return GenericMeasurement(
                value: value,
                valueRange: match.range(at: 1),
                unitSymbol: unit,
                referenceRange: referenceMatches.first.flatMap { match in
                    guard let range = Range(match.range, in: line) else { return nil }
                    return normalizedReferenceRange(String(line[range]).trimmed, kind: nil)
                }
            )
        }

        return nil
    }

    private static func genericAnalyteLabel(in line: String, valueRange: NSRange) -> String? {
        guard let prefixRange = Range(NSRange(location: 0, length: valueRange.location), in: line) else {
            return nil
        }
        var label = String(line[prefixRange])
        // Strip a real row index ("1 ", "1.", "1)") without eating a
        // numeric analyte name such as "25-OH Vitamin D".
        label = label.replacingOccurrences(
            of: #"^\s*\d+(?:[\.\)]\s*|\s+)"#,
            with: "",
            options: .regularExpression
        )
        label = label.replacingOccurrences(of: #"^[\s#•·↑↓+\-¥￥\.\):]+"#, with: "", options: .regularExpression)
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed

        guard isPlausibleGenericAnalyteLabel(label) else { return nil }
        return label
    }

    private static func isPlausibleGenericAnalyteLabel(_ label: String) -> Bool {
        guard label.count >= 2, label.count <= 80 else { return false }
        let lower = label.lowercased()
        let noise = [
            "test", "tests", "item", "items", "component", "result", "results",
            "unit", "units", "reference", "range", "interval", "flag",
            "patient", "specimen", "sample", "collected", "reported", "date",
            "项目", "结果", "单位", "参考", "范围", "标志", "标本", "样本", "报告", "时间"
        ]
        guard !noise.contains(where: { lower == $0 || lower.contains($0) }) else {
            return false
        }
        return label.rangeOfCharacter(from: .letters) != nil
    }

    private static func parseHormonePanelTableRows(_ lines: [String]) -> [LabAnalyteResult] {
        let candidates = lines.enumerated().compactMap { tableRowCandidate(from: $0, lines: lines) }
        let explicitRows = candidates.compactMap { row -> LabAnalyteResult? in
            guard let kind = row.explicitKind else { return nil }
            return analyte(from: row, kind: kind, lines: lines)
        }
        let inferredRows = inferFullPanelRows(from: candidates, lines: lines)
        return uniqued(inferredRows + explicitRows)
    }

    private static func inferFullPanelRows(from candidates: [TableRowCandidate], lines: [String]) -> [LabAnalyteResult] {
        guard candidates.count >= 6 else { return [] }

        let panelKinds: [LabAnalyteKind] = [
            .estradiol,
            .prolactin,
            .follicleStimulatingHormone,
            .luteinizingHormone,
            .testosterone,
            .progesterone,
            .dehydroepiandrosteroneSulfate
        ]

        var bestStart = 0
        var bestLength = 0
        var bestScore = 0

        for start in candidates.indices {
            let length = min(panelKinds.count, candidates.count - start)
            guard length >= 4 else { continue }

            let score = (0..<length).reduce(0) { total, offset in
                total + panelRowScore(candidates[start + offset], kind: panelKinds[offset])
            }

            if score > bestScore {
                bestStart = start
                bestLength = length
                bestScore = score
            }
        }

        guard bestLength >= 4, bestScore >= max(8, bestLength * 2 - 2) else {
            return []
        }

        return (0..<bestLength).compactMap { offset in
            let kind = panelKinds[offset]
            let row = candidates[bestStart + offset]
            return analyte(from: row, kind: kind, lines: lines)
        }
    }

    private static func analyte(
        from row: TableRowCandidate,
        kind: LabAnalyteKind,
        lines: [String]
    ) -> LabAnalyteResult? {
        let referenceRange = extractReferenceRange(from: row.line, kind: kind)
        let unitSymbol = resolvedUnitSymbol(
            row.unitSymbol.isEmpty ? extractUnitSymbol(from: row.line, fallbackReferenceRange: referenceRange) : row.unitSymbol,
            referenceRange: referenceRange,
            kind: kind
        )
        let concentrationUnit = concentrationUnit(from: unitSymbol, kind: kind)
        if kind.simulatedHormone != nil, concentrationUnit == nil {
            return nil
        }

        return LabAnalyteResult(
            kind: kind,
            name: detectedName(for: kind, in: row.evidenceText),
            value: row.value,
            unitSymbol: concentrationUnit?.symbol ?? unitSymbol,
            concentrationUnit: concentrationUnit,
            referenceRange: referenceRange,
            method: row.method ?? methodNearLine(row.lineIndex, in: lines),
            sourceLine: stripInternalParserHints(row.evidenceText)
        )
    }

    private struct TableRowCandidate {
        var lineIndex: Int
        var line: String
        var value: Double
        var unitSymbol: String
        var method: String?
        var explicitKind: LabAnalyteKind?
        var referenceBounds: (lower: Double, upper: Double)?
        var evidenceText: String
    }

    private static func tableRowCandidate(
        from item: EnumeratedSequence<[String]>.Element,
        lines: [String]
    ) -> TableRowCandidate? {
        let (index, line) = item
        guard let referenceMatch = referenceRangeMatches(in: line).first,
              let value = extractMeasuredValueBeforeReference(in: line, referenceRange: referenceMatch) else {
            return nil
        }
        let nearbyKind = detectedKindNearLine(index, line: line, in: lines)
        let evidenceText = nearbyKind.map { _ in evidenceTextNearLine(index, in: lines) } ?? line

        return TableRowCandidate(
            lineIndex: index,
            line: line,
            value: value,
            unitSymbol: extractUnitSymbol(from: line),
            method: extractMethod(from: line),
            explicitKind: nearbyKind ?? detectAnalyteKind(in: line),
            referenceBounds: referenceBounds(from: line),
            evidenceText: evidenceText
        )
    }

    private static func detectedKindNearLine(_ index: Int, line: String, in lines: [String]) -> LabAnalyteKind? {
        if let kind = detectAnalyteKind(in: lines[index]) {
            return kind
        }

        let nearbyIndices = [index - 1, index + 1, index - 2, index + 2]
            .filter { lines.indices.contains($0) }
        let scoredKinds = nearbyIndices.compactMap { candidateIndex -> (kind: LabAnalyteKind, score: Int)? in
            let line = lines[candidateIndex]
            let displayLine = stripInternalParserHints(line)
            guard referenceRangeMatches(in: displayLine).isEmpty else {
                return nil
            }
            guard displayLine.count <= 40 else { return nil }
            guard let kind = detectAnalyteKind(in: line) else { return nil }
            let distance = abs(candidateIndex - index)
            return (kind, 10 - distance * 2 + unitCompatibilityScore(candidateLine: lines[index], kind: kind))
        }
        return scoredKinds.max { $0.score < $1.score }?.kind
    }

    private static func unitCompatibilityScore(candidateLine line: String, kind: LabAnalyteKind) -> Int {
        let referenceRange = extractReferenceRange(from: line, kind: kind)
        let unit = resolvedUnitSymbol(
            extractUnitSymbol(from: line, fallbackReferenceRange: referenceRange),
            referenceRange: referenceRange,
            kind: kind
        )
        var score = 0
        switch kind {
        case .estradiol:
            if unit == "pmol/L" || unit == "pg/mL" { score += 4 }
        case .prolactin:
            if unit == "mIU/L" || unit == "mIU/mL" || unit == "ng/mL" { score += 4 }
        case .follicleStimulatingHormone, .luteinizingHormone:
            if unit == "IU/L" || unit == "mIU/mL" { score += 3 }
        case .testosterone:
            if unit == "nmol/L" || unit == "ng/dL" || unit == "ng/mL" { score += 4 }
            if let bounds = referenceBounds(from: line), bounds.upper >= 5 { score += 2 }
        case .progesterone:
            if unit == "nmol/L" || unit == "ng/mL" { score += 3 }
            if let bounds = referenceBounds(from: line), bounds.upper <= 5 { score += 2 }
        case .dehydroepiandrosteroneSulfate:
            if unit == "µmol/L" { score += 4 }
        default:
            break
        }
        return score
    }

    private static func evidenceTextNearLine(_ index: Int, in lines: [String]) -> String {
        let nearbyIndices = [index - 2, index - 1, index, index + 1, index + 2]
            .filter { lines.indices.contains($0) }
        return nearbyIndices
            .map { lines[$0] }
            .filter { !$0.trimmed.isEmpty }
            .joined(separator: " ")
    }

    private static func panelRowScore(_ row: TableRowCandidate, kind: LabAnalyteKind) -> Int {
        var score = 0
        if let explicitKind = row.explicitKind {
            if explicitKind == kind {
                score += 6
            } else {
                score -= 8
            }
        }

        let referenceRange = extractReferenceRange(from: row.line, kind: kind)
        let unit = resolvedUnitSymbol(row.unitSymbol, referenceRange: referenceRange, kind: kind)
        switch kind {
        case .estradiol:
            if unit == "pmol/L" || unit == "pg/mL" { score += 2 }
        case .prolactin:
            if unit == "mIU/L" || unit == "mIU/mL" || unit == "ng/mL" { score += 2 }
        case .follicleStimulatingHormone, .luteinizingHormone:
            if unit == "IU/L" || unit == "mIU/mL" { score += 2 }
        case .testosterone:
            if unit == "nmol/L" || unit == "ng/dL" || unit == "ng/mL" { score += 2 }
            if let bounds = row.referenceBounds, bounds.upper >= 5 { score += 1 }
        case .progesterone:
            if unit == "nmol/L" || unit == "ng/mL" { score += 2 }
            if let bounds = row.referenceBounds, bounds.upper <= 5 { score += 1 }
        case .dehydroepiandrosteroneSulfate:
            if unit == "µmol/L" { score += 2 }
        default:
            break
        }
        return score
    }

    private static func extractMeasuredValueBeforeReference(
        in line: String,
        referenceRange: NSTextCheckingResult
    ) -> Double? {
        guard let prefixRange = Range(NSRange(location: 0, length: referenceRange.range.location), in: line) else {
            return nil
        }

        let prefix = String(line[prefixRange])
        let numberPattern = #"(?<![\d.A-Za-z])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        let bounds = referenceBounds(from: line)

        return regex.matches(in: prefix, range: range).reversed().compactMap { match in
            stringCapture(1, in: prefix, match: match)
                .flatMap { correctedMeasuredValue(from: $0, referenceBounds: bounds, kind: nil) }
        }
        .first
    }

    private static func methodNearLine(_ index: Int, in lines: [String]) -> String? {
        let nearbyIndices = [index - 1, index + 1].filter { lines.indices.contains($0) }
        return nearbyIndices.compactMap { extractMethod(from: lines[$0]) }.first
    }

    private static func detectAnalyteKind(in line: String) -> LabAnalyteKind? {
        let patterns: [(LabAnalyteKind, String)] = [
            (.freeTestosterone, #"(?i)(游离睾酮|free\s+testosterone|\bfree\s+t\b)"#),
            (.sexHormoneBindingGlobulin, #"(?i)(性激素结合球蛋白|\bshbg\b)"#),
            (.estradiol, #"(?i)(雌二醇|\boestradiol\b|\bestradiol\b|\be2\b)"#),
            (.testosterone, #"(?i)(总睾酮|睾酮|睪酮|\btotal\s+t\b|\btestosterone\b|\btesto\b|testo|^\s*t\b|\bt\s*:)"#),
            (.luteinizingHormone, #"(?i)(促黄体生成素|黄体生成素|\blh\b|\bluteini[sz](?:ing|ng)\s+hormone\b)"#),
            (.follicleStimulatingHormone, #"(?i)(促卵泡生成素|卵泡刺激素|\bfsh\b|\bfollicle\s+stimulat(?:ing|ion)\s+hormone\b)"#),
            (.prolactin, #"(?i)(泌乳素|\bprolactin\b|\bprl\b)"#),
            (.progesterone, #"(?i)(孕酮|\bprogesterone\b|^\s*p\b|\bp\s*:)"#),
            (.dehydroepiandrosteroneSulfate, #"(?i)(硫酸脱氢表雄酮|脱氢表雄酮|dhea\s*-?\s*s|dheas)"#)
        ]

        for (kind, pattern) in patterns where firstMatch(pattern: pattern, in: line) != nil {
            return kind
        }
        return nil
    }

    private static func detectedName(for kind: LabAnalyteKind, in line: String) -> String {
        let cleanLine = line.trimmed
        if cleanLine.contains("雌二醇") { return "Estradiol" }
        if cleanLine.contains("睾酮") || cleanLine.contains("睪酮") || cleanLine.localizedCaseInsensitiveContains("Testo") { return kind.defaultName }
        if cleanLine.contains("泌乳素") { return "Prolactin" }
        if cleanLine.contains("促卵泡") || cleanLine.localizedCaseInsensitiveContains("FSH") { return "FSH" }
        if cleanLine.contains("促黄体") || cleanLine.localizedCaseInsensitiveContains("LH") { return "LH" }
        if cleanLine.contains("孕酮") { return "Progesterone" }
        if cleanLine.lowercased().contains("dhea") || cleanLine.contains("脱氢表雄酮") { return "DHEA-S" }
        return kind.defaultName
    }

    private static func extractMeasuredValue(from line: String, kind: LabAnalyteKind) -> Double? {
        if let referenceRange = referenceRangeMatches(in: line).first,
           let value = extractMeasuredValueBeforeReference(in: line, referenceRange: referenceRange) {
            return value
        }

        let referenceRanges = referenceRangeMatches(in: line).map(\.range)
        let analyteRanges = analyteCodeMatches(in: line, kind: kind).map(\.range)
        let numberPattern = #"(?<![\d.A-Za-z])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: fullRange)

        for match in matches
            where !referenceRanges.contains(where: { rangesOverlap($0, match.range) })
                && !analyteRanges.contains(where: { rangesOverlap($0, match.range) }) {
            guard let valueText = stringCapture(1, in: line, match: match),
                let value = correctedMeasuredValue(from: valueText, referenceBounds: referenceBounds(from: line), kind: kind),
                value >= 0 else {
                continue
            }
            return value
        }

        return nil
    }

    private static func cleanNumberText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "≤", with: "")
            .replacingOccurrences(of: "≥", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
    }

    private static func correctedMeasuredValue(
        from rawText: String,
        referenceBounds: (lower: Double, upper: Double)?,
        kind: LabAnalyteKind?
    ) -> Double? {
        let cleanText = cleanNumberText(rawText)
        guard let value = Double(cleanText), value >= 0 else {
            return nil
        }
        guard let strippedText = numberTextByDroppingLeadingFlagOne(cleanText),
              let strippedValue = Double(strippedText),
              shouldDropLeadingFlagOne(original: value, stripped: strippedValue, referenceBounds: referenceBounds, kind: kind) else {
            return value
        }
        return strippedValue
    }

    private static func numberTextByDroppingLeadingFlagOne(_ text: String) -> String? {
        guard text.hasPrefix("1"), text.count >= 2 else { return nil }
        var stripped = String(text.dropFirst())
        guard stripped.contains(where: \.isNumber) else { return nil }
        if stripped.hasPrefix(".") {
            stripped = "0" + stripped
        }
        return stripped
    }

    private static func shouldDropLeadingFlagOne(
        original: Double,
        stripped: Double,
        referenceBounds: (lower: Double, upper: Double)?,
        kind: LabAnalyteKind?
    ) -> Bool {
        guard stripped >= 0,
              stripped < original,
              let referenceBounds else {
            return false
        }

        let upper = max(referenceBounds.lower, referenceBounds.upper)
        guard upper > 0 else { return false }

        let originalRatio = original / upper
        let strippedRatio = stripped / upper

        if originalRatio >= 8, strippedRatio <= 4 {
            return true
        }
        if originalRatio >= 3, strippedRatio <= 1.5 {
            return true
        }
        if originalRatio >= 5, strippedRatio <= originalRatio * 0.4 {
            return true
        }

        return false
    }

    private static func analyteCodeMatches(in line: String, kind: LabAnalyteKind) -> [NSTextCheckingResult] {
        let codePattern: String
        switch kind {
        case .estradiol:
            codePattern = #"(?i)\(?\bE2\b\)?"#
        case .testosterone:
            codePattern = #"(?i)\(?\bT\b\)?"#
        case .luteinizingHormone:
            codePattern = #"(?i)\(?\bLH\b\)?"#
        case .follicleStimulatingHormone:
            codePattern = #"(?i)\(?\bFSH\b\)?"#
        case .prolactin:
            codePattern = #"(?i)\(?\bPRL\b\)?"#
        case .progesterone:
            codePattern = #"(?i)\(?\bP\b\)?"#
        case .sexHormoneBindingGlobulin:
            codePattern = #"(?i)\(?\bSHBG\b\)?"#
        case .freeTestosterone:
            codePattern = #"(?i)\(?\bfree\s*T\b\)?"#
        case .dehydroepiandrosteroneSulfate:
            codePattern = #"(?i)\(?\bDHEA\s*-?\s*S\b\)?"#
        case .other:
            return []
        }
        guard let regex = try? NSRegularExpression(pattern: codePattern, options: [.caseInsensitive]) else {
            return []
        }
        return regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
    }

    private static func extractReferenceRange(from line: String, kind: LabAnalyteKind? = nil) -> String? {
        guard let match = referenceRangeMatches(in: line).first,
              let range = Range(match.range, in: line) else {
            return nil
        }
        return normalizedReferenceRange(String(line[range]).trimmed, kind: kind)
    }

    private static func referenceRangeMatches(in line: String) -> [NSTextCheckingResult] {
        let pattern = #"([<>≤≥]?\s*\d+(?:[\.,]\d+)?)\s*(?:-|~|至|到)\s*([<>≤≥]?\s*\d+(?:[\.,]\d+)?)\s*([a-zA-Z0-9μµ/%]+(?:\s*/\s*[a-zA-Z0-9μµ]+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
    }

    private static func referenceBounds(from line: String) -> (lower: Double, upper: Double)? {
        guard let match = referenceRangeMatches(in: line).first,
              let lower = stringCapture(1, in: line, match: match).map(cleanNumberText).flatMap(Double.init),
              let upper = stringCapture(2, in: line, match: match).map(cleanNumberText).flatMap(Double.init) else {
            return nil
        }
        return (lower, upper)
    }

    private static func normalizedReferenceRange(_ referenceRange: String, kind: LabAnalyteKind?) -> String {
        var normalized = normalizedUnitSubstrings(in: referenceRange)
            .replacingOccurrences(of: "umol/L", with: "µmol/L", options: [.caseInsensitive])
            .replacingOccurrences(of: "wmol/L", with: "µmol/L", options: [.caseInsensitive])
            .replacingOccurrences(of: "u mol/L", with: "µmol/L", options: [.caseInsensitive])
            .replacingOccurrences(of: "μmol/L", with: "µmol/L", options: [.caseInsensitive])
            .replacingOccurrences(of: "IV/L", with: "IU/L", options: [.caseInsensitive])

        if kind == .testosterone || kind == .progesterone {
            normalized = normalized
                .replacingOccurrences(of: "mmo1/L", with: "nmol/L", options: [.caseInsensitive])
                .replacingOccurrences(of: "mmol/L", with: "nmol/L", options: [.caseInsensitive])
        }
        if kind == .dehydroepiandrosteroneSulfate {
            normalized = normalized
                .replacingOccurrences(of: "mmo1/L", with: "µmol/L", options: [.caseInsensitive])
                .replacingOccurrences(of: "mmol/L", with: "µmol/L", options: [.caseInsensitive])
        }

        return normalized
    }

    private static func extractUnitSymbol(from line: String) -> String {
        extractUnitSymbol(from: line, fallbackReferenceRange: nil)
    }

    private static func extractUnitSymbol(from line: String, fallbackReferenceRange: String?) -> String {
        if let fallbackReferenceRange,
           let unit = firstUnitSymbol(in: fallbackReferenceRange) {
            return unit
        }

        if let unit = firstUnitSymbolAfterNumber(in: line) {
            return unit
        }

        return firstUnitSymbol(in: line) ?? ""
    }

    private static var unitSymbolPattern: String {
        let massUnit = #"(?:p\s*g|n\s*g|u\s*g|µ\s*g|μ\s*g|m\s*g|g)"#
        let molarUnit = #"(?:p\s*mol|n\s*mol|u\s*mol|w\s*mol|µ\s*mol|μ\s*mol|m\s*mol|mmo[1l]|mol)"#
        let activityUnit = #"(?:u\s*IU|µ\s*IU|μ\s*IU|m\s*IU|m?[i1][uUvV]|IU|IV|1U|1V|U)"#
        let denominator = #"(?:m\s*[lL1]|d\s*[lL1]|[lL1])"#
        let countUnit = #"(?:[x×]?\s*10\s*\^?\s*\d+\s*/\s*[lL1]|10\s*\*\s*\d+\s*/\s*[lL1])"#
        let standaloneUnit = #"(?:%|mm\s*Hg|f\s*L|p\s*g|m\s*Eq\s*/?\s*[lL1]|m\s*[lL1]\s*/\s*min(?:\s*/\s*1\.?\s*73\s*m2)?|m\s*mol\s*/\s*mol|"# + countUnit + #")"#
        return #"(?<![A-Za-z])((?:(?:"# + massUnit + #"|"# + molarUnit + #"|"# + activityUnit + #")\s*/?\s*"# + denominator + #")|"# + standaloneUnit + #")(?![A-Za-z])"#
    }

    private static func firstUnitSymbol(in text: String) -> String? {
        guard let match = firstMatch(pattern: unitSymbolPattern, in: text),
              let unit = stringCapture(1, in: text, match: match) else {
            return nil
        }
        return normalizedUnitToken(unit)
    }

    private static func firstUnitSymbolAfterNumber(in line: String) -> String? {
        let numberPattern = #"(?<![\d.A-Za-z])([<>≤≥]?\s*\d+(?:[\.,]\d+)?)"#
        guard let numberRegex = try? NSRegularExpression(pattern: numberPattern),
              let unitRegex = try? NSRegularExpression(
                pattern: #"^\s*(?:[↑↓HhLl*•·\.\-–—:]|\([HhLl]\))*\s*"# + unitSymbolPattern,
                options: [.caseInsensitive]
              ) else {
            return nil
        }

        let matches = numberRegex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        for match in matches {
            let suffixLocation = match.range.location + match.range.length
            guard suffixLocation <= (line as NSString).length else { continue }
            let maxLength = min(24, (line as NSString).length - suffixLocation)
            let suffixRange = NSRange(location: suffixLocation, length: maxLength)
            guard let swiftRange = Range(suffixRange, in: line) else { continue }
            let suffix = String(line[swiftRange])
            guard let unitMatch = unitRegex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)),
                  let unit = stringCapture(1, in: suffix, match: unitMatch) else {
                continue
            }
            return normalizedUnitToken(unit)
        }

        return nil
    }

    private static func normalizedUnitSubstrings(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: unitSymbolPattern, options: [.caseInsensitive]) else {
            return text
        }

        var normalized = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: normalized),
                  let originalRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            normalized.replaceSubrange(range, with: normalizedUnitToken(String(text[originalRange])))
        }
        return normalized
    }

    private static func normalizedUnitToken(_ raw: String) -> String {
        let compact = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "μ", with: "µ")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "/m1", with: "/ml", options: [.caseInsensitive])
            .replacingOccurrences(of: "/d1", with: "/dl", options: [.caseInsensitive])
        let lower = compact.lowercased()
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "iv", with: "iu")
            .replacingOccurrences(of: "miv", with: "miu")
        switch lower {
        case "%": return "%"
        case "mmhg": return "mmHg"
        case "fl": return "fL"
        case "pg": return "pg"
        case "meq/l": return "mEq/L"
        case "ml/min": return "mL/min"
        case "ml/min/i.73m2": return "mL/min/1.73m2"
        case "pg/ml": return "pg/mL"
        case "pg/l": return "pg/L"
        case "pg/dl": return "pg/dL"
        case "pmol/l": return "pmol/L"
        case "pmol/ml": return "pmol/mL"
        case "pmol/dl": return "pmol/dL"
        case "ng/dl": return "ng/dL"
        case "ng/ml": return "ng/mL"
        case "ng/l": return "ng/L"
        case "ug/ml", "µg/ml": return "µg/mL"
        case "ug/l", "µg/l": return "µg/L"
        case "ug/dl", "µg/dl": return "µg/dL"
        case "mg/ml": return "mg/mL"
        case "mg/l": return "mg/L"
        case "mg/dl": return "mg/dL"
        case "g/ml": return "g/mL"
        case "g/l": return "g/L"
        case "g/dl": return "g/dL"
        case "nmol/l": return "nmol/L"
        case "nmol/ml": return "nmol/mL"
        case "nmol/dl": return "nmol/dL"
        case "mmol/l", "mmoi/l": return "mmol/L"
        case "mmol/ml", "mmoi/ml": return "mmol/mL"
        case "mmol/dl", "mmoi/dl": return "mmol/dL"
        case "mmol/mol", "mmoi/mol": return "mmol/mol"
        case "miu/ml": return "mIU/mL"
        case "uiu/ml": return "uIU/mL"
        case "µiu/ml": return "µIU/mL"
        case "iu/ml", "u/ml": return "IU/mL"
        case "miu/dl": return "mIU/dL"
        case "iu/dl", "u/dl": return "IU/dL"
        case "uiu/dl": return "uIU/dL"
        case "µiu/dl": return "µIU/dL"
        case "iu/l", "u/l": return "IU/L"
        case "miu/l": return "mIU/L"
        case "uiu/l": return "uIU/L"
        case "µiu/l": return "µIU/L"
        case "umol/l", "wmol/l", "µmol/l": return "µmol/L"
        case "umol/ml", "wmol/ml", "µmol/ml": return "µmol/mL"
        case "umol/dl", "wmol/dl", "µmol/dl": return "µmol/dL"
        case "mol/l": return "mol/L"
        case "mol/ml": return "mol/mL"
        case "mol/dl": return "mol/dL"
        default:
            if let normalizedCountUnit = normalizedCountUnit(lower) {
                return normalizedCountUnit
            }
            return compact
        }
    }

    private static func normalizedCountUnit(_ lower: String) -> String? {
        let normalized = lower
            .replacingOccurrences(of: "i", with: "1")
            .replacingOccurrences(of: "*", with: "^")
        guard let match = firstMatch(pattern: #"x?10\^?(\d+)/l"#, in: normalized),
              let power = stringCapture(1, in: normalized, match: match) else {
            return nil
        }
        return "10^\(power)/L"
    }

    private static func resolvedUnitSymbol(_ rawUnitSymbol: String, kind: LabAnalyteKind) -> String {
        if (kind == .testosterone || kind == .progesterone), rawUnitSymbol == "mmol/L" {
            return "nmol/L"
        }
        if kind == .dehydroepiandrosteroneSulfate, rawUnitSymbol == "mol/L" || rawUnitSymbol == "mmol/L" {
            return "µmol/L"
        }
        return rawUnitSymbol
    }

    private static func resolvedUnitSymbol(
        _ rawUnitSymbol: String,
        referenceRange: String?,
        kind: LabAnalyteKind
    ) -> String {
        let unit = resolvedUnitSymbol(rawUnitSymbol, kind: kind)
        if let inferred = inferredUnitSymbol(from: referenceRange, kind: kind) {
            if unit.isEmpty || unit == "mol/L" {
                return inferred
            }
            if kind == .prolactin, unit == "IU/L" {
                return inferred
            }
        }
        return unit
    }

    private static func inferredUnitSymbol(from referenceRange: String?, kind: LabAnalyteKind) -> String? {
        guard let referenceRange,
              let bounds = referenceBounds(from: referenceRange) else {
            return nil
        }

        switch kind {
        case .estradiol:
            return bounds.upper >= 100 ? "pmol/L" : nil
        case .testosterone:
            return bounds.upper >= 5 ? "nmol/L" : nil
        case .progesterone:
            return bounds.upper <= 10 ? "nmol/L" : nil
        case .prolactin:
            return bounds.upper >= 100 ? "mIU/L" : nil
        case .follicleStimulatingHormone, .luteinizingHormone:
            return "IU/L"
        case .dehydroepiandrosteroneSulfate:
            return "µmol/L"
        default:
            return nil
        }
    }

    private static func extractMethod(from line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("i2000sr") || lower.contains("12000sr") || lower.contains("l2000sr") {
            return "i2000SR"
        }
        let tokens = ["lc-ms/ms", "eclia", "clia", "cmia", "elisa", "化学发光", "免疫", "质谱"]
        return tokens.first { lower.contains($0.lowercased()) }
    }

    private static func extractInstitution(from lines: [String]) -> String {
        let labeled = extractField(
            from: lines,
            labels: [
                "检验机构", "检测机构", "实验室",
                "testing laboratory", "performing laboratory", "institution", "organization", "performed at"
            ]
        )
        if !labeled.isEmpty {
            let candidate = sanitizedInstitution(labeled)
            if isPlausibleInstitution(candidate) {
                return candidate
            }
        }

        for line in lines.prefix(12) {
            let candidate = sanitizedInstitution(line)
            guard isPlausibleInstitution(candidate) else { continue }
            if line.contains("医院")
                || line.localizedCaseInsensitiveContains("hospital")
                || line.localizedCaseInsensitiveContains("laboratory")
                || line.localizedCaseInsensitiveContains("medical center")
                || line.localizedCaseInsensitiveContains("clinic")
                || line.localizedCaseInsensitiveContains("klinikum")
                || line.localizedCaseInsensitiveContains("krankenhaus")
                || line.localizedCaseInsensitiveContains("laboratoire")
                || line.localizedCaseInsensitiveContains("laboratorio")
                || line.localizedCaseInsensitiveContains("labor ")
                || line.localizedCaseInsensitiveContains(" lab ")
                || line.contains("检验报告")
                || line.contains("报告单") {
                return candidate
            }
        }
        return ""
    }

    private static func sanitizedInstitution(_ raw: String) -> String {
        var value = raw.trimmed
        let noise = [
            "检验报告单", "检验报告", "报告单", "报告",
            "Laboratory Results", "Lab Results", "Laboratory Report", "Lab Report", "Laborbefund",
            "打印次数", "第1页", "共1页", "门诊", "门急诊"
        ]
        for token in noise {
            value = value.replacingOccurrences(of: token, with: "")
        }
        value = value.replacingOccurrences(of: ":", with: " ")
        value = value.replacingOccurrences(of: "：", with: " ")
        value = value
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmed

        if value.contains("大学附属"), !value.contains("医院") {
            if let siteRange = value.range(of: "（") ?? value.range(of: "(") {
                value.insert(contentsOf: "医院", at: siteRange.lowerBound)
            } else {
                value += "医院"
            }
        }

        return value.trimmed
    }

    private static func isPlausibleInstitution(_ value: String) -> Bool {
        let clean = value.trimmed
        guard clean.count >= 4 else { return false }
        let lower = clean.lowercased()
        let noise = [
            "result", "results", "report", "lab result", "lab results",
            "laboratory result", "laboratory results", "befund", "laborbefund"
        ]
        guard !noise.contains(where: { lower == $0 || lower.contains($0) }) else {
            return false
        }
        return clean.rangeOfCharacter(from: .letters) != nil
    }

    private static func extractSpecimen(from lines: [String]) -> String {
        let value = extractField(
            from: lines,
            labels: [
                "标本种类", "样本类型", "标本", "样本",
                "specimen", "sample type", "sample", "material",
                "probe", "materialart", "échantillon", "echantillon", "muestra", "amostra"
            ],
            terminators: ["收费类别", "收夷类别", "申请医生", "临床诊断", "科室", "病区", "病历号", "样本编号"]
        )
        guard !value.isEmpty else { return "" }
        return value
            .replacingOccurrences(of: "血清收", with: "血清")
            .trimmed
    }

    private static func extractReportMethod(from lines: [String], analytes: [LabAnalyteResult]) -> String {
        let labeled = extractField(
            from: lines,
            labels: ["检测方法", "检验方法", "方法学", "method", "assay"],
            terminators: ["检验项目", "结果", "参考范围", "系统", "采集时间", "报告时间"]
        )
        if isMeaningfulMethod(labeled) {
            return labeled
        }

        let methods = analytes.compactMap(\.method).filter { isMeaningfulMethod($0) }
        let grouped = Dictionary(grouping: methods, by: { $0 })
        return grouped.max { lhs, rhs in lhs.value.count < rhs.value.count }?.key ?? ""
    }

    private static func isMeaningfulMethod(_ value: String) -> Bool {
        let clean = value.trimmed
        guard clean.count >= 3 else { return false }
        let lower = clean.lowercased()
        if lower == "method" || clean == "方法" || clean == "方法学" || clean.contains("系统或") {
            return false
        }
        if clean.contains("检验项目") || clean.contains("参考范围") || clean.contains("结果") {
            return false
        }
        return true
    }

    private static func extractField(
        from lines: [String],
        labels: [String],
        terminators: [String] = []
    ) -> String {
        for line in lines {
            guard let label = labels.first(where: { line.range(of: $0, options: [.caseInsensitive]) != nil }),
                  let labelRange = line.range(of: label, options: [.caseInsensitive]) else {
                continue
            }

            var value = String(line[labelRange.upperBound...]).trimmed
            if value.hasPrefix(":") || value.hasPrefix("：") {
                value.removeFirst()
            }
            value = value.trimmed

            for terminator in terminators {
                if let terminatorRange = value.range(of: terminator, options: [.caseInsensitive]) {
                    value = String(value[..<terminatorRange.lowerBound]).trimmed
                }
            }

            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func extractDate(from lines: [String], labels: [String]) -> Date? {
        for line in lines {
            guard let label = labels.first(where: { line.range(of: $0, options: [.caseInsensitive]) != nil }),
                  let labelRange = line.range(of: label, options: [.caseInsensitive]) else {
                continue
            }
            let labeledSuffix = String(line[labelRange.upperBound...])
            if let date = extractDate(from: labeledSuffix) ?? extractDate(from: line) {
                return date
            }
        }
        return nil
    }

    private static func extractDate(from text: String) -> Date? {
        extractDates(from: text).first
    }

    private static func extractDates(from text: String) -> [Date] {
        let normalized = text
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let patterns: [(expression: String, yearFirst: Bool)] = [
            (
                #"(\d{4})\s*-\s*(\d{1,2})\s*-\s*(\d{1,2})(?:\s*(\d{1,2})\s*[:时]\s*(\d{1,2})(?:\s*[:分]\s*\d{1,2})?)?"#,
                true
            ),
            (
                #"(\d{1,2})\s*-\s*(\d{1,2})\s*-\s*(\d{4})(?:\s*(\d{1,2})\s*[:时]\s*(\d{1,2})(?:\s*[:分]\s*\d{1,2})?)?"#,
                false
            )
        ]

        var dates: [Date] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.expression) else { continue }
            let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized))

            for match in matches {
                let first = intCapture(1, in: normalized, match: match)
                let second = intCapture(2, in: normalized, match: match)
                let third = intCapture(3, in: normalized, match: match)
                let hour = intCapture(4, in: normalized, match: match) ?? 12
                let minute = intCapture(5, in: normalized, match: match) ?? 0

                let year: Int?
                let month: Int?
                let day: Int?
                if pattern.yearFirst {
                    year = first
                    month = second
                    day = third
                } else {
                    year = third
                    // Numeric day/month order is ambiguous when both
                    // components are <= 12. Preserve the existing month-first
                    // fallback, but a first component above 12 can only be the
                    // day.
                    if let first, first > 12 {
                        month = second
                        day = first
                    } else {
                        month = first
                        day = second
                    }
                }

                guard let year,
                      let month,
                      let day,
                      (1...12).contains(month),
                      (1...31).contains(day),
                      (0...23).contains(hour),
                      (0...59).contains(minute) else {
                    continue
                }
                let calendar = Calendar.current
                var components = DateComponents()
                components.calendar = calendar
                components.year = year
                components.month = month
                components.day = day
                components.hour = hour
                components.minute = minute
                if let date = components.date {
                    let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    guard resolved.year == year,
                          resolved.month == month,
                          resolved.day == day,
                          resolved.hour == hour,
                          resolved.minute == minute else {
                        continue
                    }
                    dates.append(date)
                }
            }
        }

        dates.append(contentsOf: extractMonthNameDates(from: text))
        if normalized != text {
            dates.append(contentsOf: extractMonthNameDates(from: normalized))
        }
        return dates
    }

    private static func extractMonthNameDates(from text: String) -> [Date] {
        let monthFirstPattern = #"\b([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})(?:\s+(\d{1,2})\s*:\s*(\d{2})(?:\s*([AaPp][Mm]))?)?"#
        let dayFirstPattern = #"\b(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})(?:\s+(\d{1,2})\s*:\s*(\d{2})(?:\s*([AaPp][Mm]))?)?"#
        var dates: [Date] = []

        dates.append(contentsOf: monthNameDates(in: text, pattern: monthFirstPattern, monthIndex: 1, dayIndex: 2, yearIndex: 3))
        dates.append(contentsOf: monthNameDates(in: text, pattern: dayFirstPattern, monthIndex: 2, dayIndex: 1, yearIndex: 3))
        return dates
    }

    private static func monthNameDates(
        in text: String,
        pattern: String,
        monthIndex: Int,
        dayIndex: Int,
        yearIndex: Int
    ) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))

        return matches.compactMap { match in
            guard let monthText = stringCapture(monthIndex, in: text, match: match),
                  let month = monthNumber(from: monthText),
                  let day = intCapture(dayIndex, in: text, match: match),
                  let year = intCapture(yearIndex, in: text, match: match) else {
                return nil
            }
            var hour = intCapture(4, in: text, match: match) ?? 12
            let minute = intCapture(5, in: text, match: match) ?? 0
            if let marker = stringCapture(6, in: text, match: match)?.lowercased() {
                if marker == "pm", hour < 12 { hour += 12 }
                if marker == "am", hour == 12 { hour = 0 }
            }

            var components = DateComponents()
            components.calendar = Calendar.current
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return components.date
        }
    }

    private static func monthNumber(from text: String) -> Int? {
        let prefix = text.lowercased().prefix(3)
        switch prefix {
        case "jan": return 1
        case "feb": return 2
        case "mar": return 3
        case "apr": return 4
        case "may": return 5
        case "jun": return 6
        case "jul": return 7
        case "aug": return 8
        case "sep": return 9
        case "oct": return 10
        case "nov": return 11
        case "dec": return 12
        default: return nil
        }
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

#if DEBUG && canImport(FoundationModels)
@available(iOS 27.0, *)
@MainActor
enum LabReportAIDiagnostics {
    static func run() async -> String {
        let model = SystemLanguageModel.default
        let transformModel = SystemLanguageModel(
            useCase: .contentTagging,
            guardrails: .permissiveContentTransformations
        )
        var lines: [String] = []

        lines.append("HRT Recorder Apple AI Diagnostics")
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
        lines.append("Device locale: \(Locale.current.identifier)")
        lines.append("Timestamp: \(Date().formatted(date: .numeric, time: .standard))")
        lines.append("")
        lines.append("SystemLanguageModel")
        lines.append("- availability: \(systemAvailabilityDescription(model.availability))")
        lines.append("- supports current locale: \(model.supportsLocale(Locale.current))")
        lines.append("- supports en_US: \(model.supportsLocale(Locale(identifier: "en_US")))")
        lines.append("- supports zh_Hans: \(model.supportsLocale(Locale(identifier: "zh_Hans")))")
        lines.append("")
        lines.append("ContentTransform SystemLanguageModel")
        lines.append("- availability: \(systemAvailabilityDescription(transformModel.availability))")
        lines.append("- supports current locale: \(transformModel.supportsLocale(Locale.current))")
        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *) {
            lines.append("")
            lines.append("PrivateCloudComputeLanguageModel")
            if appHasPrivateCloudComputeEntitlement() {
                let privateCloudModel = PrivateCloudComputeLanguageModel()
                lines.append("- availability: \(privateCloudAvailabilityDescription(privateCloudModel.availability))")
                lines.append("- supports current locale: \(privateCloudModel.supportsLocale(Locale.current))")
                lines.append("- supports zh_Hans: \(privateCloudModel.supportsLocale(Locale(identifier: "zh_Hans")))")
            } else {
                lines.append("- availability: unavailable.missingEntitlement")
            }
        } else {
            lines.append("")
            lines.append("PrivateCloudComputeLanguageModel")
            lines.append("- availability: unavailable.requiresIOS27")
        }
        #else
        lines.append("")
        lines.append("PrivateCloudComputeLanguageModel")
        lines.append("- availability: unavailable.notCompiledWithIOS27SDK")
        #endif
        lines.append("")
        lines.append(await runTextProbe(
            name: "default plain English text",
            model: model,
            prompt: "Reply with exactly READY.",
            instructions: "Follow the user's instruction exactly."
        ))
        lines.append("")
        lines.append(await runTextProbe(
            name: "default plain Chinese text",
            model: model,
            prompt: "请只回复 READY。",
            instructions: "Follow the user's instruction exactly."
        ))
        lines.append("")
        lines.append(await runStructuredProbe(model: transformModel))
        lines.append("")
        lines.append(await runMetadataNoMethodBoundaryProbe(model: transformModel))
        #if FOUNDATION_MODELS_IOS27
        if #available(iOS 27.0, *) {
            lines.append("")
            lines.append(await runPrivateCloudStructuredProbe())
        }
        #endif
        lines.append("")
        lines.append(await runProductionLabTextExtractionProbe())
        lines.append("")
        lines.append(await runProductionBoundaryProbe())

        return lines.joined(separator: "\n")
    }

    private static var diagnosticOptions: GenerationOptions {
        labGreedyGenerationOptions(maximumResponseTokens: 96)
    }

    private static var boundaryOptions: GenerationOptions {
        labGreedyGenerationOptions(maximumResponseTokens: 360)
    }

    private static func runTextProbe(
        name: String,
        model: SystemLanguageModel,
        prompt: String,
        instructions: String
    ) async -> String {
        guard model.isAvailable else {
            return "\(name): SKIP system model unavailable (\(systemAvailabilityDescription(model.availability)))"
        }

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt, options: diagnosticOptions)
            let content = response.content.trimmed
            var trimSet = CharacterSet.whitespacesAndNewlines
            trimSet.formUnion(CharacterSet(charactersIn: ".。!！"))
            let normalizedContent = content.trimmingCharacters(in: trimSet)
            let passed = normalizedContent.caseInsensitiveCompare("READY") == .orderedSame
            return "\(name): \(passed ? "PASS" : "FAIL") response=\(content)"
        } catch {
            return "\(name): FAIL \(describe(error))"
        }
    }

    private static func runStructuredProbe(model: SystemLanguageModel) async -> String {
        guard model.isAvailable else {
            return "structured generation: SKIP system model unavailable (\(systemAvailabilityDescription(model.availability)))"
        }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "Return the requested diagnostic structure only."
            )
            let response = try await session.respond(
                to: "Set status to READY and explanation to OK.",
                generating: GeneratedDiagnosticPayload.self,
                includeSchemaInPrompt: true,
                options: diagnosticOptions
            )
            return "structured generation: PASS status=\(response.content.status) explanation=\(response.content.explanation)"
        } catch {
            return "structured generation: FAIL \(describe(error))"
        }
    }

    private static func runMetadataNoMethodBoundaryProbe(model: SystemLanguageModel) async -> String {
        guard model.isAvailable else {
            return "metadata boundary no-method: SKIP system model unavailable (\(systemAvailabilityDescription(model.availability)))"
        }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: """
                Extract document metadata from OCR evidence only.
                Leave method empty unless the OCR explicitly contains an assay method or analyzer/instrument line or token.
                Do not use report titles, department names, specimen types, diagnoses, or generic analysis/result text as method.
                For specimen, prefer the narrowest plausible material visible in a specimen/sample field.
                If a specimen value is OCR-corrupted, normalize it only when confident; do not broaden it to generic blood unless blood is explicitly visible.
                Do not invent fields.
                """
            )
            let response = try await session.respond(
                to: """
                OCR evidence:
                \(diagnosticNoMethodOCRText)

                No assay method line is visible in this evidence.
                """,
                generating: GeneratedBoundaryMetadataPayload.self,
                includeSchemaInPrompt: true,
                options: boundaryOptions
            )
            let payload = response.content
            let method = payload.method.trimmed
            let specimen = payload.specimen.trimmed
            let methodOK = method.isEmpty
            let specimenOK = specimen.isEmpty
                || specimen == "血清"
                || specimen.localizedCaseInsensitiveContains("serum")
            return [
                "metadata boundary no-method: \(methodOK && specimenOK ? "PASS" : "FAIL")",
                "method=\(method.isEmpty ? "empty" : method)",
                "specimen=\(specimen.isEmpty ? "empty" : specimen)",
                "institution=\(payload.institution.trimmed)"
            ].joined(separator: " ")
        } catch {
            return "metadata boundary no-method: FAIL \(describe(error))"
        }
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func runPrivateCloudStructuredProbe() async -> String {
        guard appHasPrivateCloudComputeEntitlement() else {
            return "private cloud structured generation: SKIP missing com.apple.developer.private-cloud-compute entitlement"
        }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            return "private cloud structured generation: SKIP private cloud unavailable (\(privateCloudAvailabilityDescription(model.availability)))"
        }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "Return the requested diagnostic structure only."
            )
            let response = try await session.respond(
                to: "Set status to READY and explanation to PCC_OK.",
                generating: GeneratedDiagnosticPayload.self,
                includeSchemaInPrompt: true,
                options: diagnosticOptions
            )
            return "private cloud structured generation: PASS status=\(response.content.status) explanation=\(response.content.explanation)"
        } catch {
            return "private cloud structured generation: FAIL \(describe(error))"
        }
    }
    #endif

    private static func runProductionLabTextExtractionProbe() async -> String {
        let fallback = HormoneLabResultParser.parseReport(
            diagnosticLabOCRText,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        guard !fallback.analytes.isEmpty else {
            return "production lab text extraction: FAIL OCR fallback produced no analytes"
        }

        guard let outcome = await LabReportAIExtractor.extract(
            from: diagnosticLabOCRText,
            sourceKind: .pastedText,
            fallback: fallback
        ) else {
            let kinds = fallback.analytes
                .map(\.kind.rawValue)
                .joined(separator: ",")
            return "production lab text extraction: PASS fallbackOnly analytes=\(fallback.analytes.count) kinds=\(kinds) institution=\(fallback.institution) diagnostic=\(LabReportAIExtractor.detailedTextDiagnosticSummary())"
        }

        let kinds = outcome.report.analytes
            .map(\.kind.rawValue)
            .joined(separator: ",")
        return "production lab text extraction: PASS analytes=\(outcome.report.analytes.count) kinds=\(kinds) institution=\(outcome.report.institution) status=\(outcome.statusMessage ?? "")"
    }

    private static func runProductionBoundaryProbe() async -> String {
        let fallback = HormoneLabResultParser.parseReport(
            diagnosticNoMethodOCRText,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        guard !fallback.analytes.isEmpty else {
            return "production boundary no-method/no-note: FAIL OCR fallback produced no analytes"
        }

        let report = await LabReportAIExtractor.extract(
            from: diagnosticNoMethodOCRText,
            sourceKind: .pastedText,
            fallback: fallback
        )?.report ?? fallback

        let rowMethods = report.analytes
            .compactMap { $0.method?.nilIfBlank }
            .joined(separator: "|")
        let notes = report.analytes
            .compactMap { $0.note?.nilIfBlank }
            .joined(separator: "|")
        let methodOK = report.method.trimmed.isEmpty && rowMethods.isEmpty
        let notesOK = notes.isEmpty || notes
            .split(separator: "|")
            .allSatisfy { $0 == "↑" || $0 == "↓" }
        let specimenOK = report.specimen.trimmed.isEmpty || report.specimen == "血清"
        let testosterone = report.analytes.first { $0.kind == .testosterone }
        let testosteroneOK = testosterone?.displayName == LabAnalyteKind.testosterone.defaultName
            && abs((testosterone?.value ?? .nan) - 0.66) < 0.001

        return [
            "production boundary no-method/no-note: \(methodOK && notesOK && specimenOK && testosteroneOK ? "PASS" : "FAIL")",
            "reportMethod=\(report.method.trimmed.isEmpty ? "empty" : report.method.trimmed)",
            "rowMethods=\(rowMethods.isEmpty ? "empty" : rowMethods)",
            "notes=\(notes.isEmpty ? "empty" : notes)",
            "specimen=\(report.specimen.trimmed.isEmpty ? "empty" : report.specimen.trimmed)",
            "testosterone=\(testosterone?.displayName ?? "missing"):\(testosterone?.value.map { String($0) } ?? "nil")"
        ].joined(separator: " ")
    }

    private static let diagnosticLabOCRText = """
    上海中医药大学附属曙光医院（东部）检验报告单
    检验项目 结果 标志 参考范围 系统或方法学
    雌二醇（E2） 51.00 40.37-161.48pmol/L i2000SR
    垂体泌乳素（PRL） 168.12 72.66-407.4mIU/L i2000SR
    促卵泡刺激素（FSH） 2.07 0.95-11.95IU/L i2000SR
    促黄体生成素（LH） 2.09 0.57-12.07IU/L i2000SR
    睾酮（T） 7.11 4.94-32.01nmol/L i2000SR
    孕酮（P） 0.70 ↑ 0-0.64nmol/L i2000SR
    硫酸脱氢表雄酮（DHEA-S） 13.49 ↑ 1.20-10.40µmol/L i2000SR
    标本种类: 血清
    采集时间: 2026-04-10 16:34:01 接收时间: 2026-04-10 16:39:42
    报告时间: 2026-04-11 08:51:33 打印时间: 2026-04-11 08:51:49
    """

    private static let diagnosticNoMethodOCRText = """
    华中科技大学同济医学院附属协和医院核医学科报告单
    科别: 互联网门诊
    标本种类: 血消
    备注:
    单位 项目 结果 参考范围
    1 PRL 垂体泌乳素 ↑ 33.76 2.7-15.2 ng/ml
    2 E2 雌二醇 ↑69.01 11.3-43.2 pg/m1
    3 Testo 睪酮 ↓0.66 Tanner5期:6.5-30.6 nmol/L
    检验时间 14:43:22
    审核时间 15:53:03
    """

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)")
        }
        parts.append("raw=\(String(describing: error))")
        return parts.joined(separator: " | ")
    }

    @Generable(description: "Minimal diagnostic structure.")
    struct GeneratedDiagnosticPayload {
        @Guide(description: "Diagnostic status.")
        var status: String
        @Guide(description: "Short explanation.")
        var explanation: String
    }

    @Generable(description: "Boundary metadata probe payload.")
    struct GeneratedBoundaryMetadataPayload {
        @Guide(description: "Institution or organization name. Empty when unavailable.")
        var institution: String
        @Guide(description: "Testing location or site. Empty when unavailable.")
        var location: String
        @Guide(description: "Narrow normalized lab specimen/material type from a specimen/sample field. Empty when unavailable, implausible, or only generic blood can be guessed.")
        var specimen: String
        @Guide(description: "Assay method, analyzer, or platform only if explicitly visible. Empty for report titles, departments, specimen types, diagnoses, or analysis/result phrases.")
        var method: String
    }

    #if FOUNDATION_MODELS_IOS27
    @available(iOS 27.0, *)
    private static func privateCloudAvailabilityDescription(_ availability: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable.deviceNotEligible"
            case .systemNotReady:
                return "unavailable.systemNotReady"
            @unknown default:
                return "unavailable.unknown"
            }
        }
    }
    #endif

    private static func systemAvailabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable.deviceNotEligible"
            case .appleIntelligenceNotEnabled:
                return "unavailable.appleIntelligenceNotEnabled"
            case .modelNotReady:
                return "unavailable.modelNotReady"
            @unknown default:
                return "unavailable.unknown"
            }
        }
    }
}

@available(iOS 27.0, *)
enum LabReportFoundationModelDiagnostics {
    static func logStartup() {
        let model = SystemLanguageModel.default
        let parts: [String] = [
            "bundle=\(Bundle.main.bundleIdentifier ?? "unknown")",
            "locale=\(Locale.current.identifier)",
            "systemAvailability=\(systemAvailabilityDescription(model.availability))",
            "systemSupportsCurrentLocale=\(model.supportsLocale(Locale.current))",
            "systemSupportsEnUS=\(model.supportsLocale(Locale(identifier: "en_US")))",
            "systemSupportsZhHans=\(model.supportsLocale(Locale(identifier: "zh_Hans")))"
        ]

        NSLog("LAB_FOUNDATION_MODEL_DIAGNOSTIC %@", parts.joined(separator: " | "))
    }

    private static func systemAvailabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable.deviceNotEligible"
            case .appleIntelligenceNotEnabled:
                return "unavailable.appleIntelligenceNotEnabled"
            case .modelNotReady:
                return "unavailable.modelNotReady"
            @unknown default:
                return "unavailable.unknown"
            }
        }
    }
}
#endif

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
