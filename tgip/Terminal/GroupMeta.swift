import Foundation
import AppKit

struct GroupMeta: Codable {
    var icon: String = "folder"
    var displayName: String?
    /// Path to a custom image file. Shown instead of the SF Symbol when set.
    var imagePath: String?

    /// Try to find a favicon/logo in common locations under the given directory.
    static func autoDetectImage(in directory: String) -> String? {
        let candidates = [
            "favicon.ico", "favicon.png", "favicon.svg",
            "icon.png", "icon.ico", "logo.png", "logo.svg",
            "public/favicon.ico", "public/favicon.png", "public/favicon.svg",
            "public/icon.png", "public/logo.png",
            "static/favicon.ico", "static/favicon.png",
            "static/icon.png", "static/logo.png",
            "assets/favicon.ico", "assets/favicon.png",
            "assets/icon.png", "assets/logo.png",
            "resources/icon.png", "resources/logo.png",
            "src/assets/favicon.ico", "src/assets/favicon.png",
            "src/assets/logo.png", "src/assets/icon.png",
            ".github/icon.png", ".github/logo.png",
            "app/favicon.ico",
        ]

        let fm = FileManager.default
        // Expand ~ if needed
        let path = (directory as NSString).expandingTildeInPath

        for candidate in candidates {
            let full = (path as NSString).appendingPathComponent(candidate)
            if fm.fileExists(atPath: full) {
                return full
            }
        }
        return nil
    }

    private static let imageCache = NSCache<NSString, NSImage>()

    /// Load the image at imagePath as an NSImage, scaled to a small icon size.
    /// Results are cached in memory to avoid disk I/O on every SwiftUI render.
    func loadImage() -> NSImage? {
        guard let path = imagePath else { return nil }
        let key = path as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        Self.imageCache.setObject(image, forKey: key)
        return image
    }
}
