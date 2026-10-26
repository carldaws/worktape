import CoreGraphics
import Testing
@testable import worktape

struct OverlayTests {
    let window = RecordedWindow(owner: 100, frame: CGRect(x: 100, y: 100, width: 640, height: 512))

    @Test func aSmallWindowOverARecordedOneFromTheSameAppIsAnOverlay() {
        #expect(isOverlay(CGRect(x: 106, y: 106, width: 66, height: 20), from: 100, on: [window], titleBarHeight: 32))
    }

    @Test func aDialogInsideARecordedWindowIsNotAnOverlay() {
        #expect(!isOverlay(CGRect(x: 200, y: 250, width: 300, height: 150), from: 100, on: [window], titleBarHeight: 32))
    }

    @Test func aWindowFromAnotherAppIsNotAnOverlay() {
        #expect(!isOverlay(CGRect(x: 106, y: 106, width: 66, height: 20), from: 200, on: [window], titleBarHeight: 32))
    }

    @Test func anIdenticalWindowFromAnotherAppIsNotAnOverlay() {
        #expect(!isOverlay(window.frame, from: 200, on: [window], titleBarHeight: 32))
    }

    @Test func aWindowReachingOutsideIsNotAnOverlay() {
        #expect(!isOverlay(CGRect(x: 600, y: 100, width: 300, height: 200), from: 100, on: [window], titleBarHeight: 32))
    }

    @Test func nothingIsAnOverlayWhenNothingIsRecorded() {
        #expect(!isOverlay(window.frame, from: 100, on: [], titleBarHeight: 32))
    }

    @Test @MainActor func titleBarsHaveHeight() {
        #expect(standardTitleBarHeight() > 0)
    }
}

struct SlugTests {
    @Test(arguments: [
        ("examples/renderer/clear", "examples-renderer-clear"),
        ("FEED", "feed"),
        ("My App — Debug Build (60 fps)", "my-app-debug-build-60-fps"),
        ("   ", ""),
        ("", ""),
    ])
    func turnsTitlesIntoFileNames(title: String, expected: String) {
        #expect(slug(title) == expected)
    }

    @Test(arguments: [String(repeating: "a", count: 300), String(repeating: "é", count: 300)])
    func keepsFileNamesShort(title: String) {
        #expect(slug(title).utf8.count <= 100)
    }
}

struct CassetteTests {
    @Test(arguments: [
        ("my-project", ".worktapes/2026-10-22-005938"),
        ("my-project", ".worktapes/2026-10-22-005938-12"),
        ("a-project-with-a-name-far-too-long-for-the-label", ".worktapes/2026-10-22-005938"),
        ("x", ""),
    ])
    func everyRowIsTheSameWidth(project: String, tape: String) {
        let rows = Console.cassette(project, tape: tape, styled: false)
        #expect(Set(rows.map(\.count)).count == 1)
    }

    @Test func labelShowsTheProjectAndTape() {
        let rows = Console.cassette("my-project", tape: ".worktapes/2026-10-22-005938", styled: false)
        #expect(rows.contains { $0.contains("│ my-project ") })
        #expect(rows.contains { $0.contains("│ .worktapes/2026-10-22-005938 │") })
    }

    @Test func longProjectNamesAreShortened() {
        let rows = Console.cassette(String(repeating: "x", count: 60), tape: ".worktapes/2026-10-22-005938", styled: false)
        #expect(rows.contains { $0.contains("x…") })
    }
}
