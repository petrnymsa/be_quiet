import AppKit
import Foundation
import os

let browserLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "browser")

/// How a browser is asked to run JavaScript in a tab. Chromium and Safari
/// differ in that command, in what identifies a tab, and in the wording of the
/// one error that must not be swallowed — nothing else.
public enum BrowserDialect: Sendable {
    case chromium
    case safari
}

/// Chromium-family browsers and Safari. The Chromium browsers all share
/// Chrome's scripting dictionary, so among them the bundle ID is the only
/// difference; Safari brings its own dialect.
///
/// Neither dictionary has an "is this tab audible" property, hence the detour
/// through JavaScript in every tab.
public struct BrowserController: MediaController {
    private static let displayNames = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium",
        "com.apple.Safari": "Safari",
    ]

    public static let chrome = BrowserController(bundleID: "com.google.Chrome", dialect: .chromium)
    public static let safari = BrowserController(bundleID: "com.apple.Safari", dialect: .safari)

    private let bundleID: String
    private let dialect: BrowserDialect

    public let id: MediaControllerID
    public let displayName: String

    public init(bundleID: String, dialect: BrowserDialect) {
        self.bundleID = bundleID
        self.dialect = dialect
        id = switch dialect {
        case .chromium: .chrome(bundleID: bundleID)
        case .safari: .safari
        }
        displayName = Self.displayNames[bundleID] ?? bundleID
    }

    /// Checked before every script: `tell application` launches its target, and
    /// BeQuiet must never start a browser.
    @MainActor public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Probes the browser, which compiles the scripts and triggers the
    /// Automation prompt.
    @MainActor public func prepare() async {
        _ = javaScriptAccess()
    }

    @MainActor public func pauseIfPlaying() async -> PauseReceipt? {
        guard isRunning else { return nil }

        let result: NSAppleEventDescriptor
        do {
            result = try Scripts.pause(bundleID: bundleID, dialect: dialect).execute()
        } catch {
            browserLogger.error("\(self.displayName, privacy: .public) pause: \(error.logMessage, privacy: .public)")
            return nil
        }

        switch BrowserPauseResult(result) {
        case let .javaScriptDisabled(message):
            let refusal = "\(message) — \(javaScriptDisabledHint)"
            browserLogger.error("\(self.displayName, privacy: .public) pause: \(refusal, privacy: .public)")
            return nil
        case let .paused(tabs):
            guard !tabs.isEmpty else { return nil }
            browserLogger.debug("\(self.displayName, privacy: .public) paused \(tabs.count, privacy: .public) tab(s)")
            return PauseReceipt(controller: id, items: tabs)
        }
    }

    /// The one setting users must switch on by hand, probed with a no-op script
    /// in the first http(s) tab so the problem can be shown before the first
    /// call instead of surfacing as a silent "nothing to pause".
    @MainActor public func javaScriptAccess() -> BrowserJavaScriptAccess {
        guard isRunning else { return .browserNotRunning }
        do {
            return BrowserJavaScriptAccess(try Scripts.probe(bundleID: bundleID, dialect: dialect).execute())
        } catch {
            return .failed(message: error.logMessage)
        }
    }

    public var javaScriptDisabledHint: String {
        switch dialect {
        case .chromium:
            "enable View → Developer → Allow JavaScript from Apple Events in \(displayName)"
        case .safari:
            "enable Develop → Allow JavaScript from Apple Events in Safari (the Develop menu appears "
                + "after Settings → Advanced → Show features for web developers)"
        }
    }

    /// Only the elements this controller marked are started again; a tab the
    /// user paused by hand during the call stays paused.
    ///
    /// The tabs are not addressed at all — Safari identifies a tab by its
    /// position, which shifts as soon as tabs are closed or reordered. Resume
    /// therefore visits the http(s) tabs again and lets the marker decide,
    /// which makes the receipt items pure logging material.
    @MainActor public func resume(_ receipt: PauseReceipt) async {
        guard receipt.controller == id, isRunning else { return }

        do {
            _ = try Scripts.resume(bundleID: bundleID, dialect: dialect).execute()
        } catch {
            browserLogger.error("\(self.displayName, privacy: .public) resume: \(error.logMessage, privacy: .public)")
        }
    }
}

