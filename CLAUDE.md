# CLAUDE.md — RemSoundApple

iOS/macOS companion app (receive + microphone send) for the Windows **RemSound** app
(https://github.com/Ednunp/RemSound). The C# in that repo is the wire-protocol spec — when in
doubt read `src/RemSound.Core/` (`RemPacket.cs`, `RemSoundCrypto.cs`, `PeerDiscoveryService.cs`,
`HeartbeatService.cs`) and `src/RemSound.Receiver/`.

## Build workflow (read this first — development happens on Windows)

- **This machine cannot compile Swift.** Validation happens only on GitHub Actions
  (`.github/workflows/ci.yml`: swift test + unsigned iOS/macOS builds, pull requests only). For CI results,
  ask for the Actions logs or read them via `gh` if installed — never poll the GitHub API.
- **Commit, but never `git push` unless asked** — the user pushes. LF→CRLF warnings on
  commit are normal; ignore them.
- Put new code in `RemSoundKit/Sources/**` — SPM picks those files up with **no** project
  edits. Adding a file to an app target instead requires hand-editing the hand-written
  `RemSound.xcodeproj/project.pbxproj` (PBXBuildFile + PBXFileReference + group + Sources
  phase). Prefer the package — with ONE exception: App Intents code must live in the app
  targets (`Apps/Shared/RemSoundIntents.swift`, in both Sources phases), because
  SPM-hosted intents silently never appear in Shortcuts on any device.
- To check whether the Windows repo changed the protocol since the last review, use the
  `upstream-protocol-sync` skill (`.claude/skills/upstream-protocol-sync/`) — it tracks the
  last-scanned upstream commit and says which files matter.
- TestFlight — two thin callers of the shared `jonathans859/apple-ci` workflows (`@v1`),
  both platforms (iOS IPA + macOS PKG, parallel jobs, one shared app record):
  `.github/workflows/testflight.yml` ("TestFlight") **builds** on every push to `main`
  that touches more than docs/CI/`.claude` (`paths-ignore`) — swift test, then archive,
  cloud-sign with the Admin App Store Connect API key (plus one shared Apple Development
  .p12, `APPLE_DEV_CERT_P12`, for the archive step), upload; internal testers get it
  automatically, changelog = commit subject. `.github/workflows/release.yml` ("Release")
  **promotes, never rebuilds**: a published GitHub Release `vX.Y.Z` / `vX.Y.Z-bN` checks
  the tag against the pbxproj `MARKETING_VERSION` (that file is the ONLY version source —
  a raise needs a version commit), waits for the tagged commit's successful TestFlight
  run, attaches its IPA + PKG to the release, and hands that same binary to the external
  group(s) (repo variable `TESTFLIGHT_EXTERNAL_GROUPS`, "External"; notes = "What to
  Test"). So never tag a commit the build skipped. To cut a release use the `release`
  skill (`.claude/skills/release/`) — it drives the Sonnet `release-manager` subagent
  (`.claude/agents/release-manager.md`). One-time setup steps live in `docs/plan.md`;
  recurring gotchas are in the skill's "Known failure modes". **Any change to either
  workflow (or to apple-ci's inputs) updates this bullet, `docs/plan.md` and the release
  skill + agent in the same commit** — the skill drifted once and its watch command
  silently found nothing.

## Wire contract — breaking any of these silently breaks Windows interop

- **Header**: 12 bytes LE — magic `RMND`, version **1** (reject all else), type, uint16
  streamId (0 coerces to 1), uint32 sequence. One UDP port **47830** for audio + heartbeat;
  discovery on **47821**.
- **Format payload**: accept 32 / 36 (+lane byte @32) / 44 (+8-byte password fingerprint @36)
  / 46 (+uint16 sender capture latency in 0.1 ms ticks @44, upstream 2026-08-24) bytes — every
  reader takes a MINIMUM length, which is what makes growing it safe. Field @28 is
  `frameSamplesPerChannel` — a **sample count, not milliseconds**. Unknown lane values clamp
  to `.mixed`, never reject. We WRITE 46 whenever we have a fingerprint (0 ticks = nothing
  open / the device would not say, which is the "no figure" value on both sides); we do not
  read the field back yet — there is no receive-side journey display to spend it on.
  Byte @33 (reserved until upstream 6.0) is a flags byte — bit 0 = "I can decode Jamulus-style
  custom-mode Opus" (codec **3**); we write 0 and ignore it on read. **Fail closed**
  (`AudioFormatInfo.unusableReason`, upstream audit R4): channels 1-2, rate 8000-192000,
  frame 1-2880, Opus only at libopus rates; an **unknown codec is no format at all**
  (`readFormat` returns nil — it used to fall back to PCM, which would play codec 3 as noise).
  Windows sends codec 3 only to a copy that advertised the flag, never through a server.
- **TickProof** (type **11**, upstream 6.0, `TickProof.swift`): "I have ticked you, and I
  hold the password". Header type 11, streamId 0xFFFF, then 53 bytes = nonce(12)‖tag(16)‖ct of
  version(1, =1) + unix-UTC-seconds(8 LE) + our discovery **instance id**(16, RFC 4122 order =
  `UUID.uuid`), sealed with the AUDIO key under a **random** nonce (as upstream's
  ControlSealing — not the audio NonceSequence). Sent every 5 s, raw (never group-framed), to
  every path of every ticked network peer — never to a server or a member
  (`tickProofTargets`). Received ungated by allow-list and receive switch, ≤1 per address per
  2 s from the engine; opened by `TickProofGuard` (±10 min skew, replay memory by the first 8
  nonce bytes). It is how a peer that only LISTENS proves the password — without sending it,
  a Windows 6.x user is never offered our iPhone with its mic off. Pinned to upstream's
  known-answer plaintext in `TickProofTests`.
- **Types this port drops on purpose** (unknown → `readHeader` returns nil): **12 Metronome**,
  and the server-only **13 Timing / 14 Server status / 15 Server ping** (server-v2.14/2.16;
  14 is only ever sent to a member that pings with 15, which we never do).
- **Crypto**: PBKDF2-HMAC-SHA256, **100 000** iterations, salts `"RemSound.v1.audio-key"`
  (32-byte key) / `"RemSound.v1.fingerprint"` (8 bytes). AES-256-GCM packet layout is
  **`nonce(12) ‖ tag(16) ‖ ciphertext`** — CryptoKit's `combined` is nonce‖ct‖tag, do NOT
  use it. Cross-impl PBKDF2 vectors are pinned in `CryptoTests.swift`; if they fail,
  interop is broken. The iteration count is a **cross-port** contract: upstream v5.6 raised
  it to 600 000 for one day and broke this port outright; v5.7 reverted to 100 000 and
  annotated the constant "MUST stay 100k". Never mirror an iteration-count change without
  the user confirming every port moves together. (5.6's weak-password block, also reverted
  in 5.7, is deliberately NOT mirrored.) Send-side nonces are **counter-based** like the
  Windows sender — random 48-bit prefix per key ‖ 48-bit counter (`NonceSequence`, reset on
  every key rebuild), never CryptoKit's per-call random nonce. Wire-invisible (the receiver
  reads the nonce off the packet) and cheaper than a CSPRNG draw per packet.
- **PCM**: whole int24-LE frame encrypted, then split into ≤1454-byte parts with a 6-byte
  sub-header → reassemble **then** decrypt; parts arrive in order, missing part = drop frame.
  Sending PCM uses **120 samples/channel (2.5 ms)**, upstream's "Tight" size and the only one
  whose encrypted frame (720 + 28 bytes) still fits ONE datagram: a PCM frame is all-or-nothing
  on the receiver, so upstream's 5 ms default would double what a single lost packet costs.
  Each part carries its own audio sequence; `frameId` increments per frame. Format fields for
  PCM are 48000 / 2 / 24-bit / encoding 1 / blockAlign 6 / 288000 B/s.
- **Opus**: per-packet decrypt → libopus decode; on a single-packet gap decode the next
  packet with `decode_fec=1` first. Frame-size floor 120 samples.
- **Discovery JSON**: PascalCase keys, matched **case-sensitively** by Windows
  (`InstanceId`, `Name`, `AudioPort`, `CanSend`, `CanReceive`). 1.5 s announce, 8 s expiry.
  Unicast is what crosses VPNs; receiving an announcement auto-adds the source IP as a
  unicast target — that auto-learn is how iOS discovery works without broadcast.
- **Heartbeat**: 1 Hz ping, streamId 0xFFFF, payload = kind byte + int64 LE monotonic ms
  echoed verbatim in the pong (upstream 6.0 may append a 10th flags byte, same meaning as
  format @33 — read a MINIMUM of 9, never exactly 9). Pongs match peers **by IP only**. Heartbeats leave the same
  socket audio arrives on (shared NAT pinhole; also claims our relay slot).
- **Relay address-proof** (type **10**, upstream server-v2.5): the relay cookies each newly
  seen client address; echo the packet back **verbatim to its source**, from the audio socket,
  and **ungated by the allow-list** (the challenge comes from the relay, not a selected peer)
  — but **gated on who we talk to** since 2026-10-09 (upstream 6.0 `AddrCheckEchoGate`):
  answered only for an address the heartbeat pings, plus the server we are on (pushed BEFORE
  the first hello — `pushAddressCheckEchoTargets`), and at most once a second per endpoint.
  Answering anyone let one forged packet loop between two RemSound devices for ever. Since
  server-v2.13 a client that has not echoed is in no group at all, so the server must never
  drop out of that set. Pinned by `AddrCheckTests` / `AddrCheckEchoGateTests`.
  Receiving one is also the **only** way to tell that an address is a server — nothing else
  sends them (`AudioReceiverEngine.onAddrCheckReceived`).
- **Server groups** (header version **2**, upstream server-v2.9 / Windows 6.0, notes dropped
  2026-09-21 in `~/Downloads/remsound-for-jonathan`): a server used to carry one pair; now
  everyone on it with the same password is one group. Framing = the ordinary 12-byte header
  with version 2, then the sender's **16-byte client id** @12, then the ordinary payload
  untouched @28 (+16 bytes/packet; our 2.5 ms PCM frame is far under one datagram either way).
  Types 6-9 are hello / roster / full / bye. Hello (every 2 s, and at once on any change):
  32-byte name (UTF-8, cut on a **character** boundary, zero-padded) + 8-byte group tag =
  **the password fingerprint we already put at Format @36** + 1 count byte + count×16 ticked
  ids. **No password = no group** (the server groups by that tag and nothing else). Omitting
  the count byte entirely means "everyone in my group", which is what every pre-groups client
  sends — that is exactly why nothing we shipped before this breaks. Roster (type 7, ~1 Hz,
  client id all zeros): count + count×49 (16 id + 32 name + 1 flags; **48** before v2.9, so
  take the entry size from the payload length) + 1 list-flags byte; per-member bit 0 = *that
  member has ticked us*, list bit 0 = we also hold an ordinary pair slot. **The server
  includes us in our own roster — skip our own id.** Sound flows only when both sides have
  ticked each other. `RelayGroupProtocol.swift` + `RelayGroupClient.swift`, pinned by
  `RelayGroupProtocolTests` / `RelayGroupClientTests`.
  Three rules that are not optional: (1) the **safety rail** — until a roster has arrived
  within 5 s, behave exactly as before (ordinary framing, echo address checks, pair), and go
  straight back to that if the rosters stop; (2) a member exists ONLY because a roster said
  so, so when the group goes cold **every** scrap of per-server state goes with it — upstream
  half-remembered members and they could then never be listed again, because the only place a
  member is added is a roster naming someone not already held; (3) heartbeats go out in
  **both** framings (the ordinary one claims the pair slot beside a phone), audio/format/
  control only also go ordinary while the list says we hold that slot *and* the user ticked
  the partner, and address checks are **never** group-framed.
  Members have no address of their own, so each gets a **stand-in endpoint in 240.0.0.0/5**
  (FNV-1a of the client id, Windows parity) and everything this port keys by address works
  per person unchanged. Never show that address to the user; never let a packet addressed to
  one reach the socket.
- **Heartbeat pongs are matched to our own recent pings** by the echoed originator timestamp,
  not just by source IP (`HeartbeatService.recentPingTicks`). Through a server every member's
  pong reaches every other member carrying the clock of whoever pinged, so an unmatched pong
  arrives routinely — crediting it computes a round trip from a stranger's clock and holds a
  peer "healthy" on traffic that says nothing about whether it can hear us. Pinned by
  `HeartbeatTests`.
- **Allow-list**: gate audio/format by source **IP**, not port. Sessions keyed
  (endpoint, streamId), but superseded by **peer identity** + lane, not by endpoint equality
  (issue #8): one new session drops every other session of the same peer on the same lane,
  which covers a streamId rotation, a new source port on the same path, and a path handover
  in one rule. Lane-mismatched sessions still coexist (BothIndependent senders run two lanes
  per peer). The engine learns which addresses are one machine from
  `setPeerAddressGroups`, pushed by `ReceiverController.applyPeerSelection`; an address that
  is not in that map stands alone, which is the pre-#8 behaviour. On top of that, a peer
  already delivering a lane **keeps** it: another path of the same peer only opens a session
  once the active one has been silent for `pathHandoverSilence` (1 s). Without that, a sender
  aimed at both a multi-homed receiver's LAN and VPN addresses gets its audio decoded twice
  and summed against itself at two path delays — comb filtering that sounds like a bad link,
  not like an echo. Pinned by `MultiPathTests`.

## Locked product decisions (do not revisit)

- v3.x protocol only; no legacy, no relay-v2 lobby, no recording.
- Profiles (2026-07-12, user reversed the earlier "no profiles" decision): local named
  snapshots of peers + selection, password, receive/send toggles, microphone, send codec
  (2026-09-18), max delay, auto-tune on/off (2026-08-17), accept connections (2026-10-09) —
  **`ReceiverProfile.init(from:)` is hand-written and every field after `id`/`name` decodes
  with a default — keep it that way when adding fields.** Both read paths (`ProfileStore.profiles`
  and `ProfileSync.readRemote`) decode with `try?` and treat a throw as "no profiles", so a
  synthesised decoder meeting JSON from an older build would silently WIPE the user's
  profiles — and with sync on, publish that wipe. Pinned by `ProfileCompatibilityTests`.
  With auto-tune on, a profile's `targetLatencyMs` is only where the tuner starts, so
  `appliedProfile`'s drift check skips that one field for such profiles (otherwise the
  "Currently applied" marker drops seconds after applying one); every other field, including
  the auto-tune flag itself, is still compared.
  `Profiles.swift` (`ReceiverProfile` + `ProfileStore`), applied via
  `ReceiverController.applyProfile`. JSON in UserDefaults; each profile's password is its
  own Keychain item (`profile-password-<uuid>`), never in the JSON
  (`ProfileTests.testEncodedProfileJsonNeverContainsAPassword`). NOT the Windows profile
  file format — local only. A profile applies exactly as saved, send included — hand-tap
  or at launch, no exceptions (user, 2026-07-12).
  **iCloud sync (2026-07-20, opt-in, default off)** — `ProfileSync.swift` mirrors profiles
  through `NSUbiquitousKeyValueStore`, **one key per profile** (`profile-<uuid>`), never one
  array key: KVS conflict resolution is last-writer-wins per key, so per-profile keys let
  edits to different profiles on two devices both survive. `push` is deliberately
  **additive** — it never removes remote keys it doesn't recognise, so a device that hasn't
  pulled can't wipe the shared set; `removeFromCloud` (user delete) is the ONLY path that
  drops a remote key. `ReceiverSettings.syncedProfileIds` distinguishes "deleted on another
  device" (was synced, now absent → delete locally) from "created here while offline" (never
  synced → keep and push); without it the first pull eats offline-created profiles.
  Passwords do NOT go in KVS (**not** end-to-end encrypted) — profile Keychain items gain
  `kSecAttrSynchronizable` so iCloud Keychain carries them E2E-encrypted, which is exactly
  what the password-never-in-JSON rule buys. Synchronizable items need the data-protection
  keychain (`kSecUseDataProtectionKeychain`) on macOS and are a *distinct* item from the
  device-local one with the same service+account — `Keychain.read` therefore tries both
  flavours (device-local first, so an opted-out device runs on its own copy) and
  `setSynchronizable` migrates on toggle. **`SecItemDelete` on a synchronizable item wipes
  it from every device**, so `Keychain.delete` is the only thing allowed to do it and only
  a user deleting a profile may call it: an empty password is *stored*, not deleted, and
  switching sync off copies the value back locally while LEAVING the shared item up (fixed
  2026-08-11, issue #4 — the old code deleted on both paths, so toggling sync off, or
  saving a profile from a device that had not received the password yet, silently and
  unrecoverably blanked every profile password on the user's other devices). Needs the
  `com.apple.developer.ubiquity-kvstore-identifier` entitlement on BOTH targets (this is why
  `Apps/iOS/RemSound.entitlements` exists at all — it was created for this and wired into
  the hand-written pbxproj). Local/device state deliberately does NOT sync: the live
  settings, `appliedProfile`/`lastAppliedProfileId`, and the startup choice. A profile's
  microphone UID may not exist on the receiving device — capture already falls through to
  the default input, and the picker labels the dangling selection instead of hiding it.
  Startup profile (`StartupProfileChoice`: off / lastApplied / fixed id): applied in
  `ReceiverController.init` by REWRITING the persisted settings before they're read
  (`ProfileStore.applyStartupProfile(to:)`) — never via `applyProfile`, whose didSets
  re-enter `start()` during startup. Every profile field (send included, now persisted)
  is covered by that rewrite; capture itself resumes via `startupSendPending` at the end
  of the first `start()`.
  **Home screen quick actions** (iOS, user 2026-10-09): long-pressing the icon lists the
  first four profiles (`updateHomeScreenActions`, rebuilt on every `profiles` change and at
  `start()`); choosing one launches the app with THAT profile instead of the launch one.
  Cold launch: `QuickActionAppDelegate.configurationForConnecting` (Apps/iOS) calls
  `handleQuickAction` → `applyProfile` AFTER `init` but BEFORE the view's `.task` runs
  `start()` — safe, it is the stopped-receiver equivalent of a tap (its didSets may call
  `start()` themselves, which the later `.task` then no-ops). Two things make the chosen
  profile win outright and must stay in `applyProfile`: it clears `startupSendPending`
  (else the launch state's send-on resumes the mic behind a profile that has it off), and
  with no server it clears `settings.serverConnected` even when not yet connected (else
  `start()` goes to the launch state's server). Warm: `QuickActionSceneDelegate`.
- **Servers (relay groups)** (2026-10-02, upstream server-v2.9 parity): a server is **somewhere
  you go, not a peer you add** — one "Connect to server" button on Connectivity opens
  `ServerConnectView` (Windows layout, 2026-10-09: **Remembered servers first**, always shown,
  tap = go, Forget = action / context menu / Delete on macOS, up to 16; then the address box;
  then leave), and the people on it get their
  own list right under the ordinary one. One server at a time; connecting elsewhere leaves
  the first. Persisted (`serverHost` / `serverConnected` / `recentServers`) and re-entered at
  launch, like the receive and send toggles; carried in profiles (`ReceiverProfile.serverHost`,
  nil = not on one) and applied by both paths — `applyProfile` and the launch rewrite.
  A **tick is stored against the member's client id** (`server-member-<hex>` in
  `selectedPeerAddresses`), never an address, which is what makes it outlive their restart and
  ours; the hello's tick list is derived from that same selection, so one untick clears both
  halves and they cannot disagree. A new password is a new group, so the password didSet drops
  those keys — and `applyProfile` sets `applyingProfile` to stop that eating the ticks it has
  just restored. `relayClientId` is device-local: never in a profile, never in iCloud (two
  devices sharing one id would be ONE person to every server), and **never in UserDefaults**:
  it lives in a `…ThisDeviceOnly` Keychain item (data-protection keychain on macOS too,
  `Keychain.writeDeviceOnly`), because UserDefaults travel in backups and a restore onto a
  second device made both one person (upstream #10, fixed 2026-10-09). An old UserDefaults
  id is moved over unchanged; if the Keychain write fails it stays in UserDefaults rather
  than becoming a new id each launch. `DeviceOnlyStore` is injectable so CI never touches
  the real Keychain.
  **Everybody on the server shares ONE outgoing datagram** — `updateSendTargets` collapses
  every server row to the server endpoint, because the server makes the copies; a copy per
  person would also have it fan out each of them. Heartbeats go to the server for as long as
  we are there, ticked partner or not: the ordinary one claims the pair slot.
  The server's ordinary **pair partner appears as a person** and is ticked like one (it cannot
  say it has ticked us, so holding the slot beside us stands for it), keyed by the server's own
  address so a user who had already added the server as a peer sees one row with one tick, not
  the same thing twice. An address typed into add-a-peer that answers an address check is a
  server — the app offers to go there as one (`serverSuggestion`).
  The server line says "<server> isn't answering" after 10 s with no member list
  (`serverSilenceLimit`, Windows parity) instead of waiting for ever. A machine ticked both on
  the network and through the server says "same machine twice, also connected …" on both
  rows (`markSameMachineTwice`, matched by shown name like Windows).
  Why the server list is empty always has a reason on screen (no password to be grouped by, no
  member list yet, nobody else on your password), and a member who has not ticked us back says
  so rather than going quiet — that is the only thing a person cannot work out alone.
- **Accept connections from other peers** (2026-10-09, upstream `MainForm.AcceptConnections.cs`
  parity): ask each time (**default**, as upstream) / automatically / manual
  (`PeerAcceptMode`, raw values = upstream's and stored as such). **In profiles** (user,
  2026-10-09 — upstream keeps it machine-wide), so it syncs through iCloud with them; the live
  value is persisted locally. Decoded from the profile as a plain Int with `.prompt` fallback,
  never as the enum (an unknown value must not throw — see the profile-wipe rule). Three triggers: a **tick proof** that opens with
  our key (`tickProofArrived` — the row is found by the instance id the proof names), a format packet from a sender
  outside the allow-list (`AudioReceiverEngine.onUnselectedSenderHeard`, rate-limited 10 s per
  address, carries whether its fingerprint is ours — a different password or no fingerprint is
  never offered; nothing fires while receive is off), and a roster member with `ticksUs` or the
  server's pair partner, reviewed in the **functional** half of the tick
  (`reviewServerTicks`). A server's own address is never offered as a person — nor any server
  we have been on this run (`knownServerAddresses`; upstream accepted its own server after
  leaving it). An untick on ANY of a peer's paths refuses all of them. Deliberately NOT
  ported: upstream's 2-minute "different password" memory and "a device ticked before pinged
  again" (every trigger here already proves the password; the latter was upstream's stopgap
  until the phones sent tick proofs). One question
  at a time (`pendingConnectionRequest`, an alert hosted in its own view so the 1 Hz re-render
  cannot rebuild it); the macOS app opens its window for it via `onConnectionRequestPending`.
  **iOS: also a notification while off screen** (user, 2026-10-09, `ConnectionRequestNotifier`):
  posted only when `!uiVisible`, identified by the request id, with Allow
  (`.authenticationRequired` — a tick reaches your microphone, so a locked phone in somebody
  else's hand must not grant it) and Don't Allow; answered only if that id is still the
  pending one; withdrawn when answered in the app; the foreground presents no banner (the
  alert is already asking). The delegate is installed in `ReceiverController.init` —
  responses to a tap made while the app was not running go to whoever is delegate at launch.
  Permission is asked on the first FOREGROUND with Accept on "ask" (iOS shows the prompt only
  to a foreground app). No time-sensitive level: it needs an entitlement + App ID capability
  the cloud-signed builds lack.
  `PeerAcceptPolicy` (pure, `PeerAcceptTests`) holds upstream's two hard-won rules: **asked
  once per person per run**, yes or no; and a **deliberate untick sticks for the run** —
  with automatic on, unticking somebody who still has us ticked leaves their audio arriving,
  which would re-tick them, and the user could never let anyone go. Only
  `setPeerSelected` (the user) records refusals/lifts them; accepting goes through
  `applySelection`, which must not refresh (it runs inside the tick).
- **Peer details and friendly names** (2026-09-06, Windows parity): every peer row carries
  "Peer details" as an explicit VoiceOver action plus a context menu (pitfall 14 — no swipe
  actions; the separate "Rename peer" action was removed 2026-10-09 at the user's request —
  renaming lives inside the sheet), opening `PeerDetailsView` — machine name, the address and port,
  every other path a multi-homed peer answers on, how long it has been connected, ping,
  what it is sending (codec / rate / channels / frame), whether our microphone reaches it,
  and the encryption state. The ROW keeps its one-line summary: a screen-reader user arrows
  past every row every time they open the app, so the dozen live lines sit one action away —
  the same split the Diagnostics button makes for the connection panel. Built as
  `ReceiverController.peerDetails` (keyed by row id) in the **presentation** half of the 1 Hz
  tick. "Connected for" hangs off the cue path's hysteretic state (`peerConnectedSince`), not
  the raw health, so a 2 s VPN stall does not restart the clock. Names live in `PeerNameBook`
  (`PeerNames.swift`) + `ReceiverSettings.peerNames`, keyed by the peer's **announced machine
  name**, falling back to the address / typed host — that key is what makes a name outlive a
  DHCP lease or a move from the LAN to Tailscale, and it is why renaming is not keyed by
  address. Device-local and shared by every profile, exactly like the Windows named-peers
  book: a rename is NOT part of a profile, does not sync, and applying a profile never
  changes what a peer is called here. Blank name = clear, like upstream's Clear button.
  **Two devices announcing one name** (two phones still called "iPhone", upstream #10,
  2026-10-09): `PeerNameBook.resolve` keys such a device by ITSELF — `deviceKey(address)`, or
  `deviceKey("server-<hex>")` for a server member — and a name stored against the shared
  machine name applies to neither while the clash lasts; a name stored against the device
  always wins. Not the discovery instance id: it is new every launch here and on Windows.
  Shared-ness is counted per route (network rows among themselves, server members among
  themselves), because one name on the network AND on the server is one machine.
  Pinned by `PeerNamingTests`.
- **Continuous latency auto-tune** (2026-08-17, opt-in, default off like upstream's):
  `LatencyAutoTune.swift` is a port of the Windows `MainForm.TickRoute` — every 5 s it
  recommends `secondHighest(arrival gap) + secondHighest(render-callback gap) + 5 ms`,
  floored at `ceil(1.5 x frameMs)` and capped at 200 ms, raising in one step but lowering
  at most 5 ms per tick, with 5 ms hysteresis. **Second**-highest, not peak: one transient
  second must not drive the target (upstream had a lone 1046 ms gap slam the buffer to the
  cap). `decide` is pure so CI can test it without audio or network. The per-route/lane half
  of upstream's version is deliberately not ported (one mixed output here). Gating on
  underruns REQUIRES the cause split in `SessionPlayout` — `tuneBlockingUnderruns` (empty
  reads, or short reads while the LP-filtered buffer error sits >3 ms below target) vs
  `deviceGulpUnderruns` (an on-target ring that missed one chunky callback); upstream found
  that gating on the undifferentiated total pins the target high forever. Auto-tune moves are
  runtime state: `ReceiverController.autoTuneIsMovingTarget` keeps the didSet from persisting
  over the user's value or restarting the user-change deferral, and it uses the soft
  (`drainOnLower: false`) setter. Upstream v5.9's "raise arrives in seconds" fast-approach is
  NOT ported — that fixes their drift resampler's depth feedback, which this port has no
  equivalent of; here a raise fills at whatever rate audio arrives.
- **Volume boost** (2026-08-20): `VolumeBoost` (off / +3 / +6 / +12 dB) multiplies into the
  mixer gain BEFORE the soft limiter, so a boost compresses instead of clipping. Discrete
  steps, not a wider volume slider — 0-400 % is ~80 VoiceOver swipes wide, and one control
  mixing "volume" with "gain that distorts" hides that the top of the range is not free.
  Device-local like volume; deliberately NOT in profiles.
- **Headset transport controls** (2026-08-20, `RemoteTransportControls.swift`): an AirPods
  stem press, a Mac media key, or the lock-screen / Control Center play-pause button pauses
  and resumes **`receiveEnabled`** (not mute — the sender should see an honest CanReceive).
  Setting `headsetTransportControls`, default **on**, device-local, not in profiles — but
  inert on iOS while "Don't mix with other sounds" is off (pitfall 9). Two
  halves are both required and neither is optional: registered `MPRemoteCommandCenter`
  handlers AND published `MPNowPlayingInfoCenter` info — with no now-playing item the system
  has nothing to arbitrate and the press goes to another app. Keeping `playbackState =
  .paused` (rather than clearing the info) while paused is what keeps the *resume* press
  coming to us; `AudioOutput` never stopping is what keeps the session active underneath it.
  Pushed only on state change — never on the 1 Hz tick. `reassert()` re-publishes the item
  on app activation, because the change-gate otherwise makes a slot lost to the system
  unrecoverable without a relaunch — and (2026-08-27) on the other edge that can win the
  slot back: `AudioOutput.onPlaybackRecovered` fires whenever a *stopped* engine is
  restarted (interruption ended, route/configuration change, media-services reset,
  foregrounding) and `ReceiverController.reclaimTransportControls` re-publishes there. The
  app that interrupted us is the Now Playing app and keeps the slot after it stops, so
  without this the next stem press resumes *it*; eligibility needs us actually playing
  through an exclusive session, which is exactly what has just become true again. Blind by
  necessity (no public API asks who holds the slot — MediaRemote is private), so it fires
  whether or not the slot was lost, and the attempt is reported in Diagnostics.
  **There is no equivalent while mixing is on** (pitfall 9): a `.mixWithOthers` session is
  never eligible, so no re-publish can reclaim anything, and making the toggle adaptive
  would reintroduce the interruption it exists to prevent (we can only react *after* the
  other app starts). Seek/scrub/skip stay disabled; next/previous are
  registered but change nothing (an AirPods double-press is "next track").
  **Tried and removed (2026-10-09): next track as the microphone switch.** On iPhone it
  fails exactly where it is wanted: iOS will not START microphone capture from the
  background / lock screen (`AVAudioEngine.start` → `'what'` 2003329396), so it could only
  ever turn the mic off. A mute variant (capture keeps running, the press gates what is sent)
  was offered and declined — do not re-add either without asking.
  **Confirmed trap: `MPNowPlayingInfoPropertyIsLiveStream` must stay UNset.** It puts a stop
  button where pause would be, and a routed stop ends the now-playing session — with it set,
  Control Center could pause but never resume. Never "fix" the missing scrubber by declaring
  a live stream; omitting the duration already removes it.
  **Confirmed on hardware (2026-08-20): AirPods send `pause` for EVERY stem press**, in
  every state — never `play`, never `togglePlayPause`, whatever `playbackState` we publish.
  Read literally that makes the button one-way (first press pauses, the rest are no-ops),
  which was the "it disconnects but never reconnects" bug. `RemoteTransportControls.handle`
  therefore decides the direction itself: a `pause` arriving while we are already paused
  resumes. Control Center is unaffected — it sends a real `play` when paused and never
  sends `pause` twice. Two commands from one physical press (stop *and* pause) are
  coalesced by a 0.5 s gate in the same place, so the press moves the state once; keep that
  gate if you touch this. `stopCommand` is handled as a pause plus an immediate
  `reassert()`. Every routed command records itself in `lastCommand`, surfaced in the
  Diagnostics panel next to the last `AudioOutput` event
  (`ReceiverController.appendTransportDiagnostics`) — that line is what identified this,
  and it stays as long as the feature depends on guessing what an accessory sends.
  Untestable in CI and on the dev machine: verify on real hardware.
- Mic send: one mixed lane, 48 kHz stereo, **Opus by default** — 192 kbps, RESTRICTED_LOWDELAY,
  complexity 10, VBR, FEC, 10 % loss bias, 10 ms frames — mirroring the Windows sender.
  **PCM is a user choice** (`ReceiverSettings.sendCodec`, issue #7, 2026-09-18, in profiles,
  default Opus): 24-bit 2.5 ms frames, ~288 kB/s per peer against Opus's ~24, so the picker
  and its footer state the cost where the choice is made. It buys the encoder stage and the
  10 ms frame back, not audible quality — capture is mono duplicated to both channels and
  Opus at 192 kbps is already transparent for a microphone. Changing codec mid-stream rotates
  the streamId (`AudioSendEngine.setCodec`), like upstream's `OnCodecChanged`: a receiver keys
  a session on (endpoint, streamId) + the format it opened with. One endpoint per
  selected peer (two paths of one machine would double its sessions). Outbound audio uses
  the receiver's socket. The send toggle IS persisted like the receive toggle — the old
  "never persist send / mic never goes hot at launch" rule was retired by the user
  2026-07-12; do NOT reintroduce it. Send saved as on resumes at launch (consumed from
  `startupSendPending` at the END of the first `start()`, once the engines are up —
  flipping `sendEnabled` earlier re-enters `start()` from its didSet).
- **Send and receive are independent** (Windows v5 parity, 2026-07-12): the socket,
  heartbeats, and discovery run for the app's lifetime (`controller.start()` at launch);
  "Receive audio" (`receiveEnabled`, persisted, default on) gates playback ONLY —
  `engine.setPlaybackEnabled` flips the gate first, then disposes sessions. `AudioOutput`
  deliberately stays running: stopping it deactivates the shared iOS audio session, which
  would kill an active mic capture and background survival. Discovery announces the live
  CanSend/CanReceive and re-announces immediately on a toggle change.
- iOS 18 / macOS 15 minimum; **one shared bundle id** `com.jonathan859.remsound` for both
  platforms = one App Store Connect app record, universal purchase (iOS renamed from
  `.ios` 2026-07-03; macOS renamed from `.mac` 2026-07-11 — both pre-ship). The macOS
  target is App-Sandboxed (`Apps/macOS/RemSound.entitlements`: network client + server,
  audio input) — required for Mac App Store/TestFlight; never remove the sandbox.
- Password in Keychain. Control packets (type 5) parsed and ignored — upstream 5.6 sealed
  that payload with the audio key (2 plaintext bytes → 38 sealed), which changes nothing
  here while we ignore it; implementing remote volume control would mean adopting
  `ControlSealing` (seal + 10-min skew window + nonce replay memory), not the old 2-byte form.
- Opus via SPM `alta/swift-opus` pinned `exact: "0.0.2"` (raw C API needed for the FEC flag).
- **Screen-reader accessibility is the top priority**: every control labeled, status lines
  are plain sentences, audio start/stop fires cues + a VoiceOver announcement (iOS).
  **Terse UI text** (user, 2026-10-09: "way less verbose … most of the stuff should honestly
  be self explanatory"): no explanatory footers or accessibility hints that restate a
  control. Where a consequence genuinely is not obvious, an `InfoButton` (ⓘ, "About …",
  opens a short alert) sits next to the control — today only microphone quality, "Don't mix
  with other sounds", Saved profiles, and iCloud sync. Exceptions kept on purpose: the
  server list's empty-state reason, the headset toggle's "Needs …" note, the password
  footer, and the magic-tap hint on the Audio tab (it teaches a gesture). Add an ⓘ before
  adding a paragraph.
  VoiceOver **magic tap** (two-finger double tap) toggles mute anywhere in the iOS app
  (`ReceiverController.toggleMute()` announces the result); the Audio tab bar item
  reports "Muted" as its accessibility value. SwiftUI cannot attach custom VoiceOver
  actions to native tab bar items — don't try, the magic tap IS the quick-mute action.

## Pitfalls already hit (don't re-learn these)

1. AVAudioEngine mixer nodes throw an uncatchable NSException on *interleaved* connection
   formats — source nodes must use `standardFormatWithSampleRate:` (deinterleaved) and
   split planes from an interleaved scratch (see `AudioOutput.start`).
2. `opus_decode` imports with a non-optional output pointer — pass `pcm.baseAddress!`.
3. CommonCrypto PBKDF2: an empty password must still pass a **non-NULL** pointer with
   length 0 (both sides treat no-password as "" and must derive identical bytes).
4. iOS restricts UDP **broadcast** (needs a multicast entitlement). Never "fix" discovery
   with broadcast — unicast auto-learn is the iOS mechanism; manual peer entry seeds it.
5. **Never poll audio-input hardware on a timer** — AVAudioSession / HAL enumeration is
   audio-server IPC and causes audible crackling. Refresh inputs only on route-change /
   device-list notifications (`onInputsChanged`).
6. iOS clamps `installTap` buffers to ~100 ms regardless of the requested size. Low-latency
   capture must use `AVAudioSinkNode` → lock-free ring → drain thread (as implemented).
7. Multi-homed peers (LAN + Tailscale) announce from several source IPs. Never key row
   identity, allow-list, heartbeat tracking, **or connect/disconnect cue state** on a single
   address — `PeerAnnouncement.addresses` keeps all paths; selection/allow/track must cover
   ALL (`PeerDiscoveryTests` pins this). "Primary address" is not stable either: it is
   `addresses[0]`, i.e. whichever path discovery saw first and has not expired, so a quiet
   LAN leg ageing out under a live VPN stream moves it. Cue state therefore hangs off the
   **row id** (`PeerCueTracker`, issue #8) — while it was keyed on the address, a path change
   fired "lost" for the old key and "connected" for the new one on the same tick, announcing
   both while audio never stopped. For the same reason **discovery liveness must never gate playback**: the
   allow-list is re-derived from `discovery.currentPeers` on every discovery change and every
   DNS retry, and `setAllowedSenders` closes every live session that falls out of it, so a
   selected peer's addresses stay eligible for 30 s past their last sighting
   (`SelectionGrace`) — intersected with the current selection, so deselecting still cuts
   instantly. Over a VPN only unicast announcements carry and missing six in a row past the
   8 s expiry is unremarkable.
8. Jitter-buffer click-trim must keep a cushion ABOVE target latency, never trim to bare
   target (causes sustained underruns on bursty VPN paths) — see `SessionPlayout.write`.
9. iOS suspends a locked/backgrounded app whose audio session is `.mixWithOthers` (and
   lets the radio power-save under it) — inbound UDP and our heartbeats die until screen
   wake. Such an app is ALSO ineligible to be the system's Now Playing app, i.e. to receive
   headset transport presses. The session is therefore **exclusive by default**, and the
   opt-in "Don't mix with other sounds" toggle (`ReceiverSettings.exclusiveAudio`) is the
   only thing that inserts `.mixWithOthers` — in BOTH category branches of
   `AudioOutput.applySessionCategory`. Dropped 2026-08-20 ("buys nothing"), **restored
   2026-08-26** when a tester using the app as a baby monitor lost the stream every time
   another app started playing; it keeps the pre-0.7 UserDefaults key but now defaults
   **on** (`object(forKey:) == nil` check — a plain `bool` read would silently hand every
   existing install the mixable session). Turning it off costs both of the above, so the
   headset transport is *released* while it is off
   (`ReceiverController.canClaimTransportControls`) rather than left registered against a
   system that will never route a press to us, the Playback section says so under the
   headset toggle, and the Diagnostics panel reports it. Cost of the exclusive default,
   accepted: another app's playback interrupts us; the existing interruption / route-change
   / didBecomeActive observers are the recovery path. `.ended` without `.shouldResume` was
   deliberately NOT auto-resumed (we would interrupt the app that just took over, and
   ping-pong with it) until **2026-08-27**, when a device test showed that is exactly what
   another media app sends: Spotify stopping left RemSound silent AND holding no transport
   claim, so a stem press restarted *Spotify* — even after it was force-quit, because a
   silent app is not eligible and iOS parks the slot on the last app that played. The rule
   is now gated, not absolute: resume when `AVAudioSession.isOtherAudioPlaying` is **false**
   (nothing is playing, so nobody is interrupted and there is nothing to ping-pong with);
   stay down while it is true. `AudioOutput.pollInterruptionRecovery`, called from the
   functional half of the 1 Hz tick (**no new timer**), covers the two cases the notification
   does not: an app that pauses without deactivating its session never sends `.ended` at all,
   and an `.ended` that arrives while they are still playing needs picking up later. It reads
   one session property per second and ONLY while `interrupted` — that flag, and the
   recovery path it drives, stay outside `#if os(iOS)` (pitfall 12). `resumeEngine` reports
   and fires `onPlaybackRecovered` only when the start actually took: the poll retries every
   second and every attempt fails during a phone call, so an unconditional log would claim a
   recovery that never happened. Unavoidable limitation: a backgrounded silent app can be
   suspended, and a suspended app runs no tick — then only opening the app recovers.
10. Connect/disconnect cues must keep the Windows hysteresis rule (connected = audio within
    3 s OR healthy heartbeat; lost = no audio AND heartbeat unreachable ~5 s; in between
    holds state) — a bare audio-window check fires false disconnect+connect pairs on
    2-second Wi-Fi/VPN stalls (`ReceiverController.updateCues`).
11. **macOS AVAudioEngine has ONE HAL I/O unit shared by its input and output nodes**, so
    `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit` repoints the OUTPUT
    element too — selecting a mic killed the user's AirPods playback (2026-07-28). macOS
    capture therefore runs on its own input-only AUHAL (`CoreAudioInputUnit`, element 0
    disabled before the device is bound); never select a device through the engine. iOS is
    unaffected — `AVAudioSession.setPreferredInput` is route-level. Consequence: there is no
    `.AVAudioEngineConfigurationChange` for macOS capture, so the unit watches the device's
    nominal sample rate (plus the default-input device when the selection is "Default") and
    triggers the same stop/start rebuild.
12. **Engine recovery must never be nested inside `#if os(iOS)`.** `AVAudioEngine` stops
    itself on a configuration change and does not restart; on macOS that notification is the
    ONLY recovery signal (no AVAudioSession, so no interruption/route/media-reset observers
    to act as a backstop) and it fires for any Core Audio device change. It sat in the iOS
    block until 2026-07-28, which left a Mac silently dead — `isRunning` still true — after
    any device change. Reconnect the graph at OUR render format before restarting.
13. Bluetooth mics are a trap for a streaming app: opening a headset's mic drops the link
    into handsfree mode, so the mic arrives at 16/24 kHz on the Bluetooth clock AND the
    headset's own output degrades. Symptoms look unrelated to Bluetooth — the *remote* end
    hears periodic clicks from the clock drift (we have no send-side drift compensation)
    while local monitoring is clean, and the receive-side jitter buffer logs underruns and
    trims in the same minute. Diagnose by retesting on built-in speakers.
14. Row operations vs VoiceOver: `.contextMenu` is NOT reliably exposed to VoiceOver
    (macOS especially), so every row operation must ALSO be an explicit
    `.accessibilityAction(named:)` on the element VoiceOver focuses. `.swipeActions`,
    however, ARE auto-exposed as VO custom actions on iOS — combining them with explicit
    actions reads as doubled actions (user-reported). The pattern is therefore: explicit
    accessibility actions + context menu, NO swipeActions — see the peer and profile
    rows in `ReceiverRootView`.

## Architecture (everything shared lives in `RemSoundKit/Sources/RemSoundKit/`)

- Wire codec: `RemPacket.swift`, `AudioFormatInfo.swift`. Crypto: `RemSoundCrypto.swift`
  (`AudioDecryptor` network-thread only; `AudioEncryptor` capture-thread only).
- Network: `UDPSocket.swift` (BSD, IPv4 only, one blocking-recv thread),
  `PeerDiscoveryService.swift`, `HeartbeatService.swift`.
- Receive path: `AudioReceiverEngine.swift` (socket owner, dispatch, sessions, allow-list)
  → `StreamSession.swift` (decode) → `SessionPlayout.swift` (jitter buffer, fades — fades
  shape a per-session scratch BEFORE summing, never the shared mix buffer) →
  `PlayoutMixer.swift` (sum, volume, limiter) → `AudioOutput.swift` (AVAudioEngine +
  iOS session handling). `StreamDiagnostics.swift` is measurement-only telemetry hanging off
  the same path (loss / reorder / duplicate / inter-arrival gaps / the sender's Opus mode
  read from the TOC byte); aggregate per engine, not per session, so counts survive streamId
  rotation and idle pruning. Its sliding-minute window is sampled in the **functional** half
  of the refresh tick — the peak gap is read-and-reset, so sampling only while the UI is
  visible would fold a whole backgrounded session into one "last minute" figure.
- **Event log** (`EventLog.swift`, 2026-10-09, port of the Windows `RemSoundLog`; the user
  asked for "proper diagnostics/logging like the RemSound windows client"): recent events
  ALWAYS kept in memory (300, shown newest-first under Diagnostics → Recent events, and in
  the copied report), plus optional log files (`fileLoggingEnabled`, default off, device-local)
  in **Documents/Logs** — the app's own Files-app folder on iPhone (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace` in Apps/iOS/Info.plist; older builds' files in
  Application Support/Logs are moved over at launch), Show in Finder on the Mac. "Write log
  now" (Windows' button) adds a marker line, and with files off saves the recent events to
  a file of their own; "Copy recent events" copies them. Upstream's TSV layout: header, `EVT` rows, a `SNAP` counter row
  per second from the FUNCTIONAL tick (`writeLogSnapshot`), lazy creation, roll at 10 MB,
  pruned at start to 20 files / 14 days, Share button in Diagnostics. Thread-safe (lock +
  serial file queue), so the services' `onDiagnostic` hooks (engine, microphone, discovery,
  audio output) feed it straight from their threads — they existed for years and nobody
  listened. **Rules:** every user-facing change logs a line in its didSet (upstream's
  UiChangeLog lesson: ten of sixteen controls logged nothing); every accept-connections
  decision logs its reason, repeating "why not" lines once per person per run
  (`logAcceptOnce`, cleared on any tick/untick); never log a password, key or fingerprint.
  Pinned by `EventLogTests`.
- Send path: `MicrophoneCapture.swift` (sink node → `CaptureRingBuffer.swift` → drain
  thread, 10 ms units; mono duplicated to both channels) → `AudioSendEngine.swift`
  (accumulate → Opus encode or int24-LE pack → encrypt → split if over one datagram →
  targets; format re-announce every 250 ms) via
  `OpusStreamEncoder.swift` (`RemOpusShim` C target wraps variadic `opus_encoder_ctl`).
- Multi-path policy (issue #8), pure and CI-testable, both driven from `ReceiverController`:
  `PeerCueTracker.swift` (hysteretic connect/lost cues keyed by row id) and
  `SelectionGrace.swift` (allow-list eligibility past discovery's own expiry).
- Server groups: `RelayGroupProtocol.swift` (the version-2 framing, hello / roster / full /
  bye, `RelayClientId`) and `RelayGroupClient.swift` (the state machine — hello cadence,
  member list, stand-in addresses, the inbound/outbound routing rules, the 5 s safety rail).
  The engine has exactly one hook each way: `dispatch` on the way in, `sendFromAudioSocket`
  on the way out (`sendRawFromAudioSocket` is the unrouted one the client's own packets and
  the address-check echo use).
- App layer: `ReceiverController.swift` (@MainActor façade, 1 Hz refresh tick; the apps and
  the Shortcuts actions share ONE instance via `ReceiverController.shared`),
  `RemoteTransportControls.swift` (headset / lock-screen play-pause → `receiveEnabled`),
  `Apps/Shared/RemSoundIntents.swift` (Shortcuts actions: volume up/down, receiving
  on/off + toggle, mute set + toggle, set startup profile (a `StartupProfileOption`
  `AppEntity` — the launch choice mixes two fixed cases with the user's runtime profile
  list, which no `AppEnum` can express; ids "none"/"last"/UUID string are stored inside the
  user's shortcut, so they must stay stable), plus the `AppShortcutsProvider` with Siri phrases —
  compiled into BOTH app targets, deliberately NOT in RemSoundKit: SPM-library-hosted App
  Intents extract metadata cleanly at build time yet are never surfaced by on-device
  discovery on either platform, even via `AppIntentsPackage` forwarding — burned a full
  day on this 2026-07-11/12; the parameterless toggles exist because App Shortcuts can't
  pre-fill a Bool. No entitlements or ASC setup involved),
  `Profiles.swift` + `ProfileSync.swift` (saved snapshots and their opt-in iCloud mirror —
  the `ProfileSyncStore` protocol exists so the merge is testable without an iCloud account,
  which CI does not have; the real store silently no-ops when signed out, so tests against
  it would pass vacuously),
  `ReceiverRootView.swift` (shared SwiftUI — a `NavigationStack` wrapping a four-tab
  `TabView`: **Connectivity** = Status / Connected peers / Discovered peers (not on a
  server) / Discovered peers on the server / Add a peer by address / Accept connections /
  **Server last** (2026-10-09, Windows layout; the user moved Server to the bottom). Every one
  of those but Server and the accept picker is a
  **collapsible heading** (`CollapsibleHeader`: one element, `.isHeader` + `.isButton`, value
  "Expanded"/"Collapsed" — hand-built because `Section(isExpanded:)` only collapses in
  sidebar lists and what VoiceOver says for `DisclosureGroup` is undocumented); Status and
  Connected peers start open, the rest folded; which are open is REMEMBERED (`@AppStorage`
  "expanded.*", device-local, user 2026-10-09). Connected = every ticked row
  (network and server alike), discovered = the unticked ones, so a tick MOVES a row between
  lists — the row toggle posts "<name> moved to <list>" because the focused element vanishes
  (the server button opens `ServerConnectView.swift`; peer rows carry details / remove as
  VoiceOver actions + context menu, opening `PeerDetailsView.swift`; its tab bar
  item exposes the live
  traffic rates as its accessibility value, `controller.trafficSummary`; the Status
  heading shows ONLY general status — `controller.connectionDetails` — while the technical
  measurements live in `controller.diagnosticDetails` behind a Diagnostics button that opens
  `DiagnosticsView.swift`, because a dozen lines rewriting every second make the list
  tedious to arrow through when the question is just "am I connected". Both halves are
  collected regardless of whether the dialog is open, and `copyConnectionReport` copies
  both), **Send &
  Receive** = receive toggle/mic send/password, **Audio** = playback options,
  **Profiles** = saved snapshots (apply = row tap; update/rename/delete = context menu +
  VoiceOver actions, no swipe — pitfall 14; the drift-checked `controller.appliedProfile` drives a "Currently applied" row
  marker and the tab bar item's accessibility value — marker only while the live config
  exactly matches the snapshot); a persistent
  top-right About button opens `AboutView.swift`, which links to this repo and the
  official Windows repo), `Settings.swift` (UserDefaults + Keychain).
- `Apps/iOS`, `Apps/macOS`: thin entry points. iOS has the `audio` background mode; macOS
  is a `MenuBarExtra` (LSUIElement) whose **label view's `.task`** is the launch hook. The
  status item is a real menu — Show RemSound (W), Enable sending (S), Enable receiving (R),
  Exit RemSound (X), bare-letter key equivalents — and the full UI is a `Window` scene
  (id "main") with `.defaultLaunchBehavior(.suppressed)` so launch stays silent; opening
  it must also `NSApp.activate()` or the window appears behind the frontmost app, and the
  window's onAppear/onDisappear flip the activation policy `.regular`/`.accessory` — an
  accessory app is invisible to Cmd-Tab, so without the flip the open window is
  unreachable after switching away. The shared TabView needs `.tabViewStyle(.grouped)` on
  macOS: the automatic style puts tabs in the toolbar, where they collapse into an
  overflow pulldown next to the title + About button.

Known v1 simplifications (intentional): linear resampler for non-48k PCM senders, no drift
resampler (upstream v3.9.1 also added buffer-depth feedback to theirs — port both together
if drift ever becomes audible), no macOS loopback capture (virtual input devices cover it).
