import AppKit
import os

/// The menu bar glyph — headphones with a pause sign — in the three looks the
/// status item needs. Built from the designer's SVG (`Packaging/Icons/
/// MenuBarIcon.svg`, viewBox 36, 18×18 pt) so the pause bars can be dropped or
/// faded without a second asset per state. Template images: macOS recolours
/// them for the light and dark menu bar and for the pressed state.
enum MenuBarIcon: Hashable, CaseIterable {
    /// Headphones only: nothing is paused.
    case listening
    /// Faded pause bars: about to pause, or about to resume.
    case armed
    /// The full glyph: media is paused.
    case paused

    @MainActor private static var cache: [MenuBarIcon: NSImage] = [:]

    @MainActor var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let image = NSImage(data: Data(svg.utf8)) ?? Self.fallback
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    private static let headphones = """
        <path d="M6 22A12 12 0 0 1 30 22" stroke="currentColor" stroke-width="3" stroke-linecap="round"/>\
        <rect x="3" y="19" width="6" height="11" rx="3" fill="currentColor"/>\
        <rect x="27" y="19" width="6" height="11" rx="3" fill="currentColor"/>
        """

    private static let pauseBars = """
        <rect x="12.5" y="17" width="4" height="13" rx="2" fill="currentColor"/>\
        <rect x="19.5" y="17" width="4" height="13" rx="2" fill="currentColor"/>
        """

    private var svg: String {
        let bars = switch self {
        case .listening: ""
        case .armed: #"<g fill-opacity=".45">"# + Self.pauseBars + "</g>"
        case .paused: Self.pauseBars
        }
        return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" width="18" height="18" fill="none">"#
            + Self.headphones + bars + "</svg>"
    }

    @MainActor private static var fallback: NSImage {
        appLogger.error("menu bar icon SVG did not parse, falling back to a system symbol")
        return NSImage(systemSymbolName: "headphones", accessibilityDescription: "BeQuiet") ?? NSImage()
    }
}
