# CLAUDE.md — RemSoundApple

iOS/macOS companion app (receive + microphone send) for the Windows **RemSound** app
(https://github.com/Ednunp/RemSound). Reference clone of the Windows source:
`C:\Users\jonathan\gitkeep\Ednunp\RemSound` — protocol truth lives in
`src/RemSound.Core/RemPacket.cs`, `RemSoundCrypto.cs`, `PeerDiscoveryService.cs`,
`HeartbeatService.cs`; receiver behaviour in `src/RemSound.Receiver/`. When in doubt about
wire behaviour, read the C# — it is the spec.

## Hard constraints (do not change without checking the Windows source)

These are the wire contract. Breaking any of them silently breaks interop:

- **Header**: 12 bytes LE — magic `RMND` (0x444E4D52 LE), version **1** (reject everything
  else; relay v2 "lobby" headers are version 2 and out of scope), type, uint16 streamId
  (0 coerces to 1), uint32 sequence. Single canonical UDP port **47830** for audio +
  heartbeat ("single-port model"); discovery on **47821**.
- **Format payload**: accept 32 (legacy), 36 (+lane byte @32), 44 (+8-byte password
  fingerprint @36) bytes. Field @28 is `frameSamplesPerChannel` — a **sample count**, not
  milliseconds (v3.0 change). Unknown lane values clamp to `.mixed`, never reject.
- **Crypto** (`RemSoundCrypto.swift`, mirrors C# exactly): PBKDF2-HMAC-SHA256, **100 000**
  iterations, salts `"RemSound.v1.audio-key"` (32-byte key) and `"RemSound.v1.fingerprint"`
  (8-byte fingerprint). AES-256-GCM packet layout **`nonce(12) ‖ tag(16) ‖ ciphertext`**
  (CryptoKit's `combined` is nonce‖ct‖tag — do NOT use it). Cross-impl PBKDF2 vectors are
  pinned in `CryptoTests.swift` (generated with Python `hashlib.pbkdf2_hmac`); if those fail,
  interop is broken.
- **PCM path**: sender encrypts the whole int24-LE frame, then splits into ≤1454-byte parts
  with a 6-byte sub-header (frameId/partIndex/totalParts) → receiver reassembles **then**
  decrypts. Parts must arrive in order; missing part = drop whole frame.
- **Opus path**: per-packet decrypt → libopus decode; on a single-packet sequence gap,
  decode the next packet with `decode_fec=1` first (inband FEC recovery), then normally.
  Frame size floor 120 samples (2.5 ms RESTRICTED_LOWDELAY minimum).
- **Discovery JSON**: keys are PascalCase and matched **case-sensitively** by
  System.Text.Json on Windows: `InstanceId`, `Name`, `AudioPort`, `CanSend`, `CanReceive`.
  1.5 s announce cadence, 8 s peer expiry, broadcast + unicast (unicast is what crosses
  VPNs; receiving an announcement auto-adds the source IP to unicast targets — this
  bidirectional auto-learn is what makes iOS discovery work without broadcast).
- **Heartbeat**: 1 Hz ping, streamId 0xFFFF, payload = kind byte + int64 LE originator
  monotonic ms echoed verbatim in the pong (RTT needs no clock sync). Pongs are matched to
  peers **by IP only** (source port is the peer's ephemeral/NAT port). Heartbeats from our
  side leave the **same socket** the audio arrives on — that NAT pinhole is also what
  claims our slot on the public relay (v1 pairwise reflector mode; just add the relay
  hostname as a manual peer, no extra protocol).
- **Allow-list**: audio/format packets are gated by source **IP** (not port). Sessions are
  keyed (endpoint, streamId); the sender rotates streamId on codec change/restart — on a
  new streamId, supersede old sessions from the same peer **only if the lane matches**
  (BothIndependent senders run two concurrent lanes per peer).

## Locked product decisions (user-confirmed 2026-06-10; sending added 2026-06-12)

- v3.x protocol only; no legacy, no relay-v2 lobby, no recording.
- **Microphone sending** (added 2026-06-12): Opus-only (no PCM send path), single mixed
  lane, 48 kHz stereo, 192 kbps — mirrors the Windows Opus sender settings exactly
  (RESTRICTED_LOWDELAY, complexity 10, VBR, inband FEC, 10 % loss bias). Sends to the
  *selected* peers (one endpoint per peer — best heartbeat path; never two paths of the
  same machine, that would double its sessions). Outbound audio leaves the receiver's
  audio socket (shared NAT pinhole). The send toggle is deliberately NOT persisted — the
  mic never goes hot at launch. macOS captures *input devices only*; output/loopback
  capture is delegated to virtual devices (Loopback/BlackHole) appearing as inputs.
- iOS 18 / macOS 15 minimum; app name "RemSound"; bundle ids
  `com.jonathan859.remsound.ios` / `.mac`.
- Single config (no Windows-style profiles). Password in Keychain.
- Extras: connect/disconnect cue sounds only (`Resources/*.wav`, taken from the Windows
  repo). Remote-volume Control packets (type 5) are parsed and **ignored**.
- Opus via SPM package `alta/swift-opus` pinned `exact: "0.0.2"` (raw `Copus` C API needed
  for the FEC flag — Apple's AudioConverter Opus decoder has no FEC API).
- **Screen-reader accessibility is the top priority.** Every control labeled, status lines
  are plain sentences, audio-start/stop fires cues + a VoiceOver announcement (iOS).
- Hand-written `RemSound.xcodeproj` (objectVersion 60, local-package reference). If you add
  a source file to an app target, you must hand-edit `project.pbxproj` (PBXBuildFile +
  PBXFileReference + group + Sources phase). Files inside `RemSoundKit/Sources/**` need
  **no** pbxproj edits — SPM picks them up automatically. Prefer putting code in the package.

## Architecture map

- `RemSoundKit/Sources/RemSoundKit/` — everything shared:
  - `RemPacket.swift`, `AudioFormatInfo.swift` — wire codec.
  - `RemSoundCrypto.swift` — PBKDF2/AES-GCM + `AudioDecryptor` (network-thread only) +
    `AudioEncryptor` (capture-thread only; emits the wire's nonce‖tag‖ct layout).
  - `UDPSocket.swift` — BSD-socket wrapper, one blocking-recv thread (.userInteractive),
    IPv4 only (matches Windows); also interface enumeration for broadcast addresses.
  - `PeerDiscoveryService.swift`, `HeartbeatService.swift` — see contract above.
  - `AudioReceiverEngine.swift` — socket owner, packet dispatch, session table, allow-list,
    peer security status, idle prune (4 s), byte counters/uptime.
  - `StreamSession.swift` — per-stream decode (PCM/Opus+FEC), mono→stereo upmix,
    `LinearResampler` for non-48k PCM passthrough senders.
  - `SessionPlayout.swift` — jitter buffer: arms at target latency, click-trim back to
    target when > target + max(2 codec frames, 10 ms), cosine-faded underrun edges,
    disarms after 8 consecutive empty reads (re-arms at target). Fades are applied to a
    per-session scratch BEFORE summing — never multiply the shared mix buffer.
  - `PlayoutMixer.swift` — sums sessions, volume/mute, tanh soft limiter above 0.9.
  - `AudioOutput.swift` — AVAudioEngine + AVAudioSourceNode; iOS session handling
    (interruption / media-services reset / route change), reports output latency.
  - `ReceiverController.swift` — @MainActor @Observable façade; 1 Hz refresh tick drives
    peer rows, cues, and the `connectionDetails` status lines.
  - `AudioSendEngine.swift` — outbound stream (one Windows `SenderLane`, Opus-only):
    accumulate 10 ms frames → encode → encrypt → emit to targets; format re-announce
    every 250 ms; random streamId per start; no key or no targets ⇒ sends nothing.
  - `OpusStreamEncoder.swift` — libopus encoder via `RemOpusShim` (separate C target in
    the package: `opus_encoder_ctl` is C-variadic, Swift can't call it; the shim exposes
    fixed-signature wrappers and depends on swift-opus's `Copus` product).
  - `MicrophoneCapture.swift` — input capture + enumeration/selection. iOS: AVAudioSession
    ports + built-in-mic data sources; macOS: Core Audio input devices set on the input
    unit. Converts hardware format → 48 kHz interleaved stereo float (mono duplicated
    into both channels — the converter's default 1→2 mapping is not trusted). Rebuilds
    itself on `AVAudioEngineConfigurationChange`.
  - `Settings.swift` — UserDefaults + Keychain. `ReceiverRootView.swift` — shared SwiftUI.
- `Apps/iOS`, `Apps/macOS` — thin entry points. iOS has `audio` background mode (lock-screen
  playback). macOS is a `MenuBarExtra` (LSUIElement); the **label view's `.task`** is the
  app-did-launch hook — content views only appear when the menu opens.

## Build / CI workflow (important — this machine is Windows)

- **Nothing here can compile Swift.** Validation happens on GitHub Actions
  (`.github/workflows/build.yml`: swift test + unsigned iOS/macOS builds, macos-15 runner).
- `gh` CLI is **not installed** and the user doesn't want API polling. They download the
  Actions logs and drop them in the repo root as `logs_<run-id>/` folders (gitignored).
  Read failures from `logs_*/<job name>/<step>.txt`.
- **Commit, but do not `git push` unless asked** — the user pushes themselves.
- Line endings: repo is checked out with core.autocrlf; the LF→CRLF warnings on commit are
  normal, ignore them.

## Pitfalls already hit (don't re-learn these)

1. **AVAudioEngine NSException on connect** — mixer nodes reject *interleaved* formats with
   an Objective-C exception Swift cannot catch (crashed the iOS app at launch). Source node
   must use `AVAudioFormat(standardFormatWithSampleRate:channels:)` (deinterleaved); render
   into an interleaved scratch and split planes (see `AudioOutput.start`).
2. **`opus_decode` imports with a non-optional output pointer** — pass
   `pcm.baseAddress!`, not the optional.
3. `Set(json?.keys ?? [])` doesn't type-check (`Dictionary.Keys` vs `[Any]`) — unwrap first.
4. CommonCrypto PBKDF2: empty password must still pass a **non-NULL** pointer with length 0
   (Windows treats no-password as "" and both sides must derive identical bytes).
5. iOS restricts UDP **broadcast** (multicast entitlement, needs Apple approval). Do not
   "fix" discovery by relying on broadcast — the unicast auto-learn path is the supported
   mechanism on iOS; manual peer entry seeds it.
6. **Multi-homed peers (LAN + Tailscale) announce from several source IPs.** The Windows
   one-address-per-InstanceId model makes the stored peer flap between paths every
   announcement — never key UI row identity, the allow-list, or heartbeat tracking on a
   single address. `PeerAnnouncement.addresses` keeps all live paths (primary = first
   seen); selection/allow/track must cover ALL of them (`PeerDiscoveryTests` pins this).

## Known v1 simplifications (intentional, candidates for later)

- No fixed-ratio drift resampler (Windows Phase-4 design); clock drift is bounded by
  click-trim + re-arm. Upgrade only if long sessions produce audible periodic fades.
- `LinearResampler` (linear interpolation) for non-48 kHz PCM senders; Windows uses WDL.
- Control packets ignored; no per-route latency (single output, lanes are mixed).
- No recording, no profiles, no auto-update.
- Send path: no PCM send, no multi-source mixing, no macOS output-device (loopback)
  capture — virtual input devices (Loopback/BlackHole) cover that. iOS holds
  `.playAndRecord` only while sending (Bluetooth output drops to the bidirectional link's
  quality while the AirPods mic is in use — expected, not a bug).
