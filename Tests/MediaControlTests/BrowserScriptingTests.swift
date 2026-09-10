import Foundation
import Testing

@testable import MediaControl

@Suite("AppleScriptLiteral")
struct AppleScriptLiteralTests {
    @Test("quotes, backslashes and line breaks survive as AppleScript escapes")
    func escapes() {
        #expect(AppleScriptLiteral.string("plain") == "\"plain\"")
        #expect(AppleScriptLiteral.string("a\"b") == #""a\"b""#)
        #expect(AppleScriptLiteral.string(#"a\b"#) == #""a\\b""#)
        #expect(AppleScriptLiteral.string("a\nb") == #""a\nb""#)
        #expect(AppleScriptLiteral.string("a\r\tb") == #""a\r\tb""#)
        #expect(AppleScriptLiteral.string("") == "\"\"")
    }

    /// A literal is only correct if AppleScript itself reads back the original.
    @Test("AppleScript reads the literal back unchanged")
    @MainActor
    func roundTripThroughAppleScript() throws {
        let value = #"quote " backslash \ newline"# + "\n" + "tab\tend"
        let script = try #require(NSAppleScript(source: "return \(AppleScriptLiteral.string(value))"))
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        #expect(errorInfo == nil)
        #expect(result.stringValue == value)
    }
}

@Suite("BrowserPauseResult")
struct BrowserPauseResultTests {
    @Test("a list of items is parsed as the hints of the paused tabs")
    func pausedTabs() {
        #expect(BrowserPauseResult(list("1:2", "3:4")) == .paused(["1:2", "3:4"]))
    }

    @Test("an empty list means nothing was playing")
    func empty() {
        #expect(BrowserPauseResult(list()) == .paused([]))
    }

    @Test("the error marker carries the message the browser reported")
    func javaScriptDisabled() {
        let message = "\(BrowserDialect.chromium.javaScriptDisabledMessage). For more information: …"
        #expect(
            BrowserPauseResult(list(BrowserPauseResult.errorMarker, message))
                == .javaScriptDisabled(message: message)
        )
    }

    @Test("the error marker without a message still reports the case")
    func javaScriptDisabledWithoutMessage() {
        #expect(
            BrowserPauseResult(list(BrowserPauseResult.errorMarker))
                == .javaScriptDisabled(message: "unknown error")
        )
    }

    private func list(_ items: String...) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for item in items {
            list.insert(NSAppleEventDescriptor(string: item), at: 0)
        }
        return list
    }
}

@Suite("BrowserScriptSource")
struct BrowserScriptSourceTests {
    @Test("Safari is driven through `do JavaScript`")
    func safariDialect() {
        let source = BrowserScriptSource.pause(bundleID: "com.apple.Safari", dialect: .safari)
        #expect(source.contains("do JavaScript"))
        #expect(!source.contains("execute tabRef"))
        #expect(source.contains("index of tabRef"))
    }

    @Test("Chromium browsers are driven through `execute … javascript`")
    func chromiumDialect() {
        let source = BrowserScriptSource.pause(bundleID: "com.google.Chrome", dialect: .chromium)
        #expect(source.contains("execute"))
        #expect(source.contains("javascript"))
        #expect(!source.contains("do JavaScript"))
        #expect(source.contains("id of tabRef"))
    }

    /// Resume finds its elements by the marker, so no tab may appear in it.
    @Test("resume addresses no tab", arguments: [BrowserDialect.chromium, .safari])
    func resumeScansEveryTab(dialect: BrowserDialect) {
        let source = BrowserScriptSource.resume(bundleID: "com.example.Browser", dialect: dialect)
        #expect(source.contains("every tab of winRef"))
        #expect(!source.contains("whose id is"))
        #expect(source.contains("bequietPaused"))
    }
}

@Suite("BrowserController")
struct BrowserControllerTests {
    @Test("the bundle ID is part of a Chromium identity, Safari needs none")
    func identity() {
        #expect(BrowserController.chrome.id == .chrome)
        #expect(MediaControllerID.chrome.rawValue == "chrome:com.google.Chrome")
        #expect(BrowserController.chrome.displayName == "Google Chrome")

        #expect(BrowserController.safari.id == .safari)
        #expect(MediaControllerID.safari.rawValue == "safari")
        #expect(BrowserController.safari.displayName == "Safari")

        let brave = BrowserController(bundleID: "com.brave.Browser", dialect: .chromium)
        #expect(brave.id == .chrome(bundleID: "com.brave.Browser"))
        #expect(brave.displayName == "Brave Browser")

        let unknown = BrowserController(bundleID: "com.example.Unknown", dialect: .chromium)
        #expect(unknown.displayName == "com.example.Unknown")
    }

    @Test("each browser points at its own setting")
    func hints() {
        #expect(BrowserController.chrome.javaScriptDisabledHint.contains("View → Developer"))
        #expect(BrowserController.safari.javaScriptDisabledHint.contains("Develop → Allow JavaScript"))
        #expect(BrowserController.safari.javaScriptDisabledHint.contains("Show features for web developers"))
    }

    @Test("a receipt from another controller is ignored", arguments: [BrowserController.chrome, .safari])
    @MainActor
    func foreignReceipt(controller: BrowserController) async {
        await controller.resume(PauseReceipt(controller: .spotify, items: ["1:2"]))
    }
}
