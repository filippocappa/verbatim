import SwiftUI

/// What double-tap ⌥ can do, with things to say, plus your own sites to open and search.
struct CommandsView: View {
    @State private var sites = UserSites.all()
    @State private var name = ""
    @State private var address = ""
    @State private var searchExample = ""
    @FocusState private var nameFocused: Bool
    @State private var commands = UserCommands.all()
    @State private var cmdName = ""
    @State private var cmdInstruction = ""
    @FocusState private var cmdFocused: Bool
    @AppStorage("commandsTab") private var tab = "write"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Commands")
                        .font(.pageTitle)
                    HStack(spacing: 8) {
                        KeyCaps(keys: ["⌥", "⌥"])
                        Text("Double-tap Option, say what you want, then tap Option once to run it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                ModeSwitch(selection: $tab, options: [
                    .init(id: "write", symbol: "text.cursor", title: "Write", detail: "Change selected text, or run your commands"),
                    .init(id: "search", symbol: "safari", title: "Open and search", detail: "Apps, sites, and searches"),
                ])

                if tab == "write" {
                    Text("Select text and say what to change, or use one of your commands to write something new.")
                        .foregroundStyle(.secondary)
                    yourCommands
                    Examples(symbol: "text.cursor", title: "Or just say it",
                             detail: "With text selected, any instruction works. Where the text can't be edited, the result is copied instead.",
                             phrases: ["Make this shorter", "Translate it to English", "Rendilo più formale"])
                } else {
                    Text("With nothing selected, it opens apps and sites, or searches. A question on its own goes to Google.")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        Examples(symbol: "arrow.up.forward.app", title: "Open",
                                 detail: "Apps on your Mac first, then websites.",
                                 phrases: ["Open Slack", "Apri le note", "Go to GitHub"])
                        Examples(symbol: "magnifyingglass", title: "Search",
                                 detail: "Say “search <site> for …”, or “play … on YouTube”.",
                                 phrases: ["Play lo-fi beats on YouTube", "Search Amazon for AirPods Pro", "Cerca ricetta carbonara su YouTube"])
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        TileHeader(symbol: "globe", title: "Sites it can search",
                                   detail: "Any other site works too, through Google. Yours are outlined.")
                        FlowLayout(spacing: 6) {
                            ForEach(Commands.searchableSites, id: \.self) { Chip(text: $0) }
                            ForEach(sites) { Chip(text: $0.name).overlay(Capsule().strokeBorder(.primary.opacity(0.4))) }
                        }
                    }
                    .padding(16)
                    .tile()

                    yourSites
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Commands")
        .toolbarTitleDisplayMode(.inline)
    }

    private var yourCommands: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileHeader(symbol: "sparkles", title: "Your commands",
                       detail: "A short name that runs your own instruction. With text selected, it changes the selection. With nothing selected, it writes from what you say after the name and pastes it at your cursor.")

            HStack(alignment: .top, spacing: 8) {
                TextField("Name, e.g. bullets", text: $cmdName)
                    .focused($cmdFocused)
                    .frame(width: 160)
                TextField("What it should do", text: $cmdInstruction, axis: .vertical)
                    .lineLimit(1...4)
                Button(commands.contains(where: { $0.name.lowercased() == cmdName.trimmingCharacters(in: .whitespaces).lowercased() }) ? "Save" : "Add",
                       action: addCommand)
                    .buttonStyle(.glass)
                    .disabled(cmdName.trimmingCharacters(in: .whitespaces).isEmpty || cmdInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(addCommand)

            if !commands.isEmpty {
                VStack(spacing: 6) {
                    ForEach(commands) { c in
                        CommandLine(name: c.name, instruction: c.instruction) {
                            commands.removeAll { $0.id == c.id }
                            UserCommands.save(commands)
                        }
                        .onTapGesture { cmdName = c.name; cmdInstruction = c.instruction; cmdFocused = true }
                    }
                }
                Text("Click one to change it. Say “bullets, keep it to three” to add to the instruction just this time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let ideas = UserCommands.ideas.filter { idea in !commands.contains { $0.name.lowercased() == idea.name } }
            if !ideas.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commands.isEmpty ? "Start from one of these" : "More ideas")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, commands.isEmpty ? 0 : 6)
                    FlowLayout(spacing: 6) {
                        ForEach(ideas) { idea in
                            Button {
                                cmdName = idea.name; cmdInstruction = idea.instruction; cmdFocused = true
                            } label: {
                                Label(idea.name, systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .help(idea.instruction)
                        }
                    }
                }
            }
        }
        .padding(16)
        .tile()
    }

    private func addCommand() {
        let n = cmdName.trimmingCharacters(in: .whitespaces)
        let i = cmdInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !i.isEmpty else { return }
        if let at = commands.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) {
            commands[at].name = n
            commands[at].instruction = i
        } else {
            commands.append(UserCommand(name: n, instruction: i))
        }
        UserCommands.save(commands)
        cmdName = ""; cmdInstruction = ""
    }

    private var yourSites: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileHeader(symbol: "plus.square.on.square", title: "Your sites",
                       detail: "Add sites it wouldn't know, like your team's tools. Then “open Linear” or “search Linear for login bug” work.")

            HStack(spacing: 8) {
                TextField("Name, e.g. Linear", text: $name)
                    .focused($nameFocused)
                    .frame(maxWidth: 180)
                TextField("Address, e.g. linear.app/acme", text: $address)
                TextField("Search address (optional)", text: $searchExample)
                    .help("Search the site for TEST, then paste the address from your browser here.")
                Button("Add", action: add)
                    .buttonStyle(.glass)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(add)

            Text("For search, look up the word TEST on the site and paste the address from your browser. Leave it empty to search the site through Google.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !sites.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sites) { site in
                        HStack(spacing: 12) {
                            Text(site.name).fontWeight(.medium).frame(width: 160, alignment: .leading)
                            Text(site.openURL?.absoluteString ?? site.address)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(site.search == nil ? "searches through Google" : "searches the site")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Button {
                                sites.removeAll { $0.id == site.id }
                                UserSites.save(sites)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(site.name)")
                        }
                        .padding(.vertical, 9)
                        if site.id != sites.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .tile()
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !a.isEmpty else { return }
        sites.removeAll { $0.name.lowercased() == n.lowercased() }
        sites.append(UserSite(name: n, address: a, search: UserSites.template(fromExample: searchExample)))
        UserSites.save(sites)
        name = ""; address = ""; searchExample = ""
        nameFocused = true
    }
}

private struct TileHeader: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Examples: View {
    let symbol: String
    let title: String
    let detail: String
    let phrases: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileHeader(symbol: symbol, title: title, detail: detail)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(phrases, id: \.self) { p in
                    Text("“\(p)”")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .tile()
    }
}

private struct CommandLine: View {
    let name: String
    let instruction: String
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: .capsule)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(instruction)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Remove \(name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// Two big options on a track, with a knob that slides to the chosen one.
private struct ModeSwitch: View {
    struct Option: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    @Binding var selection: String
    let options: [Option]
    @Namespace private var knob

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { o in
                let on = o.id == selection
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { selection = o.id }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: o.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(on ? AnyShapeStyle(.background.opacity(0.18)) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.title).font(.headline)
                            Text(o.detail).font(.caption)
                                .foregroundStyle(on ? AnyShapeStyle(.background.opacity(0.7)) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(.primary)
                                .matchedGeometryEffect(id: "knob", in: knob)
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                        }
                    }
                    .contentShape(.rect(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.fill.quaternary, in: .rect(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .sensoryFeedback(.selection, trigger: selection)
    }
}
