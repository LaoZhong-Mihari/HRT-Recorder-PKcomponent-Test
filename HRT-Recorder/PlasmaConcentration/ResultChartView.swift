//
//  ResultChartView.swift
//  HRTRecorder
//
//    Created by mihari-zhong on 2025/8/1.
//

import Foundation
import SwiftUI
import Charts
import Combine
import UIKit

private typealias ResultChartPoint = ResultChartScaleSample

private struct ResultChartLabPoint: Identifiable {
    let id: UUID
    let hour: Double
    let concentration: Double
    let name: String
}

private struct ResultChartBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black))
    }
}

private struct ResultChartWindow {
    let points: ArraySlice<ResultChartPoint>
    let labPoints: [ResultChartLabPoint]
    let yAxisDomain: ClosedRange<Double>
}

private struct ResultChartZoomAnchor {
    let hour: Double
    let relativePosition: Double
}

private struct ResultChartInteractionSurface: UIViewRepresentable {
    let plotFrame: CGRect
    let isHoverEnabled: Bool
    let onTap: (CGPoint) -> Void
    let onHover: (CGPoint?) -> Void
    let onPanBegan: (CGPoint) -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: () -> Void
    let onMagnifyBegan: (CGPoint) -> Void
    let onMagnifyChanged: (CGFloat, CGPoint) -> Void
    let onMagnifyEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.backgroundColor = .clear
        view.plotFrame = plotFrame
        view.isMultipleTouchEnabled = true

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.allowedScrollTypesMask = .continuous
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.cancelsTouchesInView = false
        pinchGesture.delegate = context.coordinator
        view.addGestureRecognizer(pinchGesture)

        if isHoverEnabled {
            let hoverGesture = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHover(_:)))
            hoverGesture.delegate = context.coordinator
            view.addGestureRecognizer(hoverGesture)
        }

        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        uiView.plotFrame = plotFrame
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ResultChartInteractionSurface
        private var isPanning = false
        private var isMagnifying = false

        init(parent: ResultChartInteractionSurface) {
            self.parent = parent
        }

        @objc
        func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            let location = gesture.location(in: view)
            guard parent.plotFrame.contains(location) else { return }
            parent.onTap(location)
        }

        @objc
        func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began, .changed:
                parent.onHover(parent.plotFrame.contains(location) ? location : nil)
            default:
                parent.onHover(nil)
            }
        }

        @objc
        func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                guard parent.plotFrame.contains(location) else { return }
                isPanning = true
                parent.onPanBegan(location)
                parent.onPanChanged(size(from: gesture.translation(in: view)))
            case .changed:
                guard isPanning else { return }
                parent.onPanChanged(size(from: gesture.translation(in: view)))
            default:
                guard isPanning else { return }
                isPanning = false
                parent.onPanEnded()
            }
        }

        @objc
        func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                guard parent.plotFrame.contains(location) else { return }
                isMagnifying = true
                parent.onMagnifyBegan(location)
                parent.onMagnifyChanged(gesture.scale, location)
            case .changed:
                guard isMagnifying else { return }
                parent.onMagnifyChanged(gesture.scale, location)
            default:
                guard isMagnifying else { return }
                isMagnifying = false
                parent.onMagnifyEnded()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let location = gestureRecognizer.location(in: view)
            guard parent.plotFrame.contains(location) else { return false }

            if let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = panGesture.velocity(in: view)
                if velocity == .zero {
                    return true
                }
                return abs(velocity.x) >= abs(velocity.y)
            }

            return true
        }

        private func size(from point: CGPoint) -> CGSize {
            CGSize(width: point.x, height: point.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer
        }
    }

    final class InteractionView: UIView {
        var plotFrame: CGRect = .zero

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            plotFrame.contains(point)
        }
    }
}

