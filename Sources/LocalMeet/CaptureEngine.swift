import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Nenhuma tela disponível para capturar o áudio da reunião."
        }
    }
}

final class MeetingCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onAudio: ((CMSampleBuffer, AudioSource) -> Void)?
    var onStopped: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "app.localmeet.capture.samples", qos: .userInteractive)
    private var stream: SCStream?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        // Microphone capture uses AVAudioEngine so its permission and device
        // lifecycle are independent from ScreenCaptureKit.
        configuration.captureMicrophone = false

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        switch outputType {
        case .audio:
            onAudio?(sampleBuffer, .meeting)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
