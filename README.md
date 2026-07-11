# RemSound for iOS and macOS

> **AI disclaimer:** This project has been written using Claude (Fable 5 and Opus 4.8).
> Any usage is at your own risk and nothing can be guaranteed. Pull requests and issues
> are welcome.

A native receiver for [RemSound](https://github.com/Ednunp/RemSound) — listen to the audio a
RemSound sender (Windows) is transmitting, on an iPhone, iPad, or Mac. Built VoiceOver-first,
with low-latency playback and the same end-to-end encryption as the Windows app.

It speaks the RemSound v3.x wire protocol (header version 1) and current formats only.
Besides receiving, it can **send a microphone or input device** back to your RemSound peers
(Opus, encrypted). Recording and legacy/v2.x compatibility are out of scope.

## Features

* **Receives both RemSound codecs** — PCM 48 kHz 24-bit (multi-part frame reassembly) and
  Opus, including Opus inband-FEC recovery of single lost packets (via libopus, the same
  recovery the Windows receiver does).
* **Mandatory end-to-end encryption** — AES-256-GCM with the key derived from a shared
  password (PBKDF2, identical parameters to Windows). Wrong password = silence, never noise.
  Password fingerprints tell you *why* a peer is silent ("password does not match" / "peer
  app needs update").
* **LAN discovery + manual peers** — announces itself on the RemSound discovery port so the
  Windows side sees it; add a Tailscale IP or the public relay hostname manually for
  anything broadcast can't reach. Heartbeats (1 Hz ping/pong with RTT) run on the single
  canonical UDP port 47830, which also keeps the NAT pinhole open for relay mode.
* **iOS: background and lock-screen playback** — the `audio` background mode keeps reception
  running when you switch apps or lock the screen.
* **macOS: lives in the menu bar**, like the tray icon on Windows.
* **Connect/disconnect sound cues** (the Windows app's own WAVs) plus VoiceOver
  announcements when a peer's audio starts or stops.
* **Latency control** — jitter buffer with target-latency arming, click-trim, and faded
  underrun concealment. Default 80 ms like Windows; adjustable 5–500 ms.
* **Microphone sending** — stream a mic (iPhone: bottom mic, AirPods, wired headsets;
  Mac: any input device, including virtual devices like Loopback for system audio) to the
  peers you've selected, encrypted with the same shared password. Opus 48 kHz stereo at
  192 kbps, the same encoder settings as the Windows sender. The toggle resets to off on
  every launch — the microphone is never live just because the app started. Note: while
  sending from Bluetooth headphones' own mic, their playback quality drops to the
  bidirectional link — that's a Bluetooth limitation, not an app bug.

## Install (TestFlight)

Beta builds for both iOS and macOS are distributed through TestFlight:
**[join the RemSound beta](https://testflight.apple.com/join/pNCnj3z2)**. Install the
TestFlight app (iOS App Store / Mac App Store), then open the link on the device.

## Repository layout

| Path | Purpose |
| ---- | ------- |
| `RemSoundKit/` | Swift package with everything shared: wire protocol, crypto, discovery, heartbeat, jitter buffer, decode pipeline, audio output, and the shared SwiftUI views. Unit-testable with plain `swift test`. |
| `Apps/iOS/`, `Apps/macOS/` | The two thin app targets (entry point + Info.plist each). |
| `RemSound.xcodeproj` | Hand-maintained Xcode project with both app targets, referencing `RemSoundKit` as a local package. |
| `Resources/` | Connect/disconnect cue sounds (from the RemSound repo, MIT). |
| `.github/workflows/build.yml` | CI: runs the unit tests and builds both apps unsigned on every push. |

Opus comes from [alta/swift-opus](https://github.com/alta/swift-opus), which builds libopus
from source through SPM — no binaries in this repo.

## Building

On a Mac: open `RemSound.xcodeproj`, pick the `RemSound-iOS` or `RemSound-macOS` scheme, and
run. Xcode resolves the libopus package automatically on first open (network required once).

Command line:

```sh
swift test --package-path RemSoundKit                       # protocol/crypto/pipeline tests
xcodebuild -project RemSound.xcodeproj -scheme RemSound-macOS -destination 'platform=macOS' build
xcodebuild -project RemSound.xcodeproj -scheme RemSound-iOS -destination 'generic/platform=iOS' build
```

CI produces unsigned artifacts (`RemSound-macOS-unsigned.zip`, `RemSound-iOS-unsigned.ipa`).
The IPA must be signed (e.g. sideloaded with your own Apple ID) before it can run on a device.

## Connecting to a Windows sender

1. Set the **same password** on both ends (RemSound on Windows stores it on the profile).
2. Same network: the devices discover each other automatically — tick the Apple device in
   the Windows peer list, tick the Windows machine in this app.
3. Tailscale / WAN: add the other machine's IP under "Add a peer by address" (port is
   automatic), or add the public relay hostname on both ends.
4. Audio plays only from peers you have ticked, matching the Windows allow-list behaviour.

### A note on iOS LAN discovery

iOS restricts UDP broadcast. The app announces itself by broadcast *and* by unicast to every
known peer, and the Windows side auto-learns our address from any unicast announcement — so
after you add the Windows machine's IP once (or it adds yours), discovery works both ways
without the broadcast path. The OS will ask for Local Network permission on first launch;
say yes. macOS has no such restriction.

## Deliberate v1 simplifications

* Single configuration instead of Windows-style profiles.
* Clock-drift between sender and receiver is bounded by buffer trim + re-arm rather than the
  Windows fixed-ratio resampler; non-48 kHz PCM senders are resampled linearly. Both are
  upgrade points if they ever prove audible in real use.
* Remote volume control (Control packets) is parsed and ignored.
* Relay support is the v1 pairwise mode (send heartbeats at the relay host, audio reflects
  back on the same socket). The relay's v2 lobby protocol is not implemented — the Windows
  client doesn't emit it either.

## Licence

MIT, same as RemSound.
