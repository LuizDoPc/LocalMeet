import Foundation

final class MeetingStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("LocalMeet", isDirectory: true)

        fileURL = root.appendingPathComponent("meetings.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [Meeting] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([Meeting].self, from: data)) ?? []
    }

    func save(_ meetings: [Meeting]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(meetings)
        try data.write(to: fileURL, options: .atomic)
    }
}
