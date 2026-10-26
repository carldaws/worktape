import Foundation
import Testing
@testable import worktape

struct ProjectTests {
    @Test func findsTheProjectFromASubdirectory() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(atPath: root + "/.worktapes", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
            #expect(Project.containing(root + "/a/b")?.root == root)
        }
    }

    @Test func findsNothingOutsideAProject() throws {
        try withTemporaryDirectory { root in
            #expect(Project.containing(root) == nil)
        }
    }

    @Test func ignoresAFileNamedLikeTheFolder() throws {
        try withTemporaryDirectory { root in
            FileManager.default.createFile(atPath: root + "/.worktapes", contents: nil)
            #expect(Project.containing(root) == nil)
        }
    }

    @Test func initRepairsAFolderMissingItsIgnoreFile() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(atPath: root + "/.worktapes", withIntermediateDirectories: false)
            #expect(initialise(root) == 0)
            #expect(FileManager.default.fileExists(atPath: root + "/.worktapes/.gitignore"))
        }
    }

    @Test func initCreatesAFolderThatIgnoresItself() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let ignore = try String(contentsOfFile: root + "/.worktapes/.gitignore", encoding: .utf8)
            #expect(ignore == "*\n")
            #expect(initialise(root) == 1)
        }
    }
}

struct SessionTests {
    let calendar = Calendar(identifier: .gregorian)
    var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))! }

    @Test func namesTheFolderAndCastAfterTheStartTime() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let session = try Session(in: Project(root: root), startedAt: noon)
            #expect(session.directory == root + "/.worktapes/2026-10-22-120000")
            #expect(session.directoryInProject == ".worktapes/2026-10-22-120000")
            #expect(session.terminal == session.directory + "/2026-10-22-120000.cast")
        }
    }

    @Test func numbersSessionsThatStartInTheSameSecond() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let project = Project(root: root)
            _ = try Session(in: project, startedAt: noon)
            let second = try Session(in: project, startedAt: noon)
            let third = try Session(in: project, startedAt: noon)
            #expect(second.directoryInProject == ".worktapes/2026-10-22-120000-2")
            #expect(third.terminal.hasSuffix("/2026-10-22-120000-3/2026-10-22-120000-3.cast"))
        }
    }

    @Test func namesADescribedSessionAfterItsDayAndDescription() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let session = try Session(in: Project(root: root), named: "Fixing the jump!", startedAt: noon)
            #expect(session.terminal == root + "/.worktapes/2026-10-22-fixing-the-jump/2026-10-22-fixing-the-jump.cast")
        }
    }

    @Test func refusesToReuseADescriptionOnTheSameDay() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let project = Project(root: root)
            _ = try Session(in: project, named: "Fixing the jump", startedAt: noon)
            #expect(throws: SessionExists.self) {
                try Session(in: project, named: "fixing the jump", startedAt: calendar.date(byAdding: .hour, value: 1, to: noon)!)
            }
            let nextDay = try Session(in: project, named: "Fixing the jump", startedAt: calendar.date(byAdding: .day, value: 1, to: noon)!)
            #expect(nextDay.directoryInProject == ".worktapes/2026-10-23-fixing-the-jump")
        }
    }

    @Test func removesOnlyAnEmptyFolder() throws {
        try withTemporaryDirectory { root in
            #expect(initialise(root) == 0)
            let empty = try Session(in: Project(root: root), startedAt: noon)
            empty.removeDirectoryIfEmpty()
            #expect(!FileManager.default.fileExists(atPath: empty.directory))

            let used = try Session(in: Project(root: root), startedAt: calendar.date(byAdding: .hour, value: 1, to: noon)!)
            FileManager.default.createFile(atPath: used.terminal, contents: Data())
            used.removeDirectoryIfEmpty()
            #expect(FileManager.default.fileExists(atPath: used.terminal))
        }
    }
}

struct RenderSizeTests {
    @Test(arguments: [(80, 24, 32), (319, 87, 17), (2000, 600, 2)])
    func fitsTheVideoIn4K(columns: Int, rows: Int, expected: Int) {
        #expect(fontSize(columns: columns, rows: rows) == expected)
    }

    @Test func readsTheTerminalSizeFromTheCast() async throws {
        try await withTemporaryDirectory { directory in
            let cast = directory + "/session.cast"
            try """
            {"version":3,"term":{"cols":319,"rows":87,"type":"xterm-ghostty"},"timestamp":1792677978}
            [0.095, "o", "hello"]
            """.write(toFile: cast, atomically: true, encoding: .utf8)
            let size = try #require(await terminalSize(of: cast))
            #expect(size.columns == 319 && size.rows == 87)
            await #expect(throws: (any Error).self) {
                try await terminalSize(of: directory + "/missing.cast")
            }
        }
    }
}
