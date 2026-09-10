import AppKit
import Foundation
import os

let chromeLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "chrome")

/// Chromium-family browsers. They all share Chrome's scripting dictionary, so
/// the bundle ID is the only difference between Chrome, Brave, Arc and Edge.
///
/// The dictionary has no "is this tab audible" property, hence the detour
/// through `execute javascript` in every tab.
public struct ChromeController: MediaController {
    private static let displayNames = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium",
    ]

    private let bundleID: String

    public let id: MediaControllerID
    public let displayName: String

    public init(bundleID: String = "com.google.Chrome") {
        self.bundleID = bundleID
        id = .chrome(bundleID: bundleID)
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
            result = try Scripts.pause(bundleID: bundleID).execute()
        } catch {
            chromeLogger.error("pause: \(error.logMessage, privacy: .public)")
            return nil
        }

        switch ChromePauseResult(result) {
        case let .javaScriptDisabled(message):
            chromeLogger.error("pause: \(message, privacy: .public) — \(self.javaScriptDisabledHint, privacy: .public)")
            return nil
        case let .paused(tabs):
            guard !tabs.isEmpty else { return nil }
            chromeLogger.debug("paused \(tabs.count, privacy: .public) tab(s)")
            return PauseReceipt(controller: id, items: tabs.map(\.item))
        }
    }

    /// The one setting users must switch on by hand, probed with a no-op script
    /// in the first http(s) tab so the problem can be shown before the first
    /// call instead of surfacing as a silent "nothing to pause".
    @MainActor public func javaScriptAccess() -> ChromeJavaScriptAccess {
        guard isRunning else { return .browserNotRunning }
        do {
            return ChromeJavaScriptAccess(try Scripts.probe(bundleID: bundleID).execute())
        } catch {
            return .failed(message: error.logMessage)
        }
    }

    public var javaScriptDisabledHint: String {
        "enable View → Developer → Allow JavaScript from Apple Events in \(displayName)"
    }

    /// Only the elements this controller marked are started again; a tab the
    /// user paused by hand during the call stays paused. Tabs and windows that
    /// are gone by now make the lookup fail and are skipped.
    @MainActor public func resume(_ receipt: PauseReceipt) async {
        guard receipt.controller == id, isRunning else { return }

        let tabs = receipt.items.compactMap(ChromeTabID.init(item:))
        guard !tabs.isEmpty else { return }

        do {
            _ = try Scripts.resume(bundleID: bundleID, tabs: tabs).execute()
        } catch {
            chromeLogger.error("resume: \(error.logMessage, privacy: .public)")
        }
    }
}

/// A tab, addressed the way the scripting dictionary does: by its window and its
/// own ID, both of which are `text` there. This is what a receipt item encodes.
struct ChromeTabID: Hashable {
    let window: String
    let tab: String

    init(window: String, tab: String) {
        self.window = window
        self.tab = tab
    }

    /// `nil` for anything that is not `"<windowID>:<tabID>"`.
    init?(item: String) {
        let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        window = String(parts[0])
        tab = String(parts[1])
    }

    var item: String { "\(window):\(tab)" }
}

/// What the pause script returns: the tabs it paused, or the one error that must
/// not be swallowed — Chrome refusing to run JavaScript from Apple Events at all,
/// which the user has to switch on by hand.
enum ChromePauseResult: Hashable {
    case paused([ChromeTabID])
    case javaScriptDisabled(message: String)

    /// First item of the returned list when the script hit the error below.
    /// A regular item always contains a colon, so the two cannot be confused.
    static let errorMarker = "ERROR"
    static let javaScriptDisabledMessage = "Executing JavaScript through AppleScript is turned off"

    init(_ descriptor: NSAppleEventDescriptor) {
        let items = descriptor.stringItems
        if items.first == Self.errorMarker {
            self = .javaScriptDisabled(message: items.dropFirst().first ?? "unknown error")
        } else {
            self = .paused(items.compactMap(ChromeTabID.init(item:)))
        }
    }
}

