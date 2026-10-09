import SwiftUI

/// Colors and type from the Sttark brand guide (docs.sttark.com, Company > Sttark Brand Guidelines).
/// Founders Grotesk isn't licensed for desktop apps, so text uses the guide's fallback, Helvetica Neue.
enum Brand {
    static let green = NSColor(srgbRed: 0.000, green: 0.537, blue: 0.184, alpha: 1)          // Dark Green #00892F: the one main action
    static let red = NSColor(srgbRed: 0.875, green: 0.239, blue: 0.200, alpha: 1)            // #DF3D33, for marks
    static let yellow = NSColor(srgbRed: 0.898, green: 0.698, blue: 0.000, alpha: 1)         // #E5B200, never text
    static let blue = NSColor(srgbRed: 0.016, green: 0.451, blue: 0.694, alpha: 1)           // #0473B1
    /// green as small text: #007A2A on light grounds, #00A82D on dark
    static let greenText = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? NSColor(srgbRed: 0.000, green: 0.659, blue: 0.176, alpha: 1) : NSColor(srgbRed: 0.000, green: 0.478, blue: 0.165, alpha: 1)
    }
}

extension Font {
    static func brand(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }
}
