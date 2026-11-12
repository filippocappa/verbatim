import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case languages, permissions, engine, tryIt

        var title: String {
            switch self {
            case .languages: "Languages"
            case .permissions: "Permissions"
            case .engine: "Speech engine"
            case .tryIt: "Try it"
            }
        }
    }

    @Environment(DictationController.self) private var controller
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step: Step = .languages

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch step {
                    case .languages: LanguagesStep()
                    case .permissions: PermissionsStep()
                    case .engine: EngineStep()
                    case .tryIt: TryItStep()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    if step != .languages {
                        Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                    }
                    Spacer()
                    Button(step == .tryIt ? "Done" : "Continue", action: next)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .permissions && !permissionsDone)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 36)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .frame(width: 760, height: 500)
        .background {
            // Painted separately so the sidebar tint and divider run up under the title bar.
            HStack(spacing: 0) {
                Rectangle().fill(.fill.quinary).frame(width: 220)
                Divider()
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
        .onAppear { WindowRouter.openWindow = openWindow }
    }

    private var permissionsDone: Bool {
        controller.accessibilityTrusted && Permissions.microphone == .allowed
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "quote.closing")
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.background)
                    .background(.primary, in: .rect(cornerRadius: 8))
                Text(AppInfo.name).font(.system(size: 16, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Step.allCases, id: \.self) { s in
                    HStack(spacing: 10) {
                        ZStack {
                            if s.rawValue < step.rawValue {
                                Circle().fill(.primary)
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.background)
                            } else {
                                Circle().strokeBorder(s == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary), lineWidth: 1.5)
                                Text("\(s.rawValue + 1)").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(s.title).fontWeight(s == step ? .semibold : .regular)
                    }
                    .foregroundStyle(s.rawValue <= step.rawValue ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(s == step ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                }
            }
            Spacer()
            Text("Takes about a minute.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
    }

    private func next() {
        if let n = Step(rawValue: step.rawValue + 1) {
            step = n
        } else {
            UserDefaults.standard.set(true, forKey: Prefs.Key.didOnboard)
            dismissWindow(id: WindowID.onboarding)
            openWindow(id: WindowID.main)
        }
    }
}

private struct StepHeader: View {
    let step: Int
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(step) of 4").font(.caption).foregroundStyle(.secondary)
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.bottom, 20)
    }
}

private struct LanguagesStep: View {
    @AppStorage(Prefs.Key.language) private var language = "auto"
    @AppStorage(Prefs.Key.offlineLanguage) private var offlineLanguage = "en"

    var body: some View {
        VStack(alignment: .leading) {
            StepHeader(step: 1, title: "What do you speak?",
                       text: "Mix them freely. The cloud engine works out the language each time.")
            Picker("", selection: $language) {
                Text("English and Italian").tag("auto")
                Text("Only English").tag("en")
                Text("Only Italian").tag("it")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if language == "auto" {
                Picker("When offline, listen for", selection: $offlineLanguage) {
                    Text("English").tag("en")
                    Text("Italian").tag("it")
                }
                .fixedSize()
                .padding(.top, 16)
            }
        }
    }
}

private struct PermissionsStep: View {
    @Environment(DictationController.self) private var controller
    @State private var mic = Permissions.microphone

    var body: some View {
        VStack(alignment: .leading) {
            StepHeader(step: 2, title: "Two permissions, then you're set",
                       text: "\(AppInfo.name) needs to hear you, and to type into other apps. Audio is only recorded while the pill is showing.")
            Panel(padding: 14) {
                VStack(spacing: 14) {
                    PermissionRow(title: "Microphone", detail: "To hear what you say.", allowed: mic == .allowed) {
                        if mic == .notAsked {
                            Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                    Divider()
                    PermissionRow(title: "Accessibility",
                                  detail: "To paste into the app you're in and notice when you fix a word.",
                                  allowed: controller.accessibilityTrusted) {
                        Permissions.requestAccessibility()
                    }
                }
            }
            if !controller.accessibilityTrusted {
                Text("In System Settings, switch on \(AppInfo.name). This screen updates by itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
        .task {
            // Notice the microphone switch in System Settings without a restart.
            while !Task.isCancelled {
                mic = Permissions.microphone
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct EngineStep: View {
    var body: some View {
        VStack(alignment: .leading) {
            StepHeader(step: 3, title: "Add your Groq key",
                       text: "Groq runs Whisper fast enough that the text appears about as soon as you stop. Without a key, \(AppInfo.name) uses Apple's engine on this Mac, which is slower and less accurate.")
            GroqKeyField()
                .frame(maxWidth: 440)
            Text("You can skip this and add it later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }
}

private struct TryItStep: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            StepHeader(step: 4, title: "Try it here",
                       text: "Click in the box, double-tap ⌘, say a sentence, then tap ⌘ once.")
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: 440, minHeight: 120, maxHeight: 140)
                .background(.fill.quinary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                .focused($focused)
            HStack(spacing: 8) {
                KeyCaps(keys: ["⌘", "⌘"])
                Text("start").foregroundStyle(.secondary)
                KeyCaps(keys: ["⌘"]).padding(.leading, 8)
                Text("paste").foregroundStyle(.secondary)
                KeyCaps(keys: ["esc"]).padding(.leading, 8)
                Text("cancel").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.top, 12)
        }
        .onAppear { focused = true }
    }
}