struct ResultChartView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sim: SimulationResult
    let availableUnits: [ConcentrationUnit]
    let onSelectUnit: ((ConcentrationUnit) -> Void)?
    private let chartPoints: [ResultChartPoint]
    private let labPoints: [ResultChartLabPoint]
    private let chartMaxConcentration: Double
    private let preferredChartHeight: CGFloat?

    @State private var visibleDomainLength: Double = 48
    @State private var now: Date = Date()
    @State private var scrollPosition: Double = 0
    @State private var selectedHour: Double?
    @State private var hoveredHour: Double?
    @State private var magnifyBaseline: Double?
    @State private var panBaselineScrollPosition: Double?

    private let timer = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()

    init(
        sim: SimulationResult,
        labSamples: [LabSample] = [],
        availableUnits: [ConcentrationUnit] = [],
        preferredChartHeight: CGFloat? = nil,
        onSelectUnit: ((ConcentrationUnit) -> Void)? = nil
    ) {
        self.sim = sim
        self.availableUnits = availableUnits
        self.preferredChartHeight = preferredChartHeight
        self.onSelectUnit = onSelectUnit

        let points = Array(zip(sim.timeH, sim.concentrations)).map { hour, concentration in
            ResultChartPoint(hour: hour, concentration: concentration)
        }
        let hormone = sim.displayMetadata.hormone
        let unit = sim.concentrationUnit
        let labPoints = labSamples
            .filter { $0.hormone == hormone }
            .map { sample in
                ResultChartLabPoint(
                    id: sample.id,
                    hour: sample.timeH,
                    concentration: ConcentrationUnit.convert(
                        sample.concentration,
                        from: sample.unit,
                        to: unit,
                        hormone: hormone
                    ),
                    name: sample.analyteName ?? hormone.displayName
                )
            }
            .sorted { $0.hour < $1.hour }

        self.chartPoints = points
        self.labPoints = labPoints
        self.chartMaxConcentration = ResultChartScale.maximumValidConcentration(
            predicted: points.lazy.map(\.concentration),
            measured: labPoints.lazy.map(\.concentration)
        ) ?? 0
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var xAxisLabel: String {
        NSLocalizedString("chart.axis.time", comment: "X-axis label")
    }

    private var chartTitle: String {
        String.localizedStringWithFormat(
            String(localized: "chart.title"),
            sim.displayMetadata.hormone.displayName,
            sim.concentrationUnit.symbol
        )
    }

    private var yAxisLabel: String {
        String.localizedStringWithFormat(
            String(localized: "chart.axis.concentration_format"),
            sim.displayMetadata.hormone.displayName
        )
    }

    private var currentHour: Double {
        now.timeIntervalSince1970 / 3600.0
    }

    private var chartAccentColor: Color {
        sim.displayMetadata.hormone.chartColor
    }

    private var totalDomain: ClosedRange<Double> {
        guard let first = sim.timeH.first, let last = sim.timeH.last else {
            let fallback = currentHour
            return fallback...fallback
        }
        return first...last
    }

    private var visibleDomain: ClosedRange<Double> {
        let leading = clampedLeadingHour(scrollPosition, visibleLength: visibleDomainLength)
        return leading...(leading + visibleDomainLength)
    }

    private var interactiveHour: Double? {
        hoveredHour ?? selectedHour
    }

    private var displayHour: Double? {
        interactiveHour ?? currentHour
    }

    private var visibleInteractiveHour: Double? {
        guard let interactiveHour, visibleDomain.contains(interactiveHour) else {
            return nil
        }
        return interactiveHour
    }

    private var displayPoint: ResultChartPoint? {
        guard let hour = displayHour,
              let concentration = sim.concentration(at: hour) else {
            return nil
        }
        return ResultChartPoint(hour: hour, concentration: concentration)
    }

    private var currentConcentrationText: String {
        guard let value = sim.concentration(at: currentHour) else {
            return "—"
        }
        return ResultChartFormatter.concentrationLabel(for: value, unit: sim.concentrationUnit)
    }

    private var currentConcentrationAccessibilityText: String {
        let hormoneName = sim.displayMetadata.hormone.displayName
        guard let value = sim.concentration(at: currentHour) else {
            return String.localizedStringWithFormat(
                String(localized: "chart.currentConc.missing"),
                hormoneName
            )
        }

        let formattedValue = ResultChartFormatter.concentrationLabel(for: value, unit: sim.concentrationUnit)
        return String.localizedStringWithFormat(
            String(localized: "chart.currentConc.value"),
            hormoneName,
            formattedValue
        )
    }

    private var chartAccessibilityLabel: String {
        String.localizedStringWithFormat(
            String(localized: "chart.accessibility"),
            sim.displayMetadata.hormone.displayName,
            sim.concentrationUnit.symbol
        )
    }

    private var axisStepHours: Double {
        ResultChartFormatter.axisStep(for: visibleDomainLength, targetLabelCount: isPad ? 6 : 4)
    }

    private var minVisibleDomainLength: Double {
        isPad ? 12 : 8
    }

    private var maxVisibleDomainLength: Double {
        max(totalDomain.upperBound - totalDomain.lowerBound, minVisibleDomainLength)
    }

    private var isInteracting: Bool {
        panBaselineScrollPosition != nil || magnifyBaseline != nil
    }

    private var visibleChartWindow: ResultChartWindow {
        guard !chartPoints.isEmpty else {
            return ResultChartWindow(
                points: ArraySlice<ResultChartPoint>(),
                labPoints: [],
                yAxisDomain: ResultChartScale.yAxisDomain(forMaximum: chartMaxConcentration)
            )
        }

        let firstVisibleIndex = firstPointIndex(atOrAfter: visibleDomain.lowerBound)
        let lastVisibleIndex = firstPointIndex(after: visibleDomain.upperBound)
        let sliceStart = max(firstVisibleIndex - 1, chartPoints.startIndex)
        let sliceEnd = min(max(lastVisibleIndex + 1, sliceStart + 1), chartPoints.endIndex)
        let visiblePoints = chartPoints[sliceStart..<sliceEnd]
        let visibleLabPoints = labPoints.filter { visibleDomain.contains($0.hour) }

        // Read slightly beyond the visible window so the Y axis can adapt to
        // nearby peaks before they enter the plot instead of jumping at an edge.
        let contextDomain = ResultChartScale.contextDomain(
            around: visibleDomain,
            within: totalDomain
        )
        let contextLabPoints = labPoints.map {
            ResultChartScaleSample(hour: $0.hour, concentration: $0.concentration)
        }
        let boundaryConcentrations = [
            sim.concentration(at: contextDomain.lowerBound),
            sim.concentration(at: contextDomain.upperBound)
        ]
        .compactMap { $0 }
        let maxConcentration = ResultChartScale.maximumValidConcentration(
            predicted: chartPoints,
            measured: contextLabPoints,
            in: contextDomain,
            boundaryConcentrations: boundaryConcentrations
        ) ?? 0

        return ResultChartWindow(
            points: visiblePoints,
            labPoints: visibleLabPoints,
            yAxisDomain: ResultChartScale.yAxisDomain(forMaximum: maxConcentration)
        )
    }

    private var chartInterpolationMethod: InterpolationMethod {
        .catmullRom
    }

    private var xAxisValues: [Double] {
        let start = ceil(visibleDomain.lowerBound / axisStepHours) * axisStepHours
        let end = visibleDomain.upperBound

        var values: [Double] = []
        var current = start
        while current <= end + 0.001 {
            values.append(current)
            current += axisStepHours
        }

        if values.isEmpty {
            values.append(visibleDomain.lowerBound + visibleDomainLength / 2)
        }

        return values
    }

    private var chartHeight: CGFloat {
        if let preferredChartHeight {
            return preferredChartHeight
        }

        if dynamicTypeSize.isAccessibilitySize {
            return isPad ? 380 : 340
        }
        return isPad ? 320 : 260
    }

    private var shouldShowUnitMenu: Bool {
        availableUnits.count > 1 && onSelectUnit != nil
    }

    private var unitMenuForegroundColor: Color {
        Color(uiColor: .label)
    }

    private var unitMenuBackgroundColor: Color {
        chartAccentColor.opacity(0.12)
    }

    private var unitMenuBorderColor: Color {
        chartAccentColor.opacity(0.28)
    }

    @ViewBuilder
    private var unitMenu: some View {
        if shouldShowUnitMenu, let onSelectUnit {
            Menu {
                Picker(
                    String(localized: "chart.unit.title"),
                    selection: Binding(
                        get: { sim.concentrationUnit },
                        set: { newValue in
                            guard newValue != sim.concentrationUnit else { return }
                            onSelectUnit(newValue)
                        }
                    )
                ) {
                    ForEach(availableUnits, id: \.self) { unit in
                        Text(unit.localizedLabel).tag(unit)
                    }
                }
            } label: {
                Label {
                    Text(sim.concentrationUnit.localizedLabel)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .font(dynamicTypeSize.isAccessibilitySize ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(unitMenuForegroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(unitMenuBackgroundColor))
                .overlay(
                    Capsule()
                        .stroke(unitMenuBorderColor, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chart.unit.accessibility"))
        }
    }

    private var chartHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chartTitle)
                        .font(.headline)
                    Text(currentConcentrationText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(currentConcentrationAccessibilityText))
                }
                Spacer(minLength: 0)
                unitMenu
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(chartTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                    unitMenu
                }

                Text(currentConcentrationText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(currentConcentrationAccessibilityText))
            }
        }
        .padding(.horizontal)
    }

    private var concentrationChart: some View {
        let window = visibleChartWindow

        return Chart {
            areaMarks(points: window.points)
            lineMarks(points: window.points)
            labPointMarks(points: window.labPoints)
            focusMarks
        }
        .chartXScale(domain: visibleDomain)
        .chartYScale(domain: window.yAxisDomain)
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        if shouldHideAxisLabel(at: hour) {
                            EmptyView()
                        } else {
                            Text(ResultChartFormatter.axisLabel(for: hour, visibleHours: visibleDomainLength))
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? (isPad ? 5 : 4) : (isPad ? 6 : 5))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let concentration = value.as(Double.self) {
                        Text(ResultChartFormatter.yAxisLabel(for: concentration, unit: sim.concentrationUnit))
                            .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = plotFrame(for: proxy, in: geometry) {

                    ZStack(alignment: .topLeading) {
                        ResultChartInteractionSurface(
                            plotFrame: plotFrame,
                            isHoverEnabled: isPad,
                            onTap: { location in
                                selectedHour = hour(at: location, in: plotFrame)
                            },
                            onHover: { location in
                                hoveredHour = location.flatMap { hour(at: $0, in: plotFrame) }
                            },
                            onPanBegan: { _ in
                                beginPanInteraction()
                            },
                            onPanChanged: { translation in
                                updatePanInteraction(with: translation, plotFrame: plotFrame)
                            },
                            onPanEnded: {
                                endPanInteraction()
                            },
                            onMagnifyBegan: { location in
                                beginMagnifyInteraction(at: location)
                            },
                            onMagnifyChanged: { magnification, location in
                                updateMagnifyInteraction(magnification: magnification, anchorLocation: location, plotFrame: plotFrame)
                            },
                            onMagnifyEnded: {
                                endMagnifyInteraction()
                            }
                        )
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        if let visibleInteractiveHour {
                            ResultChartBadge(text: ResultChartFormatter.cursorTimeLabel(for: visibleInteractiveHour))
                                .position(
                                    x: plotFrame.minX + xPosition(for: visibleInteractiveHour, plotFrame: plotFrame),
                                    y: plotFrame.maxY + 16
                                )
                        }
                    }
                }
            }
        }
        .frame(minHeight: chartHeight)
    }

    private func plotFrame(for proxy: ChartProxy, in geometry: GeometryProxy) -> CGRect? {
        if #available(iOS 17.0, *) {
            return proxy.plotFrame.map { geometry[$0] }
        }

        return geometry[proxy.plotAreaFrame]
    }

    @ChartContentBuilder
    private func areaMarks(points: ArraySlice<ResultChartPoint>) -> some ChartContent {
        ForEach(points) { point in
            AreaMark(
                x: .value(xAxisLabel, point.hour),
                y: .value(yAxisLabel, point.concentration)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [chartAccentColor.opacity(0.28), chartAccentColor.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(chartInterpolationMethod)
        }
    }

    @ChartContentBuilder
    private func lineMarks(points: ArraySlice<ResultChartPoint>) -> some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value(xAxisLabel, point.hour),
                y: .value(yAxisLabel, point.concentration)
            )
            .interpolationMethod(chartInterpolationMethod)
            .foregroundStyle(chartAccentColor)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private func labPointMarks(points: [ResultChartLabPoint]) -> some ChartContent {
        ForEach(points) { point in
            PointMark(
                x: .value(xAxisLabel, point.hour),
                y: .value(yAxisLabel, point.concentration)
            )
            .symbolSize(120)
            .foregroundStyle(Color.orange)
            .symbol {
                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 11, height: 11)
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 15, height: 15)
                }
            }
        }
    }

    @ChartContentBuilder
    private var focusMarks: some ChartContent {
        if let point = displayPoint {
            let labPoint = nearestLabPoint(to: point.hour)
            RuleMark(x: .value(xAxisLabel, point.hour))
                .lineStyle(ruleLineStyle)
                .foregroundStyle(Color.primary.opacity(interactiveHour == nil ? 0.7 : 0.85))

            PointMark(
                x: .value(xAxisLabel, point.hour),
                y: .value(yAxisLabel, point.concentration)
            )
            .symbolSize(80)
            .symbol {
                ZStack {
                    Circle().fill(chartAccentColor).frame(width: 12, height: 12)
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
            .annotation(position: .top) {
                ResultChartBadge(text: focusBadgeText(predicted: point, lab: labPoint))
                    .fixedSize()
            }
        }
    }

    private var ruleLineStyle: StrokeStyle {
        interactiveHour == nil ? StrokeStyle(lineWidth: 1, dash: [4, 4]) : StrokeStyle(lineWidth: 1.2)
    }

    private func nearestLabPoint(to hour: Double) -> ResultChartLabPoint? {
        let threshold = max(1.0, visibleDomainLength * 0.02)
        return labPoints
            .filter { abs($0.hour - hour) <= threshold }
            .min { abs($0.hour - hour) < abs($1.hour - hour) }
    }

    private func focusBadgeText(predicted point: ResultChartPoint, lab: ResultChartLabPoint?) -> String {
        let predictedText = ResultChartFormatter.concentrationLabel(
            for: point.concentration,
            unit: sim.concentrationUnit
        )
        guard let lab else {
            return "Predicted \(predictedText)"
        }

        let labText = ResultChartFormatter.concentrationLabel(
            for: lab.concentration,
            unit: sim.concentrationUnit
        )
        return "Predicted \(predictedText)\nLab \(lab.name): \(labText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chartHeader

            concentrationChart
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(chartAccessibilityLabel))
        }
        .animation(.easeInOut(duration: 0.18), value: displayHour)
        .transaction { transaction in
            if isInteracting {
                transaction.animation = nil
            }
        }
        .onAppear {
            visibleDomainLength = defaultVisibleDomainLength
            scrollPosition = clampedLeadingHour(currentHour - visibleDomainLength / 2, visibleLength: visibleDomainLength)
        }
        .onReceive(timer) { date in
            now = date
        }
        .onChange(of: sim.timeH.first) { _ in
            visibleDomainLength = min(max(visibleDomainLength, minVisibleDomainLength), maxVisibleDomainLength)
            scrollPosition = clampedLeadingHour(currentHour - visibleDomainLength / 2, visibleLength: visibleDomainLength)
        }
    }

    private var defaultVisibleDomainLength: Double {
        isPad ? 72 : 36
    }

    private func shouldHideAxisLabel(at hour: Double) -> Bool {
        guard let visibleInteractiveHour else { return false }
        return abs(visibleInteractiveHour - hour) < axisStepHours * 0.45
    }

    private func firstPointIndex(atOrAfter hour: Double) -> Int {
        var low = chartPoints.startIndex
        var high = chartPoints.endIndex

        while low < high {
            let mid = (low + high) / 2
            if chartPoints[mid].hour < hour {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func firstPointIndex(after hour: Double) -> Int {
        var low = chartPoints.startIndex
        var high = chartPoints.endIndex

        while low < high {
            let mid = (low + high) / 2
            if chartPoints[mid].hour <= hour {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func hour(at location: CGPoint, in plotFrame: CGRect) -> Double? {
        guard plotFrame.contains(location), plotFrame.width > 0 else {
            return nil
        }

        let plotX = location.x - plotFrame.minX
        let clampedX = min(max(plotX, 0), plotFrame.width)
        let progress = Double(clampedX / plotFrame.width)
        let hour = visibleDomain.lowerBound + progress * visibleDomainLength
        return min(max(hour, totalDomain.lowerBound), totalDomain.upperBound)
    }

    private func xPosition(for hour: Double, plotFrame: CGRect) -> CGFloat {
        guard visibleDomainLength > 0 else { return 0 }
        let progress = (hour - visibleDomain.lowerBound) / visibleDomainLength
        return CGFloat(min(max(progress, 0), 1)) * plotFrame.width
    }

    private func zoomAnchor(at location: CGPoint?, in plotFrame: CGRect) -> ResultChartZoomAnchor {
        if let location,
           let hour = hour(at: location, in: plotFrame),
           plotFrame.width > 0 {
            let plotX = min(max(location.x - plotFrame.minX, 0), plotFrame.width)
            let relativePosition = Double(plotX / plotFrame.width)
            return ResultChartZoomAnchor(hour: hour, relativePosition: relativePosition)
        }

        if let interactiveHour {
            let relativePosition = (interactiveHour - visibleDomain.lowerBound) / visibleDomainLength
            return ResultChartZoomAnchor(
                hour: interactiveHour,
                relativePosition: min(max(relativePosition, 0), 1)
            )
        }

        return ResultChartZoomAnchor(
            hour: visibleDomain.lowerBound + visibleDomainLength / 2,
            relativePosition: 0.5
        )
    }

    private func beginPanInteraction() {
        hoveredHour = nil
        if panBaselineScrollPosition == nil {
            panBaselineScrollPosition = clampedLeadingHour(scrollPosition, visibleLength: visibleDomainLength)
        }
    }

    private func updatePanInteraction(with translation: CGSize, plotFrame: CGRect) {
        guard plotFrame.width > 0 else { return }
        let baseline = panBaselineScrollPosition ?? clampedLeadingHour(scrollPosition, visibleLength: visibleDomainLength)
        let deltaHours = Double(translation.width / plotFrame.width) * visibleDomainLength
        scrollPosition = clampedLeadingHour(baseline - deltaHours, visibleLength: visibleDomainLength)
    }

    private func endPanInteraction() {
        panBaselineScrollPosition = nil
    }

    private func beginMagnifyInteraction(at _: CGPoint) {
        hoveredHour = nil
        if magnifyBaseline == nil {
            magnifyBaseline = visibleDomainLength
        }
    }

    private func updateMagnifyInteraction(magnification: CGFloat, anchorLocation: CGPoint, plotFrame: CGRect) {
        let baseline = magnifyBaseline ?? visibleDomainLength
        let nextLength = min(
            max(baseline / Double(magnification), minVisibleDomainLength),
            maxVisibleDomainLength
        )
        let anchor = zoomAnchor(at: anchorLocation, in: plotFrame)
        updateVisibleDomainLength(to: nextLength, anchor: anchor)
    }

    private func endMagnifyInteraction() {
        magnifyBaseline = nil
    }

    private func updateVisibleDomainLength(to newValue: Double, anchor: ResultChartZoomAnchor? = nil) {
        let clampedLength = min(max(newValue, minVisibleDomainLength), maxVisibleDomainLength)
        let anchor = anchor ?? ResultChartZoomAnchor(
            hour: visibleDomain.lowerBound + visibleDomainLength / 2,
            relativePosition: 0.5
        )
        visibleDomainLength = clampedLength
        scrollPosition = clampedLeadingHour(
            anchor.hour - anchor.relativePosition * clampedLength,
            visibleLength: clampedLength
        )
    }

    private func clampedLeadingHour(_ candidate: Double, visibleLength: Double) -> Double {
        let totalSpan = totalDomain.upperBound - totalDomain.lowerBound
        guard totalSpan > visibleLength else { return totalDomain.lowerBound }
        return min(max(candidate, totalDomain.lowerBound), totalDomain.upperBound - visibleLength)
    }
}

private enum ResultChartFormatter {
    static func concentrationLabel(for concentration: Double, unit: ConcentrationUnit) -> String {
        String(format: "%.1f %@", locale: Locale.current, concentration, unit.symbol)
    }

    static func yAxisLabel(for concentration: Double, unit: ConcentrationUnit) -> String {
        let magnitude = abs(concentration)
        let fractionDigits: Int
        if magnitude == 0 || magnitude >= 10 {
            fractionDigits = 0
        } else if magnitude >= 1 {
            fractionDigits = 1
        } else if magnitude >= 0.1 {
            fractionDigits = 2
        } else if magnitude >= 0.01 {
            fractionDigits = 3
        } else {
            fractionDigits = 4
        }

        return String(
            format: "%.*f %@",
            locale: Locale.current,
            fractionDigits,
            concentration,
            unit.symbol
        )
    }

    static func axisStep(for visibleHours: Double, targetLabelCount: Int) -> Double {
        let targetStep = max(visibleHours / Double(max(targetLabelCount, 1)), 6)
        let preferredSteps: [Double] = [6, 12, 24, 48, 72, 96, 168, 240, 336, 504, 720]
        if let step = preferredSteps.first(where: { $0 >= targetStep }) {
            return step
        }
        return ceil(targetStep / 168) * 168
    }

    static func axisLabel(for hour: Double, visibleHours: Double) -> String {
        let date = Date(timeIntervalSince1970: hour * 3600.0)
        let components = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let clockHour = components.hour ?? 0

        if visibleHours < 48 {
            return String(format: "%d/%d\n%02d:00", locale: Locale.current, month, day, clockHour)
        }
        return String(format: "%d/%d", locale: Locale.current, month, day)
    }

    static func cursorTimeLabel(for hour: Double) -> String {
        let date = Date(timeIntervalSince1970: hour * 3600.0)
        let components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let clockHour = components.hour ?? 0
        let minute = components.minute ?? 0
        return String(format: "%d/%d %02d:%02d", locale: Locale.current, month, day, clockHour, minute)
    }
}
