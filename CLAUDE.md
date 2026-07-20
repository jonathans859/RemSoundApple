# CLAUDE.md — RemSoundApple

iOS/macOS companion app (receive + microphone send) for the Windows **RemSound** app
(https://github.com/Ednunp/RemSound). The C# in that repo is the wire-protocol spec — when in
doubt read `src/RemSound.Core/` (`RemPacket.cs`, `RemSoundCrypto.cs`, `PeerDiscoveryService.cs`,
`HeartbeatService.cs`) and `src/RemSound.Receiver/`.

## Build workflow (read this first — development happens on Windows)

- **This machine cannot compile Swift.** Validation happens only on GitHub Actions
  (`.github/workflows/build.yml`: swift test + unsigned iOS/macOS builds). For CI results,
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
- TestFlight: `.github/workflows/testflight.yml` cloud-signs **both platforms** (iOS IPA
  + macOS PKG, parallel jobs, one shared app record) via the App Store Connect API key
  (Admin; no certificates or profiles anywhere) and uploads on **every push to `main`**
  (internal testers, automatic distribution, changelog = commit subject) and on **every
  published GitHub Release `vX.Y.Z`** (external testers too — repo variable
  `TESTFLIGHT_EXTERNAL_GROUPS`, default "Beta"; notes = "What to Test"; IPA + PKG
  attached to the release). To cut a release use the `release` skill (`.claude/skills/release/`) —
  it drives the Sonnet `release-manager` subagent (`.claude/agents/release-manager.md`).
  One-time setup steps live in `plan.md`; recurring gotchas (Admin key required for cloud
  signing, the Xcode/iOS 26 SDK floor that keeps the signing job on `macos-26`) are in
  the skill's "Known failure modes".

## Wire contract — breaking any of these silently breaks Windows interop

- **Header**: 12 bytes LE — magic `RMND`, version **1** (reject all else), type, uint16
  streamId (0 coerces to 1), uint32 sequence. One UDP port **47830** for audio + heartbeat;
  discovery on **47821**.
- **Format payload**: accept 32 / 36 (+lane byte @32) / 44 (+8-byte password fingerprint @36)
  bytes. Field @28 is `frameSamplesPerChannel` — a **sample count, not milliseconds**.
  Unknown lane values clamp to `.mixed`, never reject.
- **Crypto**: PBKDF2-HMAC-SHA256, **100 000** iterations, salts `"RemSound.v1.audio-key"`
  (32-byte key) / `"RemSound.v1.fingerprint"` (8 bytes). AES-256-GCM packet layout is
  **`nonce(12) ‖ tag(16) ‖ ciphertext`** — CryptoKit's `combined` is nonce‖ct‖tag, do NOT
  use it. Cross-impl PBKDF2 vectors are pinned in `CryptoTests.swift`; if they fail,
  interop is broken.
- **PCM**: whole int24-LE frame encrypted, then split into ≤1454-byte parts with a 6-byte
  sub-header → reassemble **then** decrypt; parts arrive in order, missing part = drop frame.
- **Opus**: per-packet decrypt → libopus decode; on a single-packet gap decode the next
  packet with `decode_fec=1` first. Frame-size floor 120 samples.
- **Discovery JSON**: PascalCase keys, matched **case-sensitively** by Windows
  (`InstanceId`, `Name`, `AudioPort`, `CanSend`, `CanReceive`). 1.5 s announce, 8 s expiry.
  Unicast is what crosses VPNs; receiving an announcement auto-adds the source IP as a
  unicast target — that auto-learn is how iOS discovery works without broadcast.
- **Heartbeat**: 1 Hz ping, streamId 0xFFFF, payload = kind byte + int64 LE monotonic ms
  echoed verbatim in the pong. Pongs match peers **by IP only**. Heartbeats leave the same
  socket audio arrives on (shared NAT pinhole; also claims our relay slot).
- **Allow-list**: gate audio/format by source **IP**, not port. Sessions keyed
  (endpoint, streamId); on a new streamId from the same peer, supersede old sessions
  **only if the lane matches** (BothIndependent senders run two lanes per peer).

## Locked product decisions (do not revisit)

- v3.x protocol only; no legacy, no relay-v2 lobby, no recording.
- Profiles (2026-07-12, user reversed the earlier "no profiles" decision): local named
  snapshots of peers + selection, password, receive/send toggles, microphone, max delay —
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
  flavours and `setSynchronizable` migrates on toggle. Needs the
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
- Mic send: Opus-only, one mixed lane, 48 kHz stereo 192 kbps (RESTRICTED_LOWDELAY,
  complexity 10, VBR, FEC, 10 % loss bias) — mirrors the Windows sender. One endpoint per
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
- Password in Keychain. Control packets (type 5) parsed and ignored.
- Opus via SPM `alta/swift-opus` pinned `exact: "0.0.2"` (raw C API needed for the FEC flag).
- **Screen-reader accessibility is the top priority**: every control labeled, status lines
  are plain sentences, audio start/stop fires cues + a VoiceOver announcement (iOS).
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
   identity, allow-list, or heartbeat tracking on a single address —
   `PeerAnnouncement.addresses` keeps all paths; selection/allow/track must cover ALL
   (`PeerDiscoveryTests` pins this).
8. Jitter-buffer click-trim must keep a cushion ABOVE target latency, never trim to bare
   target (causes sustained underruns on bursty VPN paths) — see `SessionPlayout.write`.
9. iOS suspends a locked/backgrounded app whose audio session is `.mixWithOthers` (and
   lets the radio power-save under it) — inbound UDP and our heartbeats die until screen
   wake. The opt-in **Exclusive audio** setting drops `.mixWithOthers` to survive the lock
   screen; both modes are deliberate, don't remove either (`AudioOutput.setExclusiveAudio`).
10. Connect/disconnect cues must keep the Windows hysteresis rule (connected = audio within
    3 s OR healthy heartbeat; lost = no audio AND heartbeat unreachable ~5 s; in between
    holds state) — a bare audio-window check fires false disconnect+connect pairs on
    2-second Wi-Fi/VPN stalls (`ReceiverController.updateCues`).
11. Row operations vs VoiceOver: `.contextMenu` is NOT reliably exposed to VoiceOver
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
  iOS session handling).
- Send path: `MicrophoneCapture.swift` (sink node → `CaptureRingBuffer.swift` → drain
  thread, 10 ms units; mono duplicated to both channels) → `AudioSendEngine.swift`
  (accumulate → Opus encode → encrypt → targets; format re-announce every 250 ms) via
  `OpusStreamEncoder.swift` (`RemOpusShim` C target wraps variadic `opus_encoder_ctl`).
- App layer: `ReceiverController.swift` (@MainActor façade, 1 Hz refresh tick; the apps and
  the Shortcuts actions share ONE instance via `ReceiverController.shared`),
  `Apps/Shared/RemSoundIntents.swift` (Shortcuts actions: volume up/down, receiving
  on/off + toggle, mute set + toggle, plus the `AppShortcutsProvider` with Siri phrases —
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
  `TabView`: **Connectivity** = status/peers/add-peer (its tab bar item exposes the live
  traffic rates as its accessibility value, `controller.trafficSummary`), **Send &
  Receive** = receive toggle/mic send/password, **Audio** = playback options,
  **Profiles** = saved snapshots (apply = row tap; update/rename/delete = context menu +
  VoiceOver actions, no swipe — pitfall 11; the drift-checked `controller.appliedProfile` drives a "Currently applied" row
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
if drift ever becomes audible), no PCM send, no macOS loopback capture (virtual input
devices cover it).
