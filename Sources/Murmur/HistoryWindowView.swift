import AppKit
import SwiftUI

struct HistoryWindowView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    @State private var tab: Tab = .history

    enum Tab: String, CaseIterable {
        case history = "History"
        case scratchpad = "Scratchpad"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .history: historyList
            case .scratchpad: scratchpad
            }
        }
    }

    private var filtered: [HistoryEntry] {
        let entries = controller.history.entries
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.finalText.localizedCaseInsensitiveContains(search)
                || ($0.appName?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            TextField("Search dictations…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            if filtered.isEmpty {
                Spacer()
                Text(search.isEmpty ? "Dictations will appear here." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.finalText)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(entry.date, style: .time)
                            if let app = entry.appName {
                                Text("→ \(app)")
                            }
                            Text(outcomeLabel(entry.outcome))
                                .foregroundStyle(entry.outcome.hasPrefix("history-only") ? .orange : .secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.finalText, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "ax": return "inserted"
        case "paste": return "pasted"
        case "applescript": return "typed"
        default: return "not inserted"
        }
    }

    private var scratchpad: some View {
        TextEditor(text: Binding(
            get: { controller.history.scratchpad },
            set: { controller.history.scratchpad = $0 }
        ))
        .font(.body)
        .padding(8)
    }
}
