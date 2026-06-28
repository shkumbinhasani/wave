import XCTest
import SwiftUI
import AppKit

final class ThemeStoreTests: XCTestCase {

    func testInMemoryStoreRoundTripsSnapshot() {
        let store = InMemoryThemeStore()
        var snapshot = ThemeSnapshot.defaults
        snapshot.backgroundOpacity = 0.42
        snapshot.brightness = 1.0
        snapshot.lightText = false
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testUserDefaultsStoreReturnsDefaultsWhenEmpty() {
        let suite = freshSuite()
        let snapshot = UserDefaultsThemeStore(defaults: suite).load()
        XCTAssertEqual(snapshot.backgroundOpacity, ThemeSnapshot.defaults.backgroundOpacity)
        XCTAssertEqual(snapshot.vibrancy, ThemeSnapshot.defaults.vibrancy)
        XCTAssertEqual(snapshot.brightness, ThemeSnapshot.defaults.brightness)
        XCTAssertEqual(snapshot.lightText, ThemeSnapshot.defaults.lightText)
    }

    func testUserDefaultsStorePreservesScalarValues() {
        let suite = freshSuite()
        let store = UserDefaultsThemeStore(defaults: suite)
        var snapshot = ThemeSnapshot.defaults
        snapshot.backgroundOpacity = 0.33
        snapshot.vibrancy = 0.66
        snapshot.brightness = 1.0
        snapshot.lightText = false
        store.save(snapshot)

        let loaded = store.load()
        XCTAssertEqual(loaded.backgroundOpacity, 0.33, accuracy: 0.0001)
        XCTAssertEqual(loaded.vibrancy, 0.66, accuracy: 0.0001)
        XCTAssertEqual(loaded.brightness, 1.0, accuracy: 0.0001)
        XCTAssertFalse(loaded.lightText)
    }

    func testUserDefaultsStorePreservesAccentColor() {
        let suite = freshSuite()
        let store = UserDefaultsThemeStore(defaults: suite)
        var snapshot = ThemeSnapshot.defaults
        snapshot.accentColor = Color(red: 0.2, green: 0.4, blue: 0.8)
        store.save(snapshot)

        let loaded = NSColor(store.load().accentColor).usingColorSpace(.deviceRGB)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.redComponent ?? -1, 0.2, accuracy: 0.01)
        XCTAssertEqual(loaded?.greenComponent ?? -1, 0.4, accuracy: 0.01)
        XCTAssertEqual(loaded?.blueComponent ?? -1, 0.8, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func freshSuite(_ name: String = "ThemeStoreTests") -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }
}
