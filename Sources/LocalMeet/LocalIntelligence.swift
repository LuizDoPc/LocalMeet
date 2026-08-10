import Foundation
import FoundationModels
import NaturalLanguage

enum LocalIntelligenceError: LocalizedError {
    case requiresMacOS26
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            "Resumo e tradução locais exigem macOS 26 ou mais recente."
        case .unavailable(let reason):
            "O modelo local do Apple Intelligence não está disponível: \(reason)"
        }
    }
}

struct IntelligenceResult: Sendable {
    var segments: [TranscriptSegment]
    var analysis: MeetingAnalysis
}

struct LocalIntelligenceEngine: Sendable {
    func process(segments: [TranscriptSegment]) async throws -> IntelligenceResult {
        guard #available(macOS 26.0, *) else {
            throw LocalIntelligenceError.requiresMacOS26
        }
        return try await AppleIntelligenceProcessor().process(segments: segments)
    }

    func analyze(
        segments: [TranscriptSegment],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> MeetingAnalysis {
        guard #available(macOS 26.0, *) else {
            throw LocalIntelligenceError.requiresMacOS26
        }
        return try await AppleIntelligenceProcessor().analyzeMeeting(segments, progress: progress)
    }

    func translate(
        segments: [TranscriptSegment],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard #available(macOS 26.0, *) else {
            throw LocalIntelligenceError.requiresMacOS26
        }
        return try await AppleIntelligenceProcessor().translateMeeting(segments, progress: progress)
    }
}

@available(macOS 26.0, *)
private struct AppleIntelligenceProcessor {
    private let translationCharacterLimit = 900
    private let analysisCharacterLimit = 2_400
    private let summaryCharacterLimit = 2_000

    func process(segments: [TranscriptSegment]) async throws -> IntelligenceResult {
        let analysis = try await analyzeMeeting(segments, progress: nil)
        let translated = try await translateMeeting(segments, progress: nil)
        return IntelligenceResult(segments: translated, analysis: analysis)
    }

    func translateMeeting(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [TranscriptSegment] {
        try requireAvailableModel()
        var translated = segments
        let batches = segmentBatches(
            translated,
            characterLimit: translationCharacterLimit,
            itemLimit: 8
        )
        await progress?(batches.isEmpty ? 1 : 0)
        for (batchIndex, indices) in batches.enumerated() {
            let batch = indices.map { translated[$0] }
            let rows = await translateSafely(batch)
            for row in rows where row.index >= 0 && row.index < batch.count {
                let index = indices[row.index]
                translated[index].detectedLanguage = normalizedLanguage(row.originalLanguage)
                translated[index].translations = [
                    "pt": row.portuguese,
                    "en": row.english,
                    "de": row.german
                ].filter { !$0.value.isEmpty }
            }
            await progress?(Double(batchIndex + 1) / Double(max(1, batches.count)))
        }
        return translated
    }

    func analyzeMeeting(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> MeetingAnalysis {
        try requireAvailableModel()
        return try await analyze(segments, progress: progress)
    }

    private func requireAvailableModel() throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LocalIntelligenceError.unavailable(String(describing: model.availability))
        }
    }

    private func translate(_ segments: [TranscriptSegment]) async throws -> [ValidatedTranslation] {
        var rows = segments.enumerated().map { index, segment in
            let language = detectedLanguage(for: segment.text, hint: segment.detectedLanguage)
            return ValidatedTranslation(
                index: index,
                originalLanguage: language,
                portuguese: language == "pt" ? segment.text : "",
                english: language == "en" ? segment.text : "",
                german: language == "de" ? segment.text : ""
            )
        }

        for target in ["pt", "en", "de"] {
            let translated = try await translate(segments, exclusivelyTo: target)
            for (index, text) in translated where index >= 0 && index < rows.count {
                switch target {
                case "pt": rows[index].portuguese = text
                case "en": rows[index].english = text
                case "de": rows[index].german = text
                default: break
                }
            }
        }
        return rows
    }

    private func translateSafely(_ segments: [TranscriptSegment]) async -> [ValidatedTranslation] {
        do {
            return try await translate(segments)
        } catch {
            guard segments.count > 1 else {
                guard let segment = segments.first else { return [] }
                return [await translateSingleFallback(segment)]
            }
            let midpoint = segments.count / 2
            let left = await translateSafely(Array(segments[..<midpoint]))
            let right = await translateSafely(Array(segments[midpoint...])).map {
                ValidatedTranslation(
                    index: $0.index + midpoint,
                    originalLanguage: $0.originalLanguage,
                    portuguese: $0.portuguese,
                    english: $0.english,
                    german: $0.german
                )
            }
            return left + right
        }
    }

