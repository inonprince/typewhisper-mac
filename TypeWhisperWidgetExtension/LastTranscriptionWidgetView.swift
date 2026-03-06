import SwiftUI
import WidgetKit

struct LastTranscriptionWidgetView: View {
    let item: WidgetHistoryItem?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let appName = item.appName {
                        Text(appName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(item.preview)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                Spacer()

                HStack {
                    Image(systemName: "text.word.spacing")
                        .font(.caption2)
                    Text("\(item.wordsCount) words")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "mic.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No transcriptions yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
