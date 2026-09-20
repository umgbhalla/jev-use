import AVFoundation
import Combine
import CoreAudio
import Foundation
import Speech
import os

@MainActor
final class SpeechInput: ObservableObject {
    private let log = Logger(subsystem: "local.jev-use", category: "speech")
    @Published var transcript = ""
    @Published var isListening = false
    @Published var status = ""
    @Published var audioLevel: Double = 0
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let captureQueue = DispatchQueue(label: "local.jev-use.microphone")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var sampleSink: SpeechAudioSampleSink?
    private var routeObservers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var isStarting = false
    private var releaseRequested = false
    private var pendingFinal: String?
    private var recognitionMode = ""

    var hasPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestPermissions() async -> Bool {
        let current = generation
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard generation == current else { return false }
        guard microphone == .authorized else {
            status = "Microphone access is not allowed. Enable it in System Settings → Privacy & Security → Microphone."
            return false
        }

        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard generation == current else { return false }
        guard speech == .authorized else {
            status = "Speech Recognition access is not allowed. Enable it in System Settings → Privacy & Security → Speech Recognition."
            return false
        }
        return true
    }

    func start() async throws {
        cancel()
        let current = generation
        isStarting = true
        defer { if generation == current { isStarting = false } }
        transcript = ""
        status = "Preparing microphone…"
        let permitted = await requestPermissions()
        guard generation == current, !Task.isCancelled else {
            if generation == current { cancel() }
            throw CancellationError()
        }
        guard permitted else { throw SpeechInputError(message: status) }
        guard let recognizer, recognizer.isAvailable else {
            status = "Apple speech recognition is currently unavailable."
            throw SpeechInputError(message: status)
        }
        let microphone = try Self.builtInMicrophone()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Keep Apple's default language and choice of local or online processing.
        recognitionMode = "Apple speech (may use the internet)"
        self.request = request
        let sink = SpeechAudioSampleSink(request: request)
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let input = try AVCaptureDeviceInput(device: microphone)
        captureSession = session
        captureOutput = output
        sampleSink = sink
        observeCaptureRoute(session: session, microphone: microphone, generation: current)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if let error {
                    let native = error as NSError
                    var code = "\(native.domain) \(native.code)"
                    if let cause = native.userInfo[NSUnderlyingErrorKey] as? NSError {
                        code += "; \(cause.domain) \(cause.code)"
                    }
                    self.fail("Apple speech: \(native.localizedDescription) (\(code)).")
                } else if let result, result.isFinal {
                    self.stopAudio()
                    self.task = nil
                    self.request = nil
                    self.pendingFinal = result.bestTranscription.formattedString
                    if self.releaseRequested {
                        self.deliverFinal()
                    } else {
                        self.status = "Speech complete. Release the shortcut to use this command."
                    }
                }
            }
        }

        do {
            try await startCapture(session, input: input, output: output, sink: sink)
            guard generation == current, !Task.isCancelled else {
                stopAudio()
                throw CancellationError()
            }
            isStarting = false
            isListening = true
            status = "Listening — \(recognitionMode)."
            log.notice("Speech input bound to built-in microphone \(microphone.localizedName, privacy: .public), UID \(microphone.uniqueID, privacy: .public), transport \(microphone.transportType)")
        } catch {
            cancel()
            status = error.localizedDescription
            throw error
        }
    }

    private static func builtInMicrophone() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        guard let device = discovery.devices.first(where: {
            $0.isConnected && $0.transportType == Int32(kAudioDeviceTransportTypeBuiltIn)
        }) else {
            throw SpeechInputError(message: "The Mac’s built-in microphone is unavailable. Jev will not use a Bluetooth microphone.")
        }
        return device
    }

    private func startCapture(_ session: AVCaptureSession, input: AVCaptureDeviceInput,
                              output: AVCaptureAudioDataOutput, sink: SpeechAudioSampleSink) async throws {
        let captureQueue = self.captureQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    continuation.resume(throwing: SpeechInputError(message: "Jev could not start capture from the Mac’s built-in microphone."))
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(sink, queue: captureQueue)
                session.commitConfiguration()
                session.startRunning()
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SpeechInputError(message: "Jev could not start the built-in microphone capture session."))
                }
            }
        }
    }

    private func observeCaptureRoute(session: AVCaptureSession, microphone: AVCaptureDevice, generation: UUID) {
        let center = NotificationCenter.default
        routeObservers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.fail("Built-in microphone capture stopped. Jev will not switch to Bluetooth.\(detail.map { " " + $0 } ?? "")")
                }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: microphone, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.fail("The Mac’s built-in microphone disconnected. Jev stopped instead of switching devices.")
                }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.fail("Built-in microphone capture was interrupted. Jev stopped instead of switching devices.")
                }
            }
        ]
    }

    func finish() {
        if isStarting {
            cancel()
            status = "Released before the microphone was ready. Hold the shortcut to try again."
            return
        }
        guard !releaseRequested, request != nil || pendingFinal != nil else { return }
        releaseRequested = true
        if pendingFinal != nil {
            deliverFinal()
        } else {
            stopAudio { [weak self] in self?.task?.finish() }
            status = "Finishing — \(recognitionMode)."
            // Only Apple's final recognition may run a command.
        }
    }

    func cancel() {
        generation = UUID()
        isStarting = false
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        pendingFinal = nil
        releaseRequested = false
        status = "Cancelled."
    }

    private func stopAudio(completion: (() -> Void)? = nil) {
        let session = captureSession
        let output = captureOutput
        let sink = sampleSink
        captureSession = nil
        captureOutput = nil
        sampleSink = nil
        routeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        routeObservers.removeAll()
        captureQueue.async {
            session?.stopRunning()
            output?.setSampleBufferDelegate(nil, queue: nil)
            sink?.finish()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        isListening = false
        audioLevel = 0
    }

    private func deliverFinal() {
        guard let final = pendingFinal else { return }
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail("No speech was recognised.")
            return
        }
        generation = UUID()
        pendingFinal = nil
        task = nil
        request = nil
        transcript = text
        status = "Recognised — \(recognitionMode)."
        onFinal?(text)
    }

    private func fail(_ message: String) {
        cancel()
        status = message
        onFailure?(message)
    }
}

private final class SpeechAudioSampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let acceptingAudio = OSAllocatedUnfairLock(initialState: true)

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        acceptingAudio.withLock { accepting in
            if accepting { request.appendAudioSampleBuffer(sampleBuffer) }
        }
    }

    func finish() {
        acceptingAudio.withLock { accepting in
            if accepting {
                accepting = false
                request.endAudio()
            }
        }
    }
}

struct SpeechInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
