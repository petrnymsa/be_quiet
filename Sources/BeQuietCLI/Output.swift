import Darwin
import Foundation

enum Output {
    /// Flushed on every line: `bequiet watch` output is routinely piped to a file.
    static func line(_ text: String = "") {
        print(text)
        fflush(stdout)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Local wall clock as `HH:mm:ss.SSS`.
    static func timestamp(_ date: Date = Date()) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = time_t(interval.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        let milliseconds = min(Int((interval - interval.rounded(.down)) * 1000), 999)
        return String(
            format: "%02d:%02d:%02d.%03d",
            parts.tm_hour,
            parts.tm_min,
            parts.tm_sec,
            milliseconds
        )
    }

    static func event(_ tag: String, _ text: String) {
        line("\(timestamp())  \(tag.padded(to: 12))  \(text)")
    }
}

/// `1`/`0`, the compact form every CLI line uses for booleans.
func flag(_ value: Bool) -> String { value ? "1" : "0" }

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    var quoted: String { "\"\(self)\"" }
}
