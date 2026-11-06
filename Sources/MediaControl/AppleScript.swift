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
/// Every script of this process is compiled and executed on one private serial
/// queue, off the main thread: an `execute javascript` round trip into a tab
/// that stopped answering takes seconds, and on the main actor that froze the
/// whole menu bar app. `execute` suspends its caller instead of blocking it.
///
/// `@unchecked Sendable` because `compiled` and the descriptor an execution
/// returns never leave `queue` — a confinement the compiler cannot verify, and
/// the reason callers hand in a `read` closure rather than the descriptor
/// itself, which is not `Sendable`.
final class AppleScript: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "cz.nymsa.BeQuiet.applescript")

    /// AppleScript waits for the reply to a remote send on the Carbon event
    /// loop, and that only works on a secondary thread once the main thread has
    /// executed a script itself. Without this the very first execution on
    /// `queue` never returns — measured, not theory. Any script does, so this
    /// one is local and sends no Apple Event at all.
    private static let bootstrap: Void = {
        let warmUp = {
            var errorInfo: NSDictionary?
            _ = NSAppleScript(source: "return 1")?.executeAndReturnError(&errorInfo)
        }
        if Thread.isMainThread { warmUp() } else { DispatchQueue.main.sync(execute: warmUp) }
    }()

    private let source: String
    private var compiled: NSAppleScript?

    init(_ source: String) {
        self.source = source
    }

    /// `read` runs on the queue, on the descriptor the script returned.
    func execute<T: Sendable>(
        _ read: @escaping @Sendable (NSAppleEventDescriptor) -> T
    ) async throws(AppleScriptError) -> T {
        let outcome: Result<T, AppleScriptError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: self.runCatching(read))
            }
        }
        switch outcome {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    func execute() async throws(AppleScriptError) {
        try await execute { _ in }
    }

    private func runCatching<T>(_ read: (NSAppleEventDescriptor) -> T) -> Result<T, AppleScriptError> {
        do {
            let descriptor = try run()
            return .success(read(descriptor))
        } catch {
            return .failure(error)
        }
    }

    private func run() throws(AppleScriptError) -> NSAppleEventDescriptor {
        _ = Self.bootstrap
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
