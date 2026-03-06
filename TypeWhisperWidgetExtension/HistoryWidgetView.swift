import SwiftUI
import WidgetKit

struct HistoryWidgetView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stats row
            HStack(spacing: 16) {
                Label("\(data.stats.wordsToday) words today", systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(data.stats.timeSavedToday + " saved", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // History list
            if data.recentHistory.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "mic.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No transcriptions yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.recentHistory) { item in
                        HistoryRow(item: item)
                        if item.id != data.recentHistory.last?.id {
                            Divider()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct HistoryRow: View {
    let item: WidgetHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let appName = item.appName {
                    Text(appName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.timestamp, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text(item.preview)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}
