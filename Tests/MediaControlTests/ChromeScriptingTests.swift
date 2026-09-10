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

@Suite("ChromeTabID")
struct ChromeTabIDTests {
    @Test("receipt items round-trip")
    func roundTrip() {
        let tab = ChromeTabID(window: "12", tab: "345")
        #expect(tab.item == "12:345")
        #expect(ChromeTabID(item: tab.item) == tab)
    }

    @Test("only the first colon separates, so a colon in the tab ID survives")
    func trailingColons() {
        let tab = ChromeTabID(item: "12:34:56")
        #expect(tab == ChromeTabID(window: "12", tab: "34:56"))
    }

    @Test("garbage is rejected", arguments: ["", "12", ":34", "12:", ":", "12;34"])
    func garbage(item: String) {
        #expect(ChromeTabID(item: item) == nil)
    }
}

@Suite("ChromePauseResult")
struct ChromePauseResultTests {
    @Test("a list of items is parsed as paused tabs, garbage dropped")
    func pausedTabs() {
        let result = ChromePauseResult(list("1:2", "3:4", "nonsense"))
        #expect(result == .paused([ChromeTabID(window: "1", tab: "2"), ChromeTabID(window: "3", tab: "4")]))
    }

    @Test("an empty list means nothing was playing")
    func empty() {
        #expect(ChromePauseResult(list()) == .paused([]))
    }

    @Test("the error marker carries the message Chrome reported")
    func javaScriptDisabled() {
        let message = "\(ChromePauseResult.javaScriptDisabledMessage). For more information: …"
        #expect(
            ChromePauseResult(list(ChromePauseResult.errorMarker, message))
                == .javaScriptDisabled(message: message)
        )
    }

    @Test("the error marker without a message still reports the case")
    func javaScriptDisabledWithoutMessage() {
        #expect(
            ChromePauseResult(list(ChromePauseResult.errorMarker))
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

@Suite("ChromeController")
struct ChromeControllerTests {
    @Test("the bundle ID is part of the identity and names the browser")
    func identity() {
        #expect(ChromeController().id == .chrome)
        #expect(MediaControllerID.chrome.rawValue == "chrome:com.google.Chrome")
        #expect(ChromeController().displayName == "Google Chrome")
        #expect(ChromeController(bundleID: "com.brave.Browser").displayName == "Brave Browser")
        #expect(ChromeController(bundleID: "com.example.Unknown").displayName == "com.example.Unknown")
    }

    @Test("a receipt from another controller is ignored")
    @MainActor
    func foreignReceipt() async {
        await ChromeController().resume(PauseReceipt(controller: .spotify, items: ["1:2"]))
    }
}
