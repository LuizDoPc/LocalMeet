import Foundation

enum RecoveryAudioError: LocalizedError {
    case noAudio
    case couldNotPreserve(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "Nenhum arquivo de áudio foi produzido pela gravação."
        case .couldNotPreserve(let details):
            "Não foi possível preservar o áudio para recuperação: \(details)"
        }
    }
}

final class RecoveryAudioStore: @unchecked Sendable {
    private let rootDirectory: URL

    init(baseDirectory: URL? = nil) {
        let applicationSupport = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("LocalMeet", isDirectory: true)
        rootDirectory = applicationSupport.appendingPathComponent("RecoveryAudio", isDirectory: true)
    }

    func preserve(files: [AudioSource: URL], meetingID: UUID) throws -> [AudioSource: URL] {
        guard !files.isEmpty else { throw RecoveryAudioError.noAudio }
        let directory = directory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var preserved: [AudioSource: URL] = [:]
        do {
            for (source, sourceURL) in files {
                let destination = originalAudioURL(for: source, meetingID: meetingID)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 else {
                    throw RecoveryAudioError.couldNotPreserve("o arquivo \(source.rawValue) ficou vazio")
                }
                preserved[source] = destination
            }
        } catch {
            throw RecoveryAudioError.couldNotPreserve(error.localizedDescription)
        }
        return preserved
    }

    func files(for meetingID: UUID) -> [AudioSource: URL] {
        AudioSource.allCases.reduce(into: [:]) { result, source in
            let url = originalAudioURL(for: source, meetingID: meetingID)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                return
            }
            result[source] = url
        }
    }

    func directory(for meetingID: UUID) -> URL {
        rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    func remove(meetingID: UUID) throws {
        let directory = directory(for: meetingID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func originalAudioURL(for source: AudioSource, meetingID: UUID) -> URL {
        directory(for: meetingID).appendingPathComponent("\(source.rawValue).caf")
    }
}
