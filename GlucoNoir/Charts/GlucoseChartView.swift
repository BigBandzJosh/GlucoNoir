//
//  GlucoseChartView.swift
//  GlucoNoir
//

import SwiftUI
import Charts

struct GlucoseChartView: View {
    let readings: [ShareGlucoseReading]
    let unit: GlucoseUnit
    let window: ChartWindow
    let palette: Palette

    // Computed once at init, not in the view body. Segment building
    // downsamples and sorts; at 30 days that is ~8,600 readings, and a body
    // recomputation triggered by an unrelated one-second timer would redo all
    // of it every tick.
    private let segments: [ChartSegment]
    private let yDomain: ClosedRange<Double>

    init(readings: [ShareGlucoseReading], unit: GlucoseUnit, window: ChartWindow, palette: Palette) {
        self.readings = readings
        self.unit = unit
        self.window = window
        self.palette = palette

        // Scale the gap threshold with the window: at 30 days an 11-minute
        // break is sub-pixel, and splitting on it would produce thousands of
        // one-point segments and no visible line.
        let threshold = max(ChartDataBuilder.gapThreshold, window.duration / 120)
        self.segments = ChartDataBuilder.segments(from: readings, unit: unit, gapThreshold: threshold)
        self.yDomain = ChartDataBuilder.yDomain(for: readings, unit: unit)
    }

    private var xDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-window.duration)...now
    }

    private var targetLow: Double { ChartDataBuilder.displayValue(TargetRange.lowMgdl, unit) }
    private var targetHigh: Double { ChartDataBuilder.displayValue(TargetRange.highMgdl, unit) }

    var body: some View {
        Chart {
            // Target range band, drawn behind everything.
            RectangleMark(
                xStart: .value("Start", xDomain.lowerBound),
                xEnd: .value("End", xDomain.upperBound),
                yStart: .value("Low", targetLow),
                yEnd: .value("High", targetHigh)
            )
            .foregroundStyle(palette.rangeIn.opacity(0.10))

            RuleMark(y: .value("Low", targetLow))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(palette.textSecondary.opacity(0.35))
            RuleMark(y: .value("High", targetHigh))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(palette.textSecondary.opacity(0.35))

            // One series per gap-free run, so the line breaks where data is
            // genuinely missing rather than inventing a path across it.
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Glucose", point.value),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(palette.textPrimary.opacity(0.85))
                }
            }

            // Points carry the range colouring; a single-hue line stays readable
            // while excursions remain obvious.
            ForEach(showsPoints ? segments : []) { segment in
                ForEach(segment.points) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Glucose", point.value)
                    )
                    .symbolSize(pointSize)
                    .foregroundStyle(palette.color(forGlucose: point.valueMgdl))
                }
            }

            // Emphasise the newest reading.
            if let last = segments.last?.points.last {
                PointMark(
                    x: .value("Time", last.date),
                    y: .value("Glucose", last.value)
                )
                .symbolSize(90)
                .foregroundStyle(palette.color(forGlucose: last.valueMgdl))
                .annotation(position: .top, spacing: 4) {
                    Text(unit.format(last.valueMgdl))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.color(forGlucose: last.valueMgdl))
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(palette.textSecondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(unit == .mmolL ? String(format: "%.1f", v) : String(Int(v)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: window.axisStride.component, count: window.axisStride.count)) { value in
                AxisGridLine().foregroundStyle(palette.textSecondary.opacity(0.15))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: window.isMultiDay
                             ? .dateTime.day().month(.abbreviated)
                             : .dateTime.hour().minute())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Glucose over the last \(window.label)")
        .accessibilityValue(accessibilitySummary)
    }

    /// Denser windows need smaller points to stay legible.
    private var pointSize: CGFloat {
        switch window {
        case .h3: return 22
        case .h6: return 14
        case .h12: return 8
        case .h24: return 5
        // Multi-day windows are dense enough that markers become noise; the
        // line alone carries the shape.
        case .d7, .d14, .d30: return 0
        }
    }

    private var showsPoints: Bool { pointSize > 0 }

    /// Swift Charts is opaque to VoiceOver by default.
    private var accessibilitySummary: String {
        guard let newest = readings.max(by: { $0.sampleTime < $1.sampleTime }) else {
            return "No readings"
        }
        let values = readings.map(\.valueMgdl)
        guard let lo = values.min(), let hi = values.max() else { return "No readings" }
        return "Latest \(unit.format(newest.valueMgdl)) \(unit.label). "
             + "Range \(unit.format(lo)) to \(unit.format(hi)). "
             + "\(readings.count) readings."
    }
}
