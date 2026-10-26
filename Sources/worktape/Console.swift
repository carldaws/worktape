import Darwin
import Foundation

enum Console {
    enum Style: String {
        case red = "1;31"
        case yellow = "33"
        case bold = "1"
        case dim = "2"
    }

    private static let interactive = isatty(STDERR_FILENO) == 1
    static let styled = interactive && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func recording(_ project: String, to tape: String) {
        write("")
        cassette(project, tape: tape).forEach(write)
        write(style("  ■ stop    $ worktape stop", .dim))
        write(style("  ‖ pause   ctrl+\\", .dim))
        write("")
    }

    static func cassette(_ project: String, tape: String, styled: Bool = styled) -> [String] {
        let width = max(36, tape.count + 8)
        let labelWidth = width - 8
        let name = project.count > labelWidth ? project.prefix(labelWidth - 1) + "…" : project
        let line = { (count: Int) in String(repeating: "─", count: count) }
        let blank = { (count: Int) in String(repeating: " ", count: count) }
        let side = { (content: String) in "  │" + content + "│" }

        return [
            "  ╭" + line(width) + "╮",
            side(style("  ● REC", .red, when: styled) + blank(width - 17) + "worktape  "),
            side("  ┌" + line(width - 6) + "┐  "),
            side("  │ " + style(String(name), .bold, when: styled) + blank(labelWidth - name.count) + " │  "),
            side("  │ " + tape + blank(labelWidth - tape.count) + " │  "),
            side("  └" + line(width - 6) + "┘  "),
            side("   ╭─────╮   " + String(repeating: "┈", count: width - 26) + "   ╭─────╮   "),
            side("   │  ◎  │" + blank(width - 20) + "│  ◎  │   "),
            side("   ╰─────╯" + blank(width - 20) + "╰─────╯   "),
            "  ╰─────╱" + line(width - 12) + "╲─────╯",
        ]
    }

    static func stopped(_ project: String, after elapsed: Duration) {
        write("")
        write("  " + style("■ STOP", .bold) + "  \(project)  " + style(elapsed.formatted(.time(pattern: .hourMinuteSecond)), .dim))
    }

    static func note(_ message: String) {
        write(style("  \(message)", .dim))
    }

    static func working(_ activity: String, frame: Int, elapsed: Duration) {
        guard interactive else { return }
        let reel = ["◐", "◓", "◑", "◒"][frame % 4]
        let time = elapsed.formatted(.time(pattern: .minuteSecond))
        fputs("\r\u{1b}[K" + style("  \(reel) \(activity)  \(time)", .dim), stderr)
    }

    static func doneWorking() {
        guard interactive else { return }
        fputs("\r\u{1b}[K", stderr)
    }

    static func saved(in directory: String, _ files: [String]) {
        write("")
        write("  saved in \(directory)")
        for file in files {
            write("    \(file)")
        }
        write("")
    }

    static func problem(_ message: String) {
        write(style("  ! \(message)", .yellow))
    }

    private static func write(_ line: String) {
        fputs(line + "\n", stderr)
    }

    private static func style(_ text: String, _ style: Style, when enabled: Bool = styled) -> String {
        enabled ? "\u{1b}[\(style.rawValue)m\(text)\u{1b}[0m" : text
    }
}