    private func translateSingleFallback(_ segment: TranscriptSegment) async -> ValidatedTranslation {
        let language = detectedLanguage(for: segment.text, hint: segment.detectedLanguage)
        var values = ["pt": "", "en": "", "de": ""]
        for target in ["pt", "en", "de"] {
            if language == target {
                values[target] = segment.text
            } else if let translated = try? await retryTranslation(segment.text, target: target) {
                values[target] = translated
            }
        }
        return ValidatedTranslation(
            index: 0,
            originalLanguage: language,
            portuguese: values["pt", default: ""],
            english: values["en", default: ""],
            german: values["de", default: ""]
        )
    }

    private func translate(
        _ segments: [TranscriptSegment],
        exclusivelyTo target: String
    ) async throws -> [Int: String] {
        let targetName = targetLanguageName(target)
        let session = LanguageModelSession(instructions: """
            You are a professional translator. Translate every input exclusively into \(targetName), preserving names, numbers, dates and product terms. Never explain, summarize or answer the content. Return one plain-text line per input using exactly this format: [index] translation
            """)
        var result: [Int: String] = [:]
        let candidates = segments.enumerated().filter { index, segment in
            let language = detectedLanguage(for: segment.text, hint: segment.detectedLanguage)
            if language == target { result[index] = segment.text }
            return language != target
        }
        guard !candidates.isEmpty else { return result }
        let input = candidates.map { index, segment in "[\(index)] \(segment.text)" }
            .joined(separator: "\n")
        let response = try await session.respond(
            to: "Translate these indexed meeting lines into \(targetName):\n\(input)",
            options: GenerationOptions(maximumResponseTokens: 650)
        )

        for (index, text) in parseIndexedLines(response.content) where index >= 0 && index < segments.count {
            let original = segments[index].text
            let originalLanguage = detectedLanguage(
                for: original,
                hint: segments[index].detectedLanguage
            )
            if originalLanguage == target {
                result[index] = original
            } else if languageMatches(text, target: target) {
                result[index] = text
            } else if let retried = try await retryTranslation(original, target: target) {
                result[index] = retried
            }
        }
        for (index, segment) in candidates where result[index] == nil {
            if let retried = try await retryTranslation(segment.text, target: target) {
                result[index] = retried
            }
        }
        return result
    }

    private func parseIndexedLines(_ value: String) -> [(Int, String)] {
        value.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.first == "[", let closing = line.firstIndex(of: "]"),
                  let index = Int(line[line.index(after: line.startIndex)..<closing]) else {
                return nil
            }
            let text = line[line.index(after: closing)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-:— "))
            return text.isEmpty ? nil : (index, text)
        }
    }

    private func retryTranslation(_ text: String, target: String) async throws -> String? {
        let targetName = targetLanguageName(target)
        let instruction: String
        switch target {
        case "de": instruction = "Übersetze den Text ins Deutsche. Antworte ausschließlich mit der deutschen Übersetzung."
        case "pt": instruction = "Traduza o texto para português do Brasil. Responda somente com a tradução em português."
        default: instruction = "Translate the text into English. Reply only with the English translation."
        }
        let session = LanguageModelSession(instructions: instruction)
        let response = try await session.respond(
            to: "\(targetName):\n\(text)",
            options: GenerationOptions(maximumResponseTokens: 320)
        )
        let clean = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        return languageMatches(clean, target: target) ? clean : nil
    }

    private func targetLanguageName(_ code: String) -> String {
        switch code {
        case "de": "German (Deutsch)"
        case "pt": "Brazilian Portuguese (Português do Brasil)"
        default: "English"
        }
    }

    private func detectedLanguage(for text: String, hint: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage?.rawValue,
           ["pt", "en", "de"].contains(language) {
            return language
        }
        return normalizedLanguage(hint)
    }

