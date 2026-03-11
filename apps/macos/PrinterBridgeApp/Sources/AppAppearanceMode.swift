import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    static let storageKey = "PrinterBridgeAppearanceMode"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var windowAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }
}

enum WindowAppearanceController {
    @MainActor
    static func apply(_ mode: AppAppearanceMode) {
        let appearance = mode.windowAppearance

        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            window.invalidateShadow()
        }
    }
}
