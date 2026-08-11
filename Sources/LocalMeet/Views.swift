import SwiftUI

private enum Theme {
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.42, green: 0.43, blue: 0.43)
    static let paper = Color(red: 0.965, green: 0.953, blue: 0.925)
    static let card = Color(red: 0.992, green: 0.987, blue: 0.973)
    static let orange = Color(red: 0.91, green: 0.33, blue: 0.10)
    static let green = Color(red: 0.14, green: 0.49, blue: 0.34)
    static let line = Color.black.opacity(0.10)
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            ZStack {
                Theme.paper.ignoresSafeArea()
                if let meeting = state.selectedMeeting {
                    MeetingDetailView(meeting: meeting)
                } else if state.recordingStatus != .idle {
                    RecordingView()
                } else {
                    WelcomeView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if state.isRecording, state.selectedMeeting != nil {
                    ActiveRecordingBar()
                }
            }
        }
        .frame(minWidth: 980, minHeight: 650)
        .tint(Theme.orange)
        .alert("O LocalMeet precisa da sua ajuda", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.dismissError() } }
        )) {
            Button("Abrir Ajustes") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
                state.dismissError()
            }
            Button("Agora não", role: .cancel) { state.dismissError() }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.ink)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Text("LocalMeet")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(16)

            Button(action: state.toggleRecording) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(state.isRecording ? .white : Theme.orange)
                        .frame(width: 9, height: 9)
                    Text(state.isRecording ? "Encerrar reunião" : "Nova reunião")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("⌘R")
                        .font(.caption.monospaced())
                        .opacity(0.55)
                }
                .foregroundStyle(state.isRecording ? .white : Theme.ink)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(state.isRecording ? Theme.orange : Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Theme.line, lineWidth: state.isRecording ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.recordingStatus == .preparing || state.recordingStatus == .processing)
            .padding(.horizontal, 12)
            .keyboardShortcut("r", modifiers: [.command])

            if state.isRecording {
                Button {
                    state.showActiveRecording()
                } label: {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Theme.orange)
                            .frame(width: 8, height: 8)
                        Text("Gravação em andamento")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(state.elapsedLabel)
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(Theme.card.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .help("Voltar aos controles da gravação")
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.green)
                Text("100% neste Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.6)

            HStack {
                Text("REUNIÕES")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.muted)
                Spacer()
                if !state.processingQueue.isEmpty {
                    Label("\(state.processingQueue.count) na fila", systemImage: "list.number")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.orange)
                }
                Text("\(state.meetings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 7)

            if !state.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterTag("Todas", selected: state.selectedTagFilter == nil) {
                            state.selectedTagFilter = nil
                        }
                        ForEach(state.allTags, id: \.self) { tag in
                            filterTag(tag, selected: state.selectedTagFilter == tag) {
                                state.selectedTagFilter = tag
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 5)
                }
            }

            List(selection: $state.selection) {
                ForEach(state.filteredMeetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id)
                        .contextMenu {
                            Button("Exportar Markdown") { state.export(meeting) }
                            Divider()
                            Button("Apagar", role: .destructive) { state.delete(meeting) }
                                .disabled(state.isQueuedOrProcessing(meeting.id))
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.muted)
                TextField("Buscar nas transcrições", text: $state.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.white.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(12)
        }
        .background(Color(red: 0.92, green: 0.91, blue: 0.88))
    }

    private func filterTag(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .white : Theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selected ? Theme.ink : Color.white.opacity(0.65))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ActiveRecordingBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.orange)
                .frame(width: 8, height: 8)
            Text("GRAVANDO")
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(Theme.orange)
            Text(state.elapsedLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(state.isMicrophoneMuted ? "Microfone silenciado" : "Microfone + sistema")
                .font(.caption)
                .foregroundStyle(state.isMicrophoneMuted ? Theme.orange : Theme.muted)
            Spacer()
            Button {
                state.toggleMicrophoneMute()
            } label: {
                Label(
                    state.isMicrophoneMuted ? "Reativar microfone" : "Silenciar microfone",
                    systemImage: state.isMicrophoneMuted ? "mic.fill" : "mic.slash.fill"
                )
            }
            .buttonStyle(.borderless)
            .foregroundStyle(state.isMicrophoneMuted ? Theme.green : Theme.ink)
            Button("Ver gravação") {
                state.showActiveRecording()
            }
            .buttonStyle(.bordered)
            Button("Encerrar") {
                state.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.orange)
        }
        .padding(.horizontal, 24)
        .frame(height: 50)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                Text("·")
                Text(meeting.durationLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let progress = state.processingProgress[meeting.id], progress.isVisible {
                HStack(spacing: 5) {
                    Image(systemName: progressIcon(progress.stage))
                    Text(progress.stage.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(progress.activeFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(progressColor(progress.stage))
                ProgressView(value: progress.activeFraction)
                    .progressViewStyle(.linear)
                    .tint(progressColor(progress.stage))
            }
        }
        .padding(.vertical, 6)
    }

    private func progressIcon(_ stage: MeetingProcessingStage) -> String {
        switch stage {
        case .queued: "clock"
        case .transcribing: "waveform"
        case .summarizing: "sparkles"
        case .translating: "character.bubble"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func progressColor(_ stage: MeetingProcessingStage) -> Color {
        if state.selection == meeting.id { return .white }
        if case .failed = stage { return Theme.orange }
        return Theme.green
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                modelBadge
            }
            .padding(24)

            Spacer()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Theme.orange.opacity(0.10))
                        .frame(width: 104, height: 104)
                    Circle()
                        .fill(Theme.orange)
                        .frame(width: 70, height: 70)
                    Image(systemName: "waveform")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 10) {
                    Text("Sua memória de reunião,\nsem sair do Mac.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink)
                    Text("Português, English e Deutsch — até na mesma conversa.\nO idioma muda automaticamente e nada vai para a nuvem.")
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(4)
                }

                Button(action: primaryAction) {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .background(Theme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.modelStatus == .downloading || state.modelStatus == .checking)

                HStack(spacing: 10) {
                    accessPill("Microfone", icon: "mic.fill", status: state.microphoneAccess)
                    accessPill("Áudio do sistema", icon: "speaker.wave.2.fill", status: state.systemAudioAccess)
                }
                Picker("Microfone", selection: Binding(
                    get: { state.selectedMicrophoneID },
                    set: { state.selectMicrophone($0) }
                )) {
                    ForEach(state.microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)

                HStack(spacing: 26) {
                    trustItem("character.bubble", "PT · EN · DE automático")
                    trustItem("translate", "Original + tradução")
                    trustItem("checklist", "Resumo e ações locais")
                }
                .padding(.top, 8)
            }

            Spacer()
            Text("O áudio temporário é apagado assim que a transcrição termina.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 24)
        }
    }

    private var modelBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.modelStatus == .ready ? Theme.green : Theme.orange)
                .frame(width: 7, height: 7)
            Text(state.modelStatusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            if state.modelStatus == .downloading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Theme.line) }
    }

    private var buttonTitle: String {
        switch state.modelStatus {
        case .needsDownload, .unavailable: "Preparar modelo local"
        case .downloading: "Baixando…"
        default: "Começar a ouvir"
        }
    }

    private var buttonIcon: String {
        switch state.modelStatus {
        case .needsDownload, .unavailable: "arrow.down.circle"
        default: "record.circle"
        }
    }

    private func primaryAction() {
        switch state.modelStatus {
        case .needsDownload, .unavailable:
            state.prepareLocalModel()
        case .ready:
            state.toggleRecording()
        default:
            break
        }
    }

    private func trustItem(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.muted)
        }
    }

    private func accessPill(_ label: String, icon: String, status: AppState.AccessStatus) -> some View {
        let granted = status == .granted
        return Label(label, systemImage: granted ? "checkmark.circle.fill" : icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(granted ? Theme.green : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.card)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Theme.line) }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.orange).frame(width: 8, height: 8)
                        Text(state.recordingStatus == .preparing ? "PREPARANDO" : state.recordingStatus == .processing ? "PROCESSANDO LOCALMENTE" : "OUVINDO AGORA")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(Theme.orange)
                    }
                    Text("Reunião em andamento")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Spacer()
                Text(state.elapsedLabel)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                Button {
                    state.toggleMicrophoneMute()
                } label: {
                    Label(
                        state.isMicrophoneMuted ? "Reativar meu microfone" : "Silenciar meu microfone",
                        systemImage: state.isMicrophoneMuted ? "mic.fill" : "mic.slash.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(state.isMicrophoneMuted ? Theme.green : Theme.ink)
                .controlSize(.large)
                .disabled(!state.isRecording)
                Button("Encerrar") { state.toggleRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.orange)
                    .controlSize(.large)
                    .disabled(!state.isRecording)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
            .background(Theme.card)
            .overlay(alignment: .bottom) { Divider() }

            if state.recordingStatus == .preparing || state.recordingStatus == .processing {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text(state.recordingStatus == .processing ? state.processingMessage : "Conectando ao áudio local…")
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 22) {
                    MiniWaveform()
                        .scaleEffect(2.2)
                        .frame(height: 60)
                    Text(state.isMicrophoneMuted ? "Seu microfone está silenciado" : "Capturando reunião e microfone")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(
                        state.isMicrophoneMuted
                            ? "Sua voz não entrará na transcrição enquanto o mute estiver ativo.\nO áudio do sistema continua sendo capturado normalmente."
                            : "O Whisper identifica Português, English e Deutsch automaticamente.\nA transcrição original aparece ao encerrar."
                    )
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(4)
                    HStack(spacing: 8) {
                        languageChip("PT")
                        languageChip("EN")
                        languageChip("DE")
                    }
                    VStack(spacing: 7) {
                        HStack(spacing: 10) {
                            Text("RESUMO COM")
                                .font(.caption2.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(Theme.muted)
                            Picker("Modelo do resumo", selection: Binding(
                                get: { state.selectedSummaryProvider },
                                set: { state.selectSummaryProvider($0) }
                            )) {
                                ForEach(SummaryProvider.allCases) { provider in
                                    Text(provider.label).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 230)
                        }
                        Text(state.selectedSummaryProvider.detail)
                            .font(.caption)
                            .foregroundStyle(state.selectedSummaryProvider == .local ? Theme.green : Theme.orange)
                    }
                    HStack(spacing: 10) {
                        AudioSignalPill(
                            title: "Microfone",
                            icon: "mic.fill",
                            active: state.microphoneIsReceivingAudio,
                            muted: state.isMicrophoneMuted
                        )
                        AudioSignalPill(
                            title: "Áudio do sistema",
                            icon: "speaker.wave.2.fill",
                            active: state.systemIsReceivingAudio
                        )
                    }
                    Text("Entrada selecionada: \(state.selectedMicrophoneName)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    LiveTranscriptView()
                        .frame(maxWidth: 780, maxHeight: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.green)
                Text("Chamada + microfone no mesmo pipeline local · áudio apagado ao finalizar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                MiniWaveform()
            }
            .padding(.horizontal, 30)
            .frame(height: 48)
            .background(Theme.card)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func languageChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Theme.card)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Theme.line) }
    }
}

private struct LiveTranscriptView: View {
    @EnvironmentObject private var state: AppState
    @State private var followsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(Theme.green)
                Text("TRANSCRIÇÃO AO VIVO")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
                Text("aprox. 15–25 s de atraso")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Toggle("Seguir", isOn: $followsLatest)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.card)
            .overlay(alignment: .bottom) { Divider() }

            if state.liveTranscriptSegments.isEmpty {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("O primeiro trecho aparece após a primeira janela de áudio.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Text("A gravação final continua independente e protegida.")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(state.liveTranscriptSegments) { segment in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(segment.timestamp)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.muted)
                                        .frame(width: 42, alignment: .leading)
                                    Text(segment.source.label)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(segment.source == .microphone ? Theme.orange : Theme.green)
                                        .frame(width: 62, alignment: .leading)
                                    Text(segment.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.ink)
                                        .textSelection(.enabled)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: state.liveTranscriptSegments.count) {
                        guard followsLatest, let lastID = state.liveTranscriptSegments.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }
}

private struct AudioSignalPill: View {
    let title: String
    let icon: String
    let active: Bool
    var muted = false

    var body: some View {
        Label(
            muted ? "\(title) silenciado" : active ? "\(title) ativo" : "Aguardando \(title.lowercased())",
            systemImage: muted ? "mic.slash.fill" : icon
        )
            .font(.caption.weight(.semibold))
            .foregroundStyle(muted ? Theme.orange : active ? Theme.green : Theme.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.card)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(
                    muted ? Theme.orange.opacity(0.45) : active ? Theme.green.opacity(0.35) : Theme.line
                )
            }
    }
}

