import SwiftUI
import SezishCore

/// Cloud vs on-device dictation, plus the local model's lifecycle.
struct RecognitionPane: View {
    @Environment(AppState.self) private var appState

    /// Without baked credentials the cloud option is not offered at all — the
    /// footer explains the absence instead of showing a dead radio button.
    private var cloudAvailable: Bool { appState.settings.cloudCredentials != nil }

    var body: some View {
        Form {
            Section {
                Picker(selection: modeBinding) {
                    if cloudAvailable {
                        option(title: appState.strings.cloudTitle,
                               subtitle: appState.strings.cloudSubtitle)
                            .tag(TranscriptionMode.cloud)
                    }
                    option(title: appState.strings.localTitle,
                           subtitle: appState.strings.localSubtitle)
                        .tag(TranscriptionMode.local)
                    // Always offered: the key is the user's own, so nothing in the build
                    // decides whether this engine is available.
                    option(title: appState.strings.geminiTitle,
                           subtitle: appState.strings.geminiSubtitle)
                        .tag(TranscriptionMode.gemini)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } footer: {
                if !cloudAvailable {
                    Text(appState.strings.cloudUnavailable)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if appState.transcriptionMode == .gemini { geminiSection }

            if appState.usesLocalTranscription {
                Section {
                    Picker(selection: modelBinding) {
                        ForEach(AsrModel.allCases, id: \.self) { model in
                            option(title: modelTitle(model), subtitle: modelSubtitle(model))
                                .tag(model)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    modelStatus
                } header: {
                    Text(appState.strings.modelSection)
                } footer: {
                    Text(appState.strings.modelFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(unusedInstalledModels, id: \.self) { model in
                    Section {
                        LabeledContent {
                            Button(appState.strings.delete) { appState.deleteModel(model) }
                                .buttonStyle(.bordered)
                        } label: {
                            option(title: modelTitle(model), subtitle: appState.strings.modelInactiveHint)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.recognition.title(appState.strings))
    }

    /// The CHOSEN mode, not the effective one: picking gemini before pasting a key must
    /// leave the radio on gemini, or the key field it opens would close under the cursor.
    /// The one exception is a build without cloud credentials, where the cloud radio is
    /// not drawn at all and the default choice has to read as local.
    private var modeBinding: Binding<TranscriptionMode> {
        Binding(
            get: {
                let chosen = appState.transcriptionMode
                return chosen == .cloud && !cloudAvailable ? .local : chosen
            },
            set: { appState.setTranscriptionMode($0) }
        )
    }

    private var geminiKeyBinding: Binding<String> {
        // Straight through to AppSettings, per the SummaryPane idiom: a `@State` mirror
        // would start empty on every switch back into this pane and overwrite the key.
        Binding(
            get: { appState.settings.geminiApiKey ?? "" },
            set: { appState.setGeminiApiKey($0) }
        )
    }

    private var geminiSmartBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.geminiSmartMode },
            set: { appState.setGeminiSmartMode($0) }
        )
    }

    @ViewBuilder private var geminiSection: some View {
        Section {
            LabeledContent(appState.strings.geminiKeyLabel) {
                SecureField(appState.strings.geminiKeyPlaceholder, text: geminiKeyBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 1) {
                Toggle(appState.strings.geminiSmartTitle, isOn: geminiSmartBinding)
                Text(appState.strings.geminiSmartSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Link(appState.strings.geminiGetKey, destination: Self.apiKeyURL)
                .font(.system(size: 11))
        } header: {
            Text(appState.strings.geminiSection)
        } footer: {
            // No key means dictation silently runs somewhere else — say so in red,
            // the same way a failed model download is reported.
            if appState.settings.geminiApiKey == nil {
                Text(appState.strings.geminiKeyMissing)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.red)
            } else {
                Text(appState.strings.geminiFooter)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let apiKeyURL = URL(string: "https://aistudio.google.com/apikey")!

    private var modelBinding: Binding<AsrModel> {
        Binding(get: { appState.localModel }, set: { appState.setLocalModel($0) })
    }

    /// Downloaded but not selected — the only models the user may delete.
    private var unusedInstalledModels: [AsrModel] {
        AsrModel.allCases.filter { $0 != appState.localModel && appState.installedModels.contains($0) }
    }

    private func modelTitle(_ model: AsrModel) -> String {
        switch model {
        case .multilingual: appState.strings.modelMultiTitle
        case .ruEnPunctuated: appState.strings.modelRuEnTitle
        }
    }

    private func modelSubtitle(_ model: AsrModel) -> String {
        switch model {
        case .multilingual: appState.strings.modelMultiSubtitle
        case .ruEnPunctuated: appState.strings.modelRuEnSubtitle
        }
    }

    private func option(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch appState.modelPhase {
        case .ready:
            Label {
                Text(appState.strings.modelInstalled)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appState.strings.downloadingModel)
                    Spacer()
                    Text("\(Int(fraction * 100)) %")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                BrandProgressBar(fraction: fraction)
            }
        case .missing:
            Button(appState.strings.downloadModel) { appState.downloadModel() }
                .buttonStyle(.borderedProminent)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.red)
                    .lineLimit(2)
                Button(appState.strings.downloadModel) { appState.downloadModel() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
