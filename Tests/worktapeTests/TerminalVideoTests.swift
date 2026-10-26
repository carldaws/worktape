import AVFoundation
import Foundation
import SwiftTerm
import Testing
@testable import worktape

struct VideoLayoutTests {
    @Test(arguments: [(80, 24), (188, 58), (319, 87), (2000, 600)])
    func fitsTheLargestFontIn4K(columns: Int, rows: Int) {
        let layout = VideoLayout(columns: columns, rows: rows, advance: 0.6)
        #expect(layout.width <= VideoLayout.widest && layout.height <= VideoLayout.tallest)
        #expect(layout.width % 2 == 0 && layout.height % 2 == 0)
        #expect(layout.fontSize <= VideoLayout.largestFontSize)
    }

    @Test func shrinksTheFontOnlyWhenItMustFit() {
        #expect(VideoLayout(columns: 80, rows: 24, advance: 0.6).fontSize == VideoLayout.largestFontSize)
        #expect(VideoLayout(columns: 188, rows: 58, advance: 0.6).fontSize == 26)
    }
}

struct CastReaderTests {
    @Test func readsTheHeaderThenEvents() throws {
        try withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try """
            {"version":3,"term":{"cols":120,"rows":40,"theme":{"fg":"#d8dee9","bg":"#2e3440","palette":"#000000:#111111:#222222:#333333:#444444:#555555:#666666:#777777"}}}
            [0.5, "o", "hello"]
            [0.25, "r", "100x30"]

            """.write(toFile: cast, atomically: true, encoding: .utf8)
            let reader = CastReader(path: cast)
            let first = try #require(try reader.next())
            #expect(first.code == "o" && first.data == "hello" && first.time == 0.5)
            #expect(reader.header?.columns == 120 && reader.header?.rows == 40)
            #expect(reader.header?.colors?.bg == "#2e3440")
            #expect(try reader.next()?.data == "100x30")
            #expect(try reader.next() == nil)
        }
    }

    @Test func waitsForTheRestOfALineStillBeingWritten() throws {
        try withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try "{\"version\":3,\"term\":{\"cols\":80,\"rows\":24}}\n[0.1, \"o\", \"he".write(toFile: cast, atomically: true, encoding: .utf8)
            let reader = CastReader(path: cast)
            #expect(try reader.next() == nil)

            let file = try #require(FileHandle(forWritingAtPath: cast))
            try file.seekToEnd()
            try file.write(contentsOf: Data("llo\"]\n".utf8))
            try file.close()
            #expect(try reader.next()?.data == "hello")
        }
    }

    @Test func readsAFinalLineWithoutANewlineOnlyAtTheEnd() throws {
        try withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try "{\"version\":3,\"term\":{\"cols\":80,\"rows\":24}}\n[0.1, \"o\", \"last\"]".write(toFile: cast, atomically: true, encoding: .utf8)
            let reader = CastReader(path: cast)
            #expect(try reader.next() == nil)
            #expect(try reader.next(atEnd: true)?.data == "last")
        }
    }

    @Test func skipsLinesItCantRead() throws {
        try withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try "{\"version\":3,\"term\":{\"cols\":80,\"rows\":24}}\n[0.1, \"o\"\nnonsense\n[0.2, \"o\", \"next\"]\n".write(toFile: cast, atomically: true, encoding: .utf8)
            let reader = CastReader(path: cast)
            #expect(try reader.next()?.data == "next")
        }
    }

    @Test func waitsForTheFileToAppear() throws {
        try withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            let reader = CastReader(path: cast)
            #expect(try reader.next() == nil)
            try "{\"version\":3,\"term\":{\"cols\":80,\"rows\":24}}\n[0.1, \"o\", \"hi\"]\n".write(toFile: cast, atomically: true, encoding: .utf8)
            #expect(try reader.next()?.data == "hi")
        }
    }
}

struct TimelineTests {
    @Test func cutsLongPausesFromIntervals() {
        var timeline = Timeline(version: 3, idleLimit: 0.5)
        #expect(timeline.advance(to: 0.25) == 0.25)
        #expect(timeline.advance(to: 30) == 0.75)
        #expect(timeline.advance(to: 0.125) == 0.875)
    }

    @Test func cutsLongPausesFromVersionTwoTimestamps() {
        var timeline = Timeline(version: 2, idleLimit: 0.5)
        #expect(timeline.advance(to: 0.25) == 0.25)
        #expect(timeline.advance(to: 30) == 0.75)
        #expect(timeline.advance(to: 30.125) == 0.875)
    }
}

struct ScreenPainterTests {
    let delegate = SilentDelegate()

