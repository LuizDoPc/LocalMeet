import AVFoundation
import Foundation
import NaturalLanguage
import Testing
@testable import LocalMeet

private actor LiveChunkCollector {
    private var values: [LiveAudioChunk] = []

    func append(_ chunk: LiveAudioChunk) { values.append(chunk) }
    func chunks() -> [LiveAudioChunk] { values }
}

@Test func meetingRoundTripAndMarkdownExport() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let meeting = Meeting(
        title: "Planejamento semanal",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 125,
        localeIdentifier: "pt-BR",
        segments: [
            TranscriptSegment(
                source: .meeting,
                offset: 3,
                text: "Vamos começar.",
                detectedLanguage: "pt",
                translations: ["en": "Let's begin.", "de": "Fangen wir an."]
            ),
            TranscriptSegment(source: .microphone, offset: 8, text: "Perfeito.")
        ],
        analysis: MeetingAnalysis(
            summary: "Planejamento da semana.",
            decisions: [],
            actionItems: [
                ActionItem(
                    task: "Enviar relatório",
                    owner: "Ana",
                    dueDate: "sexta-feira",
                    isCompleted: true,
                    completedAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
            ],
            keyDates: []
        ),
        tags: ["Cliente", "Produto"],
        transcriptionError: "Retry available",
        transcriptionAttemptCount: 2
    )
    let store = MeetingStore(baseDirectory: directory)
    try store.save([meeting])

    let loaded = try #require(store.load().first)
    #expect(loaded == meeting)
    #expect(loaded.markdown.contains("**[00:03] Reunião · Português:** Vamos começar."))
    #expect(loaded.segments[0].translations["de"] == "Fangen wir an.")
    #expect(loaded.tags == ["Cliente", "Produto"])
    #expect(loaded.analysis?.actionItems.first?.isCompleted == true)
    #expect(loaded.analysis?.actionItems.first?.completedAt != nil)
    #expect(loaded.transcriptionError == "Retry available")
    #expect(loaded.transcriptionAttemptCount == 2)
    #expect(loaded.markdown.contains("Transcrito localmente"))
}

@Test func recoveryAudioSurvivesUntilExplicitCleanup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-recovery-test-\(UUID().uuidString)", isDirectory: true)
    let captureDirectory = directory.appendingPathComponent("capture", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

    let meetingAudio = captureDirectory.appendingPathComponent("meeting.caf")
    let microphoneAudio = captureDirectory.appendingPathComponent("microphone.caf")
    try Data(repeating: 0x31, count: 4_096).write(to: meetingAudio)
    try Data(repeating: 0x42, count: 2_048).write(to: microphoneAudio)

    let meetingID = UUID()
    let store = RecoveryAudioStore(baseDirectory: directory)
    let preserved = try store.preserve(
        files: [.meeting: meetingAudio, .microphone: microphoneAudio],
        meetingID: meetingID
    )

    try FileManager.default.removeItem(at: captureDirectory)
    #expect(preserved.count == 2)
    #expect(store.files(for: meetingID).keys.contains(.meeting))
    #expect(store.files(for: meetingID).keys.contains(.microphone))
    #expect(FileManager.default.fileExists(atPath: preserved[.meeting]!.path))
    #expect(FileManager.default.fileExists(atPath: preserved[.microphone]!.path))

    try store.remove(meetingID: meetingID)
    #expect(store.files(for: meetingID).isEmpty)
}