private struct MeetingDetailView: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var selectedSection = 0
    @State private var showingNewTag = false
    @State private var newTag = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    if editingTitle {
                        HStack(spacing: 8) {
                            TextField("Nome da reunião", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .focused($titleFieldFocused)
                                .onSubmit { saveTitle() }
                            Button("Salvar", systemImage: "checkmark") { saveTitle() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.green)
                            Button("Cancelar", systemImage: "xmark") {
                                editingTitle = false
                                titleFieldFocused = false
                            }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.muted)
                        }
                    } else {
                        HStack(spacing: 7) {
                            Text(meeting.title)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            beginEditingTitle()
                        }
                        .help("Clique para editar o nome da reunião")
                    }
                    Text("\(meeting.startedAt.formatted(date: .long, time: .shortened))  ·  \(meeting.durationLabel)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        ForEach(meeting.tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    state.removeTag(tag, from: meeting.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.orange.opacity(0.10))
                            .foregroundStyle(Theme.orange)
                            .clipShape(Capsule())
                        }
                        Menu {
                            let available = state.allTags.filter { !meeting.tags.contains($0) }
                            ForEach(available, id: \.self) { tag in
                                Button(tag) { state.addTag(tag, to: meeting.id) }
                            }
                            if !available.isEmpty { Divider() }
                            Button("Criar nova tag…") { showingNewTag = true }
                        } label: {
                            Label("Tag", systemImage: "plus")
                                .font(.caption.weight(.semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    if let diagnostics = meeting.captureDiagnostics {
                        HStack(spacing: 10) {
                            captureStatus(
                                diagnostics.microphoneSignalDetected,
                                label: diagnostics.microphoneName,
                                icon: "mic.fill"
                            )
                            captureStatus(
                                diagnostics.systemSignalDetected,
                                label: "Áudio do sistema",
                                icon: "speaker.wave.2.fill"
                            )
                        }
                    }
                }
                Spacer()
                Picker("Visualização", selection: $selectedSection) {
                    Text("Resumo").tag(0)
                    Text("Transcrição").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button { state.export(meeting) } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(30)
            .background(Theme.card)
            .overlay(alignment: .bottom) { Divider() }

            if let progress = state.processingProgress[meeting.id], progress.isVisible {
                MeetingPipelineProgressView(progress: progress)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(Theme.card.opacity(0.78))
                    .overlay(alignment: .bottom) { Divider() }
            }

            if meeting.segments.isEmpty {
                ContentUnavailableView {
                    Label(
                        state.transcriptionMeetingID == meeting.id
                            ? "Transcrevendo áudio preservado…"
                            : state.isQueuedOrProcessing(meeting.id)
                                ? "Reunião aguardando na fila"
                                : "Transcrição não concluída",
                        systemImage: state.transcriptionMeetingID == meeting.id
                            ? "waveform.badge.magnifyingglass"
                            : "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    if state.transcriptionMeetingID == meeting.id {
                        Text("As trilhas do microfone e do áudio do sistema continuam protegidas no Mac.")
                    } else if state.isQueuedOrProcessing(meeting.id) {
                        Text("O áudio está preservado. O LocalMeet começará esta reunião quando as anteriores terminarem.")
                    } else if state.hasRecoveryAudio(for: meeting.id) {
                        Text(meeting.transcriptionError ?? "O áudio está preservado e pode ser transcrito novamente.")
                    } else {
                        Text(meeting.transcriptionError ?? "Não há áudio de recuperação disponível para esta gravação.")
                    }
                } actions: {
                    if state.hasRecoveryAudio(for: meeting.id) {
                        VStack(spacing: 7) {
                            Text("DEPOIS DE TRANSCREVER, RESUMIR COM")
                                .font(.caption2.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(Theme.muted)
                            Picker("Modelo do resumo", selection: Binding(
                                get: { state.selectedSummaryProvider },
                                set: { state.selectSummaryProvider($0) }
                            )) {
                                ForEach(SummaryProvider.allCases) { provider in
                                    Text(provider.label).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 270)
                            Text(state.selectedSummaryProvider.detail)
                                .font(.caption)
                                .foregroundStyle(
                                    state.selectedSummaryProvider == .local ? Theme.green : Theme.orange
                                )
                        }
                        .padding(.bottom, 6)
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await state.retryTranscription(
                                        meetingID: meeting.id,
                                        summaryProvider: .local
                                    )
                                }
                            } label: {
                                Label("Repetir com LLM local", systemImage: "cpu")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                Task {
                                    await state.retryTranscription(
                                        meetingID: meeting.id,
                                        summaryProvider: .claude
                                    )
                                }
                            } label: {
                                Label("Repetir com Claude", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!state.claudeIsAvailable)
                        }
                        .disabled(state.isQueuedOrProcessing(meeting.id))
                        if !state.claudeIsAvailable {
                            Text("Claude Code não foi encontrado neste Mac.")
                                .font(.caption)
                                .foregroundStyle(Theme.orange)
                        }
                        Button("Mostrar áudio de recuperação") {
                            state.revealRecoveryAudio(meetingID: meeting.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if selectedSection == 0 {
                AnalysisView(meeting: meeting)
            } else {
                transcriptView
            }
        }
        .alert("Nova tag", isPresented: $showingNewTag) {
            TextField("Ex.: Cliente, Produto, Interna", text: $newTag)
            Button("Cancelar", role: .cancel) { newTag = "" }
            Button("Adicionar") {
                state.addTag(newTag, to: meeting.id)
                newTag = ""
            }
        } message: {
            Text("A tag ficará disponível para outras reuniões e para os filtros da barra lateral.")
        }
    }

    private var transcriptView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MOSTRAR TRADUÇÃO EM")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
                Picker("Tradução", selection: $state.translationTarget) {
                    ForEach(LanguageOption.supported) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Button {
                    Task { await state.translateMeeting(meetingID: meeting.id) }
                } label: {
                    Label(
                        state.translationMeetingID == meeting.id ? "Traduzindo…" : "Refazer traduções",
                        systemImage: state.translationMeetingID == meeting.id ? "ellipsis" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderless)
                .disabled(state.isQueuedOrProcessing(meeting.id))
                Spacer()
                Text("Original e tradução podem ser corrigidos")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 30)
            .frame(height: 52)
            .background(Theme.card.opacity(0.7))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(meeting.segments) { segment in
                        TranscriptBubble(
                            meetingID: meeting.id,
                            segment: segment,
                            translationTarget: state.translationTarget,
                            editingDisabled: state.isQueuedOrProcessing(meeting.id)
                        )
                    }
                }
                .padding(30)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func saveTitle() {
        state.rename(meeting, to: draftTitle)
        editingTitle = false
        titleFieldFocused = false
    }

    private func beginEditingTitle() {
        draftTitle = meeting.title
        editingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func captureStatus(_ detected: Bool, label: String, icon: String) -> some View {
        Label(detected ? "\(label): sinal captado" : "\(label): sem sinal", systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(detected ? Theme.green : Theme.orange)
    }
}

private struct AnalysisView: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        Group {
            if state.analysisMeetingID == meeting.id {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("\((state.summaryProvider(for: meeting.id) ?? state.selectedSummaryProvider).label) está organizando a reunião…")
                        .foregroundStyle(Theme.muted)
                    Text("Resumo · decisões · ações · responsáveis · datas")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let analysis = meeting.analysis {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SummaryProviderControls(
                            currentProvider: analysis.summaryProvider,
                            actionTitle: "Resumir novamente",
                            disabled: state.isQueuedOrProcessing(meeting.id)
                        ) {
                            Task { await state.regenerateSummary(meetingID: meeting.id) }
                        }
                        analysisCard("RESUMO", icon: "text.alignleft") {
                            EditableTextBlock(
                                text: analysis.summary,
                                accessibilityLabel: "Editar resumo"
                            ) { updated in
                                state.updateSummary(meetingID: meeting.id, text: updated)
                            }
                        }
                        if !analysis.decisions.isEmpty {
                            analysisCard("DECISÕES", icon: "checkmark.seal") {
                                ForEach(Array(analysis.decisions.enumerated()), id: \.offset) { index, decision in
                                    EditableDecisionRow(
                                        decision: decision,
                                        onSave: { state.updateDecision(meetingID: meeting.id, index: index, text: $0) },
                                        onDelete: { state.deleteDecision(meetingID: meeting.id, index: index) }
                                    )
                                }
                            }
                        }
                        analysisCard("ACTION POINTS", icon: "checklist") {
                            if analysis.actionItems.isEmpty {
                                Text("Nenhuma ação explícita identificada.").foregroundStyle(Theme.muted)
                            } else {
                                ForEach(analysis.actionItems) { item in
                                    EditableActionPointRow(
                                        item: item,
                                        onToggle: {
                                            state.toggleAction(meetingID: meeting.id, actionID: item.id)
                                        },
                                        onSave: { task, owner, dueDate in
                                            state.updateAction(
                                                meetingID: meeting.id,
                                                actionID: item.id,
                                                task: task,
                                                owner: owner,
                                                dueDate: dueDate
                                            )
                                        },
                                        onDelete: {
                                            state.deleteAction(meetingID: meeting.id, actionID: item.id)
                                        }
                                    )
                                }
                            }
                        }
                        if !analysis.keyDates.isEmpty {
                            analysisCard("DATAS IMPORTANTES", icon: "calendar.badge.clock") {
                                ForEach(analysis.keyDates) { item in
                                    EditableKeyDateRow(
                                        item: item,
                                        onSave: { date, context in
                                            state.updateKeyDate(
                                                meetingID: meeting.id,
                                                keyDateID: item.id,
                                                date: date,
                                                context: context
                                            )
                                        },
                                        onDelete: {
                                            state.deleteKeyDate(meetingID: meeting.id, keyDateID: item.id)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 18) {
                    ContentUnavailableView {
                        Label("Resumo ainda não gerado", systemImage: "sparkles")
                    } description: {
                        Text("Escolha o modelo que deve analisar esta transcrição.")
                    }
                    SummaryProviderControls(
                        currentProvider: nil,
                        actionTitle: "Gerar resumo e traduções",
                        disabled: state.isQueuedOrProcessing(meeting.id)
                    ) {
                        Task { await state.analyze(meetingID: meeting.id) }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private func analysisCard<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 13, content: content)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Theme.line) }
    }
}

private struct SummaryProviderControls: View {
    @EnvironmentObject private var state: AppState
    let currentProvider: SummaryProvider?
    let actionTitle: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MODELO DO RESUMO")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(Theme.muted)
                    if let currentProvider {
                        Text("Resumo atual: \(currentProvider.label)")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Picker("Modelo do resumo", selection: Binding(
                    get: { state.selectedSummaryProvider },
                    set: { state.selectSummaryProvider($0) }
                )) {
                    ForEach(SummaryProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Button(actionTitle, systemImage: "arrow.clockwise", action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || (state.selectedSummaryProvider == .claude && !state.claudeIsAvailable))
            }
            HStack(spacing: 7) {
                Image(systemName: state.selectedSummaryProvider == .local ? "lock.fill" : "cloud.fill")
                Text(state.selectedSummaryProvider.detail)
                if !state.claudeIsAvailable {
                    Text("· Claude Code não encontrado")
                }
            }
            .font(.caption)
            .foregroundStyle(state.selectedSummaryProvider == .local ? Theme.green : Theme.orange)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }
}

private struct EditableTextBlock: View {
    let text: String
    let accessibilityLabel: String
    let onSave: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 9) {
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 110)
                    .background(Color.white.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.orange.opacity(0.35)) }
                editControls(save: save, cancel: { editing = false })
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Text(text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                editButton { beginEditing() }
                    .accessibilityLabel(accessibilityLabel)
            }
        }
    }

    private func beginEditing() {
        draft = text
        editing = true
    }

    private func save() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onSave(clean)
        editing = false
    }
}

private struct EditableDecisionRow: View {
    let decision: String
    let onSave: (String) -> Void
    let onDelete: () -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(Theme.green)
                .padding(.top, editing ? 6 : 2)
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Decisão", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    editControls(save: save, cancel: { editing = false })
                }
            } else {
                Text(decision)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                editButton {
                    draft = decision
                    editing = true
                }
                deleteButton(action: onDelete)
            }
        }
    }

    private func save() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onSave(clean)
        editing = false
    }
}

private struct EditableActionPointRow: View {
    let item: ActionItem
    let onToggle: () -> Void
    let onSave: (String, String, String) -> Void
    let onDelete: () -> Void
    @State private var editing = false
    @State private var draftTask = ""
    @State private var draftOwner = ""
    @State private var draftDueDate = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.isCompleted ? Theme.green : Theme.orange)
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Marcar como pendente" : "Marcar como concluído")

            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Action point", text: $draftTask, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    HStack(spacing: 8) {
                        TextField("Responsável", text: $draftOwner)
                            .textFieldStyle(.roundedBorder)
                        TextField("Prazo", text: $draftDueDate)
                            .textFieldStyle(.roundedBorder)
                    }
                    editControls(save: save, cancel: { editing = false })
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.task)
                        .fontWeight(.semibold)
                        .strikethrough(item.isCompleted, color: Theme.muted)
                        .foregroundStyle(item.isCompleted ? Theme.muted : Theme.ink)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Label(item.owner ?? "Responsável não definido", systemImage: "person")
                        Label(item.dueDate ?? "Sem prazo definido", systemImage: "calendar")
                        if let completedAt = item.completedAt {
                            Label(
                                "Concluído em \(completedAt.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: "checkmark"
                            )
                            .foregroundStyle(Theme.green)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                editButton(action: beginEditing)
                deleteButton(action: onDelete)
            }
        }
    }

    private func beginEditing() {
        draftTask = item.task
        draftOwner = item.owner ?? ""
        draftDueDate = item.dueDate ?? ""
        editing = true
    }

    private func save() {
        let clean = draftTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onSave(clean, draftOwner, draftDueDate)
        editing = false
    }
}