/// What the pause script returns: a hint per tab it paused, or the one error
/// that must not be swallowed — the browser refusing to run JavaScript from
/// Apple Events at all, which the user has to switch on by hand.
enum BrowserPauseResult: Hashable {
    case paused([String])
    case javaScriptDisabled(message: String)

    /// First item of the returned list when the script hit the error above.
    /// A tab hint always contains a colon, so the two cannot be confused.
    static let errorMarker = "ERROR"

    init(_ descriptor: NSAppleEventDescriptor) {
        let items = descriptor.stringItems
        if items.first == Self.errorMarker {
            self = .javaScriptDisabled(message: items.dropFirst().first ?? "unknown error")
        } else {
            self = .paused(items)
        }
    }
}

public enum BrowserJavaScriptAccess: Hashable, Sendable {
    case available
    case disabled(message: String)
    case browserNotRunning
    case noScriptableTab
    case failed(message: String)

    static let availableMarker = "OK"
    static let noTabMarker = "NOTAB"

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.stringValue {
        case Self.availableMarker: self = .available
        case Self.noTabMarker: self = .noScriptableTab
        default:
            let items = descriptor.stringItems
            guard items.first == BrowserPauseResult.errorMarker else {
                self = .failed(message: "unexpected result \(items)")
                return
            }
            self = .disabled(message: items.dropFirst().first ?? "unknown error")
        }
    }
}

extension NSAppleEventDescriptor {
    /// AppleScript lists are 1-based; a non-list descriptor reports no items.
    var stringItems: [String] {
        guard numberOfItems > 0 else { return [] }
        return (1 ... numberOfItems).compactMap { atIndex($0)?.stringValue }
    }
}

private enum JavaScript {
    /// Pauses only what is actually playing and marks those elements, so that
    /// resume can tell them apart from whatever the user paused themselves.
    /// Elements fed by a live `MediaStream` (`srcObject`) are the call itself —
    /// Meet's participants — and are never touched.
    static let pause = """
        (() => {
          const playing = [...document.querySelectorAll('video,audio')]
            .filter(m => !m.paused && !m.ended && m.readyState > 2 && !m.srcObject);
          playing.forEach(m => { m.dataset.bequietPaused = '1'; m.pause(); });
          return playing.length ? '1' : '0';
        })()
        """

    static let resume = """
        (() => {
          const mine = [...document.querySelectorAll('video,audio')]
            .filter(m => m.dataset.bequietPaused === '1');
          mine.forEach(m => { delete m.dataset.bequietPaused; if (m.paused && !m.ended) m.play(); });
        })()
        """
}

extension BrowserDialect {
    /// AppleScript that evaluates `javaScript` in the tab `tabRef` refers to.
    func evaluate(_ javaScript: String) -> String {
        let literal = AppleScriptLiteral.string(javaScript)
        return switch self {
        case .chromium: "execute tabRef javascript \(literal)"
        case .safari: "do JavaScript \(literal) in tabRef"
        }
    }

    /// AppleScript expression naming the tab `tabRef` refers to, in terms of
    /// `winRef` and `tabRef`. Safari tabs have no ID, only a position, so this
    /// is good for a log line and nothing else.
    var tabHint: String {
        switch self {
        case .chromium: #"((id of winRef as text) & ":" & (id of tabRef as text))"#
        case .safari: #"((id of winRef as text) & ":" & (index of tabRef as text))"#
        }
    }

    /// The wording the browser uses when *Allow JavaScript from Apple Events*
    /// is off. Nothing else tells that refusal apart from a tab that simply
    /// cannot be scripted, and the two must not be treated alike.
    var javaScriptDisabledMessage: String {
        switch self {
        case .chromium: "Executing JavaScript through AppleScript is turned off"
        case .safari: "Allow JavaScript from Apple Events"
        }
    }
}

