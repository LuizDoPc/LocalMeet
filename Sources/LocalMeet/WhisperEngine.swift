import AVFoundation
import CryptoKit
import Foundation

enum WhisperError: LocalizedError {
    case executableMissing
    case modelDownloadFailed
    case conversionFailed(String)
    case transcriptionFailed(String)
    case invalidOutput
    case noSpeechRecognized

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "O motor de transcrição local não foi encontrado dentro do aplicativo."
        case .modelDownloadFailed:
            "O modelo multilíngue não pôde ser baixado ou validado."
        case .conversionFailed(let details):
            "Não foi possível preparar o áudio: \(details)"
        case .transcriptionFailed(let details):
            "A transcrição local falhou: \(details)"
        case .invalidOutput:
            "O motor local retornou uma transcrição inválida."
        case .noSpeechRecognized:
            "O áudio foi preservado, mas nenhuma fala foi reconhecida. Você pode tentar transcrever novamente."
        }
    }
}

struct WhisperEngine: Sendable {
    static let modelSizeDescription = "466 MB"
    private static let expectedSHA1 = "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
    private static let modelURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
    )!

    let applicationSupport: URL

    init(applicationSupport: URL? = nil) {
        self.applicationSupport = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("LocalMeet", isDirectory: true)
    }

    var modelURL: URL {
        applicationSupport
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ggml-small.bin")
    }

    var isReady: Bool {
        executableURL != nil && FileManager.default.fileExists(atPath: modelURL.path)
    }

    var executableURL: URL? {
        let bundledRuntime = Bundle.main.resourceURL?
            .appendingPathComponent("WhisperRuntime/bin/whisper-cli")
        let bundledLegacy = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli")
        let candidates = [
            bundledRuntime,
            bundledLegacy,
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func ensureModel() async throws {
        guard executableURL != nil else { throw WhisperError.executableMissing }
        if FileManager.default.fileExists(atPath: modelURL.path) { return }

        let modelsDirectory = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              sha1(of: temporaryURL) == Self.expectedSHA1 else {
            throw WhisperError.modelDownloadFailed
        }
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: modelURL)
    }

    func transcribe(
        files: [AudioSource: URL],
        progress: (@Sendable (AudioSource, Double) async -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard let executableURL else { throw WhisperError.executableMissing }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperError.modelDownloadFailed
        }

        return try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
            for (source, fileURL) in files {
                group.addTask {
                    try await transcribe(
                        file: fileURL,
                        source: source,
                        executableURL: executableURL,
                        progress: progress
                    )
                }
            }
            var all: [TranscriptSegment] = []
            for try await segments in group { all += segments }
            return all.sorted { $0.offset < $1.offset }
        }
    }

    private func transcribe(
        file: URL,
        source: AudioSource,
        executableURL: URL,
        progress: (@Sendable (AudioSource, Double) async -> Void)?
    ) async throws -> [TranscriptSegment] {
        try await Task.detached(priority: .userInitiated) {
            await progress?(source, 0.02)
            let directory = file.deletingLastPathComponent()
            let waveURL = directory.appendingPathComponent("\(source.rawValue).wav")

            let conversion = try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
                arguments: [file.path, waveURL.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
            )
            guard conversion.status == 0 else {
                throw WhisperError.conversionFailed(conversion.output)
            }
            await progress?(source, 0.08)

            let chunks = try makeAudioChunks(waveURL: waveURL, directory: directory, source: source)
            var segments: [TranscriptSegment] = []
            await progress?(source, chunks.isEmpty ? 1 : 0.10)

            // Each short window runs language detection again, allowing code-switching
            // between Portuguese, English and German during one meeting.
            for (chunkIndex, chunkURL) in chunks.enumerated() {
                let outputBase = directory.appendingPathComponent(
                    "\(source.rawValue)-transcript-\(chunkIndex)"
                )
                let result = try runProcess(
                    executable: executableURL,
                    arguments: [
                        "-m", modelURL.path,
                        "-f", chunkURL.path,
                        "-l", "auto",
                        "-ojf",
                        "-of", outputBase.path,
                        "-np",
                        "-sns",
                        "--prompt", "Português, English, Deutsch. Preserve the spoken language exactly."
                    ]
                )
                guard result.status == 0 else {
                    throw WhisperError.transcriptionFailed(result.output)
                }

                let jsonURL = outputBase.appendingPathExtension("json")
                guard let data = try? Data(contentsOf: jsonURL),
                      let document = try? JSONDecoder().decode(WhisperDocument.self, from: data) else {
                    throw WhisperError.invalidOutput
                }
                let language = document.result.language.lowercased()
                segments += document.transcription.compactMap { entry in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !text.hasPrefix("[") else { return nil }
                    return TranscriptSegment(
                        source: source,
                        offset: TimeInterval(chunkIndex * 20) + TimeInterval(entry.offsets.from) / 1_000,
                        text: text,
                        detectedLanguage: language
                    )
                }
                let fraction = 0.10 + 0.90 * Double(chunkIndex + 1) / Double(max(1, chunks.count))
                await progress?(source, fraction)
            }
            return segments
        }.value
    }

    private func makeAudioChunks(
        waveURL: URL,
        directory: URL,
        source: AudioSource
    ) throws -> [URL] {
        let input = try AVAudioFile(
            forReading: waveURL,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let format = input.processingFormat
        let framesPerChunk = AVAudioFrameCount(format.sampleRate * 20)
        var urls: [URL] = []
        var index = 0

        while input.framePosition < input.length {
            let framesRemaining = input.length - input.framePosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(framesPerChunk), framesRemaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw WhisperError.conversionFailed("Não foi possível criar uma janela de áudio.")
            }
            try input.read(into: buffer, frameCount: frameCount)
            let chunkURL = directory.appendingPathComponent("\(source.rawValue)-chunk-\(index).wav")
            let output = try AVAudioFile(
                forWriting: chunkURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try output.write(from: buffer)
            urls.append(chunkURL)
            index += 1
        }
        return urls
    }

    private func sha1(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var digest = Insecure.SHA1()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            digest.update(data: Data(bytesNoCopy: buffer, count: count, deallocator: .none))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private func runProcess(executable: URL, arguments: [String]) throws -> ProcessResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    if executable.lastPathComponent == "whisper-cli",
       let runtime = Bundle.main.resourceURL?.appendingPathComponent("WhisperRuntime"),
       FileManager.default.fileExists(atPath: runtime.path) {
        var environment = ProcessInfo.processInfo.environment
        let backendName = localCPUBackendName()
        environment["GGML_BACKEND_PATH"] = runtime
            .appendingPathComponent("libexec")
            .appendingPathComponent(backendName)
            .path
        process.environment = environment
    }
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
        status: process.terminationStatus,
        output: String(data: data, encoding: .utf8) ?? ""
    )
}

private func localCPUBackendName() -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    process.arguments = ["-n", "machdep.cpu.brand_string"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    let brand = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if brand.contains("M1") { return "libggml-cpu-apple_m1.so" }
    if brand.contains("M4") || brand.contains("M5") { return "libggml-cpu-apple_m4.so" }
    return "libggml-cpu-apple_m2_m3.so"
}

private struct WhisperDocument: Decodable {
    struct Result: Decodable { let language: String }
    struct Entry: Decodable {
        struct Offsets: Decodable { let from: Int; let to: Int }
        let offsets: Offsets
        let text: String
    }

    let result: Result
    let transcription: [Entry]
}
