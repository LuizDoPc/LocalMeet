import Foundation

enum WhisperXError: LocalizedError {
    case notInstalled
    case tokenMissing
    case processingFailed(String)
    case invalidOutput
    case noSpeakers

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "WhisperX não encontrado. Instale com `uv tool install whisperx` e autentique o Hugging Face para habilitar a identificação de participantes."
        case .tokenMissing:
            "Salve um token de leitura do Hugging Face nos Ajustes para baixar o modelo local de diarização."
        case .processingFailed(let details):
            "O WhisperX não conseguiu identificar os participantes: \(details)"
        case .invalidOutput:
            "O WhisperX terminou sem produzir uma diarização válida."
        case .noSpeakers:
            "O WhisperX não encontrou vozes distintas nesta gravação."
        }
    }
}

struct WhisperXEngine: Sendable {
    let executableURL: URL?
    let workingDirectory: URL

    init(
        executableURL: URL? = WhisperXEngine.locateExecutable(),
        workingDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("LocalMeet", isDirectory: true)
            .appendingPathComponent("WhisperXRuns", isDirectory: true)
    }

    var isAvailable: Bool { executableURL != nil || Self.locateExecutable() != nil }

    func diarize(
        file: URL,
        segments: [TranscriptSegment],
        huggingFaceToken: String?
    ) async throws -> [TranscriptSegment] {
        guard let executableURL = executableURL ?? Self.locateExecutable() else {
            throw WhisperXError.notInstalled
        }
        guard huggingFaceToken?.isEmpty == false else { throw WhisperXError.tokenMissing }
        return try await Task.detached(priority: .userInitiated) {
            let runDirectory = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: runDirectory) }

            let result = try Self.run(
                executable: executableURL,
                huggingFaceToken: huggingFaceToken,
                arguments: [
                    file.path,
                    "--model", "small",
                    "--device", "cpu",
                    "--compute_type", "int8",
                    "--diarize",
                    "--output_format", "json",
                    "--output_dir", runDirectory.path
                ]
            )
            guard result.status == 0 else {
                throw WhisperXError.processingFailed(Self.concise(result.output))
            }
            guard let outputURL = try FileManager.default.contentsOfDirectory(
                at: runDirectory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension.lowercased() == "json" }),
                  let data = try? Data(contentsOf: outputURL),
                  let document = try? JSONDecoder().decode(WhisperXDocument.self, from: data) else {
                throw WhisperXError.invalidOutput
            }
            let turns = document.segments.compactMap { item -> SpeakerTurn? in
                guard let speaker = item.speaker, !speaker.isEmpty else { return nil }
                return SpeakerTurn(start: item.start, end: item.end, speaker: speaker)
            }
            guard !turns.isEmpty else { throw WhisperXError.noSpeakers }
            return Self.assign(turns: turns, to: segments)
        }.value
    }

    static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("WhisperXRuntime/bin/whisperx"),
            home.appendingPathComponent(".local/bin/whisperx"),
            home.appendingPathComponent(".cargo/bin/whisperx"),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisperx"),
            URL(fileURLWithPath: "/usr/local/bin/whisperx")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func assign(
        turns: [SpeakerTurn],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.map { segment in
            var updated = segment
            guard segment.source == .meeting else {
                updated.speakerID = "LOCAL_USER"
                return updated
            }
            let start = segment.offset
            // whisper.cpp does not persist an end time. The next segment boundary,
            // capped at 15 seconds, is a stable approximation for overlap scoring.
            let nextOffset = segments
                .filter { $0.source == .meeting && $0.offset > start }
                .map(\.offset)
                .min() ?? (start + 5)
            let end = min(start + 15, max(start + 0.25, nextOffset))
            let best = turns.max { lhs, rhs in
                overlap(start, end, lhs.start, lhs.end) < overlap(start, end, rhs.start, rhs.end)
            }
            if let best, overlap(start, end, best.start, best.end) > 0 {
                updated.speakerID = best.speaker
            }
            return updated
        }
    }

    private static func overlap(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    private static func run(
        executable: URL,
        huggingFaceToken: String?,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        let additions = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        environment["PATH"] = additions.joined(separator: ":") + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        if let huggingFaceToken, !huggingFaceToken.isEmpty {
            environment["HF_TOKEN"] = huggingFaceToken
        }
        process.environment = environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func concise(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.suffix(1_200))
    }
}

private struct SpeakerTurn {
    let start: Double
    let end: Double
    let speaker: String
}

private struct WhisperXDocument: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let speaker: String?
    }
    let segments: [Segment]
}
