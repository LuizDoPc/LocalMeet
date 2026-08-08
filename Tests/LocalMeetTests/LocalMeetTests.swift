import AVFoundation
import Foundation
import NaturalLanguage
import Testing
@testable import LocalMeet

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
        tags: ["Cliente", "Produto"]
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
    #expect(loaded.markdown.contains("Transcrito localmente"))
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
    defer { try? FileManager.default.removeItem(at: output) }

    let asset = AVURLAsset(url: sample)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(readerOutput)
    #expect(reader.startReading())

    let writer = SampleBufferChannelWriter(url: output)
    while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
        writer.append(sampleBuffer)
    }
    let capturedURL = writer.finish()
    #expect(capturedURL != nil)
    #expect(writer.receivedSignal)
    #expect((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 10_000)
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
