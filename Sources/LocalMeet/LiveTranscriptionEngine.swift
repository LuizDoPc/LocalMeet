import Foundation

actor LiveTranscriptionEngine {
    typealias SegmentHandler = @Sendable ([TranscriptSegment]) async -> Void

    private let whisper: WhisperEngine
    private let rootDirectory: URL
    private let onSegments: SegmentHandler
    private var pending: [LiveAudioChunk] = []
    private var isProcessing = false
    private var isAccepting = true
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        whisper: WhisperEngine,
        rootDirectory: URL,
        onSegments: @escaping SegmentHandler
    ) {
        self.whisper = whisper
        self.rootDirectory = rootDirectory
        self.onSegments = onSegments
    }

    func enqueue(_ chunk: LiveAudioChunk) {
        guard isAccepting else {
            try? FileManager.default.removeItem(at: chunk.url.deletingLastPathComponent())
            return
        }
        pending.append(chunk)
        guard !isProcessing else { return }
        isProcessing = true
        Task { await drain() }
    }

    func stop() async {
        isAccepting = false
        for chunk in pending {
            try? FileManager.default.removeItem(at: chunk.url.deletingLastPathComponent())
        }
        pending.removeAll()
        if isProcessing {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private func drain() async {
        while isAccepting, !pending.isEmpty {
            let chunk = pending.removeFirst()
            do {
                let rawSegments = try await whisper.transcribe(files: [chunk.source: chunk.url])
                let adjusted = rawSegments.map { segment in
                    TranscriptSegment(
                        source: segment.source,
                        offset: chunk.offset + segment.offset,
                        text: segment.text,
                        detectedLanguage: segment.detectedLanguage
                    )
                }
                if isAccepting, !adjusted.isEmpty {
                    await onSegments(adjusted)
                }
            } catch {
                // Live captions are best-effort. The preserved full recording is still
                // processed by the normal retryable transcription pipeline at the end.
            }
            try? FileManager.default.removeItem(at: chunk.url.deletingLastPathComponent())
        }
        isProcessing = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
