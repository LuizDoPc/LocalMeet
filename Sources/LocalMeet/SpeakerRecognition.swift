import Foundation

struct VoiceMatch: Equatable, Sendable {
    let contactID: UUID
    let similarity: Double
}

enum SpeakerProfileMatcher {
    // Pyannote embeddings are compared with cosine similarity. Requiring both
    // a strong score and separation from the runner-up avoids eager identity
    // assignment when two contacts have acoustically similar voices.
    static let similarityThreshold = 0.78
    static let minimumMargin = 0.05

    static func matches(
        speakerEmbeddings: [String: [Double]],
        contacts: [Contact]
    ) -> [String: VoiceMatch] {
        let enrolled = contacts.compactMap { contact -> (Contact, [Double])? in
            guard let embedding = normalized(contact.voiceEmbedding),
                  contact.voiceSampleCount > 0 else { return nil }
            return (contact, embedding)
        }
        guard !enrolled.isEmpty else { return [:] }

        struct Candidate {
            let speakerID: String
            let contactID: UUID
            let similarity: Double
            let margin: Double
        }

        var candidates: [Candidate] = []
        for (speakerID, rawEmbedding) in speakerEmbeddings {
            guard let embedding = normalized(rawEmbedding) else { continue }
            let ranked = enrolled.map { contact, profile in
                (contact.id, cosine(embedding, profile))
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.1 ?? -1
            candidates.append(
                Candidate(
                    speakerID: speakerID,
                    contactID: best.0,
                    similarity: best.1,
                    margin: best.1 - runnerUp
                )
            )
        }

        var usedSpeakers: Set<String> = []
        var usedContacts: Set<UUID> = []
        var result: [String: VoiceMatch] = [:]
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity }) {
            guard candidate.similarity >= similarityThreshold,
                  candidate.margin >= minimumMargin,
                  !usedSpeakers.contains(candidate.speakerID),
                  !usedContacts.contains(candidate.contactID) else { continue }
            result[candidate.speakerID] = VoiceMatch(
                contactID: candidate.contactID,
                similarity: candidate.similarity
            )
            usedSpeakers.insert(candidate.speakerID)
            usedContacts.insert(candidate.contactID)
        }
        return result
    }

    static func mergedProfile(
        existing: [Double]?,
        sampleCount: Int,
        sample: [Double]
    ) -> (embedding: [Double], sampleCount: Int)? {
        guard let normalizedSample = normalized(sample) else { return nil }
        guard let existing = normalized(existing), sampleCount > 0,
              existing.count == normalizedSample.count else {
            return (normalizedSample, 1)
        }
        let count = Double(sampleCount)
        let averaged = zip(existing, normalizedSample).map { old, new in
            (old * count + new) / (count + 1)
        }
        guard let normalizedAverage = normalized(averaged) else { return nil }
        return (normalizedAverage, sampleCount + 1)
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalized(_ values: [Double]?) -> [Double]? {
        guard let values, !values.isEmpty,
              values.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return nil }
        return values.map { $0 / magnitude }
    }
}
