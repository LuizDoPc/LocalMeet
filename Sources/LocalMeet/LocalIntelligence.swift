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
}

@available(macOS 26.0, *)
private struct AppleIntelligenceProcessor {
    func process(segments: [TranscriptSegment]) async throws -> IntelligenceResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LocalIntelligenceError.unavailable(String(describing: model.availability))
        }

        var translated = segments
        for start in stride(from: 0, to: translated.count, by: 8) {
            let end = min(start + 8, translated.count)
            let batch = Array(translated[start..<end])
            let rows = try await translate(batch)
            for row in rows where row.index >= 0 && row.index < batch.count {
                let index = start + row.index
                translated[index].detectedLanguage = normalizedLanguage(row.originalLanguage)
                translated[index].translations = [
                    "pt": row.portuguese,
                    "en": row.english,
                    "de": row.german
                ]
            }
        }

        let analysis = try await analyze(translated)
        return IntelligenceResult(segments: translated, analysis: analysis)
    }

    private func translate(_ segments: [TranscriptSegment]) async throws -> [ValidatedTranslation] {
        var rows = segments.enumerated().map { index, segment in
            ValidatedTranslation(
                index: index,
                originalLanguage: detectedLanguage(for: segment.text, hint: segment.detectedLanguage),
                portuguese: segment.text,
                english: segment.text,
                german: segment.text
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

    private func translate(
        _ segments: [TranscriptSegment],
        exclusivelyTo target: String
    ) async throws -> [Int: String] {
        let targetName = targetLanguageName(target)
        let session = LanguageModelSession(instructions: """
            You are a professional translator. Translate every input exclusively into \(targetName). Every output text field must be written in \(targetName), even when the source is English. Preserve names, numbers, dates and product terms. Never explain, summarize, answer the content, or use another language. Return exactly one item per index.
            """)
        let input = segments.enumerated().map { index, segment in
            "[\(index)] \(segment.text)"
        }.joined(separator: "\n")
        let response = try await session.respond(
            to: "Translate these indexed meeting lines into \(targetName):\n\(input)",
            generating: GeneratedSingleTranslationBatch.self
        )

        var result: [Int: String] = [:]
        for item in response.content.items where item.index >= 0 && item.index < segments.count {
            let original = segments[item.index].text
            let originalLanguage = detectedLanguage(
                for: original,
                hint: segments[item.index].detectedLanguage
            )
            if originalLanguage == target {
                result[item.index] = original
            } else if languageMatches(item.text, target: target) {
                result[item.index] = item.text
            } else if let retried = try await retryTranslation(original, target: target) {
                result[item.index] = retried
            }
        }
        return result
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
        let response = try await session.respond(to: "\(targetName):\n\(text)")
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

    private func analyze(_ segments: [TranscriptSegment]) async throws -> MeetingAnalysis {
        let transcriptLines = segments.map {
            "[\($0.timestamp)] \($0.source.label) (\($0.detectedLanguage)): \($0.text)"
        }
        let chunks = chunk(transcriptLines, characterLimit: 6_000)
        var factualNotes: [String] = []

        for part in chunks {
            let session = LanguageModelSession(instructions: """
                Extract factual meeting notes. Keep explicit decisions, tasks, owners, deadlines and dates. Never infer an owner or date. Keep proper names exactly as spoken. Reply in Portuguese.
                """)
            let response = try await session.respond(to: part)
            factualNotes.append(response.content)
        }

        let finalSession = LanguageModelSession(instructions: """
            Create a factual Portuguese meeting brief from extracted notes. Do not invent tasks, people, dates, decisions or commitments. When owner or deadline was not explicitly stated, use an empty string. Merge duplicates.
            """)
        let response = try await finalSession.respond(
            to: factualNotes.joined(separator: "\n\n--- PARTE ---\n\n"),
            generating: GeneratedAnalysis.self
        )
        let value = response.content
        return MeetingAnalysis(
            summary: value.summary,
            decisions: value.decisions,
            actionItems: value.actionItems.map {
                ActionItem(task: $0.task, owner: optional($0.owner), dueDate: optional($0.dueDate))
            },
            keyDates: value.keyDates.map { KeyDate(date: $0.date, context: $0.context) }
        )
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
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedSingleTranslationBatch {
    var items: [GeneratedSingleTranslation]
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedSingleTranslation {
    var index: Int
    var text: String
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