    private func languageMatches(_ text: String, target: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return !text.isEmpty }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue == target
    }

    private func analyze(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> MeetingAnalysis {
        let transcriptLines = segments.map {
            "[\($0.timestamp)] \($0.source.label) (\($0.detectedLanguage)): \($0.text)"
        }
        let transcriptChunks = chunk(transcriptLines, characterLimit: analysisCharacterLimit)
        var partialAnalyses: [MeetingAnalysis] = []
        await progress?(0)
        for (index, part) in transcriptChunks.enumerated() {
            partialAnalyses.append(try await analyzeTranscriptChunk(part, number: index + 1))
            await progress?(0.82 * Double(index + 1) / Double(max(1, transcriptChunks.count)))
        }

        let merged = merge(partialAnalyses)
        await progress?(0.88)
        let summary = try await summarizeHierarchically(partialAnalyses.map(\.summary))
        await progress?(1)
        return MeetingAnalysis(
            summary: summary,
            decisions: merged.decisions,
            actionItems: merged.actionItems,
            keyDates: merged.keyDates
        )
    }

    private func analyzeTranscriptChunk(_ transcript: String, number: Int) async throws -> MeetingAnalysis {
        let session = LanguageModelSession(instructions: """
            Extract a compact factual meeting brief in Brazilian Portuguese from one transcript chunk. Keep every explicit decision, task, owner, deadline and important date. Never infer information. Keep names exactly as spoken. Limit the summary to 100 words and merge duplicates within this chunk. Use an empty string when an owner or deadline was not explicitly stated.
            """)
        let response = try await session.respond(
            to: "Parte \(number) da reunião:\n\(transcript)",
            generating: GeneratedAnalysis.self,
            options: GenerationOptions(maximumResponseTokens: 900)
        )
        return meetingAnalysis(from: response.content)
    }

    private func summarizeHierarchically(_ summaries: [String]) async throws -> String {
        var level = summaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !level.isEmpty else { return "Nenhum resumo disponível." }

        while level.count > 1 {
            let groups = chunk(level, characterLimit: summaryCharacterLimit)
            var nextLevel: [String] = []
            for group in groups {
                let session = LanguageModelSession(instructions: """
                    Combine partial meeting summaries into one concise factual summary in Brazilian Portuguese. Preserve decisions, commitments, names and dates. Do not invent information. Use at most 140 words.
                    """)
                let response = try await session.respond(
                    to: group,
                    options: GenerationOptions(maximumResponseTokens: 400)
                )
                let clean = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { nextLevel.append(clean) }
            }
            guard !nextLevel.isEmpty else { return level.joined(separator: " ") }
            level = nextLevel
        }
        return level[0]
    }

    private func merge(_ analyses: [MeetingAnalysis]) -> MeetingAnalysis {
        var decisions: [String] = []
        var actions: [ActionItem] = []
        var dates: [KeyDate] = []

        for analysis in analyses {
            for decision in analysis.decisions where !contains(decision, in: decisions) {
                decisions.append(decision)
            }
            for action in analysis.actionItems {
                if let index = actions.firstIndex(where: {
                    normalizedKey($0.task) == normalizedKey(action.task)
                }) {
                    if actions[index].owner == nil { actions[index].owner = action.owner }
                    if actions[index].dueDate == nil { actions[index].dueDate = action.dueDate }
                } else {
                    actions.append(action)
                }
            }
            for date in analysis.keyDates where !dates.contains(where: {
                normalizedKey($0.date + " " + $0.context) == normalizedKey(date.date + " " + date.context)
            }) {
                dates.append(date)
            }
        }
        return MeetingAnalysis(summary: "", decisions: decisions, actionItems: actions, keyDates: dates)
    }

    private func meetingAnalysis(from value: GeneratedAnalysis) -> MeetingAnalysis {
        MeetingAnalysis(
            summary: value.summary,
            decisions: value.decisions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            actionItems: value.actionItems.compactMap {
                let task = $0.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: optional($0.owner), dueDate: optional($0.dueDate))
            },
            keyDates: value.keyDates.compactMap {
                let date = $0.date.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = $0.context.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !date.isEmpty, !context.isEmpty else { return nil }
                return KeyDate(date: date, context: context)
            }
        )
    }

    private func segmentBatches(
        _ segments: [TranscriptSegment],
        characterLimit: Int,
        itemLimit: Int
    ) -> [[Int]] {
        var batches: [[Int]] = []
        var current: [Int] = []
        var currentCharacters = 0

        for index in segments.indices {
            let cost = segments[index].text.count + 16
            if !current.isEmpty,
               (currentCharacters + cost > characterLimit || current.count >= itemLimit) {
                batches.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(index)
            currentCharacters += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func chunk(_ lines: [String], characterLimit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count > characterLimit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? ["Nenhuma fala reconhecida."] : chunks
    }

    private func normalizedLanguage(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("pt") || lower.contains("portugu") { return "pt" }
        if lower.hasPrefix("de") || lower.contains("german") || lower.contains("deutsch") { return "de" }
        if lower.hasPrefix("en") || lower.contains("english") || lower.contains("ingl") { return "en" }
        return "mixed"
    }

    private func optional(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func contains(_ value: String, in values: [String]) -> Bool {
        let key = normalizedKey(value)
        return values.contains { normalizedKey($0) == key }
    }

    private func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ValidatedTranslation {
    var index: Int
    var originalLanguage: String
    var portuguese: String
    var english: String
    var german: String
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedAnalysis {
    var summary: String
    var decisions: [String]
    var actionItems: [GeneratedActionItem]
    var keyDates: [GeneratedKeyDate]
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedActionItem {
    var task: String
    var owner: String
    var dueDate: String
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedKeyDate {
    var date: String
    var context: String
}
