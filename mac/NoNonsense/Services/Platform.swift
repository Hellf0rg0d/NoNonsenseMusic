import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit

/// The Mac's and the iPhone's picture type, for the services both apps share.
typealias PlatformImage = NSImage

extension PlatformImage {
    nonisolated static func make(_ image: CGImage) -> PlatformImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    nonisolated var readableCGImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#else
import UIKit

typealias PlatformImage = UIImage

extension PlatformImage {
    nonisolated static func make(_ image: CGImage) -> PlatformImage { UIImage(cgImage: image) }
    nonisolated var readableCGImage: CGImage? { cgImage }
}
#endif

/// A colour's hue, saturation and brightness, 0 to 1 each (nil for one that has none, such as a pattern).
func hueSaturationBrightness(_ color: Color) -> (hue: Double, saturation: Double, brightness: Double)? {
    #if os(macOS)
    guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
    return (Double(rgb.hueComponent), Double(rgb.saturationComponent), Double(rgb.brightnessComponent))   // explicit: Xcode 26.6
    #else
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
    return (Double(h), Double(s), Double(b))
    #endif
}

extension Color {
    /// "#RRGGBB" (the # is optional) to a colour; nil when it is not six hex digits.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The colour as "#RRGGBB" (sRGB).
    var hexString: String {
        #if os(macOS)
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "#%02X%02X%02X", Int((min(max(r, 0), 1) * 255).rounded()),
                      Int((min(max(g, 0), 1) * 255).rounded()), Int((min(max(b, 0), 1) * 255).rounded()))
    }
}
