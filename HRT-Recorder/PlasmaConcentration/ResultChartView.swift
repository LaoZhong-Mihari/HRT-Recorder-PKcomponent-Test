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

private struct ResultChartPoint: Identifiable {
    let hour: Double
    let concentration: Double

    var id: Double { hour }
}

private struct ResultChartBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black))
    }
}

private struct ResultChartWindow {
    let points: ArraySlice<ResultChartPoint>
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
    private let chartPoints: [ResultChartPoint]
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

    init(sim: SimulationResult, preferredChartHeight: CGFloat? = nil) {
        self.sim = sim
        self.preferredChartHeight = preferredChartHeight

        let points = Array(zip(sim.timeH, sim.concPGmL)).map { hour, concentration in
            ResultChartPoint(hour: hour, concentration: concentration)
        }

        self.chartPoints = points
        self.chartMaxConcentration = points.lazy.map(\.concentration).max() ?? 0
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var xAxisLabel: String {
        NSLocalizedString("chart.axis.time", comment: "X-axis label")
    }

    private var yAxisLabel: String {
        NSLocalizedString("chart.axis.conc", comment: "Y-axis label")
    }

    private var currentHour: Double {
        now.timeIntervalSince1970 / 3600.0
    }

    private var chartAccentColor: Color {
        .pink
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
            return NSLocalizedString("chart.currentConc.missing", comment: "Current concentration unavailable")
        }
        let formatted = value.formatted(.number.precision(.fractionLength(1)))
        return String.localizedStringWithFormat(
            NSLocalizedString("chart.currentConc.value", comment: "Current concentration label"),
            formatted
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
                yAxisDomain: ResultChartFormatter.yAxisDomain(forMaximum: chartMaxConcentration)
            )
        }

        let firstVisibleIndex = firstPointIndex(atOrAfter: visibleDomain.lowerBound)
        let lastVisibleIndex = firstPointIndex(after: visibleDomain.upperBound)
        let sliceStart = max(firstVisibleIndex - 1, chartPoints.startIndex)
        let sliceEnd = min(max(lastVisibleIndex + 1, sliceStart + 1), chartPoints.endIndex)
        let visiblePoints = chartPoints[sliceStart..<sliceEnd]
        let maxConcentration = visiblePoints.lazy.map(\.concentration).max() ?? chartMaxConcentration

        return ResultChartWindow(
            points: visiblePoints,
            yAxisDomain: ResultChartFormatter.yAxisDomain(forMaximum: maxConcentration)
        )
    }

    private var chartInterpolationMethod: InterpolationMethod {
        isInteracting ? .linear : .catmullRom
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

    private var concentrationChart: some View {
        let window = visibleChartWindow

        return Chart {
            areaMarks(points: window.points)
            lineMarks(points: window.points)
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
                        Text(ResultChartFormatter.yAxisLabel(for: concentration))
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
    private var focusMarks: some ChartContent {
        if let point = displayPoint {
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
                ResultChartBadge(text: ResultChartFormatter.concentrationLabel(for: point.concentration))
                    .fixedSize()
            }
        }
    }

    private var ruleLineStyle: StrokeStyle {
        interactiveHour == nil ? StrokeStyle(lineWidth: 1, dash: [4, 4]) : StrokeStyle(lineWidth: 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("chart.title"))
                        .font(.headline)
                    Text(currentConcentrationText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(currentConcentrationText)
                }
                .padding(.horizontal)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LocalizedStringKey("chart.title"))
                            .font(.headline)
                        Spacer()
                        Text(currentConcentrationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(currentConcentrationText)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("chart.title"))
                            .font(.headline)
                        Text(currentConcentrationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(currentConcentrationText)
                    }
                }
                .padding(.horizontal)
            }

            concentrationChart
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(LocalizedStringKey("chart.accessibility")))
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
    static func concentrationLabel(for concentration: Double) -> String {
        String(format: "%.1f pg/mL", locale: Locale.current, concentration)
    }

    static func yAxisDomain(forMaximum concentration: Double) -> ClosedRange<Double> {
        let topBoundary = max(concentration, 50) * 1.1
        return 0...topBoundary
    }

    static func yAxisLabel(for concentration: Double) -> String {
        if concentration >= 10 {
            return String(format: "%.0f pg/mL", locale: Locale.current, concentration)
        }
        return String(format: "%.1f pg/mL", locale: Locale.current, concentration)
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