@Test func processingQueuePersistsOrderAndProgressStartsAtTheRightStage() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-queue-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstID = UUID()
    let secondID = UUID()
    let requests = [
        ProcessingRequest(meetingID: firstID, kind: .fullPipeline, summaryProvider: .claude),
        ProcessingRequest(meetingID: secondID, kind: .translationOnly)
    ]
    let store = ProcessingQueueStore(baseDirectory: directory)
    try store.save(requests)
    #expect(store.load() == requests)
    #expect(store.load().first?.summaryProvider == .claude)

    let emptyMeeting = Meeting(
        id: firstID,
        title: "Aguardando",
        startedAt: Date(),
        duration: 30,
        localeIdentifier: "pt+en+de",
        segments: []
    )
    let emptyProgress = MeetingProcessingProgress.queued(position: 2, meeting: emptyMeeting)
    #expect(emptyProgress.stage == .queued(position: 2))
    #expect(emptyProgress.transcription == 0)
    #expect(emptyProgress.summary == 0)
    #expect(emptyProgress.translation == 0)

    let translatedMeeting = Meeting(
        id: secondID,
        title: "Pronta",
        startedAt: Date(),
        duration: 30,
        localeIdentifier: "pt+en+de",
        segments: [
            TranscriptSegment(
                source: .meeting,
                offset: 0,
                text: "Hallo",
                detectedLanguage: "de",
                translations: ["pt": "Olá", "en": "Hello", "de": "Hallo"]
            )
        ],
        analysis: MeetingAnalysis(summary: "Resumo", decisions: [], actionItems: [], keyDates: [])
    )
    let translatedProgress = MeetingProcessingProgress.queued(position: 1, meeting: translatedMeeting)
    #expect(translatedProgress.transcription == 1)
    #expect(translatedProgress.summary == 1)
    #expect(translatedProgress.translation == 1)
}

@Test func claudeLocalInstallationProducesStructuredMeetingAnalysis() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-claude-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("claude")
    let response = #"{"is_error":false,"structured_output":{"summary":"Resumo pelo Claude","decisions":["Aprovado"],"actionItems":[{"task":"Enviar ata","owner":"Ana","dueDate":"sexta-feira"}],"keyDates":[{"date":"sexta-feira","context":"Envio da ata"}]}}"#
    let script = """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' '\(response)'
        """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let engine = ClaudeCLIEngine(executableURL: executable, workingDirectory: directory)

    let analysis = try await engine.analyze(segments: [
        TranscriptSegment(source: .meeting, offset: 0, text: "Ana enviará a ata na sexta-feira.")
    ])

    #expect(analysis.summary == "Resumo pelo Claude")
    #expect(analysis.summaryProvider == .claude)
    #expect(analysis.decisions == ["Aprovado"])
    #expect(analysis.actionItems.first?.task == "Enviar ata")
    #expect(analysis.actionItems.first?.owner == "Ana")
    #expect(analysis.keyDates.first?.date == "sexta-feira")
}

@Test func installedClaudeGeneratesMeetingAnalysis() async throws {
    guard ProcessInfo.processInfo.environment["LOCALMEET_CLAUDE_TEST"] == "1",
          let executable = ClaudeCLIEngine.locateExecutable() else { return }
    let workingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-installed-claude-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workingDirectory) }
    let analysis = try await ClaudeCLIEngine(
        executableURL: executable,
        workingDirectory: workingDirectory
    ).analyze(segments: [
        TranscriptSegment(
            source: .meeting,
            offset: 0,
            text: "A equipe aprovou o lançamento para 12 de setembro."
        ),
        TranscriptSegment(
            source: .microphone,
            offset: 5,
            text: "Ana enviará as notas da versão até sexta-feira."
        )
    ])
    #expect(analysis.summaryProvider == .claude)
    #expect(!analysis.summary.isEmpty)
    #expect(!analysis.decisions.isEmpty)
    #expect(analysis.actionItems.contains { $0.owner?.localizedCaseInsensitiveContains("Ana") == true })
}

@Test func localMultilingualIntelligence() async throws {
    guard ProcessInfo.processInfo.environment["LOCALMEET_AI_TEST"] == "1" else { return }
    let segments = [
        TranscriptSegment(
            source: .meeting,
            offset: 0,
            text: "We will launch the beta on September 12. Anna will prepare the release notes."
        ),
        TranscriptSegment(
            source: .microphone,
            offset: 8,
            text: "Perfekt, ich schicke die finale Liste bis Freitag."
        ),
        TranscriptSegment(
            source: .meeting,
            offset: 14,
            text: "Combinado. O responsável pela revisão será o Marcos."
        )
    ]

    let result = try await LocalIntelligenceEngine().process(segments: segments)
    #expect(result.segments.count == 3)
    #expect(result.segments.allSatisfy { !$0.translations["pt", default: ""].isEmpty })
    let german = try #require(result.segments.first?.translations["de"])
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(german)
    #expect(recognizer.dominantLanguage == .german)
    #expect(!result.analysis.summary.isEmpty)
    #expect(!result.analysis.actionItems.isEmpty)
}