private struct EditableKeyDateRow: View {
    let item: KeyDate
    let onSave: (String, String) -> Void
    let onDelete: () -> Void
    @State private var editing = false
    @State private var draftDate = ""
    @State private var draftContext = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Data", text: $draftDate)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField("Contexto", text: $draftContext, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }
                    editControls(save: save, cancel: { editing = false })
                }
            } else {
                Text(item.date)
                    .fontWeight(.bold)
                    .frame(width: 120, alignment: .leading)
                    .textSelection(.enabled)
                Text(item.context)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                editButton(action: beginEditing)
                deleteButton(action: onDelete)
            }
        }
    }

    private func beginEditing() {
        draftDate = item.date
        draftContext = item.context
        editing = true
    }

    private func save() {
        let cleanDate = draftDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContext = draftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDate.isEmpty, !cleanContext.isEmpty else { return }
        onSave(cleanDate, cleanContext)
        editing = false
    }
}

private func editButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "pencil")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Theme.muted)
    .help("Editar")
}

private func deleteButton(action: @escaping () -> Void) -> some View {
    Button(role: .destructive, action: action) {
        Image(systemName: "trash")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Theme.orange)
    .help("Apagar")
}

private func editControls(save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        Button("Salvar", systemImage: "checkmark", action: save)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        Button("Cancelar", action: cancel)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct MeetingPipelineProgressView: View {
    let progress: MeetingProcessingProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: stageIcon)
                    .foregroundStyle(stageColor)
                Text(progress.stage.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if case .queued(let position) = progress.stage {
                    Text("#\(position)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 18) {
                PipelineProgressBar(title: "Transcrição", value: progress.transcription)
                PipelineProgressBar(title: "Resumo", value: progress.summary)
                PipelineProgressBar(title: "Traduções", value: progress.translation)
            }
            if case .failed(let message) = progress.stage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.orange)
                    .lineLimit(2)
            }
        }
    }

    private var stageIcon: String {
        switch progress.stage {
        case .queued: "clock"
        case .transcribing: "waveform"
        case .summarizing: "sparkles"
        case .translating: "character.bubble"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var stageColor: Color {
        if case .failed = progress.stage { return Theme.orange }
        return Theme.green
    }
}

private struct PipelineProgressBar: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(value >= 1 ? Theme.green : Theme.orange)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TranscriptBubble: View {
    @EnvironmentObject private var state: AppState
    let meetingID: UUID
    let segment: TranscriptSegment
    var translationTarget: String? = nil
    var editingDisabled = false
    @State private var editing = false
    @State private var draftOriginal = ""
    @State private var draftTranslation = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(segment.timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(segment.source.label.uppercased())
                    Text(segment.languageLabel.uppercased())
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    if !editing {
                        editButton(action: beginEditing)
                            .disabled(editingDisabled)
                    }
                }
                .font(.caption2.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(segment.source == .microphone ? Theme.orange : Theme.green)
                if editing {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("ORIGINAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.muted)
                        TextEditor(text: $draftOriginal)
                            .font(.system(size: 15))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 70)
                            .background(Color.white.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        if let translationTarget,
                           segment.translations[translationTarget] != nil {
                            Text("TRADUÇÃO · \(languageName(translationTarget).uppercased())")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.orange)
                            TextEditor(text: $draftTranslation)
                                .font(.system(size: 15))
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(minHeight: 70)
                                .background(Color.white.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        editControls(save: save, cancel: { editing = false })
                    }
                } else {
                    Text(segment.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    if let translationTarget,
                       let translated = segment.translations[translationTarget],
                       translated.localizedCaseInsensitiveCompare(segment.text) != .orderedSame {
                        Divider().padding(.vertical, 3)
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "translate")
                                .foregroundStyle(Theme.orange)
                            Text(translated)
                                .foregroundStyle(Theme.muted)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                        }
                    }
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
        }
    }

    private func beginEditing() {
        draftOriginal = segment.text
        if let translationTarget {
            draftTranslation = segment.translations[translationTarget] ?? ""
        }
        editing = true
    }

    private func save() {
        state.updateTranscriptSegment(
            meetingID: meetingID,
            segmentID: segment.id,
            original: draftOriginal,
            translationLanguage: translationTarget,
            translation: translationTarget == nil ? nil : draftTranslation
        )
        editing = false
    }

    private func languageName(_ identifier: String) -> String {
        LanguageOption.supported.first(where: { $0.id == identifier })?.name ?? identifier
    }
}

private struct LiveTranscriptBubble: View {
    let source: AudioSource
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: source == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                .foregroundStyle(source == .microphone ? Theme.orange : Theme.green)
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(source.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                    Text("AO VIVO")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                .foregroundStyle(source == .microphone ? Theme.orange : Theme.green)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.orange.opacity(0.25)) }
        }
    }
}

private struct MiniWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<9, id: \.self) { index in
                    Capsule()
                        .fill(Theme.orange.opacity(0.75))
                        .frame(width: 3, height: 5 + abs(sin(phase * 3 + Double(index))) * 14)
                }
            }
            .frame(height: 22)
        }
    }
}
