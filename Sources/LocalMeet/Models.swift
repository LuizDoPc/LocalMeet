import Foundation

enum SummaryProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "LLM local"
        case .claude: "Claude"
        }
    }

    var detail: String {
        switch self {
        case .local: "Apple Intelligence · tudo permanece neste Mac"
        case .claude: "Claude Code instalado · envia a transcrição para a Anthropic"
        }
    }
}

enum AudioSource: String, Codable, CaseIterable, Sendable {
    case meeting
    case microphone

    var label: String {
        switch self {
        case .meeting: "Reunião"
        case .microphone: "Você"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let source: AudioSource
    let offset: TimeInterval
    var text: String
    var detectedLanguage: String
    var translations: [String: String]

    init(
        id: UUID = UUID(),
        source: AudioSource,
        offset: TimeInterval,
        text: String,
        detectedLanguage: String = "und",
        translations: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.offset = offset
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detectedLanguage = detectedLanguage
        self.translations = translations
    }

    var timestamp: String {
        let total = max(0, Int(offset))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var languageLabel: String {
        switch detectedLanguage.lowercased() {
        case "pt", "pt-br": "Português"
        case "en", "en-us": "English"
        case "de", "de-de": "Deutsch"
        default: "Idioma automático"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, offset, text, detectedLanguage, translations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(AudioSource.self, forKey: .source)
        offset = try values.decode(TimeInterval.self, forKey: .offset)
        text = try values.decode(String.self, forKey: .text)
        detectedLanguage = try values.decodeIfPresent(String.self, forKey: .detectedLanguage) ?? "und"
        translations = try values.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
    }
}

struct ActionItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var task: String
    var owner: String?
    var dueDate: String?
    var isCompleted: Bool
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        task: String,
        owner: String? = nil,
        dueDate: String? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, task, owner, dueDate, isCompleted, completedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try values.decode(String.self, forKey: .task)
        owner = try values.decodeIfPresent(String.self, forKey: .owner)
        dueDate = try values.decodeIfPresent(String.self, forKey: .dueDate)
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

struct KeyDate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var date: String
    var context: String

    init(id: UUID = UUID(), date: String, context: String) {
        self.id = id
        self.date = date
        self.context = context
    }
}

struct MeetingAnalysis: Codable, Hashable, Sendable {
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var keyDates: [KeyDate]
    var summaryProvider: SummaryProvider? = nil
}

struct CaptureDiagnostics: Codable, Hashable, Sendable {
    var microphoneSignalDetected: Bool
    var systemSignalDetected: Bool
    var microphoneName: String
}

struct Meeting: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    let duration: TimeInterval
    let localeIdentifier: String
    var segments: [TranscriptSegment]
    var analysis: MeetingAnalysis?
    var tags: [String]
    var captureDiagnostics: CaptureDiagnostics?
    var transcriptionError: String?
    var transcriptionAttemptCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        localeIdentifier: String,
        segments: [TranscriptSegment],
        analysis: MeetingAnalysis? = nil,
        tags: [String] = [],
        captureDiagnostics: CaptureDiagnostics? = nil,
        transcriptionError: String? = nil,
        transcriptionAttemptCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.localeIdentifier = localeIdentifier
        self.segments = segments
        self.analysis = analysis
        self.tags = tags
        self.captureDiagnostics = captureDiagnostics
        self.transcriptionError = transcriptionError
        self.transcriptionAttemptCount = transcriptionAttemptCount
    }

    var durationLabel: String {
        let total = max(0, Int(duration))
        if total >= 3_600 {
            return String(format: "%dh %02dmin", total / 3_600, (total % 3_600) / 60)
        }
        return String(format: "%d min", max(1, total / 60))
    }

    var searchableText: String {
        var values = [title] + tags
        values += segments.flatMap { [$0.text] + Array($0.translations.values) }
        if let analysis {
            values += [analysis.summary]
            values += analysis.decisions
            values += analysis.actionItems.flatMap { [$0.task, $0.owner ?? "", $0.dueDate ?? ""] }
            values += analysis.keyDates.flatMap { [$0.date, $0.context] }
        }
        return values.joined(separator: " ")
    }

    var markdown: String {
        var lines = [
            "# \(title)",
            "",
            "**Data:** \(startedAt.formatted(date: .long, time: .shortened))  ",
            "**Duração:** \(durationLabel)  ",
            "**Idioma:** \(localeIdentifier)",
            "**Tags:** \(tags.isEmpty ? "—" : tags.joined(separator: ", "))",
            "",
            "## Transcrição",
            ""
        ]
        lines += segments.map { segment in
            var line = "**[\(segment.timestamp)] \(segment.source.label) · \(segment.languageLabel):** \(segment.text)"
            if let translated = segment.translations["pt"], translated != segment.text {
                line += "\n\n> Tradução: \(translated)"
            }
            return line
        }
        if let analysis {
            lines += ["", "## Resumo", "", analysis.summary]
            if !analysis.decisions.isEmpty {
                lines += ["", "## Decisões", ""] + analysis.decisions.map { "- \($0)" }
            }
            if !analysis.actionItems.isEmpty {
                lines += ["", "## Ações", ""] + analysis.actionItems.map {
                    "- [\($0.isCompleted ? "x" : " ")] \($0.task) — **Responsável:** \($0.owner ?? "Não definido") · **Prazo:** \($0.dueDate ?? "Não definido")\($0.completedAt.map { " · **Concluído em:** \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")"
                }
            }
            if !analysis.keyDates.isEmpty {
                lines += ["", "## Datas importantes", ""] + analysis.keyDates.map { "- **\($0.date):** \($0.context)" }
            }
        }
        lines.append("")
        lines.append("_Transcrito localmente com LocalMeet._")
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, localeIdentifier, segments, analysis, tags, captureDiagnostics
        case transcriptionError, transcriptionAttemptCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        localeIdentifier = try values.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "multilingual"
        segments = try values.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        analysis = try values.decodeIfPresent(MeetingAnalysis.self, forKey: .analysis)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        captureDiagnostics = try values.decodeIfPresent(CaptureDiagnostics.self, forKey: .captureDiagnostics)
        transcriptionError = try values.decodeIfPresent(String.self, forKey: .transcriptionError)
        transcriptionAttemptCount = try values.decodeIfPresent(Int.self, forKey: .transcriptionAttemptCount) ?? 0
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String

    static let supported = [
        LanguageOption(id: "pt", name: "Português"),
        LanguageOption(id: "en", name: "English"),
        LanguageOption(id: "de", name: "Deutsch")
    ]
}
