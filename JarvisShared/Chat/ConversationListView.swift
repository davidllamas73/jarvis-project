import SwiftUI
import Foundation

/// Chat history grouped by recency, with search, rename and delete.
/// macOS: sidebar list with native selection. iOS: tappable rows inside the drawer.
struct ConversationListView: View {
    @EnvironmentObject private var store: ChatStore
    /// iOS drawer passes this to close itself after a pick.
    var onSelect: (() -> Void)? = nil

    @State private var search = ""
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        list
            .searchable(text: $search, prompt: "Search chats")
            .overlay {
                if store.conversations.isEmpty {
                    ContentUnavailableView("No chats yet",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your conversations with Jarvis show up here."))
                } else if sections.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .alert("Rename chat", isPresented: Binding(
                get: { renamingID != nil },
                set: { if !$0 { renamingID = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    if let id = renamingID { store.rename(id, to: renameText) }
                    renamingID = nil
                }
                Button("Cancel", role: .cancel) { renamingID = nil }
            }
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        List(selection: Binding(
            get: { store.selectedID },
            set: { if let id = $0 { store.select(id) } }
        )) {
            sectionedRows
        }
        .listStyle(.sidebar)
        #else
        List {
            sectionedRows
        }
        .listStyle(.plain)
        #endif
    }

    private var sectionedRows: some View {
        ForEach(sections, id: \.title) { section in
            Section(section.title) {
                ForEach(section.items) { convo in
                    row(convo)
                        .tag(convo.id)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                renameText = convo.title
                                renamingID = convo.id
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(convo.id)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(convo.id)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ convo: JarvisConversation) -> some View {
        #if os(macOS)
        rowLabel(convo)
        #else
        Button {
            store.select(convo.id)
            onSelect?()
        } label: {
            rowLabel(convo)
        }
        .buttonStyle(.plain)
        .listRowBackground(convo.id == store.selectedID ? Color.accentColor.opacity(0.12) : Color.clear)
        #endif
    }

    private func rowLabel(_ convo: JarvisConversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(convo.title)
                .lineLimit(1)
            if let preview = convo.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text {
                Text(preview.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Grouping

    private struct DaySection {
        let title: String
        let items: [JarvisConversation]
    }

    private var filtered: [JarvisConversation] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.conversations }
        return store.conversations.filter { convo in
            convo.title.localizedCaseInsensitiveContains(q)
                || convo.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [JarvisConversation])] = [
            ("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Older", [])
        ]
        for convo in filtered {
            let d = convo.updatedAt
            if cal.isDateInToday(d) {
                buckets[0].1.append(convo)
            } else if cal.isDateInYesterday(d) {
                buckets[1].1.append(convo)
            } else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 {
                buckets[2].1.append(convo)
            } else {
                buckets[3].1.append(convo)
            }
        }
        return buckets.filter { !$0.1.isEmpty }.map { DaySection(title: $0.0, items: $0.1) }
    }
}
