import XCTest
@testable import RemSoundKit

/// Pins the iCloud profile-sync reconciliation. Everything runs against an in-memory
/// stand-in for `NSUbiquitousKeyValueStore` — CI has no iCloud account, and the real store
/// silently no-ops when signed out, which would make these pass vacuously.
final class ProfileSyncTests: XCTestCase {
    /// In-memory `ProfileSyncStore`. Two of these sharing a `backing` dictionary model two
    /// devices on one account.
    private final class FakeSyncStore: ProfileSyncStore {
        final class Shared { var values: [String: Data] = [:] }
        let shared: Shared

        init(shared: Shared = Shared()) { self.shared = shared }

        func data(forKey key: String) -> Data? { shared.values[key] }
        func set(_ data: Data?, forKey key: String) { shared.values[key] = data }
        func removeObject(forKey key: String) { shared.values[key] = nil }
        var allKeys: [String] { Array(shared.values.keys) }
        @discardableResult func synchronize() -> Bool { true }
    }

    private var defaults: UserDefaults!
    private let suiteName = "ProfileSyncTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeProfile(_ name: String, latency: Int = 80) -> ReceiverProfile {
        ReceiverProfile(
            name: name,
            manualPeers: [ManualPeer(host: "100.64.0.7")],
            selectedPeerAddresses: ["100.64.0.7"],
            receiveEnabled: true,
            sendEnabled: false,
            selectedMicrophoneId: nil,
            targetLatencyMs: latency)
    }

    // MARK: - Merge

    func testRemoteContentWinsForAProfilePresentOnBothSides() {
        let local = makeProfile("Home", latency: 80)
        var remote = local
        remote.targetLatencyMs = 200

        let result = ProfileSync.merge(local: [local], remote: [remote], syncedIds: [local.id])

        XCTAssertEqual(result.profiles, [remote])
        XCTAssertTrue(result.toPush.isEmpty)
        XCTAssertTrue(result.deleted.isEmpty)
    }

    func testProfileCreatedOfflineIsKeptAndPushed() {
        // Never published (not in syncedIds), so its absence remotely is not a delete.
        let local = makeProfile("Home")

        let result = ProfileSync.merge(local: [local], remote: [], syncedIds: [])

        XCTAssertEqual(result.profiles, [local])
        XCTAssertEqual(result.toPush, [local])
        XCTAssertTrue(result.deleted.isEmpty)
    }

    func testProfileDeletedOnAnotherDeviceIsRemovedHere() {
        // Published before (in syncedIds) and now gone remotely = a real delete.
        let local = makeProfile("Home")

        let result = ProfileSync.merge(local: [local], remote: [], syncedIds: [local.id])

        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.deleted, [local.id])
        XCTAssertTrue(result.toPush.isEmpty)
    }

    func testNewRemoteProfilesArriveAppendedAndNameSorted() {
        let home = makeProfile("Home")
        let office = makeProfile("Office")
        let travel = makeProfile("Travel")

        // Home is in syncedIds, so it must also be in the remote set — a synced profile
        // missing remotely means "deleted on another device", which is a different case
        // (testProfileDeletedOnAnotherDeviceIsRemovedHere).
        let result = ProfileSync.merge(local: [home], remote: [home, travel, office],
                                       syncedIds: [home.id])

        // Local order preserved, arrivals appended in a device-independent order.
        XCTAssertEqual(result.profiles.map(\.name), ["Home", "Office", "Travel"])
    }

    func testLocalOrderIsNotReshuffledByASync() {
        let travel = makeProfile("Travel")
        let home = makeProfile("Home")
        let local = [travel, home] // deliberately not alphabetical

        let result = ProfileSync.merge(local: local, remote: local, syncedIds: Set(local.map(\.id)))

        XCTAssertEqual(result.profiles.map(\.name), ["Travel", "Home"])
    }

    // MARK: - Store round trip

    func testPushIsAdditiveSoAnUnpulledDeviceCannotWipeTheSharedSet() {
        let store = FakeSyncStore()
        let home = makeProfile("Home")
        let travel = makeProfile("Travel")
        ProfileSync.push([home, travel], to: store)

        // A fresh device that has not pulled publishes only what it knows.
        ProfileSync.push([makeProfile("Fresh")], to: store)

        let remote = ProfileSync.readRemote(from: store)
        XCTAssertEqual(Set(remote.map(\.name)), ["Home", "Travel", "Fresh"])
    }

    func testRemoveIsTheOnlyPathThatDropsARemoteProfile() {
        let store = FakeSyncStore()
        let home = makeProfile("Home")
        ProfileSync.push([home], to: store)
        XCTAssertEqual(ProfileSync.readRemote(from: store).count, 1)

        ProfileSync.remove(id: home.id, from: store)
        XCTAssertTrue(ProfileSync.readRemote(from: store).isEmpty)
    }

    func testUnreadableRemoteEntryDoesNotBlockTheOthers() {
        let store = FakeSyncStore()
        ProfileSync.push([makeProfile("Home")], to: store)
        store.set(Data("not json".utf8), forKey: ProfileSync.key(for: UUID()))

        XCTAssertEqual(ProfileSync.readRemote(from: store).map(\.name), ["Home"])
    }

    func testStoreIgnoresUnrelatedKeys() {
        let store = FakeSyncStore()
        ProfileSync.push([makeProfile("Home")], to: store)
        store.set(Data("whatever".utf8), forKey: "someOtherSetting")

        XCTAssertEqual(ProfileSync.readRemote(from: store).count, 1)
    }

    // MARK: - ProfileStore integration

    func testSyncOffMeansNothingLeavesTheDevice() {
        let store = FakeSyncStore()
        let profileStore = ProfileStore(defaults: defaults, syncStore: store)
        profileStore.profiles = [makeProfile("Home")]

        XCTAssertTrue(store.allKeys.isEmpty)
        XCTAssertNil(profileStore.mergeFromCloud())
    }

    func testTurningSyncOnPublishesExistingProfiles() {
        let store = FakeSyncStore()
        let profileStore = ProfileStore(defaults: defaults, syncStore: store)
        profileStore.profiles = [makeProfile("Home")]

        profileStore.setSyncEnabled(true)

        XCTAssertEqual(ProfileSync.readRemote(from: store).map(\.name), ["Home"])
    }

    func testASecondDeviceAdoptsTheSharedProfiles() {
        let shared = FakeSyncStore.Shared()
        let deviceA = ProfileStore(defaults: defaults, syncStore: FakeSyncStore(shared: shared))
        deviceA.setSyncEnabled(true)
        deviceA.profiles = [makeProfile("Home"), makeProfile("Office")]

        // A second device: its own defaults suite = its own local storage.
        let otherDefaults = UserDefaults(suiteName: "ProfileSyncTests.deviceB")!
        otherDefaults.removePersistentDomain(forName: "ProfileSyncTests.deviceB")
        defer { otherDefaults.removePersistentDomain(forName: "ProfileSyncTests.deviceB") }
        let deviceB = ProfileStore(defaults: otherDefaults, syncStore: FakeSyncStore(shared: shared))
        deviceB.setSyncEnabled(true)

        XCTAssertEqual(Set(deviceB.profiles.map(\.name)), ["Home", "Office"])
    }

    func testADeleteOnOneDeviceReachesTheOther() {
        let shared = FakeSyncStore.Shared()
        let deviceA = ProfileStore(defaults: defaults, syncStore: FakeSyncStore(shared: shared))
        deviceA.setSyncEnabled(true)
        let home = makeProfile("Home")
        let office = makeProfile("Office")
        deviceA.profiles = [home, office]

        let otherDefaults = UserDefaults(suiteName: "ProfileSyncTests.deviceB")!
        otherDefaults.removePersistentDomain(forName: "ProfileSyncTests.deviceB")
        defer { otherDefaults.removePersistentDomain(forName: "ProfileSyncTests.deviceB") }
        let deviceB = ProfileStore(defaults: otherDefaults, syncStore: FakeSyncStore(shared: shared))
        deviceB.setSyncEnabled(true)
        XCTAssertEqual(deviceB.profiles.count, 2)

        // A deletes Office the way the controller does.
        deviceA.profiles = [home]
        deviceA.removeFromCloud(id: office.id)

        XCTAssertEqual(deviceB.mergeFromCloud()?.map(\.name), ["Home"])
    }

    func testAPullWithNothingChangedReportsNoUpdate() {
        let store = FakeSyncStore()
        let profileStore = ProfileStore(defaults: defaults, syncStore: store)
        profileStore.setSyncEnabled(true)
        profileStore.profiles = [makeProfile("Home")]

        // nil = "nothing moved", which is what stops the controller republishing the list
        // (and re-rendering the Profiles tab) on every notification the store emits.
        XCTAssertNil(profileStore.mergeFromCloud())
        XCTAssertEqual(profileStore.profiles.map(\.name), ["Home"])
    }

    /// The reason passwords ride iCloud Keychain instead: the key-value store is not
    /// end-to-end encrypted, so nothing password-shaped may ever be written to it.
    func testNothingWrittenToTheCloudStoreContainsAPassword() {
        let store = FakeSyncStore()
        let profileStore = ProfileStore(defaults: defaults, syncStore: store)
        profileStore.setSyncEnabled(true)
        profileStore.profiles = [makeProfile("Home")]
        profileStore.setPassword("hunter2", forProfile: profileStore.profiles[0].id)

        for key in store.allKeys {
            let json = String(decoding: store.data(forKey: key) ?? Data(), as: UTF8.self).lowercased()
            XCTAssertFalse(json.contains("password"))
            XCTAssertFalse(json.contains("hunter2"))
        }
    }
}
