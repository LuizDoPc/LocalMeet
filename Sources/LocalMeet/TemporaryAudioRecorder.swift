import AVFoundation
import CoreMedia
import Foundation

enum AudioRecordingError: LocalizedError {
    case couldNotStart
    case couldNotAppend

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Não foi possível iniciar o arquivo temporário de áudio."
        case .couldNotAppend: "Não foi possível continuar gravando o áudio temporário."
        }
    }
}

final class SampleBufferChannelWriter {
    let url: URL
    private var file: AVAudioFile?
    private var wroteAudio = false
    private(set) var receivedSignal = false

    init(url: URL) {
        self.url = url
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        do {
            let buffer = try pcmBuffer(from: sampleBuffer)
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try file?.write(from: buffer)
            wroteAudio = true
            if containsAudibleSignal(buffer) { receivedSignal = true }
        } catch {
            // The app keeps the other audio channel alive if one source is unavailable.
        }
    }

    func finish() -> URL? {
        file = nil
        return wroteAudio ? url : nil
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw AudioRecordingError.couldNotStart
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard sizingStatus == noErr, requiredSize > 0 else {
            throw AudioRecordingError.couldNotAppend
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  bufferListNoCopy: audioBufferList,
                  deallocator: nil
              ) else {
            throw AudioRecordingError.couldNotAppend
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        return pcmBuffer
    }
}

final class TemporaryAudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.localmeet.audio-files", qos: .userInitiated)
    let directory: URL
    private let systemWriter: SampleBufferChannelWriter
    private let microphoneWriter: SampleBufferChannelWriter

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        systemWriter = SampleBufferChannelWriter(url: directory.appendingPathComponent("meeting.caf"))
        microphoneWriter = SampleBufferChannelWriter(url: directory.appendingPathComponent("microphone.caf"))
    }

    func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        queue.async { [weak self] in
            guard source == .meeting else { return }
            self?.systemWriter.append(sampleBuffer)
        }
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            self?.microphoneWriter.append(sampleBuffer)
        }
    }

    var microphoneHasData: Bool {
        microphoneWriter.receivedSignal
    }

    var systemAudioHasData: Bool {
        systemWriter.receivedSignal
    }

    func flushSystemAudio() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func finish() async -> [AudioSource: URL] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [:])
                    return
                }
                Task {
                    var results: [AudioSource: URL] = [:]
                    if let url = self.systemWriter.finish() {
                        results[.meeting] = url
                    }
                    if let url = self.microphoneWriter.finish() {
                        results[.microphone] = url
                    }
                    continuation.resume(returning: results)
                }
            }
        }
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func containsAudibleSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return false }
    let channels = max(1, Int(buffer.format.channelCount))
    let sampleLimit = min(frames, 4_096)

    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
        guard let data = buffer.floatChannelData else { return false }
        for channel in 0..<channels {
            for frame in stride(from: 0, to: sampleLimit, by: 8) where abs(data[channel][frame]) > 0.003 {
                return true
            }
        }
    case .pcmFormatInt16:
        guard let data = buffer.int16ChannelData else { return false }
        for channel in 0..<channels {
            for frame in stride(from: 0, to: sampleLimit, by: 8) where abs(Int(data[channel][frame])) > 96 {
                return true
            }
        }
    case .pcmFormatInt32:
        guard let data = buffer.int32ChannelData else { return false }
        for channel in 0..<channels {
            for frame in stride(from: 0, to: sampleLimit, by: 8) where abs(Int64(data[channel][frame])) > 1_000_000 {
                return true
            }
        }
    default:
        return wroteNonZeroBytes(buffer)
    }
    return false
}

private func wroteNonZeroBytes(_ buffer: AVAudioPCMBuffer) -> Bool {
    let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for audioBuffer in buffers {
        guard let data = audioBuffer.mData else { continue }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: Int(audioBuffer.mDataByteSize), by: 32) where bytes[index] != 0 {
            return true
        }
    }
    return false
}
