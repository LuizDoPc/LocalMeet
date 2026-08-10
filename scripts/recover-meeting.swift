#!/usr/bin/env swift

import Foundation

private struct WhisperDocument: Decodable {
    struct Result: Decodable { let language: String }
    struct Entry: Decodable {
        struct Offsets: Decodable { let from: Int }
        let offsets: Offsets
        let text: String
    }

    let result: Result
    let transcription: [Entry]
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 5 else {
    fail("Usage: recover-meeting.swift <meetings.json> <recovery-audio-directory> <meeting-id> <output.json>")
}

let meetingsURL = URL(fileURLWithPath: CommandLine.arguments[1])
let recoveryURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let meetingID = CommandLine.arguments[3].uppercased()
let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])
let decoder = JSONDecoder()
var segments: [[String: Any]] = []

for source in ["meeting", "microphone"] {
    var chunkIndex = 0
    while true {
        let transcriptURL = recoveryURL.appendingPathComponent("\(source)-transcript-\(chunkIndex).json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { break }
        let document: WhisperDocument
        do {
            let data = try Data(contentsOf: transcriptURL)
            document = try decoder.decode(
                WhisperDocument.self,
                from: Data(String(decoding: data, as: UTF8.self).utf8)
            )
        } catch {
            fail("Invalid transcript checkpoint \(transcriptURL.lastPathComponent): \(error.localizedDescription)")
        }

        for entry in document.transcription {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  !text.hasPrefix("["),
                  text.range(of: #"[A-Za-zÀ-ÖØ-öø-ÿ]"#, options: .regularExpression) != nil else {
                continue
            }
            segments.append([
                "id": UUID().uuidString,
                "source": source,
                "offset": Double(chunkIndex * 20) + Double(entry.offsets.from) / 1_000,
                "text": text,
                "detectedLanguage": document.result.language.lowercased(),
                "translations": [String: String]()
            ])
        }
        chunkIndex += 1
    }
}

guard !segments.isEmpty else { fail("No speech segments were recovered") }
segments.sort { ($0["offset"] as? Double ?? 0) < ($1["offset"] as? Double ?? 0) }

let sourceData = try Data(contentsOf: meetingsURL)
guard var meetings = try JSONSerialization.jsonObject(with: sourceData) as? [[String: Any]],
      let meetingIndex = meetings.firstIndex(where: {
          ($0["id"] as? String)?.uppercased() == meetingID
      }) else {
    fail("Meeting \(meetingID) was not found")
}

meetings[meetingIndex]["segments"] = segments
meetings[meetingIndex]["transcriptionError"] = nil
let outputData = try JSONSerialization.data(withJSONObject: meetings, options: [.prettyPrinted, .sortedKeys])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try outputData.write(to: outputURL, options: .atomic)
print("Recovered \(segments.count) segments to \(outputURL.path)")
