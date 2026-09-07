import Foundation

enum ProcessingRequestKind: String, Codable, Sendable {
    case fullPipeline
    case diarizationOnly
    case summaryAndTranslation
    case summaryOnly
    case translationOnly
}

struct ProcessingRequest: Codable, Equatable, Sendable {
    let meetingID: UUID
    let kind: ProcessingRequestKind
    let summaryProvider: SummaryProvider?

    init(
        meetingID: UUID,
        kind: ProcessingRequestKind,
        summaryProvider: SummaryProvider? = nil
    ) {
        self.meetingID = meetingID
        self.kind = kind
        self.summaryProvider = summaryProvider
    }
}

enum MeetingProcessingStage: Equatable, Sendable {
    case queued(position: Int)
    case transcribing
    case diarizing
    case summarizing
    case translating
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .queued(let position): "Na fila · posição \(position)"
        case .transcribing: "Transcrevendo áudio"
        case .diarizing: "Identificando participantes com WhisperX"
        case .summarizing: "Gerando resumo e ações"
        case .translating: "Traduzindo PT · EN · DE"
        case .completed: "Processamento concluído"
        case .failed: "Processamento interrompido"
        }
    }
}

struct MeetingProcessingProgress: Equatable, Sendable {
    var stage: MeetingProcessingStage
    var transcription: Double
    var diarization: Double = 0
    var summary: Double
    var translation: Double

    var activeFraction: Double {
        switch stage {
        case .queued: 0
        case .transcribing: transcription
        case .diarizing: diarization
        case .summarizing: summary
        case .translating: translation
        case .completed: 1
        case .failed: (transcription + diarization + summary + translation) / 4
        }
    }

    var isVisible: Bool {
        if case .completed = stage { return false }
        return true
    }

    static func queued(position: Int, meeting: Meeting) -> MeetingProcessingProgress {
        MeetingProcessingProgress(
            stage: .queued(position: position),
            transcription: meeting.segments.isEmpty ? 0 : 1,
            diarization: meeting.participants.isEmpty ? 0 : 1,
            summary: meeting.analysis == nil ? 0 : 1,
            translation: !meeting.segments.isEmpty && meeting.segments.allSatisfy { segment in
                ["pt", "en", "de"].allSatisfy { segment.translations[$0]?.isEmpty == false }
            } ? 1 : 0
        )
    }
}

final class ProcessingQueueStore {
    private let fileURL: URL

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("LocalMeet", isDirectory: true)
        fileURL = root.appendingPathComponent("processing-queue.json")
    }

    func load() -> [ProcessingRequest] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ProcessingRequest].self, from: data)) ?? []
    }

    func save(_ requests: [ProcessingRequest]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(requests)
        try data.write(to: fileURL, options: .atomic)
    }
}

actor AudioProgressAccumulator {
    private var values: [AudioSource: Double] = [:]
    private let sources: [AudioSource]

    init(sources: [AudioSource]) {
        self.sources = sources
    }

    func update(source: AudioSource, fraction: Double) -> Double {
        values[source] = min(1, max(0, fraction))
        guard !sources.isEmpty else { return 0 }
        return sources.reduce(0) { $0 + values[$1, default: 0] } / Double(sources.count)
    }
}
