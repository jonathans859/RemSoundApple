# RemSound for iOS and macOS

> **AI disclaimer:** This project has been written using Claude (Fable 5, Opus 4.8 and
> Opus 5.5). Any usage is at your own risk and nothing can be guaranteed. Pull requests and
> issues are welcome.

A native companion to [RemSound](https://github.com/Ednunp/RemSound) for iPhone, iPad and
Mac: hear what RemSound computers are sending, and send your own microphone back. Built
VoiceOver-first, with low-latency playback and the same end-to-end encryption as the
Windows app.

It speaks the RemSound v3.x wire protocol (header version 1) and the server group protocol
(header version 2), and is kept in step with the Windows app — the protocol was last
reviewed against RemSound 6.1 and server-v2.16.

## Features

**Audio**
* **Receives both RemSound codecs**: PCM 48 kHz 24-bit and Opus, including Opus
  forward-error-correction recovery of single lost packets.
* **Sends a microphone or input device** to the peers you have ticked (iPhone: built-in mic,
  AirPods, wired headsets; Mac: any input, including virtual devices like Loopback for
  system audio). Opus at 192 kbps by default, the Windows sender's settings; uncompressed
  PCM is a choice for local networks (about 290 kB/s per peer instead of 24).
* **Latency control**: jitter buffer with a 5–500 ms maximum delay (80 ms by default, like
  Windows), and optional automatic adjustment that follows the network.
* **Extra volume** (+3 / +6 / +12 dB) through a limiter, for quiet senders.

**Connecting**
* **Mandatory end-to-end encryption**: AES-256-GCM with a key derived from a shared
  password. Wrong password means silence, never noise, and the peer says why.
* **Network discovery** of RemSound computers, plus peers added by address (a Tailscale IP,
  for example). Machines on several networks at once (LAN and VPN) stay one peer.
* **Servers**: connect to a RemSound server and everyone on it using your password appears
  in a list of their own; sound flows once you have ticked each other. Servers you have
  used are remembered.
* **Accept connections**: when someone ticks you first, RemSound can ask you, tick them
  back automatically, or leave it to you. On iPhone the question arrives as a notification
  with Allow / Don't Allow while the app is in the background.
* **Peer details and names**: address, paths, ping, what a peer is sending, and a name of
  your own for each peer.

**Everyday use**
* **Profiles**: saved setups (peers, server, password, send and receive, microphone,
  delay, how connections are accepted), optionally synced through iCloud. One can be
  applied at launch — or picked from the app icon's menu on iPhone (long-press).
* **Headset and lock screen controls**: an AirPods press, the media keys, or the lock screen
  play button pause and resume receiving.
* **Shortcuts and Siri**: volume, receiving on/off, mute, and the launch profile.
* **iPhone: keeps playing in the background and on the lock screen.**
  **Mac: lives in the menu bar**, like the tray icon on Windows.
* **Accessibility**: every control labelled for VoiceOver, sound cues and announcements
  when peers connect or drop, and a two-finger double tap to mute from anywhere (iOS).
* **Diagnostics and logs**: connection measurements, a list of recent events (including
  why a connection was or was not offered), and optional log files — on iPhone in the
  Files app under On My iPhone → RemSound → Logs.

## Install (TestFlight)

Beta builds for both iOS and macOS are distributed through TestFlight:
**[join the RemSound beta](https://testflight.apple.com/join/pNCnj3z2)**. Install the
TestFlight app (iOS App Store / Mac App Store), then open the link on the device.

## Connecting to a Windows computer

1. Set the **same password** on both ends (RemSound on Windows keeps it in the profile).
2. **Same network:** the devices find each other. Tick the Apple device in RemSound on
   Windows and the Windows machine here — or tick it on one side and accept on the other.
3. **Across networks:** add the other machine's address under "Add a peer by address"
   (Tailscale works well), or both connect to the same RemSound server.
4. Audio plays only from peers you have ticked, exactly as on Windows.

### A note on iOS network discovery

iOS restricts UDP broadcast. The app announces itself by broadcast *and* directly to every
peer it knows, and the Windows side learns our address from any announcement it receives —
so once either side has added the other's address, discovery works both ways. iOS asks for
Local Network permission on first launch; say yes.

## Not supported, on purpose

* **Windows-only features**: ASIO lanes, the DAW plugin, recording, the metronome,
  Jamulus-style frames, and hearing yourself through a server.
* **Remote volume control** packets from peers are ignored.
* **Clock drift** between sender and receiver is bounded by buffer trimming rather than the
  Windows drift resampler; non-48 kHz PCM senders are resampled linearly. Both are upgrade
  points if they ever prove audible.
* **Starting the microphone from the lock screen** is not possible on iPhone: iOS only
  allows an app to start recording while it is open.
* Protocols before v3.x and the old relay "lobby" are not implemented.

## Repository layout

| Path | Purpose |
| ---- | ------- |
| `RemSoundKit/` | Swift package with everything shared: wire protocol, crypto, discovery, heartbeats, server groups, the receive and send pipelines, profiles, the event log, and the shared SwiftUI views. Unit-tested with plain `swift test`. |
| `Apps/iOS/`, `Apps/macOS/` | The two thin app targets, plus `Apps/Shared/` for the Shortcuts actions (App Intents have to live in the app targets). |
| `RemSound.xcodeproj` | Hand-maintained Xcode project with both app targets, referencing `RemSoundKit` as a local package. |
| `Resources/` | Sound cues (from the RemSound repo, MIT). |
| `.github/workflows/` | `ci.yml`: pull requests — unit tests and unsigned builds of both apps. `testflight.yml`: every push to `main` and every release — tests, then signed builds uploaded to TestFlight. |

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

Pull-request CI produces unsigned artifacts (`RemSound-macOS-unsigned.zip`,
`RemSound-iOS-unsigned.ipa`). The IPA must be signed (e.g. sideloaded with your own Apple
ID) before it can run on a device.

## Licence

MIT, same as RemSound.
