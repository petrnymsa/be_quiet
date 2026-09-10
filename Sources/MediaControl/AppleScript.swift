import Foundation

enum AppleScriptError: Error, Hashable {
    case compilationFailed(message: String)
    case executionFailed(code: Int, message: String)

    /// `errAEEventNotPermitted`: the user has not allowed this process to send
    /// Apple Events to the target application.
    static let automationDeniedCode = -1743

    var logMessage: String {
        switch self {
        case let .compilationFailed(message):
            "compilation failed: \(message)"
        case let .executionFailed(code, message) where code == Self.automationDeniedCode:
            "not permitted (\(code)): \(message) — allow this app to control the target in "
                + "System Settings → Privacy & Security → Automation"
        case let .executionFailed(code, message):
            "failed (\(code)): \(message)"
        }
    }
}

/// One AppleScript source, compiled on first use and reused afterwards.
///
/// Compilation is by far the expensive part and it reads the target's scripting
/// dictionary from disk, without launching it. Only sending a command launches
/// the application, which is why callers must check that it is already running.
///
/// `NSAppleScript` is not thread-safe, hence the main actor isolation; it also
/// keeps every Apple Event this process sends on one thread.
@MainActor
final class AppleScript {
    private let source: String
    private var compiled: NSAppleScript?

    init(_ source: String) {
        self.source = source
    }

    func execute() throws(AppleScriptError) -> NSAppleEventDescriptor {
        let script = try compiledScript()
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw AppleScriptError.executionFailed(code: errorInfo.errorCode, message: errorInfo.errorMessage)
        }
        return result
    }

    private func compiledScript() throws(AppleScriptError) -> NSAppleScript {
        if let compiled { return compiled }

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError.compilationFailed(message: "source could not be read")
        }
        guard script.compileAndReturnError(&errorInfo) else {
            throw AppleScriptError.compilationFailed(message: errorInfo?.errorMessage ?? "unknown error")
        }
        compiled = script
        return script
    }
}

private extension NSDictionary {
    var errorMessage: String {
        self[NSAppleScript.errorMessage] as? String ?? "unknown error"
    }

    var errorCode: Int {
        self[NSAppleScript.errorNumber] as? Int ?? 0
    }
}

/// AppleScript string literals cannot span lines and know only backslash
/// escapes, so anything spliced into a script source — the JavaScript that
/// drives the browser above all — has to be encoded first.
enum AppleScriptLiteral {
    static func string(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value {
            switch character {
            case "\\": escaped += #"\\"#
            case "\"": escaped += #"\""#
            case "\n": escaped += #"\n"#
            case "\r": escaped += #"\r"#
            case "\t": escaped += #"\t"#
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