@Test func localLongMeetingIntelligence() async throws {
    guard let directoryPath = ProcessInfo.processInfo.environment["LOCALMEET_LONG_MEETING_DIRECTORY"] else {
        return
    }
    let meetings = MeetingStore(baseDirectory: URL(fileURLWithPath: directoryPath)).load()
    let meeting = try #require(meetings.first(where: { !$0.segments.isEmpty }))

    let result = try await LocalIntelligenceEngine().process(segments: meeting.segments)
    #expect(result.segments.count == meeting.segments.count)
    #expect(result.segments.allSatisfy { !$0.translations["pt", default: ""].isEmpty })
    #expect(!result.analysis.summary.isEmpty)
}

@Test func localLongMeetingAnalysis() async throws {
    guard let directoryPath = ProcessInfo.processInfo.environment["LOCALMEET_LONG_ANALYSIS_DIRECTORY"] else {
        return
    }
    let meetings = MeetingStore(baseDirectory: URL(fileURLWithPath: directoryPath)).load()
    let meeting = try #require(meetings.first(where: { !$0.segments.isEmpty }))

    let analysis = try await LocalIntelligenceEngine().analyze(segments: meeting.segments)
    #expect(!analysis.summary.isEmpty)
}

@Test func localWhisperTranscription() async throws {
    guard ProcessInfo.processInfo.environment["LOCALMEET_WHISPER_TEST"] == "1" else { return }
    let sample = URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/jfk.wav")
    guard FileManager.default.fileExists(atPath: sample.path) else { return }

    let engine = WhisperEngine()
    #expect(engine.isReady)
    let segments = try await engine.transcribe(files: [.meeting: sample, .microphone: sample])
    #expect(segments.first?.detectedLanguage == "en")
    #expect(segments.map(\.text).joined().localizedCaseInsensitiveContains("fellow Americans"))
    #expect(Set(segments.map(\.source)) == Set([.meeting, .microphone]))
}

@Test func temporaryAudioCapturePipeline() async throws {
    guard ProcessInfo.processInfo.environment["LOCALMEET_AUDIO_TEST"] == "1" else { return }
    let sample = URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/jfk.wav")
    guard FileManager.default.fileExists(atPath: sample.path) else { return }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-capture-\(UUID().uuidString).caf")
    let liveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-live-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: output) }
    defer { try? FileManager.default.removeItem(at: liveDirectory) }
    let collector = LiveChunkCollector()
    let mutedRecorder = try TemporaryAudioRecorder(
        liveTranscriptionDirectory: liveDirectory,
        liveChunkDuration: 1
    ) { chunk in
        Task { await collector.append(chunk) }
    }
    defer { mutedRecorder.removeTemporaryFiles() }
    mutedRecorder.setMicrophoneMuted(true)

    let asset = AVURLAsset(url: sample)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(readerOutput)
    #expect(reader.startReading())

    let writer = SampleBufferChannelWriter(url: output)
    while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
        writer.append(sampleBuffer)
        mutedRecorder.appendMicrophone(sampleBuffer)
    }
    let capturedURL = writer.finish()
    let mutedURL = try #require(await mutedRecorder.finish()[.microphone])
    #expect(capturedURL != nil)
    #expect(writer.receivedSignal)
    #expect(!mutedRecorder.microphoneHasData)
    #expect((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 10_000)

    let originalAudio = try AVAudioFile(forReading: output)
    let mutedAudio = try AVAudioFile(forReading: mutedURL)
    #expect(mutedAudio.length == originalAudio.length)
    try await Task.sleep(for: .milliseconds(100))
    let liveChunks = await collector.chunks()
    #expect(liveChunks.count >= 2)
    #expect(liveChunks.allSatisfy { $0.source == .microphone })
    #expect(zip(liveChunks, liveChunks.dropFirst()).allSatisfy { $0.0.offset < $0.1.offset })
    #expect(liveChunks.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
}

@Test func dynamicLanguageSwitching() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALMEET_MULTILINGUAL_AUDIO"] else { return }
    let audio = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: audio.path) else { return }

    let segments = try await WhisperEngine().transcribe(files: [.meeting: audio])
    let languages = Set(segments.map(\.detectedLanguage))
    #expect(languages.contains("pt"))
    #expect(languages.contains("en"))
    #expect(languages.contains("de"))
}

