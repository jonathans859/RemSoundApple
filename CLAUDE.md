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
  phase). Prefer the package.
- To check whether the Windows repo changed the protocol since the last review, use the
  `upstream-protocol-sync` skill (`.claude/skills/upstream-protocol-sync/`) — it tracks the
  last-scanned upstream commit and says which files matter.
- Releases/TestFlight: use the `release` skill (`.claude/skills/release/`). Publishing a
  GitHub Release `vX.Y.Z` triggers `.github/workflows/release.yml` (signed IPA →
  TestFlight, notes = release body). One-time setup steps live in `plan.md`.

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

- v3.x protocol only; no legacy, no relay-v2 lobby, no recording, no profiles.
- Mic send: Opus-only, one mixed lane, 48 kHz stereo 192 kbps (RESTRICTED_LOWDELAY,
  complexity 10, VBR, FEC, 10 % loss bias) — mirrors the Windows sender. One endpoint per
  selected peer (two paths of one machine would double its sessions). Outbound audio uses
  the receiver's socket. The send toggle is deliberately NOT persisted — the mic never goes
  hot at launch.
- iOS 18 / macOS 15 minimum; bundle ids `com.jonathan859.remsound` (iOS; renamed from
  `.ios` 2026-07-03, pre-ship) / `com.jonathan859.remsound.mac` (macOS).
- Password in Keychain. Control packets (type 5) parsed and ignored.
- Opus via SPM `alta/swift-opus` pinned `exact: "0.0.2"` (raw C API needed for the FEC flag).
- **Screen-reader accessibility is the top priority**: every control labeled, status lines
  are plain sentences, audio start/stop fires cues + a VoiceOver announcement (iOS).

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
- App layer: `ReceiverController.swift` (@MainActor façade, 1 Hz refresh tick),
  `ReceiverRootView.swift` (shared SwiftUI), `Settings.swift` (UserDefaults + Keychain).
- `Apps/iOS`, `Apps/macOS`: thin entry points. iOS has the `audio` background mode; macOS
  is a `MenuBarExtra` (LSUIElement) whose **label view's `.task`** is the launch hook.

Known v1 simplifications (intentional): linear resampler for non-48k PCM senders, no drift
resampler (upstream v3.9.1 also added buffer-depth feedback to theirs — port both together
if drift ever becomes audible), no PCM send, no macOS loopback capture (virtual input
devices cover it).
