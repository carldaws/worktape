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
    session.startTerminalVideo()
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
    await session.finishTerminalVideo()
    session.report()
    session.removeDirectoryIfEmpty()
    return session.lostPermission ? 1 : asciinema.exitCode ?? 1
}

private let terminalClosed = Atomic(false)
private let recorderPID = Atomic<pid_t>(0)
private let sessionVideo = Mutex<TerminalVideo?>(nil)

private func listenForShutdown() -> [any DispatchSourceSignal] {
    signal(SIGINT, SIG_IGN)
    return [SIGHUP, SIGTERM].map { shutdown in
        signal(shutdown, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: shutdown, queue: .main)
        source.setEventHandler {
            if shutdown == SIGHUP {
                terminalClosed.store(true, ordering: .relaxed)
            }
            let recorder = recorderPID.load(ordering: .relaxed)
            if recorder != 0 {
                endShells(under: recorder)
            } else if shutdown == SIGTERM {
                sessionVideo.withLock { $0 }?.cancel()
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
    private var terminalVideo: TerminalVideo?
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

    func startTerminalVideo() {
        let video = TerminalVideo.start(from: terminal, to: (terminal as NSString).deletingPathExtension + ".mp4")
        terminalVideo = video
        sessionVideo.withLock { $0 = video }
    }

    func update(under recorder: pid_t, paused: Bool, titleBarHeight: CGFloat) async {
        defer { terminalVideo?.windowsRecording = !recordings.isEmpty }
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
        terminalVideo?.windowsRecording = false
    }

    func finishTerminalVideo() async {
        guard let video = terminalVideo else { return }
        guard FileManager.default.fileExists(atPath: terminal) else {
            video.cancel()
            return
        }
        switch await video.finishShowingProgress(quietly: { terminalClosed.load(ordering: .relaxed) }) {
        case .saved:
            break
        case .cancelled:
            problems.append("stopped before the terminal video was finished, so there's no terminal video")
        case .failed(let reason):
            problems.append("can't render the terminal video: \(reason)")
        }
    }

    func report() {
        let video = terminalVideo.flatMap { $0.outcome == .saved ? $0.path : nil }
        let terminalFiles = FileManager.default.fileExists(atPath: terminal) ? [terminal] + [video].compactMap { $0 } : []
        let files = terminalFiles + saved.sorted()
        if !files.isEmpty {
            Console.saved(in: directoryInProject, files.map { ($0 as NSString).lastPathComponent })
        }
        problems.forEach(Console.problem)
    }

    func removeDirectoryIfEmpty() {
        rmdir(directory)
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
