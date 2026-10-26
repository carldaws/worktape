import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization

final class WindowRecording {
    enum Outcome {
        case saved
        case nothingCaptured
    }

    let path: String
    private let stream: SCStream
    private let capture: WindowCapture

    private init(path: String, stream: SCStream, capture: WindowCapture) {
        self.path = path
        self.stream = stream
        self.capture = capture
    }

    var stopReason: String? {
        capture.stopReason
    }

    static func start(_ window: SCWindow, to path: String) async throws -> WindowRecording {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: WindowCapture.frameRate)
        configuration.queueDepth = 8
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = true

        let capture = try WindowCapture(path: path, width: configuration.width, height: configuration.height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: capture)
        do {
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.queue)
        } catch {
            capture.cancel()
            throw error
        }
        let failure: (any Error)? = await waitAtMost(.seconds(5), orReturn: CaptureError.timedOut) { done in
            stream.startCapture { done($0) }
        }
        if let failure {
            await waitAtMost(.seconds(5), orReturn: ()) { done in
                stream.stopCapture { _ in done(()) }
            }
            capture.cancel()
            throw failure
        }
        return WindowRecording(path: path, stream: stream, capture: capture)
    }

    func end(at time: CMTime) async {
        await capture.end(at: time)
    }

    func finish() async throws -> Outcome {
        await end(at: CMClock.hostTimeClock.time)
        let stream = stream
        await waitAtMost(.seconds(5), orReturn: ()) { done in
            stream.stopCapture { _ in done(()) }
        }
        return try await capture.finish()
    }
}

enum CaptureError: LocalizedError {
    case timedOut

    var errorDescription: String? { "screen capture didn't respond in time" }
}

enum WindowList {
    case windows([SCWindow])
    case denied
    case unavailable
}

func listWindows() async -> WindowList {
    await waitAtMost(.seconds(5), orReturn: .unavailable) { done in
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            if let content {
                done(.windows(content.windows))
            } else if (error as? SCStreamError)?.code == .userDeclined {
                done(.denied)
            } else {
                done(.unavailable)
            }
        }
    }
}

private final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameRate: Int32 = 60
    static let framesToWaitBeforeRepeating = 2

    let queue = DispatchQueue(label: "worktape window capture")
    private let path: String
    private let writer: VideoWriter
    private let streamStop = Mutex<String?>(nil)
    private let repeater: any DispatchSourceTimer
    private var start: CMTime?
    private var ended = false
    private var latest: CVPixelBuffer?
    private var nextFrame = 0
    private var writeFailure: (any Error)?

    init(path: String, width: Int, height: Int) throws {
        self.path = path
        writer = try VideoWriter(path: path, fileType: .mov, width: width, height: height, frameRate: Self.frameRate, realTime: true, audio: true)
        repeater = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        repeater.schedule(deadline: .now(), repeating: 1 / Double(Self.frameRate))
        repeater.setEventHandler { [weak self] in self?.repeatLatestUntilNow() }
        repeater.resume()
    }

    var stopReason: String? {
        streamStop.withLock { $0 }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !ended, writeFailure == nil else { return }
        switch type {
        case .screen:
            record(sample)
        case .audio:
            if let start {
                attempt { try writer.appendAudio(sample, from: start) }
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stopped = CMClock.hostTimeClock.time
        streamStop.withLock { $0 = error.localizedDescription }
        queue.async { [self] in endOnQueue(at: stopped) }
    }

    func end(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                endOnQueue(at: time)
                continuation.resume()
            }
        }
    }

    func finish() async throws -> WindowRecording.Outcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                endOnQueue(at: CMClock.hostTimeClock.time)
                if start == nil || writeFailure != nil {
                    discard()
                    continuation.resume(with: writeFailure.map { .failure($0) } ?? .success(.nothingCaptured))
                    return
                }
                do {
                    try writer.finish(frames: nextFrame)
                    continuation.resume(returning: .saved)
                } catch {
                    discard()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in discard() }
    }

    private func discard() {
        ended = true
        repeater.cancel()
        writer.cancel()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func endOnQueue(at time: CMTime) {
        guard !ended else { return }
        ended = true
        repeater.cancel()
        if let start {
            repeatLatest(through: frame(at: time, from: start))
        }
    }

    private func record(_ sample: CMSampleBuffer) {
        guard let image = sample.imageBuffer, sample.presentationTimeStamp.isValid, Self.hasNewImage(sample) else { return }
        let start = start ?? sample.presentationTimeStamp
        self.start = start
        let frame = frame(at: sample.presentationTimeStamp, from: start)
        repeatLatest(through: frame - 1)
        latest = image
        if frame >= nextFrame {
            write(image, frame: frame)
        }
    }

    private func repeatLatestUntilNow() {
        guard let start else { return }
        repeatLatest(through: frame(at: CMClock.hostTimeClock.time, from: start) - Self.framesToWaitBeforeRepeating)
    }

    private func repeatLatest(through frame: Int) {
        guard let latest else { return }
        while nextFrame <= frame && writeFailure == nil {
            write(latest, frame: nextFrame)
        }
    }

    private func write(_ image: CVPixelBuffer, frame: Int) {
        attempt { try writer.append(image, frame: frame) }
        nextFrame = frame + 1
    }

    private func attempt(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            writeFailure = error
        }
    }

    private func frame(at time: CMTime, from start: CMTime) -> Int {
        Int(((time - start).seconds * Double(Self.frameRate)).rounded())
    }

    private static func hasNewImage(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: status) == .complete
    }
}

// ScreenCaptureKit crashes without this in a command-line tool.
func connectToWindowServer() {
    _ = CGMainDisplayID()
}
