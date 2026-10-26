import Darwin
import Foundation
import Testing
@testable import worktape

struct ChildProcessTests {
    @Test(arguments: [
        (Int32(0), Int32(0)),
        (Int32(3 << 8), Int32(3)),
        (SIGTERM, 128 + SIGTERM),
        (SIGKILL, 128 + SIGKILL),
    ])
    func turnsWaitStatusesIntoShellExitCodes(status: Int32, expected: Int32) {
        #expect(ChildProcess.shellExitCode(fromWaitStatus: status) == expected)
    }

    @Test func reportsTheExitCode() async throws {
        let child = try ChildProcess.spawn(["/bin/sh", "-c", "exit 3"], environment: [:])
        #expect(await exitCode(of: child) == 3)
    }

    @Test func failsToSpawnAMissingCommand() {
        #expect(throws: POSIXError.self) {
            try ChildProcess.spawn(["worktape-test-no-such-command"], environment: [:])
        }
    }

    @Test func childrenStopOnInterruptEvenWhenWorktapeIgnoresIt() async throws {
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let child = try ChildProcess.spawn(["/bin/sh", "-c", "kill -INT $$; sleep 5"], environment: [:])
        #expect(await exitCode(of: child) == 128 + SIGINT)
    }

    @Test func childrenStopOnTerminateEvenWhenTheSpawningThreadBlocksIt() async throws {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        let child = try ChildProcess.spawn(["/bin/sh", "-c", "kill -TERM $$; sleep 5"], environment: [:])
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        #expect(await exitCode(of: child) == 128 + SIGTERM)
    }

    @Test func findsChildrenNamesAndAncestry() async throws {
        let child = try ChildProcess.spawn(["/bin/sleep", "5"], environment: [:])
        defer { kill(child.pid, SIGKILL) }
        #expect(children(of: getpid()).contains(child.pid))
        #expect(name(of: child.pid) == "sleep")
        #expect(isDescendant(child.pid, of: getpid()))
        #expect(!isDescendant(getpid(), of: child.pid))
        #expect(!name(of: getpid()).isEmpty)
    }
}

@Suite(.serialized)
struct StopTests {
    @Test func refusesOutsideARecording() {
        unsetenv("WORKTAPE_PID")
        #expect(stop() == 1)
    }

    @Test func refusesToSignalAProcessThatIsNotWorktape() {
        setenv("WORKTAPE_PID", String(getpid()), 1)
        defer { unsetenv("WORKTAPE_PID") }
        #expect(stop() == 1)
    }
}

struct WaitAtMostTests {
    @Test func returnsTheValueWhenItArrivesInTime() async {
        #expect(await waitAtMost(.seconds(5), orReturn: 0) { done in done(42) } == 42)
    }

    @Test func returnsTheFallbackWhenNothingArrives() async {
        let started = ContinuousClock.now
        #expect(await waitAtMost(.milliseconds(50), orReturn: -1) { _ in } == -1)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func ignoresAValueThatArrivesTooLate() async throws {
        let value = await waitAtMost(.milliseconds(50), orReturn: -1) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done(1) }
        }
        #expect(value == -1)
        try await Task.sleep(for: .milliseconds(300))
    }
}