@Test @MainActor func tagsAndActionCompletionPersist() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(baseDirectory: directory)
    let action = ActionItem(task: "Publicar release", owner: "Luiz")
    let meeting = Meeting(
        title: "Release",
        startedAt: Date(),
        duration: 60,
        localeIdentifier: "pt+en+de",
        segments: [TranscriptSegment(source: .microphone, offset: 0, text: "Vamos publicar.")],
        analysis: MeetingAnalysis(
            summary: "Release",
            decisions: [],
            actionItems: [action],
            keyDates: []
        )
    )
    let state = AppState(store: store)
    state.meetings = [meeting]

    state.addTag("Produto", to: meeting.id)
    state.toggleAction(meetingID: meeting.id, actionID: action.id)

    let saved = try #require(store.load().first)
    #expect(saved.tags == ["Produto"])
    #expect(saved.analysis?.actionItems.first?.isCompleted == true)
    #expect(saved.analysis?.actionItems.first?.completedAt != nil)
}

@Test @MainActor func generatedContentEditsAndDeletesPersist() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("localmeet-editing-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(baseDirectory: directory)
    let keptAction = ActionItem(task: "Errado", owner: "Pessoa errada", dueDate: "amanhã")
    let removedAction = ActionItem(task: "Remover")
    let keptDate = KeyDate(date: "10/10", context: "Contexto errado")
    let removedDate = KeyDate(date: "11/11", context: "Remover")
    let segment = TranscriptSegment(
        source: .meeting,
        offset: 0,
        text: "Texto com typoo",
        detectedLanguage: "pt",
        translations: ["en": "Text with typoo"]
    )
    let meeting = Meeting(
        title: "Nome antigo",
        startedAt: Date(),
        duration: 60,
        localeIdentifier: "pt+en+de",
        segments: [segment],
        analysis: MeetingAnalysis(
            summary: "Resumo errado",
            decisions: ["Decisão errada", "Remover decisão"],
            actionItems: [keptAction, removedAction],
            keyDates: [keptDate, removedDate]
        )
    )
    try store.save([meeting])
    let state = AppState(
        store: store,
        whisper: WhisperEngine(applicationSupport: directory),
        recoveryAudio: RecoveryAudioStore(baseDirectory: directory)
    )

    state.rename(meeting, to: "Nome corrigido")
    state.updateSummary(meetingID: meeting.id, text: "Resumo corrigido")
    state.updateDecision(meetingID: meeting.id, index: 0, text: "Decisão corrigida")
    state.deleteDecision(meetingID: meeting.id, index: 1)
    state.updateAction(
        meetingID: meeting.id,
        actionID: keptAction.id,
        task: "Enviar documento",
        owner: "Ana",
        dueDate: "sexta-feira"
    )
    state.deleteAction(meetingID: meeting.id, actionID: removedAction.id)
    state.updateKeyDate(
        meetingID: meeting.id,
        keyDateID: keptDate.id,
        date: "12/10",
        context: "Lançamento"
    )
    state.deleteKeyDate(meetingID: meeting.id, keyDateID: removedDate.id)
    state.updateTranscriptSegment(
        meetingID: meeting.id,
        segmentID: segment.id,
        original: "Texto sem typo",
        translationLanguage: "en",
        translation: "Text without typo"
    )

    let saved = try #require(store.load().first)
    #expect(saved.title == "Nome corrigido")
    #expect(saved.analysis?.summary == "Resumo corrigido")
    #expect(saved.analysis?.decisions == ["Decisão corrigida"])
    #expect(saved.analysis?.actionItems.map(\.task) == ["Enviar documento"])
    #expect(saved.analysis?.actionItems.first?.owner == "Ana")
    #expect(saved.analysis?.actionItems.first?.dueDate == "sexta-feira")
    #expect(saved.analysis?.keyDates.map(\.date) == ["12/10"])
    #expect(saved.analysis?.keyDates.first?.context == "Lançamento")
    #expect(saved.segments.first?.text == "Texto sem typo")
    #expect(saved.segments.first?.translations["en"] == "Text without typo")
    #expect(saved.markdown.contains("Resumo corrigido"))
    #expect(saved.markdown.contains("Enviar documento"))
}