    @Test func joinsBoxLinesAcrossRows() throws {
        let painter = ScreenPainter(columns: 3, rows: 3)
        let terminal = whiteOnBlack(columns: 3, rows: 3)
        terminal.feed(text: "│\r\n│\r\n│")
        let pixels = try render(terminal.makeRenderSnapshot(scope: .full), with: painter)

        let layout = painter.layout
        let x = layout.left + layout.cellWidth / 2
        let lit = (layout.top..<(layout.top + layout.cellHeight * 3)).filter { pixels.brightness(x: x, y: $0) > 0.5 }
        #expect(lit.count == layout.cellHeight * 3)
    }

    @Test func drawsTheCursorAsABlock() throws {
        let painter = ScreenPainter(columns: 3, rows: 1)
        let terminal = whiteOnBlack(columns: 3, rows: 1)
        terminal.feed(text: "\u{1b}[2C")
        let pixels = try render(terminal.makeRenderSnapshot(scope: .full), with: painter)

        let layout = painter.layout
        let y = layout.top + layout.cellHeight / 2
        #expect(pixels.brightness(x: layout.left + layout.cellWidth * 5 / 2, y: y) > 0.5)
        #expect(pixels.brightness(x: layout.left + layout.cellWidth / 2, y: y) < 0.5)
    }

    private func whiteOnBlack(columns: Int, rows: Int) -> Terminal {
        var options = TerminalOptions.default
        options.cols = columns
        options.rows = rows
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.foregroundColor = SwiftTerm.Color(red: 65535, green: 65535, blue: 65535)
        terminal.backgroundColor = SwiftTerm.Color(red: 0, green: 0, blue: 0)
        return terminal
    }

    private func render(_ screen: TerminalRenderSnapshot, with painter: ScreenPainter) throws -> Pixels {
        let layout = painter.layout
        let context = try #require(CGContext(
            data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        painter.paint(screen, into: context)
        return Pixels(context: context)
    }
}

@Suite(.serialized) struct TerminalVideoTests {
    @Test func rendersAConstantFrameRateVideoWithPausesCut() async throws {
        try await withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try """
            {"version":3,"term":{"cols":40,"rows":10}}
            [0.2, "o", "hello"]
            [60, "o", " world"]

            """.write(toFile: cast, atomically: true, encoding: .utf8)

            let video = TerminalVideo.start(from: cast, to: directory + "/session.mp4")
            #expect(await finished(video) == .saved)

            let asset = AVURLAsset(url: URL(filePath: directory + "/session.mp4"))
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 3.7) < 0.05)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.nominalFrameRate) == 30)
            let format = try #require(try await track.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        }
    }

    @Test func catchesUpOnWhatItMissedWhileHeld() async throws {
        try await withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try "{\"version\":3,\"term\":{\"cols\":40,\"rows\":10}}\n".write(toFile: cast, atomically: true, encoding: .utf8)
            let video = TerminalVideo.start(from: cast, to: directory + "/session.mp4")
            video.windowsRecording = true

            let file = try #require(FileHandle(forWritingAtPath: cast))
            try file.seekToEnd()
            try file.write(contentsOf: Data("[0.5, \"o\", \"one\"]\n[0.5, \"o\", \"two\"]\n".utf8))
            try file.close()
            try await Task.sleep(for: .milliseconds(500))
            #expect(video.progress < 1)

            #expect(await finished(video) == .saved)
            let duration = try await AVURLAsset(url: URL(filePath: directory + "/session.mp4")).load(.duration).seconds
            #expect(abs(duration - 4) < 0.05)
        }
    }

    @Test func leavesNothingBehindWhenCancelled() async throws {
        try await withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try "{\"version\":3,\"term\":{\"cols\":40,\"rows\":10}}\n[0.5, \"o\", \"one\"]\n".write(toFile: cast, atomically: true, encoding: .utf8)
            let scratchBefore = try scratchVideos()
            let video = TerminalVideo.start(from: cast, to: directory + "/session.mp4")
            try await Task.sleep(for: .milliseconds(500))
            video.cancel()
            #expect(await finished(video) == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: directory + "/session.mp4"))
            #expect(try scratchVideos() == scratchBefore)
        }
    }

    @Test func reportsAnEmptyRecording() async throws {
        try await withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            FileManager.default.createFile(atPath: cast, contents: Data())
            let video = TerminalVideo.start(from: cast, to: directory + "/session.mp4")
            #expect(await finished(video) == .failed("the terminal recording is empty"))
        }
    }

    private func finished(_ video: TerminalVideo) async -> TerminalVideo.Outcome? {
        video.finish()
        for _ in 0..<600 {
            if let outcome = video.outcome {
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func scratchVideos() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter {
            $0.hasPrefix("worktape-") && $0.hasSuffix(".mp4")
        })
    }
}

private struct Pixels {
    let context: CGContext

    func brightness(x: Int, y: Int) -> Double {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let pixel = bytes + y * context.bytesPerRow + x * 4
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
