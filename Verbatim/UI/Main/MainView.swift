import SwiftUI
import SwiftData

enum Page: String, CaseIterable, Identifiable {
    case home, stats, history, meetings, dictionary, snippets, style, commands
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .stats: "Stats"
        case .history: "History"
        case .meetings: "Meetings"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        case .commands: "Commands"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .stats: "chart.bar.xaxis"
        case .history: "clock"
        case .meetings: "person.2.wave.2"
        case .dictionary: "character.book.closed"
        case .snippets: "text.quote"
        case .style: "textformat"
        case .commands: "command"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .stats: "2"
        case .history: "3"
        case .meetings: "4"
        case .dictionary: "5"
        case .snippets: "6"
        case .style: "7"
        case .commands: "8"
        }
    }
}

struct MainView: View {
    @SceneStorage("page") private var page: Page = .home

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(page) }, set: { if let p = $0 { page = p } })) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            #if DEBUG
            .onAppear {
                if let p = UserDefaults.standard.string(forKey: "page").flatMap(Page.init(rawValue:)) { page = p }
            }
            #endif
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            switch page {
            case .home: HomeView()
            case .stats: StatsView()
            case .history: HistoryView()
            case .meetings: MeetingsView()
            case .dictionary: DictionaryView()
            case .snippets: SnippetsView()
            case .style: StyleView()
            case .commands: CommandsView()
            }
        }
        .background {
            // ⌘1 to ⌘4 switch pages.
            ForEach(Page.allCases) { p in
                Button("") { page = p }.keyboardShortcut(p.shortcut, modifiers: .command).hidden()
            }
        }
        .frame(minWidth: 820, minHeight: 640)
    }
}

private struct SidebarFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EngineStatus()
            HStack(spacing: 8) {
                KeyCaps(keys: ["⌘", "⌘"])
                Text("double-tap to dictate").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                KeyCaps(keys: ["⌥", "⌥"])
                Text("double-tap for a command").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
}

#if DEBUG
#Preview {
    MainView()
        .environment(DictationController.shared)
        .modelContainer(Store.container)
        .frame(width: 1080, height: 820)
}
#endif