/// The script sources, addressed by bundle ID so the localised application name
/// does not matter. Pure string building, so the tests can read them without a
/// browser anywhere near.
///
/// Every loop skips what cannot run JavaScript before trying: tabs whose URL is
/// not http(s) — `chrome://`, extensions — and empty tabs, whose URL Safari
/// reports as `missing value`. The `try` per window covers windows without tabs
/// at all.
enum BrowserScriptSource {
    static func pause(bundleID: String, dialect: BrowserDialect) -> String {
        """
        tell application id \(AppleScriptLiteral.string(bundleID))
            set hits to {}
            repeat with winRef in every window
                try
                    repeat with tabRef in every tab of winRef
                        try
                            set urlText to URL of tabRef
                            if urlText is not missing value and urlText starts with "http" then
                                set outcome to (\(dialect.evaluate(JavaScript.pause))) as text
                                if outcome is "1" then
                                    set end of hits to \(dialect.tabHint)
                                end if
                            end if
                        on error errMsg number errNum
                            if errMsg contains \(AppleScriptLiteral.string(dialect.javaScriptDisabledMessage)) then
                                return {\(AppleScriptLiteral.string(BrowserPauseResult.errorMarker)), errMsg}
                            end if
                        end try
                    end repeat
                end try
            end repeat
            return hits
        end tell
        """
    }

    /// The same iteration as `pause`, because the marker is what selects the
    /// elements; a tab that throws is simply skipped.
    static func resume(bundleID: String, dialect: BrowserDialect) -> String {
        """
        tell application id \(AppleScriptLiteral.string(bundleID))
            repeat with winRef in every window
                try
                    repeat with tabRef in every tab of winRef
                        try
                            set urlText to URL of tabRef
                            if urlText is not missing value and urlText starts with "http" then
                                \(dialect.evaluate(JavaScript.resume))
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        """
    }

    static func probe(bundleID: String, dialect: BrowserDialect) -> String {
        """
        tell application id \(AppleScriptLiteral.string(bundleID))
            repeat with winRef in every window
                try
                    repeat with tabRef in every tab of winRef
                        set urlText to URL of tabRef
                        if urlText is not missing value and urlText starts with "http" then
                            try
                                \(dialect.evaluate("1"))
                                return \(AppleScriptLiteral.string(BrowserJavaScriptAccess.availableMarker))
                            on error errMsg number errNum
                                if errMsg contains \(AppleScriptLiteral.string(dialect.javaScriptDisabledMessage)) then
                                    return {\(AppleScriptLiteral.string(BrowserPauseResult.errorMarker)), errMsg}
                                end if
                            end try
                        end if
                    end repeat
                end try
            end repeat
            return \(AppleScriptLiteral.string(BrowserJavaScriptAccess.noTabMarker))
        end tell
        """
    }
}

@MainActor
private enum Scripts {
    private static var pauseScripts: [String: AppleScript] = [:]
    private static var resumeScripts: [String: AppleScript] = [:]

    /// One script per browser and phase, compiled on first use: compilation is
    /// the expensive part and neither source ever changes.
    static func pause(bundleID: String, dialect: BrowserDialect) -> AppleScript {
        if let existing = pauseScripts[bundleID] { return existing }
        let script = AppleScript(BrowserScriptSource.pause(bundleID: bundleID, dialect: dialect))
        pauseScripts[bundleID] = script
        return script
    }

    static func resume(bundleID: String, dialect: BrowserDialect) -> AppleScript {
        if let existing = resumeScripts[bundleID] { return existing }
        let script = AppleScript(BrowserScriptSource.resume(bundleID: bundleID, dialect: dialect))
        resumeScripts[bundleID] = script
        return script
    }

    static func probe(bundleID: String, dialect: BrowserDialect) -> AppleScript {
        AppleScript(BrowserScriptSource.probe(bundleID: bundleID, dialect: dialect))
    }
}
