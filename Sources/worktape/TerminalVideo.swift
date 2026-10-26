import AVFoundation
import Foundation
import SwiftTerm
import Synchronization

final class TerminalVideo: Sendable {
    enum Outcome: Sendable, Equatable {
        case saved
        case cancelled
        case failed(String)
    }

    private struct State {
        var windowsRecording = false
        var finishing = false
        var cancelled = false
        var consumed = 0
        var outcome: Outcome?
    }

    let path: String
    private let cast: String
    private let state = Mutex(State())

    private init(cast: String, path: String) {
        self.cast = cast
        self.path = path
    }

    static func start(from cast: String, to path: String) -> TerminalVideo {
        let video = TerminalVideo(cast: cast, path: path)
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("worktape-\(UUID().uuidString).mp4")
        let thread = Thread { video.run(writingTo: scratch) }
        thread.name = "worktape terminal video"
        thread.qualityOfService = .utility
        thread.start()
        return video
    }

    var windowsRecording: Bool {
        get { state.withLock { $0.windowsRecording } }
        set { state.withLock { $0.windowsRecording = newValue } }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    func finish() {
        state.withLock {
            $0.windowsRecording = false
            $0.finishing = true
        }
    }

    var outcome: Outcome? {
        state.withLock { $0.outcome }
    }

    var progress: Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: cast)[.size] as? Int) ?? 0
        let consumed = state.withLock { $0.consumed }
        return size > 0 ? min(1, Double(consumed) / Double(size)) : 0
    }

    func finishShowingProgress(quietly: () -> Bool) async -> Outcome {
        finish()
        if !quietly() {
            Console.note("rendering \((path as NSString).lastPathComponent)")
        }
        let started = ContinuousClock.now
        var frame = 0
        while true {
            if let outcome {
                if !quietly() {
                    Console.doneWorking()
                }
                return outcome
            }
            if !quietly() {
                Console.working("encoding \(Int(progress * 100))%", frame: frame, elapsed: ContinuousClock.now - started)
            }
            frame += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func run(writingTo scratch: String) {
        let replay = Replay(cast: cast, writingTo: scratch)
        let outcome = render(replay, through: scratch)
        if outcome != .saved {
            replay.abandon()
        }
        state.withLock { $0.outcome = outcome }
    }

    private func render(_ replay: Replay, through scratch: String) -> Outcome {
        do {
            let outcome = try play(replay)
            if outcome == .saved {
                try FileManager.default.moveItem(atPath: scratch, toPath: path)
            }
            return outcome
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func play(_ replay: Replay) throws -> Outcome {
        while true {
            let (windowsRecording, finishing, cancelled) = state.withLock { ($0.windowsRecording, $0.finishing, $0.cancelled) }
            if cancelled {
                return .cancelled
            }
            if windowsRecording && replay.isBetweenUpdates {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            if try replay.step(atEnd: finishing) {
                state.withLock { $0.consumed = replay.consumed }
                continue
            }
            if finishing {
                try replay.finish()
                return .saved
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

private final class Replay {
    private let reader: CastReader
    private let scratch: String
    private var player: Player?

    init(cast: String, writingTo scratch: String) {
        reader = CastReader(path: cast)
        self.scratch = scratch
    }

    var consumed: Int { reader.consumed }

    var isBetweenUpdates: Bool { player?.isBetweenUpdates ?? true }

    func step(atEnd: Bool) throws -> Bool {
        guard let event = try reader.next(atEnd: atEnd) else { return false }
        try preparedPlayer().play(event)
        return true
    }

    func finish() throws {
        try preparedPlayer().finish()
    }

    func abandon() {
        player?.cancel()
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func preparedPlayer() throws -> Player {
        if let player {
            return player
        }
        guard let header = reader.header else { throw ReplayError.empty }
        let made = try Player(header, writingTo: scratch)
        player = made
        return made
    }
}

private final class Player {
    static let idleLimit = 0.5
    static let lastFrameDuration = 3.0
    static let synchronizedOutputLimit = 1.0

    private let terminal: Terminal
    private let delegate = SilentDelegate()
    private let painter: ScreenPainter
    private let writer: VideoWriter
    private var timeline: Timeline
    private var frame = 0
    private var changed = true
    private var shown: CVPixelBuffer?
    private var updateStarted: Double?

    init(_ header: CastHeader, writingTo scratch: String) throws {
        var options = TerminalOptions.default
        options.cols = header.columns
        options.rows = header.rows
        options.scrollback = 0
        terminal = Terminal(delegate: delegate, options: options)
        let theme = header.colors.flatMap(ColorTheme.init) ?? .dracula
        terminal.installPalette(colors: theme.palette.map(\.color))
        terminal.foregroundColor = theme.foreground.color
        terminal.backgroundColor = theme.background.color

        painter = ScreenPainter(columns: header.columns, rows: header.rows)
        writer = try VideoWriter(path: scratch, fileType: .mp4, width: painter.layout.width, height: painter.layout.height, frameRate: 30)
        timeline = Timeline(version: header.version, idleLimit: Self.idleLimit)
    }

    var isBetweenUpdates: Bool { updateStarted == nil }

    func play(_ event: CastEvent) throws {
        let time = timeline.advance(to: event.time)
        try showFrames(before: time)

        switch event.code {
        case "o":
            terminal.terminalLock.withLock {
                terminal.feed(byteArray: Array(event.data.utf8))
            }
        case "r":
            let size = event.data.split(separator: "x").compactMap { Int($0) }
            guard size.count == 2, size[0] > 0, size[1] > 0 else { return }
            terminal.terminalLock.withLock {
                terminal.resize(cols: size[0], rows: size[1])
            }
        default:
            return
        }
        changed = true
        let updating = terminal.terminalLock.withLock { terminal.synchronizedOutputActive }
        if !updating {
            updateStarted = nil
        } else if updateStarted == nil {
            updateStarted = time
        }
    }

    func finish() throws {
        endUpdate()
        try showFrames(before: timeline.now + Self.lastFrameDuration)
        try writer.finish(frames: frame)
    }

    func cancel() {
        writer.cancel()
    }

    private func endUpdate() {
        guard updateStarted != nil else { return }
        terminal.terminalLock.withLock { terminal.expireSynchronizedOutput() }
        updateStarted = nil
    }

    private func frameTime(_ frame: Int) -> Double {
        Double(frame) / Double(writer.frameRate)
    }

    private func showFrames(before time: Double) throws {
        while frameTime(frame) < time {
            try showFrame()
        }
    }

    private func showFrame() throws {
        let now = frameTime(frame)
        if let updateStarted, now - updateStarted >= Self.synchronizedOutputLimit {
            endUpdate()
        }
        let screenIsReady = changed && isBetweenUpdates
        if shown == nil || screenIsReady {
            let screen = terminal.makeRenderSnapshot(scope: .full)
            shown = try writer.draw { painter.paint(screen, into: $0) }
            changed = false
        }
        if let shown {
            try writer.append(shown, frame: frame)
        }
        frame += 1
    }
}

final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

enum ReplayError: LocalizedError {
    case empty

    var errorDescription: String? { "the terminal recording is empty" }
}

private struct ColorTheme {
    static let dracula = ColorTheme(
        foreground: RGB(hex: "#f8f8f2")!,
        background: RGB(hex: "#282a36")!,
        palette: [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
        ].compactMap(RGB.init(hex:))
    )

    let foreground: RGB
    let background: RGB
    let palette: [RGB]
}

extension ColorTheme {
    init?(_ theme: CastHeader.Theme) {
        guard let foreground = RGB(hex: theme.fg), let background = RGB(hex: theme.bg) else { return nil }
        let colors = theme.palette.split(separator: ":").compactMap { RGB(hex: String($0)) }
        guard colors.count == 8 || colors.count == 16 else { return nil }
        self.init(foreground: foreground, background: background, palette: colors.count == 8 ? colors + colors : colors)
    }
}

private extension RGB {
    var color: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}
