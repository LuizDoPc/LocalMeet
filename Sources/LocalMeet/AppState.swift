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
    @Published private(set) var processingQueue: [ProcessingRequest] = []
    @Published private(set) var processingProgress: [UUID: MeetingProcessingProgress] = [:]
    @Published var errorMessage: String?
    @Published var microphoneAccess: AccessStatus = .unknown
    @Published var systemAudioAccess: AccessStatus = .unknown
    @Published var microphoneIsReceivingAudio = false
    @Published var systemIsReceivingAudio = false
    @Published var isMicrophoneMuted = false
    @Published var microphones: [MicrophoneOption] = []
    @Published var selectedMicrophoneID = ""

    private let store: MeetingStore
    private let whisper: WhisperEngine
    private let recoveryAudio: RecoveryAudioStore
    private let queueStore: ProcessingQueueStore
    private let intelligence = LocalIntelligenceEngine()
    private var captureEngine: MeetingCaptureEngine?
    private var microphoneEngine: MicrophoneCaptureEngine?
    private var audioRecorder: TemporaryAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var queueWorker: Task<Void, Never>?

    init(
        store: MeetingStore = MeetingStore(),
        whisper: WhisperEngine = WhisperEngine(),
        recoveryAudio: RecoveryAudioStore? = nil
    ) {
        self.store = store
        self.whisper = whisper
        self.recoveryAudio = recoveryAudio ?? RecoveryAudioStore(baseDirectory: whisper.applicationSupport)
        queueStore = ProcessingQueueStore(baseDirectory: whisper.applicationSupport)
        meetings = store.load().sorted { $0.startedAt > $1.startedAt }
        let meetingIDs = Set(meetings.map(\.id))
        processingQueue = queueStore.load().filter { meetingIDs.contains($0.meetingID) }
        selection = meetings.first?.id
        restoreQueueProgress()
        try? queueStore.save(processingQueue)
        refreshMicrophones()
        Task { @MainActor [weak self] in
            self?.refreshModelStatus()
            self?.refreshPermissionStatus()
            self?.startQueueWorker()
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

    func toggleMicrophoneMute() {
        guard isRecording else { return }
        isMicrophoneMuted.toggle()
        audioRecorder?.setMicrophoneMuted(isMicrophoneMuted)
        if isMicrophoneMuted { microphoneIsReceivingAudio = false }
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
            isMicrophoneMuted = false
            recorder.setMicrophoneMuted(false)
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
            isMicrophoneMuted = false
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
            _ = try recoveryAudio.preserve(files: files, meetingID: meetingID)
            audioRecorder?.removeTemporaryFiles()
            enqueue(meetingID: meetingID, kind: .fullPipeline)
        } catch {
            markTranscriptionFailure(meetingID: meetingID, error: error)
        }

        audioRecorder = nil
        captureEngine = nil
        microphoneEngine = nil
        startedAt = nil
        isMicrophoneMuted = false
        recordingStatus = .idle
        processingMessage = ""

    }

    func retryTranscription(meetingID: UUID) async {
        let files = recoveryAudio.files(for: meetingID)
        guard !files.isEmpty else {
            let error = RecoveryAudioError.noAudio
            markTranscriptionFailure(meetingID: meetingID, error: error)
            return
        }
        enqueue(meetingID: meetingID, kind: .fullPipeline)
    }

    func hasRecoveryAudio(for meetingID: UUID) -> Bool {
        !recoveryAudio.files(for: meetingID).isEmpty
    }

    func isQueuedOrProcessing(_ meetingID: UUID) -> Bool {
        processingQueue.contains { $0.meetingID == meetingID }
    }

    func revealRecoveryAudio(meetingID: UUID) {
        let files = Array(recoveryAudio.files(for: meetingID).values)
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    func analyze(meetingID: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.segments.isEmpty else { return }
        enqueue(meetingID: meetingID, kind: .summaryAndTranslation)
    }

    func translateMeeting(meetingID: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.segments.isEmpty else { return }
        enqueue(meetingID: meetingID, kind: .translationOnly)
    }

    func delete(_ meeting: Meeting) {
        processingQueue.removeAll { $0.meetingID == meeting.id }
        processingProgress.removeValue(forKey: meeting.id)
        persistQueue()
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
                self.microphoneIsReceivingAudio = !self.isMicrophoneMuted
                    && (self.audioRecorder?.microphoneHasData ?? false)
                self.systemIsReceivingAudio = self.audioRecorder?.systemAudioHasData ?? false
            }
        }
    }

    private func enqueue(meetingID: UUID, kind: ProcessingRequestKind) {
        guard meetings.contains(where: { $0.id == meetingID }) else { return }
        guard !processingQueue.contains(where: { $0.meetingID == meetingID }) else { return }

        processingQueue.append(ProcessingRequest(meetingID: meetingID, kind: kind))
        refreshQueuePositions()
        persistQueue()
        startQueueWorker()
    }

    private func startQueueWorker() {
        guard queueWorker == nil, !processingQueue.isEmpty else { return }
        queueWorker = Task { @MainActor [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    private func drainProcessingQueue() async {
        while let request = processingQueue.first {
            await process(request)
            if processingQueue.first == request {
                processingQueue.removeFirst()
            } else {
                processingQueue.removeAll { $0 == request }
            }
            refreshQueuePositions()
            persistQueue()
        }
        queueWorker = nil
        if !processingQueue.isEmpty { startQueueWorker() }
    }

    private func process(_ request: ProcessingRequest) async {
        guard meetings.contains(where: { $0.id == request.meetingID }) else { return }

        do {
            switch request.kind {
            case .fullPipeline:
                if meetings.first(where: { $0.id == request.meetingID })?.segments.isEmpty != false {
                    try await performTranscription(meetingID: request.meetingID)
                }
                try await performSummary(meetingID: request.meetingID)
                try await performTranslation(meetingID: request.meetingID)
            case .summaryAndTranslation:
                try await performSummary(meetingID: request.meetingID)
                try await performTranslation(meetingID: request.meetingID)
            case .translationOnly:
                try await performTranslation(meetingID: request.meetingID)
            }
            processingProgress[request.meetingID] = MeetingProcessingProgress(
                stage: .completed,
                transcription: 1,
                summary: meetings.first(where: { $0.id == request.meetingID })?.analysis == nil ? 0 : 1,
                translation: 1
            )
        } catch {
            refreshModelStatus()
            if case .transcribing = processingProgress[request.meetingID]?.stage {
                markTranscriptionFailure(meetingID: request.meetingID, error: error)
            } else {
                let prefix: String
                if case .translating = processingProgress[request.meetingID]?.stage,
                   meetings.first(where: { $0.id == request.meetingID })?.analysis != nil {
                    prefix = "O resumo foi salvo, mas as traduções não foram concluídas"
                } else {
                    prefix = "Não foi possível concluir o processamento"
                }
                errorMessage = "\(prefix): \(error.localizedDescription)"
            }
            var progress = processingProgress[request.meetingID]
                ?? progressSnapshot(meetingID: request.meetingID, stage: .failed(error.localizedDescription))
            progress.stage = .failed(error.localizedDescription)
            processingProgress[request.meetingID] = progress
        }

        transcriptionMeetingID = nil
        analysisMeetingID = nil
        translationMeetingID = nil
    }

    private func performTranscription(meetingID: UUID) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        let files = recoveryAudio.files(for: meetingID)
        guard !files.isEmpty else { throw RecoveryAudioError.noAudio }

        transcriptionMeetingID = meetingID
        meetings[index].transcriptionAttemptCount += 1
        meetings[index].transcriptionError = nil
        processingProgress[meetingID] = progressSnapshot(meetingID: meetingID, stage: .transcribing)
        persistMeetings()

        if !whisper.isReady {
            modelStatus = .downloading
            try await whisper.ensureModel()
            modelStatus = .ready
        }

        let accumulator = AudioProgressAccumulator(sources: Array(files.keys))
        let segments = try await whisper.transcribe(files: files) { [weak self] source, fraction in
            let combined = await accumulator.update(source: source, fraction: fraction)
            await self?.setTranscriptionProgress(meetingID: meetingID, fraction: combined)
        }
        guard !segments.isEmpty else { throw WhisperError.noSpeechRecognized }
        guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[currentIndex].segments = segments
        meetings[currentIndex].transcriptionError = nil
        try store.save(meetings)
        setTranscriptionProgress(meetingID: meetingID, fraction: 1)
        transcriptionMeetingID = nil

        do {
            try recoveryAudio.remove(meetingID: meetingID)
        } catch {
            errorMessage = "A transcrição foi salva, mas o áudio temporário não pôde ser removido: \(error.localizedDescription)"
        }
    }

    private func performSummary(meetingID: UUID) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].segments.isEmpty else { throw WhisperError.noSpeechRecognized }
        analysisMeetingID = meetingID
        updateStage(meetingID: meetingID, stage: .summarizing)

        var refreshedAnalysis = try await intelligence.analyze(
            segments: meetings[index].segments
        ) { [weak self] fraction in
            await self?.setSummaryProgress(meetingID: meetingID, fraction: fraction)
        }
        guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
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
        setSummaryProgress(meetingID: meetingID, fraction: 1)
        analysisMeetingID = nil
    }

    private func performTranslation(meetingID: UUID) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].segments.isEmpty else { throw WhisperError.noSpeechRecognized }
        translationMeetingID = meetingID
        updateStage(meetingID: meetingID, stage: .translating)
        let translated = try await intelligence.translate(
            segments: meetings[index].segments
        ) { [weak self] fraction in
            await self?.setTranslationProgress(meetingID: meetingID, fraction: fraction)
        }
        guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[currentIndex].segments = translated
        try store.save(meetings)
        setTranslationProgress(meetingID: meetingID, fraction: 1)
        translationMeetingID = nil
    }

    private func setTranscriptionProgress(meetingID: UUID, fraction: Double) {
        var progress = processingProgress[meetingID]
            ?? progressSnapshot(meetingID: meetingID, stage: .transcribing)
        progress.stage = .transcribing
        progress.transcription = clamped(fraction)
        processingProgress[meetingID] = progress
    }

    private func setSummaryProgress(meetingID: UUID, fraction: Double) {
        var progress = processingProgress[meetingID]
            ?? progressSnapshot(meetingID: meetingID, stage: .summarizing)
        progress.stage = .summarizing
        progress.summary = clamped(fraction)
        processingProgress[meetingID] = progress
    }

    private func setTranslationProgress(meetingID: UUID, fraction: Double) {
        var progress = processingProgress[meetingID]
            ?? progressSnapshot(meetingID: meetingID, stage: .translating)
        progress.stage = .translating
        progress.translation = clamped(fraction)
        processingProgress[meetingID] = progress
    }

    private func updateStage(meetingID: UUID, stage: MeetingProcessingStage) {
        var progress = processingProgress[meetingID] ?? progressSnapshot(meetingID: meetingID, stage: stage)
        progress.stage = stage
        processingProgress[meetingID] = progress
    }

    private func progressSnapshot(
        meetingID: UUID,
        stage: MeetingProcessingStage
    ) -> MeetingProcessingProgress {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            return MeetingProcessingProgress(stage: stage, transcription: 0, summary: 0, translation: 0)
        }
        var snapshot = MeetingProcessingProgress.queued(position: 1, meeting: meeting)
        snapshot.stage = stage
        return snapshot
    }

    private func restoreQueueProgress() {
        for (index, request) in processingQueue.enumerated() {
            guard let meeting = meetings.first(where: { $0.id == request.meetingID }) else { continue }
            processingProgress[request.meetingID] = .queued(position: index + 1, meeting: meeting)
        }
    }

    private func refreshQueuePositions() {
        for (index, request) in processingQueue.enumerated() {
            guard let meeting = meetings.first(where: { $0.id == request.meetingID }) else { continue }
            if index > 0 || {
                guard let current = processingProgress[request.meetingID] else { return true }
                if case .queued = current.stage { return true }
                return false
            }() {
                processingProgress[request.meetingID] = .queued(position: index + 1, meeting: meeting)
            }
        }
    }

    private func persistQueue() {
        do {
            try queueStore.save(processingQueue)
        } catch {
            errorMessage = "Não foi possível salvar a fila de processamento: \(error.localizedDescription)"
        }
    }

    private func clamped(_ fraction: Double) -> Double {
        min(1, max(0, fraction))
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
