import SwiftUI
import Charts
import WidgetKit

struct ChartWidgetView: View {
    let chartPoints: [WidgetChartPoint]
    let stats: WidgetStatsData

    var body: some View {
        HStack(spacing: 12) {
            // Chart
            VStack(alignment: .leading, spacing: 4) {
                Text("7-Day Activity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if chartPoints.isEmpty {
                    Spacer()
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Chart(chartPoints) { point in
                        BarMark(
                            x: .value("Day", point.dateLabel),
                            y: .value("Words", point.wordCount)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisValueLabel()
                                .font(.system(size: 8))
                        }
                    }
                    .chartYAxis(.hidden)
                }
            }
            .frame(maxWidth: .infinity)

            // Stats sidebar
            VStack(alignment: .leading, spacing: 10) {
                StatItem(label: "This Week", value: "\(stats.wordsThisWeek)")
                StatItem(label: "Avg WPM", value: stats.averageWPM)
                StatItem(label: "Apps", value: "\(stats.appsUsed)")
            }
            .frame(width: 80)
        }
    }
}

private struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .semibold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
