import AIListenerCore
import SwiftUI

// MARK: - SessionFavoritesStore

/// Local-only favorites: a `UserDefaults` set of session IDs.
///
/// Per XUC-12 scope, favorites do **not** modify `SessionStore` schema — the
/// underlying data source (`listPlayableSessions` / `SessionListItem`) stays
/// unchanged. This store is a thin observable wrapper so the sidebar can react
/// to favorite toggles and re-derive the filtered list.
@MainActor
final class SessionFavoritesStore: ObservableObject {
    @Published private(set) var favoriteIds: Set<String> = []

    private let defaults: UserDefaults
    private let key = "AIListener.favoriteSessionIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: key) as? [String] {
            favoriteIds = Set(raw)
        }
    }

    func isFavorite(_ sessionId: String) -> Bool {
        favoriteIds.contains(sessionId)
    }

    func toggle(_ sessionId: String) {
        if favoriteIds.contains(sessionId) {
            favoriteIds.remove(sessionId)
        } else {
            favoriteIds.insert(sessionId)
        }
        persist()
    }

    func setFavorite(_ sessionId: String, favorite: Bool) {
        if favorite {
            favoriteIds.insert(sessionId)
        } else {
            favoriteIds.remove(sessionId)
        }
        persist()
    }

    private func persist() {
        defaults.set(Array(favoriteIds), forKey: key)
    }
}

// MARK: - SidebarView

/// Left-column sidebar for the three-pane library layout (XUC-12).
///
/// Contains:
/// - A top search box bound to `searchText`.
/// - Navigation items (最近 / 全部 / 收藏 / 回收站) bound to `selectedFilter`.
/// - A bottom bar with a user avatar + a settings button that opens
///   `AISettingsView` via the `showingAISettings` binding (the settings view's
///   logic is unchanged — only its trigger source migrated here from the
///   app-level sheet).
///
/// Switching the navigation filter or typing in the search box drives the
/// middle-column session list via the shared bindings, which
/// `SessionLibraryView` consumes to re-filter `model.sessions`.
struct SidebarView: View {
    @Binding var searchText: String
    @Binding var selectedFilter: SidebarFilter
    @Binding var showingAISettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top search box.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索会话", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)

            // Navigation items.
            List(selection: $selectedFilter) {
                ForEach(SidebarFilter.allCases, id: \.self) { filter in
                    Label(filter.label, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .listStyle(.sidebar)

            // Bottom: user avatar + settings entry.
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地用户")
                        .font(.subheadline.weight(.medium))
                    Text("数据仅存于本机")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAISettings = true
                } label: {
                    Label("AI 纪要与隐私设置", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("AI 纪要与隐私设置")
            }
            .padding(10)
        }
        .navigationTitle("AI 听记")
    }
}
