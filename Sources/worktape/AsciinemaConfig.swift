import Foundation
import RegexBuilder

struct AsciinemaConfig {
    let directory: String

    static func create(extending userConfig: String = userConfigFile, in parent: String = NSTemporaryDirectory()) throws -> AsciinemaConfig? {
        let existing = (try? String(contentsOfFile: userConfig, encoding: .utf8)) ?? ""
        guard !configuresNotifications(existing) else { return nil }

        let directory = (parent as NSString).appendingPathComponent("worktape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        let config = AsciinemaConfig(directory: directory)
        do {
            let contents = existing + "\n" + config.notifications
            try contents.write(toFile: config.file("config.toml"), atomically: true, encoding: .utf8)
        } catch {
            config.remove()
            throw error
        }
        return config
    }

    var isPaused: Bool {
        FileManager.default.fileExists(atPath: file("paused"))
    }

    var promptShowsState: Bool {
        FileManager.default.fileExists(atPath: file("prompt"))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func file(_ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    var notificationCommand: String {
        """
        case "$TEXT" in
          Paused*) : > '\(file("paused"))' ;;
          Resumed*) rm -f '\(file("paused"))' ;;
        esac
        """
    }

    private var notifications: String {
        """
        [notifications]
        command = '''
        \(notificationCommand)
        '''

        """
    }

    static var userConfigFile: String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["ASCIINEMA_CONFIG_HOME"]
            ?? environment["XDG_CONFIG_HOME"].map { ($0 as NSString).appendingPathComponent("asciinema") }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/asciinema")
        return (home as NSString).appendingPathComponent("config.toml")
    }

    static func configuresNotifications(_ config: String) -> Bool {
        let key = /\s*["']?notifications["']?\s*/
        let table = Regex { ZeroOrMore(.whitespace); "["; key; ChoiceOf { "]"; "." }; ZeroOrMore(.any) }
        let dottedKeyOrInlineTable = Regex { key; ChoiceOf { "."; "=" }; ZeroOrMore(.any) }
        return config.split(separator: "\n").contains { line in
            line.wholeMatch(of: table) != nil || line.wholeMatch(of: dottedKeyOrInlineTable) != nil
        }
    }
}
