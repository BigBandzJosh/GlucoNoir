//
//  StatisticsView.swift
//  GlucoNoir
//

import SwiftUI

struct StatisticsView: View {
    let stats: GlucoseStatistics
    let unit: GlucoseUnit
    let window: ChartWindow
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if stats.readingCount == 0 {
                Text("No readings in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            } else {
                rangeBar
                bandLegend
                metrics
                caveats
            }
        }
    }

    // MARK: Distribution bar

    /// Stacked proportional bar. Ordered low at the bottom to match how an AGP
    /// report presents the same distribution.
    private var rangeBar: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(orderedBands, id: \.self) { band in
                    let fraction = stats.fraction(band)
                    if fraction > 0 {
                        palette.color(for: band)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 10)
    }

    private var orderedBands: [GlycemicBand] {
        [.veryLow, .low, .inRange, .high, .veryHigh]
    }

    private var bandLegend: some View {
        VStack(spacing: 5) {
            ForEach(orderedBands, id: \.self) { band in
                let fraction = stats.fraction(band)
                if fraction > 0 || band == .inRange {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(palette.color(for: band))
                            .frame(width: 7, height: 7)
                        Text(band.label)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                        Spacer()
                        Text(GlucoseStatistics.percent(fraction))
                            .font(.system(size: 12, weight: band == .inRange ? .semibold : .regular,
                                          design: .monospaced))
                            .foregroundStyle(band == .inRange ? palette.textPrimary : palette.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            metric("Average", stats.meanDisplay(unit), unit.label)
            metric("CV", stats.cvDisplay, stats.meetsCVTarget ? "target met" : "target <36%",
                   highlight: !stats.meetsCVTarget)
            if let gmi = stats.gmiDisplay {
                metric("GMI", gmi, "est. A1C")
            } else {
                metric("SD", stats.sdDisplay(unit), unit.label)
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ caption: String,
                        highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.textSecondary.opacity(0.7))
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(highlight ? palette.rangeHigh : palette.textPrimary)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(palette.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Caveats

    /// Statistics from a sparse or short window are unreliable, and saying so
    /// is more useful than quietly presenting a confident-looking number.
    @ViewBuilder
    private var caveats: some View {
        if !stats.isReliable {
            caveat("Based on \(GlucoseStatistics.percent(stats.coverage)) of expected readings — treat these figures as indicative.")
        }
        if stats.gmi == nil && window.duration >= GlucoseStatistics.gmiMinimumDuration {
            caveat("GMI needs 70% coverage over 14 days.")
        } else if stats.gmi == nil {
            caveat("GMI appears on windows of 14 days or longer.")
        }
    }

    private func caveat(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(palette.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }
}
