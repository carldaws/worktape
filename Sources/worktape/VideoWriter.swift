import AVFoundation
import CoreGraphics

final class VideoWriter {
    let frameRate: Int32
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(path: String, fileType: AVFileType, width: Int, height: Int, frameRate: Int32, realTime: Bool = false, audio withAudio: Bool = false) throws {
        self.frameRate = frameRate
        writer = try AVAssetWriter(outputURL: URL(filePath: path), fileType: fileType)
        writer.shouldOptimizeForNetworkUse = !realTime
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.6,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: !realTime,
            ],
        ])
        video.expectsMediaDataInRealTime = realTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(video)

        if withAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audio.expectsMediaDataInRealTime = realTime
            writer.add(audio)
            self.audio = audio
        } else {
            audio = nil
        }

        guard writer.startWriting() else { throw writer.error ?? VideoWriterError.stopped }
        writer.startSession(atSourceTime: .zero)
    }

    func draw(_ paint: (CGContext) -> Void) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
              let buffer = made
        else { throw writer.error ?? VideoWriterError.stopped }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw VideoWriterError.cantDraw }
        paint(context)
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, frame: Int) throws {
        guard writer.status == .writing else { throw writer.error ?? VideoWriterError.stopped }
        if video.expectsMediaDataInRealTime {
            guard video.isReadyForMoreMediaData else { return }
        } else {
            try waitUntilReady(video)
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: frameRate)) else {
            throw writer.error ?? VideoWriterError.stopped
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, from start: CMTime) throws {
        guard let audio, audio.isReadyForMoreMediaData, sample.presentationTimeStamp >= start else { return }
        let timing = try sample.sampleTimingInfos().map { timing in
            var shifted = timing
            shifted.presentationTimeStamp = timing.presentationTimeStamp - start
            return shifted
        }
        guard audio.append(try CMSampleBuffer(copying: sample, withNewTiming: timing)) else {
            throw writer.error ?? VideoWriterError.stopped
        }
    }

    func finish(frames: Int) throws {
        guard writer.status == .writing else { throw writer.error ?? VideoWriterError.stopped }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: frameRate))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? VideoWriterError.stopped }
    }

    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? VideoWriterError.stopped }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

enum VideoWriterError: LocalizedError {
    case stopped
    case cantDraw

    var errorDescription: String? {
        switch self {
        case .stopped: "the video encoder stopped"
        case .cantDraw: "can't draw into a video frame"
        }
    }
}