public enum ChromeJavaScriptAccess: Hashable, Sendable {
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
            guard items.first == ChromePauseResult.errorMarker else {
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
    static let pause = """
        (() => {
          const playing = [...document.querySelectorAll('video,audio')]
            .filter(m => !m.paused && !m.ended && m.readyState > 2);
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

/// Addressed by bundle ID so the localised application name does not matter.
@MainActor
private enum Scripts {
    private static var pauseScripts: [String: AppleScript] = [:]

    /// One script per browser, compiled on first use: compilation is the
    /// expensive part and the source never changes.
    static func pause(bundleID: String) -> AppleScript {
        if let existing = pauseScripts[bundleID] { return existing }
        let script = AppleScript(pauseSource(bundleID: bundleID))
        pauseScripts[bundleID] = script
        return script
    }

    /// Compiled per call, because the tabs to resume are part of the source.
    /// That happens once per call end, so the cost does not matter.
    static func resume(bundleID: String, tabs: [ChromeTabID]) -> AppleScript {
        AppleScript(resumeSource(bundleID: bundleID, tabs: tabs))
    }

    static func probe(bundleID: String) -> AppleScript {
        AppleScript(probeSource(bundleID: bundleID))
    }

    /// Tabs whose URL is not http(s) — `chrome://`, extensions, blank pages —
    /// throw on `execute javascript` and are skipped before that happens.
    private static func pauseSource(bundleID: String) -> String {
        """
        tell application id \(AppleScriptLiteral.string(bundleID))
            set hits to {}
            repeat with winRef in every window
                repeat with tabRef in every tab of winRef
                    try
                        set urlText to URL of tabRef
                        if urlText starts with "http" then
                            set outcome to (execute tabRef javascript \(AppleScriptLiteral.string(JavaScript.pause))) as text
                            if outcome is "1" then
                                set end of hits to ((id of winRef as text) & ":" & (id of tabRef as text))
                            end if
                        end if
                    on error errMsg number errNum
                        if errMsg contains \(AppleScriptLiteral.string(ChromePauseResult.javaScriptDisabledMessage)) then
                            return {\(AppleScriptLiteral.string(ChromePauseResult.errorMarker)), errMsg}
                        end if
                    end try
                end repeat
            end repeat
            return hits
        end tell
        """
    }

    private static func probeSource(bundleID: String) -> String {
        """
        tell application id \(AppleScriptLiteral.string(bundleID))
            repeat with winRef in every window
                repeat with tabRef in every tab of winRef
                    if (URL of tabRef) starts with "http" then
                        try
                            execute tabRef javascript "1"
                            return \(AppleScriptLiteral.string(ChromeJavaScriptAccess.availableMarker))
                        on error errMsg number errNum
                            if errMsg contains \(AppleScriptLiteral.string(ChromePauseResult.javaScriptDisabledMessage)) then
                                return {\(AppleScriptLiteral.string(ChromePauseResult.errorMarker)), errMsg}
                            end if
                        end try
                    end if
                end repeat
            end repeat
            return \(AppleScriptLiteral.string(ChromeJavaScriptAccess.noTabMarker))
        end tell
        """
    }

    private static func resumeSource(bundleID: String, tabs: [ChromeTabID]) -> String {
        let pairs = tabs
            .map { "{\(AppleScriptLiteral.string($0.window)), \(AppleScriptLiteral.string($0.tab))}" }
            .joined(separator: ", ")
        return """
        tell application id \(AppleScriptLiteral.string(bundleID))
            repeat with pair in {\(pairs)}
                try
                    set winRef to first window whose id is (item 1 of pair)
                    set tabRef to first tab of winRef whose id is (item 2 of pair)
                    execute tabRef javascript \(AppleScriptLiteral.string(JavaScript.resume))
                end try
            end repeat
        end tell
        """
    }
}
