import SwiftUI

@main
struct LocalMeetApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button(state.isRecording ? "Encerrar reunião" : "Nova reunião") {
                    state.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button(state.isMicrophoneMuted ? "Reativar meu microfone" : "Silenciar meu microfone") {
                    state.toggleMicrophoneMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!state.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            LabeledContent("Transcrição", value: "Português · English · Deutsch automáticos")
            LabeledContent("Microfone", value: accessLabel(state.microphoneAccess))
            Picker("Dispositivo de entrada", selection: Binding(
                get: { state.selectedMicrophoneID },
                set: { state.selectMicrophone($0) }
            )) {
                ForEach(state.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
            }
            LabeledContent("Áudio do sistema", value: accessLabel(state.systemAudioAccess))
            Picker("Idioma padrão da tradução", selection: $state.translationTarget) {
                ForEach(LanguageOption.supported) { language in
                    Text(language.name).tag(language.id)
                }
            }
            Picker("Modelo padrão do resumo", selection: Binding(
                get: { state.selectedSummaryProvider },
                set: { state.selectSummaryProvider($0) }
            )) {
                ForEach(SummaryProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            LabeledContent(
                "Claude Code",
                value: state.claudeIsAvailable ? "Instalação local encontrada" : "Não encontrado"
            )
            LabeledContent(
                "Privacidade",
                value: state.selectedSummaryProvider == .local
                    ? "Resumo processado somente neste Mac"
                    : "A transcrição é enviada à Anthropic"
            )
            LabeledContent("Áudio", value: "Nunca armazenado")
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500, height: 380)
    }

    private func accessLabel(_ status: AppState.AccessStatus) -> String {
        switch status {
        case .unknown: "Será solicitado ao iniciar"
        case .granted: "Permitido"
        case .denied: "Bloqueado nos Ajustes"
        }
    }
}
