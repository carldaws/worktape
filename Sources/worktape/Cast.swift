import Foundation

struct CastHeader: Decodable {
    struct Terminal: Decodable {
        let cols: Int
        let rows: Int
        let theme: Theme?
    }

    struct Theme: Decodable {
        let fg: String
        let bg: String
        let palette: String
    }

    let version: Int
    let term: Terminal?
    let width: Int?
    let height: Int?
    let theme: Theme?

    var columns: Int { term?.cols ?? width ?? 80 }
    var rows: Int { term?.rows ?? height ?? 24 }
    var colors: Theme? { term?.theme ?? theme }
}

struct CastEvent: Decodable {
    let time: Double
    let code: String
    let data: String

    init(from decoder: any Decoder) throws {
        var fields = try decoder.unkeyedContainer()
        time = try fields.decode(Double.self)
        code = try fields.decode(String.self)
        data = (try? fields.decode(String.self)) ?? ""
    }
}

struct Timeline {
    private let idleLimit: Double
    private let intervals: Bool
    private var previous = 0.0
    private(set) var now = 0.0

    init(version: Int, idleLimit: Double) {
        self.idleLimit = idleLimit
        intervals = version >= 3
    }

    mutating func advance(to time: Double) -> Double {
        let gap = intervals ? time : time - previous
        previous = time
        now += min(max(gap, 0), idleLimit)
        return now
    }
}

final class CastReader {
    private let path: String
    private var file: FileHandle?
    private var pending = Data()
    private(set) var consumed = 0
    private(set) var header: CastHeader?

    init(path: String) {
        self.path = path
    }

    deinit {
        try? file?.close()
    }

    func next(atEnd: Bool = false) throws -> CastEvent? {
        while let line = try nextLine(atEnd: atEnd) {
            guard !line.isEmpty else { continue }
            guard header != nil else {
                header = try JSONDecoder().decode(CastHeader.self, from: line)
                continue
            }
            if let event = try? JSONDecoder().decode(CastEvent.self, from: line) {
                return event
            }
        }
        return nil
    }

    private func nextLine(atEnd: Bool) throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                return take(upTo: newline, separator: 1)
            }
            if file == nil {
                file = FileHandle(forReadingAtPath: path)
            }
            guard let file, let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            pending.append(chunk)
        }
        guard atEnd, !pending.isEmpty else { return nil }
        return take(upTo: pending.endIndex, separator: 0)
    }

    private func take(upTo end: Data.Index, separator: Int) -> Data {
        let line = Data(pending[pending.startIndex..<end])
        let length = line.count + separator
        consumed += length
        pending.removeFirst(length)
        return line
    }
}
