import Darwin
import Foundation

// Foundation's Process gives children their own process group, so they can't own the terminal.
final class ChildProcess {
    let pid: pid_t
    private(set) var exitCode: Int32?

    private init(pid: pid_t) {
        self.pid = pid
    }

    static func spawn(_ arguments: [String], environment: [String: String], discardingOutput: Bool = false) throws -> ChildProcess {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if discardingOutput {
            for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
                posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null", O_WRONLY, 0)
            }
        }

        // Children otherwise inherit ignored and blocked signals.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGINT, SIGHUP, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var unblockedSignals = sigset_t()
        sigemptyset(&unblockedSignals)
        posix_spawnattr_setsigmask(&attributes, &unblockedSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var pid = pid_t()
        let error = posix_spawnp(&pid, argv[0], &fileActions, &attributes, argv, envp)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
        return ChildProcess(pid: pid)
    }

    func hasExited() -> Bool {
        guard exitCode == nil else { return true }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return false }
        exitCode = Self.shellExitCode(fromWaitStatus: status)
        return true
    }

    static func shellExitCode(fromWaitStatus status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        return terminatingSignal == 0 ? (status >> 8) & 0xff : 128 + terminatingSignal
    }
}

func name(of pid: pid_t) -> String {
    var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    return String(decoding: buffer.prefix(Int(max(length, 0))), as: UTF8.self)
}

func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 64)
    let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    return Array(pids.prefix(Int(max(count, 0))))
}

func isDescendant(_ pid: pid_t, of root: pid_t) -> Bool {
    var current = pid
    while current > 1 {
        if current == root { return true }
        guard let parent = parentPID(of: current) else { return false }
        current = parent
    }
    return false
}

func controllingTerminal(of pid: pid_t) -> dev_t? {
    guard let terminal = kernelInfo(of: pid)?.kp_eproc.e_tdev, terminal != -1 else { return nil }
    return terminal
}

func shellTerminal(under recorder: pid_t) -> dev_t? {
    let recorderTerminal = controllingTerminal(of: recorder)
    return children(of: recorder).lazy.compactMap(controllingTerminal).first { $0 != recorderTerminal }
}

private func parentPID(of pid: pid_t) -> pid_t? {
    kernelInfo(of: pid)?.kp_eproc.e_ppid
}

private func kernelInfo(of pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}
