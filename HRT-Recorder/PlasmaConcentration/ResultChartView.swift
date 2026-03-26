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

struct ResultChartView: View {
    let sim: SimulationResult
    private let chartPoints: [ResultChartPoint]
    private let chartMaxConcentration: Double

    @State private var visibleDomainLength: Double = 48
    @State private var now: Date = Date()
    @State private var scrollPosition: Double = 0
    @State private var selectedHour: Double?
    @State private var hoveredHour: Double?
    @State private var magnifyBaseline: Double?
    @State private var panBaselineScrollPosition: Double?
    @State private var frozenYAxisDomain: ClosedRange<Double>?

    private let timer = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()

    init(sim: SimulationResult) {
        self.sim = sim

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
        isPad ? 320 : 260
    }

    private var concentrationChart: some View {
        let window = visibleChartWindow
        let displayedYAxisDomain = frozenYAxisDomain ?? window.yAxisDomain

        return Chart {
            areaMarks(points: window.points)
            lineMarks(points: window.points)
            focusMarks
        }
        .chartXScale(domain: visibleDomain)
        .chartYScale(domain: displayedYAxisDomain)
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
            AxisMarks(position: .leading, values: .automatic(desiredCount: isPad ? 6 : 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let concentration = value.as(Double.self) {
                        Text(ResultChartFormatter.yAxisLabel(for: concentration))
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrameAnchor = proxy.plotFrame {
                    let plotFrame = geometry[plotFrameAnchor]

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .highPriorityGesture(panGesture(plotFrame: plotFrame))
                            .simultaneousGesture(selectionTapGesture(proxy: proxy, plotFrame: plotFrame))
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                guard isPad else { return }
                                switch phase {
                                case .active(let location):
                                    hoveredHour = chartHour(at: location, plotFrame: plotFrame, proxy: proxy)
                                case .ended:
                                    hoveredHour = nil
                                }
                            }

                        if let visibleInteractiveHour {
                            ResultChartBadge(text: ResultChartFormatter.cursorTimeLabel(for: visibleInteractiveHour))
                                .position(
                                    x: plotFrame.minX + xPosition(for: visibleInteractiveHour, proxy: proxy),
                                    y: plotFrame.maxY + 16
                                )
                        }
                    }
                }
            }
        }
        .simultaneousGesture(magnifyGesture)
        .frame(minHeight: chartHeight)
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
        .onChange(of: sim.timeH.first) {
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

    private func beginChartInteraction() {
        if frozenYAxisDomain == nil {
            frozenYAxisDomain = visibleChartWindow.yAxisDomain
        }
    }

    private func endChartInteractionIfNeeded() {
        if panBaselineScrollPosition == nil && magnifyBaseline == nil {
            frozenYAxisDomain = nil
        }
    }

    private func chartHour(at location: CGPoint, plotFrame: CGRect, proxy: ChartProxy) -> Double? {
        guard plotFrame.contains(location) else {
            return nil
        }

        let plotX = location.x - plotFrame.minX
        let clampedX = min(max(plotX, 0), proxy.plotSize.width)
        guard let hour = proxy.value(atX: clampedX, as: Double.self) else {
            return nil
        }
        return min(max(hour, totalDomain.lowerBound), totalDomain.upperBound)
    }

    private func xPosition(for hour: Double, proxy: ChartProxy) -> CGFloat {
        proxy.position(forX: hour) ?? 0
    }

    private func selectionTapGesture(proxy: ChartProxy, plotFrame: CGRect) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if let hour = chartHour(at: value.location, plotFrame: plotFrame, proxy: proxy) {
                    selectedHour = hour
                }
            }
    }

    private func panGesture(plotFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard plotFrame.contains(value.startLocation) else { return }
                hoveredHour = nil
                let baseline = panBaselineScrollPosition ?? clampedLeadingHour(scrollPosition, visibleLength: visibleDomainLength)
                if panBaselineScrollPosition == nil {
                    panBaselineScrollPosition = baseline
                    beginChartInteraction()
                }

                let deltaHours = Double(value.translation.width / plotFrame.width) * visibleDomainLength
                scrollPosition = clampedLeadingHour(baseline - deltaHours, visibleLength: visibleDomainLength)
            }
            .onEnded { _ in
                panBaselineScrollPosition = nil
                endChartInteractionIfNeeded()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let baseline = magnifyBaseline ?? visibleDomainLength
                if magnifyBaseline == nil {
                    magnifyBaseline = visibleDomainLength
                    beginChartInteraction()
                }

                let nextLength = min(
                    max(baseline / Double(value.magnification), minVisibleDomainLength),
                    maxVisibleDomainLength
                )
                updateVisibleDomainLength(to: nextLength)
            }
            .onEnded { _ in
                magnifyBaseline = nil
                endChartInteractionIfNeeded()
            }
    }

    private func updateVisibleDomainLength(to newValue: Double) {
        let clampedLength = min(max(newValue, minVisibleDomainLength), maxVisibleDomainLength)
        let center = visibleInteractiveHour ?? (visibleDomain.lowerBound + visibleDomainLength / 2)
        visibleDomainLength = clampedLength
        scrollPosition = clampedLeadingHour(center - clampedLength / 2, visibleLength: clampedLength)
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
