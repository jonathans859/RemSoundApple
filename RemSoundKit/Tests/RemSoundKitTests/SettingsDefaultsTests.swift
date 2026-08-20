import XCTest
@testable import RemSoundKit

/// Pins the settings whose default is NOT the zero value. `defaults.bool(forKey:)` returns
/// false for an absent key, so every default-on flag needs the explicit
/// `object(forKey:) == nil` check — rewriting one as a plain `bool` read flips the shipped
/// default for every existing install and is invisible until someone notices the feature is
/// off on a fresh device.
final class SettingsDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SettingsDefaultsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultOnFlagsAreOnWithNothingStored() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertTrue(settings.receiveEnabled)
        XCTAssertTrue(settings.cuesEnabled)
        XCTAssertTrue(settings.headsetTransportControls)
    }

    func testDefaultOnFlagsRoundTripFalse() {
        let settings = ReceiverSettings(defaults: defaults)
        settings.receiveEnabled = false
        settings.cuesEnabled = false
        settings.headsetTransportControls = false

        let reloaded = ReceiverSettings(defaults: defaults)
        XCTAssertFalse(reloaded.receiveEnabled)
        XCTAssertFalse(reloaded.cuesEnabled)
        XCTAssertFalse(reloaded.headsetTransportControls)
    }
}
