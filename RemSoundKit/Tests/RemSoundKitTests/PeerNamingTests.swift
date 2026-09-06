import XCTest
@testable import RemSoundKit

/// Pins the peer-naming rules. The load-bearing one is the identity key: a friendly name is
/// stored against the peer's machine name, so it survives the peer changing address (DHCP,
/// LAN today and Tailscale tomorrow). Keying on the address instead would silently lose every
/// name the first time a peer moved — the exact failure the Windows book was built to avoid.
final class PeerNamingTests: XCTestCase {
    func testMachineNameIsNilWhenThePeerAnnouncesNoneOrJustItsAddress() {
        XCTAssertEqual(PeerNameBook.machineName(announced: "ANDRE-PC", addressString: "192.168.1.5"), "ANDRE-PC")
        XCTAssertNil(PeerNameBook.machineName(announced: "192.168.1.5", addressString: "192.168.1.5"))
        XCTAssertNil(PeerNameBook.machineName(announced: "   ", addressString: "192.168.1.5"))
    }

    func testNameFollowsTheMachineAcrossAddresses() {
        var book = PeerNameBook()
        let lanKey = PeerNameBook.identityKey(
            machineName: PeerNameBook.machineName(announced: "ANDRE-PC", addressString: "192.168.1.5"),
            fallback: "192.168.1.5")
        book.set("Andre's desktop", for: lanKey)

        // Same machine, now announcing from a Tailscale address.
        let vpnKey = PeerNameBook.identityKey(
            machineName: PeerNameBook.machineName(announced: "ANDRE-PC", addressString: "100.64.0.2"),
            fallback: "100.64.0.2")
        XCTAssertEqual(book.name(for: vpnKey), "Andre's desktop")
    }

    func testPeerWithNoMachineNameIsKeyedByItsAddress() {
        var book = PeerNameBook()
        let key = PeerNameBook.identityKey(machineName: nil, fallback: "100.64.0.9")
        book.set("Relay box", for: key)
        XCTAssertEqual(book.name(for: "100.64.0.9"), "Relay box")
        XCTAssertNil(book.name(for: "100.64.0.8"))
    }

    func testKeysAreCaseInsensitiveLikeTheWindowsBook() {
        var book = PeerNameBook()
        book.set("Studio Mac", for: "ANDRE-PC")
        XCTAssertEqual(book.name(for: "andre-pc"), "Studio Mac")
    }

    func testBlankNameClearsTheEntryAndOnlyRealChangesReportChanged() {
        var book = PeerNameBook()
        XCTAssertTrue(book.set("Andre's desktop", for: "ANDRE-PC"))
        XCTAssertFalse(book.set("  Andre's desktop  ", for: "ANDRE-PC")) // trimmed, unchanged
        XCTAssertTrue(book.set("   ", for: "ANDRE-PC"))                  // blank = clear
        XCTAssertNil(book.name(for: "ANDRE-PC"))
        XCTAssertTrue(book.storage.isEmpty)
        XCTAssertFalse(book.set(nil, for: "ANDRE-PC"))                   // already gone
    }

    func testNamesRoundTripThroughSettings() {
        let suite = "PeerNamingTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertTrue(settings.peerNames.isEmpty)

        var book = PeerNameBook(settings.peerNames)
        book.set("Andre's desktop", for: "ANDRE-PC")
        settings.peerNames = book.storage

        let reloaded = PeerNameBook(ReceiverSettings(defaults: defaults).peerNames)
        XCTAssertEqual(reloaded.name(for: "ANDRE-PC"), "Andre's desktop")
    }
}
