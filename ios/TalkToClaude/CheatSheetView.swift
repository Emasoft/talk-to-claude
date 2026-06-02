import SwiftUI

struct CheatItem: Identifiable {
    let id = UUID()
    let say: String        // the spoken phrase (yellow chip)
    let out: String        // the literal output it types (blue chip)
    let label: String
    let triggers: [String]
}

struct CheatGroup: Identifiable {
    let id = UUID()
    let group: String
    let items: [CheatItem]

    /// Parse one group from the server's `{type:"cheatsheet"}` payload. Tolerant of
    /// older payloads that lack `say`/`out` (falls back to triggers/label).
    static func from(json: [String: Any]) -> CheatGroup? {
        guard let group = json["group"] as? String,
              let rawItems = json["items"] as? [[String: Any]] else { return nil }
        let items = rawItems.compactMap { it -> CheatItem? in
            let triggers = it["triggers"] as? [String] ?? []
            let label = it["label"] as? String ?? ""
            let say = it["say"] as? String ?? triggers.first ?? label
            let out = it["out"] as? String ?? label
            guard !say.isEmpty else { return nil }
            return CheatItem(say: say, out: out, label: label, triggers: triggers)
        }
        return CheatGroup(group: group, items: items)
    }
}

/// Searchable list of every voice command, served by the Mac (so it always
/// matches what's actually wired in).
struct CheatSheetView: View {
    let groups: [CheatGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [CheatGroup] {
        guard !query.isEmpty else { return groups }
        let q = query.lowercased()
        return groups.compactMap { group in
            let items = group.items.filter { item in
                item.label.lowercased().contains(q)
                    || item.triggers.contains { $0.lowercased().contains(q) }
            }
            return items.isEmpty ? nil : CheatGroup(group: group.group, items: items)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "Connect to load commands",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Tap the mic to connect; the Mac sends the command list.")
                    )
                } else {
                    List {
                        ForEach(filtered) { group in
                            Section(group.group.capitalized) {
                                ForEach(group.items) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.label)
                                            .font(.body.monospaced())
                                        Text(item.triggers.prefix(6).joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Search commands (e.g. invio, parentesi, spell)")
                }
            }
            .navigationTitle("Voice commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
