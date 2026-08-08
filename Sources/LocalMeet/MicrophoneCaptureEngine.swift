@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum MicrophoneCaptureError: LocalizedError {
    case noInput
    case couldNotConfigure

    var errorDescription: String? {
        switch self {
        case .noInput: "O microfone selecionado não está disponível."
        case .couldNotConfigure: "Não foi possível iniciar o microfone selecionado."
        }
    }
}

final class MicrophoneCaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onAudio: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sampleQueue = DispatchQueue(label: "app.localmeet.microphone.samples", qos: .userInteractive)
    private let deviceID: String?

    init(deviceID: String?) {
        self.deviceID = deviceID
        super.init()
    }

    func start() async throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw MicrophoneCaptureError.noInput }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.couldNotConfigure
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let started = await withCheckedContinuation { continuation in
            sampleQueue.async { [session] in
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard started else { throw MicrophoneCaptureError.couldNotConfigure }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        onAudio?(sampleBuffer)
    }
}
