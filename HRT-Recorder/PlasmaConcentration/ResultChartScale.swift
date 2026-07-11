//
//  ResultChartScale.swift
//  HRT-Recorder
//

import Foundation

struct ResultChartScaleSample: Identifiable {
    let hour: Double
    let concentration: Double

    var id: Double { hour }
}

enum ResultChartScale {
    nonisolated static func contextDomain(
        around visibleDomain: ClosedRange<Double>,
        within totalDomain: ClosedRange<Double>,
        contextFraction: Double = 0.25
    ) -> ClosedRange<Double> {
        let visibleLength = max(visibleDomain.upperBound - visibleDomain.lowerBound, 0)
        let contextLength = visibleLength * max(contextFraction, 0)
        let proposedLowerBound = visibleDomain.lowerBound - contextLength
        let proposedUpperBound = visibleDomain.upperBound + contextLength
        let lowerBound = min(max(proposedLowerBound, totalDomain.lowerBound), totalDomain.upperBound)
        let upperBound = min(max(proposedUpperBound, totalDomain.lowerBound), totalDomain.upperBound)
        return min(lowerBound, upperBound)...max(lowerBound, upperBound)
    }

    nonisolated static func maximumValidConcentration(
        predicted: [ResultChartScaleSample],
        measured: [ResultChartScaleSample],
        in domain: ClosedRange<Double>,
        boundaryConcentrations: [Double] = []
    ) -> Double? {
        let firstIndex = firstPointIndex(atOrAfter: domain.lowerBound, in: predicted)
        let endIndex = firstPointIndex(after: domain.upperBound, in: predicted)
        let predictedValues = predicted[firstIndex..<endIndex].lazy.map(\.concentration)
        let measuredValues = measured.lazy
            .filter { domain.contains($0.hour) }
            .map(\.concentration)

        return [
            maximumValidConcentration(in: predictedValues),
            maximumValidConcentration(in: measuredValues),
            maximumValidConcentration(in: boundaryConcentrations)
        ]
        .compactMap { $0 }
        .max()
    }

    nonisolated static func maximumValidConcentration<Predicted: Sequence, Measured: Sequence>(
        predicted: Predicted,
        measured: Measured
    ) -> Double? where Predicted.Element == Double, Measured.Element == Double {
        [
            maximumValidConcentration(in: predicted),
            maximumValidConcentration(in: measured)
        ]
        .compactMap { $0 }
        .max()
    }

    nonisolated static func yAxisDomain(forMaximum concentration: Double) -> ClosedRange<Double> {
        guard concentration.isFinite, concentration > 0 else {
            return 0...1
        }

        let paddedMaximum = concentration * 1.12
        let upperBound = paddedMaximum.isFinite
            ? max(paddedMaximum, concentration)
            : concentration
        return 0...upperBound
    }

    private nonisolated static func maximumValidConcentration<S: Sequence>(in values: S) -> Double?
    where S.Element == Double {
        values.lazy
            .filter { $0.isFinite && $0 >= 0 }
            .max()
    }

    private nonisolated static func firstPointIndex(
        atOrAfter hour: Double,
        in points: [ResultChartScaleSample]
    ) -> Int {
        var low = points.startIndex
        var high = points.endIndex

        while low < high {
            let mid = (low + high) / 2
            if points[mid].hour < hour {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private nonisolated static func firstPointIndex(
        after hour: Double,
        in points: [ResultChartScaleSample]
    ) -> Int {
        var low = points.startIndex
        var high = points.endIndex

        while low < high {
            let mid = (low + high) / 2
            if points[mid].hour <= hour {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
