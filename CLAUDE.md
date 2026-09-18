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
- TestFlight: `.github/workflows/testflight.yml` cloud-signs **both platforms** (iOS IPA
  + macOS PKG, parallel jobs, one shared app record) via the App Store Connect API key
  (Admin; no certificates or profiles anywhere) and uploads on **every push to `main`**
  (internal testers, automatic distribution, changelog = commit subject) and on **every
  published GitHub Release `vX.Y.Z`** (external testers too — repo variable
  `TESTFLIGHT_EXTERNAL_GROUPS`, default "Beta"; notes = "What to Test"; IPA + PKG
  attached to the release). To cut a release use the `release` skill (`.claude/skills/release/`) —
  it drives the Sonnet `release-manager` subagent (`.claude/agents/release-manager.md`).
  One-time setup steps live in `docs/plan.md`; recurring gotchas (Admin key required for cloud
  signing, the Xcode/iOS 26 SDK floor that keeps the signing job on `macos-26`) are in
  the skill's "Known failure modes".

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
  echoed verbatim in the pong. Pongs match peers **by IP only**. Heartbeats leave the same
  socket audio arrives on (shared NAT pinhole; also claims our relay slot).
- **Relay address-proof** (type **10**, upstream server-v2.5): the relay cookies each newly
  seen client address; echo the packet back **verbatim to its source**, from the audio socket,
  and **ungated by the allow-list** (the challenge comes from the relay, not a selected peer).
  Watch-only upstream today — when the relay flips `--require-addr-check`, a client that never
  echoes has all forwarded traffic withheld. Pinned by `AddrCheckTests`.
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
  (2026-09-18), max delay, auto-tune on/off (2026-08-17) —
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
- **Peer details and friendly names** (2026-09-06, Windows parity): every peer row carries
  "Peer details" and "Rename peer" as explicit VoiceOver actions plus a context menu (pitfall
  14 — no swipe actions), opening `PeerDetailsView` — machine name, the address and port,
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
- Send path: `MicrophoneCapture.swift` (sink node → `CaptureRingBuffer.swift` → drain
  thread, 10 ms units; mono duplicated to both channels) → `AudioSendEngine.swift`
  (accumulate → Opus encode or int24-LE pack → encrypt → split if over one datagram →
  targets; format re-announce every 250 ms) via
  `OpusStreamEncoder.swift` (`RemOpusShim` C target wraps variadic `opus_encoder_ctl`).
- Multi-path policy (issue #8), pure and CI-testable, both driven from `ReceiverController`:
  `PeerCueTracker.swift` (hysteretic connect/lost cues keyed by row id) and
  `SelectionGrace.swift` (allow-list eligibility past discovery's own expiry).
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
  `TabView`: **Connectivity** = status/peers/add-peer (peer rows carry details / rename /
  remove as VoiceOver actions + context menu, opening `PeerDetailsView.swift`; its tab bar
  item exposes the live
  traffic rates as its accessibility value, `controller.trafficSummary`; the Connection
  section shows ONLY general status — `controller.connectionDetails` — while the technical
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
