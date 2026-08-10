import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AppState: ObservableObject {
    enum RecordingStatus: Equatable {
        case idle
        case preparing
        case recording
        case processing
    }

    enum ModelStatus: Equatable {
        case checking
        case needsDownload
        case downloading
        case ready
        case unavailable(String)
    }

    enum AccessStatus: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published var meetings: [Meeting]
    @Published var selection: UUID?
    @Published var searchText = ""
    @Published var selectedTagFilter: String?
    @Published var translationTarget = "pt"
    @Published var recordingStatus: RecordingStatus = .idle
    @Published var modelStatus: ModelStatus = .checking
    @Published var elapsed: TimeInterval = 0
    @Published var processingMessage = ""
    @Published var analysisMeetingID: UUID?
    @Published var translationMeetingID: UUID?
    @Published var transcriptionMeetingID: UUID?
    @Published var errorMessage: String?
    @Published var microphoneAccess: AccessStatus = .unknown
    @Published var systemAudioAccess: AccessStatus = .unknown
    @Published var microphoneIsReceivingAudio = false
    @Published var systemIsReceivingAudio = false
    @Published var microphones: [MicrophoneOption] = []
    @Published var selectedMicrophoneID = ""

    private let store: MeetingStore
    private let whisper: WhisperEngine
    private let recoveryAudio: RecoveryAudioStore
    private let intelligence = LocalIntelligenceEngine()
    private var captureEngine: MeetingCaptureEngine?
    private var microphoneEngine: MicrophoneCaptureEngine?
    private var audioRecorder: TemporaryAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    init(
        store: MeetingStore = MeetingStore(),
        whisper: WhisperEngine = WhisperEngine(),
        recoveryAudio: RecoveryAudioStore? = nil
    ) {
        self.store = store
        self.whisper = whisper
        self.recoveryAudio = recoveryAudio ?? RecoveryAudioStore(baseDirectory: whisper.applicationSupport)
        meetings = store.load().sorted { $0.startedAt > $1.startedAt }
        selection = meetings.first?.id
        refreshMicrophones()
        Task { @MainActor [weak self] in
            self?.refreshModelStatus()
            self?.refreshPermissionStatus()
        }
    }

    var isRecording: Bool { recordingStatus == .recording }
    var isBusy: Bool { recordingStatus != .idle }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selection }
    }

    var filteredMeetings: [Meeting] {
        meetings.filter { meeting in
            let matchesTag = selectedTagFilter.map { tag in
                meeting.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
            } ?? true
            let matchesSearch = searchText.isEmpty || meeting.searchableText.localizedCaseInsensitiveContains(searchText)
            return matchesTag && matchesSearch
        }
    }

    var allTags: [String] {
        var seen: Set<String> = []
        return meetings
            .flatMap(\.tags)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    var modelStatusLabel: String {
        switch modelStatus {
        case .checking: "Verificando modelos locais…"
        case .needsDownload: "Modelo multilíngue necessário (\(WhisperEngine.modelSizeDescription))"
        case .downloading: "Baixando modelo multilíngue…"
        case .ready: "PT · EN · DE prontos"
        case .unavailable(let message): message
        }
    }

    var selectedMicrophoneName: String {
        microphones.first(where: { $0.id == selectedMicrophoneID })?.name ?? "Microfone padrão"
    }

    func prepareLocalModel() {
        guard modelStatus != .downloading else { return }
        modelStatus = .downloading
        Task {
            do {
                try await whisper.ensureModel()
                modelStatus = .ready
            } catch {
                modelStatus = .unavailable(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else if recordingStatus == .idle {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        recordingStatus = .preparing
        errorMessage = nil

        do {
            if !whisper.isReady {
                modelStatus = .downloading
                processingMessage = "Preparando o modelo multilíngue pela primeira vez…"
                try await whisper.ensureModel()
                modelStatus = .ready
            }
            try await requestPermissions()
            let recorder = try TemporaryAudioRecorder()
            let engine = MeetingCaptureEngine()
            let microphone = MicrophoneCaptureEngine(
                deviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
            )
            engine.onAudio = { [weak recorder] sampleBuffer, source in
                recorder?.append(sampleBuffer, source: source)
            }
            microphone.onAudio = { [weak recorder] sampleBuffer in
                recorder?.appendMicrophone(sampleBuffer)
            }
            engine.onStopped = { [weak self] error in
                Task { @MainActor in
                    guard self?.recordingStatus == .recording else { return }
                    self?.errorMessage = error.localizedDescription
                    await self?.stopRecording()
                }
            }

            audioRecorder = recorder
            captureEngine = engine
            microphoneEngine = microphone
            do {
                try await microphone.start()
                try await engine.start()
            } catch {
                await microphone.stop()
                throw error
            }

            startedAt = Date()
            elapsed = 0
            microphoneIsReceivingAudio = false
            systemIsReceivingAudio = false
            selection = nil
            recordingStatus = .recording
            startTimer()
        } catch {
            audioRecorder?.removeTemporaryFiles()
            audioRecorder = nil
            captureEngine = nil
            microphoneEngine = nil
            recordingStatus = .idle
            refreshModelStatus()
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard recordingStatus == .recording else { return }
        recordingStatus = .processing
        processingMessage = "Preparando o áudio local…"
        timer?.invalidate()
        timer = nil

        await microphoneEngine?.stop()
        await captureEngine?.stop()
        let microphoneSignal = audioRecorder?.microphoneHasData ?? false
        let systemSignal = audioRecorder?.systemAudioHasData ?? false
        let files = await audioRecorder?.finish() ?? [:]
        microphoneIsReceivingAudio = microphoneSignal
        systemIsReceivingAudio = systemSignal
        let start = startedAt ?? Date()
        let meetingID = UUID()

        let meeting = Meeting(
            id: meetingID,
            title: defaultTitle(for: start),
            startedAt: start,
            duration: elapsed,
            localeIdentifier: "pt+en+de",
            segments: [],
            captureDiagnostics: CaptureDiagnostics(
                microphoneSignalDetected: microphoneSignal,
                systemSignalDetected: systemSignal,
                microphoneName: selectedMicrophoneName
            )
        )
        meetings.insert(meeting, at: 0)
        selection = meeting.id
        persistMeetings()

        do {
            processingMessage = "Preservando o áudio antes da transcrição…"
            let preservedFiles = try recoveryAudio.preserve(files: files, meetingID: meetingID)
            audioRecorder?.removeTemporaryFiles()
            processingMessage = "Detectando idiomas e transcrevendo no Mac…"
            await transcribePreservedMeeting(meetingID: meetingID, files: preservedFiles)
        } catch {
            markTranscriptionFailure(meetingID: meetingID, error: error)
        }

        audioRecorder = nil
        captureEngine = nil
        microphoneEngine = nil
        startedAt = nil
        recordingStatus = .idle
        processingMessage = ""

    }

    func retryTranscription(meetingID: UUID) async {
        guard transcriptionMeetingID == nil else { return }
        let files = recoveryAudio.files(for: meetingID)
        guard !files.isEmpty else {
            let error = RecoveryAudioError.noAudio
            markTranscriptionFailure(meetingID: meetingID, error: error)
            return
        }
        await transcribePreservedMeeting(meetingID: meetingID, files: files)
    }

    func hasRecoveryAudio(for meetingID: UUID) -> Bool {
        !recoveryAudio.files(for: meetingID).isEmpty
    }

    func revealRecoveryAudio(meetingID: UUID) {
        let files = Array(recoveryAudio.files(for: meetingID).values)
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    func analyze(meetingID: UUID) async {
        guard analysisMeetingID == nil,
              let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].segments.isEmpty else { return }
        analysisMeetingID = meetingID
        do {
            var refreshedAnalysis = try await intelligence.analyze(segments: meetings[index].segments)
            guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                analysisMeetingID = nil
                return
            }
            let previousActions = meetings[currentIndex].analysis?.actionItems ?? []
            for actionIndex in refreshedAnalysis.actionItems.indices {
                if let previous = previousActions.first(where: {
                    $0.task.localizedCaseInsensitiveCompare(refreshedAnalysis.actionItems[actionIndex].task) == .orderedSame
                }) {
                    refreshedAnalysis.actionItems[actionIndex].isCompleted = previous.isCompleted
                    refreshedAnalysis.actionItems[actionIndex].completedAt = previous.completedAt
                }
            }
            meetings[currentIndex].analysis = refreshedAnalysis
            try store.save(meetings)
        } catch {
            errorMessage = error.localizedDescription
            analysisMeetingID = nil
            return
        }
        analysisMeetingID = nil
        await translateMeeting(meetingID: meetingID)
    }

    func translateMeeting(meetingID: UUID) async {
        guard translationMeetingID == nil,
              let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].segments.isEmpty else { return }
        translationMeetingID = meetingID
        do {
            let translated = try await intelligence.translate(segments: meetings[index].segments)
            guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                translationMeetingID = nil
                return
            }
            meetings[currentIndex].segments = translated
            try store.save(meetings)
        } catch {
            let prefix = meetings.first(where: { $0.id == meetingID })?.analysis == nil
                ? "Não foi possível traduzir"
                : "O resumo foi salvo, mas não foi possível concluir todas as traduções"
            errorMessage = "\(prefix): \(error.localizedDescription)"
        }
        translationMeetingID = nil
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        if selection == meeting.id { selection = meetings.first?.id }
        try? store.save(meetings)
        try? recoveryAudio.remove(meetingID: meeting.id)
    }

    func rename(_ meeting: Meeting, to title: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        meetings[index].title = clean
        try? store.save(meetings)
    }

    func toggleAction(meetingID: UUID, actionID: UUID) {
        guard let meetingIndex = meetings.firstIndex(where: { $0.id == meetingID }),
              let actionIndex = meetings[meetingIndex].analysis?.actionItems.firstIndex(where: { $0.id == actionID }) else {
            return
        }
        let completed = !(meetings[meetingIndex].analysis?.actionItems[actionIndex].isCompleted ?? false)
        meetings[meetingIndex].analysis?.actionItems[actionIndex].isCompleted = completed
        meetings[meetingIndex].analysis?.actionItems[actionIndex].completedAt = completed ? Date() : nil
        try? store.save(meetings)
    }

    func addTag(_ name: String, to meetingID: UUID) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].tags.contains(where: {
                  $0.localizedCaseInsensitiveCompare(clean) == .orderedSame
              }) else { return }
        meetings[index].tags.append(clean)
        meetings[index].tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        try? store.save(meetings)
    }

    func removeTag(_ name: String, from meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[index].tags.removeAll { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
        if selectedTagFilter?.localizedCaseInsensitiveCompare(name) == .orderedSame,
           !meetings.contains(where: { $0.tags.contains(name) }) {
            selectedTagFilter = nil
        }
        try? store.save(meetings)
    }

    func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = sanitizedFilename(meeting.title) + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try meeting.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Não foi possível exportar: \(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func selectMicrophone(_ id: String) {
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: "selectedMicrophoneID")
    }

    private func refreshModelStatus() {
        if whisper.executableURL == nil {
            modelStatus = .unavailable("whisper.cpp não instalado")
        } else {
            modelStatus = whisper.isReady ? .ready : .needsDownload
        }
    }

    private func requestPermissions() async throws {
        let microphone: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = true
        case .notDetermined:
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphone = false
        }
        microphoneAccess = microphone ? .granted : .denied
        guard microphone else { throw PermissionError.microphone }

        if CGPreflightScreenCaptureAccess() {
            systemAudioAccess = .granted
        } else {
            let granted = CGRequestScreenCaptureAccess()
            systemAudioAccess = granted ? .granted : .denied
            guard granted else { throw PermissionError.systemAudio }
        }
    }

    private func refreshPermissionStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneAccess = .granted
        case .denied, .restricted: microphoneAccess = .denied
        default: microphoneAccess = .unknown
        }
        systemAudioAccess = CGPreflightScreenCaptureAccess() ? .granted : .unknown
    }

    private func refreshMicrophones() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        microphones = devices.map { MicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let saved = UserDefaults.standard.string(forKey: "selectedMicrophoneID")
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        selectedMicrophoneID = microphones.contains(where: { $0.id == saved })
            ? (saved ?? "")
            : (defaultID ?? microphones.first?.id ?? "")
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                self.microphoneIsReceivingAudio = self.audioRecorder?.microphoneHasData ?? false
                self.systemIsReceivingAudio = self.audioRecorder?.systemAudioHasData ?? false
            }
        }
    }

    private func transcribePreservedMeeting(
        meetingID: UUID,
        files: [AudioSource: URL]
    ) async {
        guard transcriptionMeetingID == nil,
              let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        transcriptionMeetingID = meetingID
        meetings[index].transcriptionAttemptCount += 1
        meetings[index].transcriptionError = nil
        persistMeetings()

        do {
            let segments = try await whisper.transcribe(files: files)
            guard !segments.isEmpty else { throw WhisperError.noSpeechRecognized }
            guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                transcriptionMeetingID = nil
                return
            }
            meetings[currentIndex].segments = segments
            meetings[currentIndex].transcriptionError = nil
            try store.save(meetings)
            do {
                try recoveryAudio.remove(meetingID: meetingID)
            } catch {
                errorMessage = "A transcrição foi salva, mas o áudio temporário não pôde ser removido: \(error.localizedDescription)"
            }
            transcriptionMeetingID = nil
            Task { await analyze(meetingID: meetingID) }
        } catch {
            markTranscriptionFailure(meetingID: meetingID, error: error)
            transcriptionMeetingID = nil
        }
    }

    private func markTranscriptionFailure(meetingID: UUID, error: Error) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        let message = error.localizedDescription
        meetings[index].transcriptionError = message
        persistMeetings()
        errorMessage = message
    }

    private func persistMeetings() {
        do {
            try store.save(meetings)
        } catch {
            errorMessage = "Não foi possível salvar a reunião: \(error.localizedDescription)"
        }
    }

    private func defaultTitle(for date: Date) -> String {
        "Reunião de \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func sanitizedFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^a-zA-Z0-9À-ÿ -]", with: "", options: .regularExpression)
    }
}

enum PermissionError: LocalizedError {
    case microphone
    case systemAudio

    var errorDescription: String? {
        switch self {
        case .microphone:
            "Permita o LocalMeet em Ajustes do Sistema › Privacidade e Segurança › Microfone."
        case .systemAudio:
            "Permita o LocalMeet em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema. Depois, reabra o app."
        }
    }
}
