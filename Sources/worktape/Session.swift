import AppKit
import Darwin
import ScreenCaptureKit
import Synchronization

func record(_ description: String? = nil) async -> Int32 {
    if let description, slug(description).isEmpty {
        log("describe the session with letters or numbers")
        return EX_USAGE
    }
    guard ProcessInfo.processInfo.environment["WORKTAPE_RECORDING"] == nil else {
        log("already recording")
        return 1
    }
    guard let project = Project.containing(FileManager.default.currentDirectoryPath) else {
        log("no .worktapes here or in any parent directory, run worktape init first")
        return 1
    }
    connectToWindowServer()
    guard case .windows = await listWindows() else {
        log("can't see windows, check your terminal has screen recording permission")
        return 1
    }

    let asciinemaConfig: AsciinemaConfig?
    do {
        asciinemaConfig = try AsciinemaConfig.create()
    } catch {
        log("can't set up pausing: \(error.localizedDescription)")
        return 1
    }
    defer { asciinemaConfig?.remove() }

    let session: Session
    do {
        session = try Session(in: project, named: description)
    } catch let error as SessionExists {
        log("\(project.name) already has a session called \(error.name), add something like \"part 2\" to the description")
        return 1
    } catch {
        log("can't create a session folder in \(project.recordings): \(error.localizedDescription)")
        return 1
    }

    var environment = ProcessInfo.processInfo.environment
    environment["WORKTAPE_RECORDING"] = project.root
    environment["WORKTAPE_PID"] = String(getpid())
    if let asciinemaConfig {
        environment["ASCIINEMA_CONFIG_HOME"] = asciinemaConfig.directory
        environment["WORKTAPE_STATE"] = asciinemaConfig.directory
    }

    let shutdownSignals = listenForShutdown()
    defer { shutdownSignals.forEach { $0.cancel() } }

    Console.recording(project.name, to: session.directoryInProject)
    let started = ContinuousClock.now
    let asciinema: ChildProcess
    do {
        asciinema = try ChildProcess.spawn(["asciinema", "rec", "--quiet", session.terminal], environment: environment)
    } catch {
        log("can't start asciinema: \(error.localizedDescription)")
        session.removeDirectoryIfEmpty()
        return 1
    }

    let titleBarHeight = await standardTitleBarHeight()
    recorderPID.store(asciinema.pid, ordering: .relaxed)
    var wasPaused = false
    while !asciinema.hasExited() && !session.lostPermission {
        let paused = asciinemaConfig?.isPaused ?? false
        if paused != wasPaused {
            wasPaused = paused
            if asciinemaConfig?.promptShowsState == true {
                for shell in children(of: asciinema.pid) {
                    kill(shell, SIGWINCH)
                }
            }
        }
        await session.update(under: asciinema.pid, paused: paused, titleBarHeight: titleBarHeight)
        try? await Task.sleep(for: .milliseconds(250))
    }
    if session.lostPermission {
        endShells(under: asciinema.pid)
        while !asciinema.hasExited() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    recorderPID.store(0, ordering: .relaxed)
    Console.stopped(project.name, after: ContinuousClock.now - started)

    await session.finishAll()
    await session.renderTerminal()
    session.report()
    session.removeDirectoryIfEmpty()
    return session.lostPermission ? 1 : asciinema.exitCode ?? 1
}

private let terminalClosed = Atomic(false)
private let recorderPID = Atomic<pid_t>(0)
private let renderPID = Atomic<pid_t>(0)

private func listenForShutdown() -> [any DispatchSourceSignal] {
    signal(SIGINT, SIG_IGN)
    return [SIGHUP, SIGTERM].map { shutdown in
        signal(shutdown, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: shutdown, queue: .main)
        source.setEventHandler {
            if shutdown == SIGHUP {
                terminalClosed.store(true, ordering: .relaxed)
            }
            let render = renderPID.load(ordering: .relaxed)
            let recorder = recorderPID.load(ordering: .relaxed)
            if render != 0 {
                kill(render, SIGINT)
            } else if recorder != 0 {
                endShells(under: recorder)
            }
        }
        source.resume()
        return source
    }
}

private func endShells(under recorder: pid_t) {
    for shell in children(of: recorder) {
        kill(shell, SIGHUP)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard recorderPID.load(ordering: .relaxed) == recorder else { return }
        for shell in children(of: recorder) {
            kill(shell, SIGKILL)
        }
    }
}

final class Session {
    let directory: String
    let terminal: String
    let directoryInProject: String
    private var terminalVideo: String?
    private var recordings: [CGWindowID: WindowRecording] = [:]
    private var ignored: Set<CGWindowID> = []
    private var issued: Set<String> = []
    private var saved: [String] = []
    private var problems: [String] = []
    private(set) var lostPermission = false

    init(in project: Project, named description: String? = nil, startedAt started: Date = .now) throws {
        let label = description.map { "\(day(started))-\(slug($0))" } ?? timestamp(started)
        var name = label
        var copy = 2
        while true {
            do {
                try FileManager.default.createDirectory(
                    atPath: (project.recordings as NSString).appendingPathComponent(name),
                    withIntermediateDirectories: false
                )
                break
            } catch CocoaError.fileWriteFileExists {
                guard description == nil else { throw SessionExists(name: name) }
                name = "\(label)-\(copy)"
                copy += 1
            }
        }
        directory = (project.recordings as NSString).appendingPathComponent(name)
        directoryInProject = ((project.recordings as NSString).lastPathComponent as NSString).appendingPathComponent(name)
        terminal = (directory as NSString).appendingPathComponent("\(name).cast")
    }

    func update(under recorder: pid_t, paused: Bool, titleBarHeight: CGFloat) async {
        guard !paused else {
            await finishAll()
            return
        }
        let stoppedBeforeListing = recordings.compactMapValues(\.stopReason)
        let windows: [SCWindow]
        switch await listWindows() {
        case .windows(let list):
            windows = list
        case .denied:
            lostPermission = true
            problems.append("lost screen recording permission, so worktape stopped recording")
            return
        case .unavailable:
            return
        }

        let open = Set(windows.map(\.windowID))
        let closed = recordings.filter { !open.contains($0.key) }
        for (id, recording) in closed {
            recordings[id] = nil
            await finish(recording)
        }
        for (id, reason) in stoppedBeforeListing {
            guard let recording = recordings.removeValue(forKey: id) else { continue }
            ignored.insert(id)
            problems.append("stopped recording \((recording.path as NSString).lastPathComponent): \(reason)")
            await finish(recording)
        }

        var recorded = windows.filter { recordings[$0.windowID] != nil }.compactMap { window in
            window.owningApplication.map { RecordedWindow(owner: $0.processID, frame: window.frame) }
        }
        let sessionTerminal = shellTerminal(under: recorder)
        for window in windows where window.isOnScreen && recordings[window.windowID] == nil && !ignored.contains(window.windowID) {
            guard window.windowLayer == 0,
                  let owner = window.owningApplication,
                  isDescendant(owner.processID, of: recorder)
                    || sessionTerminal != nil && controllingTerminal(of: owner.processID) == sessionTerminal
            else {
                ignored.insert(window.windowID)
                continue
            }
            guard !isOverlay(window.frame, from: owner.processID, on: recorded, titleBarHeight: titleBarHeight) else { continue }
            let name = [window.title ?? "", owner.applicationName].map(slug).first { !$0.isEmpty } ?? "window"
            let path = newRecording(named: name)
            do {
                recordings[window.windowID] = try await WindowRecording.start(window, to: path)
                recorded.append(RecordedWindow(owner: owner.processID, frame: window.frame))
            } catch {
                ignored.insert(window.windowID)
                problems.append("couldn't record \(owner.applicationName): \(error.localizedDescription)")
            }
        }
    }

    func finishAll() async {
        for recording in recordings.values {
            await finish(recording)
        }
        recordings = [:]
    }

    func renderTerminal() async {
        guard FileManager.default.fileExists(atPath: terminal) else { return }
        let quietly = terminalClosed.load(ordering: .relaxed)
        guard let failure = await render(quietly: quietly) else { return }
        let terminalClosedDuringRender = !quietly && terminalClosed.load(ordering: .relaxed)
        if terminalClosedDuringRender, await render(quietly: true) == nil {
            return
        }
        problems.append(failure)
    }

    func report() {
        let terminalFiles = FileManager.default.fileExists(atPath: terminal) ? [terminal] + [terminalVideo].compactMap { $0 } : []
        let files = terminalFiles + saved.sorted()
        if !files.isEmpty {
            Console.saved(in: directoryInProject, files.map { ($0 as NSString).lastPathComponent })
        }
        problems.forEach(Console.problem)
    }

    func removeDirectoryIfEmpty() {
        rmdir(directory)
    }

    private func render(quietly: Bool) async -> String? {
        let video = (terminal as NSString).deletingPathExtension + ".mp4"
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("worktape-\(UUID().uuidString)")
        let animation = scratch + ".gif"
        let rendering = scratch + ".mp4"
        defer {
            try? FileManager.default.removeItem(atPath: animation)
            try? FileManager.default.removeItem(atPath: rendering)
        }

        Console.note("rendering \((video as NSString).lastPathComponent), ctrl+c to skip")
        let size = try? await terminalSize(of: terminal)
        let font = size.map { fontSize(columns: $0.columns, rows: $0.rows) } ?? largestFontSize
        let agg = ["agg", "--font-size", String(font), "--idle-time-limit", "0.5", terminal, animation]
        let ffmpeg = [
            "ffmpeg", "-nostdin", "-v", "error", "-i", animation,
            "-vf", "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", rendering,
        ]
        if let failure = await run(agg, discardingOutput: quietly, activity: nil) {
            return failure
        }
        if let failure = await run(ffmpeg, discardingOutput: true, activity: quietly ? nil : "encoding") {
            return failure
        }

        do {
            try FileManager.default.moveItem(atPath: rendering, toPath: video)
        } catch {
            return "can't save the terminal video: \(error.localizedDescription)"
        }
        terminalVideo = video
        return nil
    }

    private func run(_ arguments: [String], discardingOutput: Bool, activity: String?) async -> String? {
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(arguments, environment: ProcessInfo.processInfo.environment, discardingOutput: discardingOutput)
        } catch {
            return "can't run \(arguments[0]) to render the terminal video: \(error.localizedDescription)"
        }
        renderPID.store(child.pid, ordering: .relaxed)
        defer { renderPID.store(0, ordering: .relaxed) }

        let started = ContinuousClock.now
        var frame = 0
        while !child.hasExited() {
            if let activity {
                Console.working(activity, frame: frame, elapsed: ContinuousClock.now - started)
            }
            frame += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        if activity != nil {
            Console.doneWorking()
        }
        return child.exitCode == 0 ? nil : "\(arguments[0]) didn't finish, so there's no terminal video"
    }

    private func newRecording(named name: String) -> String {
        let stem = "\(timestamp())-\(name)"
        var path = (directory as NSString).appendingPathComponent("\(stem).mov")
        var copy = 2
        while issued.contains(path) || FileManager.default.fileExists(atPath: path) {
            path = (directory as NSString).appendingPathComponent("\(stem)-\(copy).mov")
            copy += 1
        }
        issued.insert(path)
        return path
    }

    private func finish(_ recording: WindowRecording) async {
        do {
            try await recording.finish()
            saved.append(recording.path)
        } catch {
            problems.append("\((recording.path as NSString).lastPathComponent) may be unplayable: \(error.localizedDescription)")
        }
    }
}

let largestFontSize = 32

func fontSize(columns: Int, rows: Int) -> Int {
    let aggCellWidth = 0.6
    let aggLineHeight = 1.4
    // agg pads the video by half a cell on every side.
    let widest = 3840 / (Double(columns + 1) * aggCellWidth)
    let tallest = 2160 / (Double(rows + 1) * aggLineHeight)
    return max(1, Int(min(Double(largestFontSize), widest, tallest)))
}

func terminalSize(of cast: String) async throws -> (columns: Int, rows: Int)? {
    struct Header: Decodable {
        struct Terminal: Decodable {
            let cols: Int
            let rows: Int
        }
        let term: Terminal
    }
    for try await line in URL(filePath: cast).lines {
        let header = try JSONDecoder().decode(Header.self, from: Data(line.utf8))
        return (header.term.cols, header.term.rows)
    }
    return nil
}

struct SessionExists: Error {
    let name: String
}

struct RecordedWindow {
    let owner: pid_t
    let frame: CGRect
}

// Capturing a window makes its app put a small window of its own over the title bar.
func isOverlay(_ frame: CGRect, from owner: pid_t, on recorded: [RecordedWindow], titleBarHeight: CGFloat) -> Bool {
    recorded.contains { window in
        let titleBar = CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: titleBarHeight)
        return window.owner == owner && titleBar.contains(frame)
    }
}

@MainActor
func standardTitleBarHeight() -> CGFloat {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    return frame.height - NSWindow.contentRect(forFrameRect: frame, styleMask: .titled).height
}

func slug(_ name: String) -> String {
    let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    var length = 0
    let short = words.prefix { character in
        length += character.utf8.count
        return length <= 100
    }
    return String(short).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
