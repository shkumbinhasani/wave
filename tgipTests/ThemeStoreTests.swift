import XCTest
import SwiftUI
import AppKit

final class ThemeStoreTests: XCTestCase {

    func testInMemoryStoreRoundTripsSnapshot() {
        let store = InMemoryThemeStore()
        var snapshot = ThemeSnapshot.defaults
        snapshot.tint = 0.42
        snapshot.appearance = .light
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testUserDefaultsStoreReturnsDefaultsWhenEmpty() {
        let suite = freshSuite()
        let snapshot = UserDefaultsThemeStore(defaults: suite).load()
        XCTAssertEqual(snapshot.tint, ThemeSnapshot.defaults.tint)
        XCTAssertEqual(snapshot.appearance, ThemeSnapshot.defaults.appearance)
        XCTAssertNil(snapshot.accentColor)
    }

    func testUserDefaultsStorePreservesScalarValues() {
        let suite = freshSuite()
        let store = UserDefaultsThemeStore(defaults: suite)
        var snapshot = ThemeSnapshot.defaults
        snapshot.tint = 0.33
        snapshot.appearance = .system
        store.save(snapshot)

        let loaded = store.load()
        XCTAssertEqual(loaded.tint, 0.33, accuracy: 0.0001)
        XCTAssertEqual(loaded.appearance, .system)
    }

    func testUserDefaultsStorePreservesAccentColor() {
        let suite = freshSuite()
        let store = UserDefaultsThemeStore(defaults: suite)
        var snapshot = ThemeSnapshot.defaults
        snapshot.accentColor = Color(red: 0.2, green: 0.4, blue: 0.8)
        store.save(snapshot)

        let loaded = store.load().accentColor.flatMap { NSColor($0).usingColorSpace(.deviceRGB) }
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.redComponent ?? -1, 0.2, accuracy: 0.01)
        XCTAssertEqual(loaded?.greenComponent ?? -1, 0.4, accuracy: 0.01)
        XCTAssertEqual(loaded?.blueComponent ?? -1, 0.8, accuracy: 0.01)
    }

    func testSwitchingBackToSystemAccentForgetsCustomColor() {
        let suite = freshSuite()
        let store = UserDefaultsThemeStore(defaults: suite)
        var snapshot = ThemeSnapshot.defaults
        snapshot.accentColor = .red
        store.save(snapshot)
        snapshot.accentColor = nil
        store.save(snapshot)
        XCTAssertNil(store.load().accentColor)
    }

    func testLegacyBrightnessMigratesToAppearance() {
        let suite = freshSuite()
        suite.set(1.0, forKey: "t.bri")
        XCTAssertEqual(UserDefaultsThemeStore(defaults: suite).load().appearance, .light)
        suite.set(0.0, forKey: "t.bri")
        XCTAssertEqual(UserDefaultsThemeStore(defaults: suite).load().appearance, .dark)
    }

    func testLegacyAccentWithoutSystemFlagLoadsAsCustom() {
        let suite = freshSuite()
        suite.set([0.9, 0.1, 0.1], forKey: "t.acc")
        XCTAssertNotNil(UserDefaultsThemeStore(defaults: suite).load().accentColor)
    }

    // MARK: - Helpers

    private func freshSuite(_ name: String = "ThemeStoreTests") -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }
}
