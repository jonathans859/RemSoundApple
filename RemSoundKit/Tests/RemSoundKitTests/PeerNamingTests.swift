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

    // MARK: - Two devices, one name (upstream issue #10)

    private let mumsAddress = "192.168.1.20"
    private let kidsAddress = "192.168.1.21"

    private func resolve(_ book: PeerNameBook, address: String, shared: Bool) -> (key: String, name: String?) {
        book.resolve(machineName: "iPhone", nameIsShared: shared,
                     deviceKeys: [PeerNameBook.deviceKey(address)], fallback: address)
    }

    /// Two iPhones both still called "iPhone": renaming one must not rename the other.
    func testRenamingOneOfTwoSameNamedDevicesLeavesTheOtherAlone() {
        var book = PeerNameBook()
        let mum = resolve(book, address: mumsAddress, shared: true)
        book.set("Mum's phone", for: mum.key)

        XCTAssertEqual(resolve(book, address: mumsAddress, shared: true).name, "Mum's phone")
        XCTAssertNil(resolve(book, address: kidsAddress, shared: true).name)
    }

    /// A name given while the machine name was unique still follows the machine to another
    /// address — the reason names were keyed on the machine name in the first place.
    func testAUniqueNameStillFollowsTheMachine() {
        var book = PeerNameBook()
        book.set("Mum's phone", for: resolve(book, address: mumsAddress, shared: false).key)
        XCTAssertEqual(resolve(book, address: "100.64.0.7", shared: false).name, "Mum's phone")
    }

    /// While a second device announces the same name, a name stored against that shared name
    /// belongs to neither of them — the bug was it showing on both.
    func testANameForTheSharedMachineNameAppliesToNeitherWhileItIsShared() {
        var book = PeerNameBook()
        book.set("Mum's phone", for: "iPhone")
        XCTAssertNil(resolve(book, address: mumsAddress, shared: true).name)
        XCTAssertNil(resolve(book, address: kidsAddress, shared: true).name)
        XCTAssertEqual(resolve(book, address: mumsAddress, shared: false).name, "Mum's phone",
                       "and comes back once the name is unique again")
    }

    /// A device renamed while it shared its name keeps that name when the other one leaves.
    func testADeviceNamedWhileSharedKeepsItsNameAfterwards() {
        var book = PeerNameBook()
        book.set("Mum's phone", for: resolve(book, address: mumsAddress, shared: true).key)
        XCTAssertEqual(resolve(book, address: mumsAddress, shared: false).name, "Mum's phone")
    }

    func testSharedNamesAreCountedCaseInsensitivelyAndIgnoreTheUnnamed() {
        let shared = PeerNameBook.sharedNames(["iPhone", "IPHONE", "Studio PC", nil, nil])
        XCTAssertTrue(PeerNameBook.isShared("iphone", in: shared))
        XCTAssertFalse(PeerNameBook.isShared("Studio PC", in: shared))
        XCTAssertFalse(PeerNameBook.isShared(nil, in: shared))
    }
}
