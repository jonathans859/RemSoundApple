import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Headset and system transport controls: an AirPods stem press (or the Mac's media keys,
/// or the play/pause button in Control Center and on the lock screen) pauses and resumes
/// receiving.
///
/// The mechanism is `MPRemoteCommandCenter`. Those presses are *remote control events*, and
/// the system delivers them to whichever app it currently considers the **Now Playing** app.
/// Being that app takes two things, and only doing one of them silently does nothing:
///
/// 1. registered command handlers (below), and
/// 2. published `MPNowPlayingInfoCenter` info — without a "now playing" item there is
///    nothing for the system to arbitrate over, and the press goes elsewhere.
///
/// It also takes an audio session that is NOT `.mixWithOthers`: a mixable app is not
/// eligible to be the Now Playing app. RemSound now always holds the session exclusively
/// (see `AudioOutput.applySessionCategory`), so that condition is met by construction —
/// but if the mixable mode ever comes back, this stops working while it is on.
///
/// Kept deliberately cheap: nothing here runs on the 1 Hz tick. The Now Playing info is
/// pushed only when the receive state actually changes, so this costs no periodic IPC.
///
/// What a press *means* is decided here, not by the accessory — AirPods send `pause` for
/// every stem press regardless of state, so a literal reading makes the button one-way.
/// See `handle`.
@MainActor
public final class RemoteTransportControls {
    /// Play pressed (resume receiving).
    public var onPlay: (() -> Void)?
    /// Pause pressed while we are playing (pause receiving). A pause pressed while we are
    /// already paused calls `onPlay` instead — see `handle`.
    public var onPause: (() -> Void)?
    /// A press the accessory did not resolve to a direction — flip whatever we are doing.
    public var onToggle: (() -> Void)?

    private var isActive = false
    /// Last published (playing, detail) pair, so an unchanged update does no IPC.
    private var published: (playing: Bool, detail: String)?
    /// App-activation observer, so returning to the app can reclaim a lost Now Playing slot.
    private var activationObserver: NSObjectProtocol?

    /// The last command the system actually routed to us, for the Diagnostics panel. This
    /// exists because the failure mode here is *silence*: when a headset press does nothing,
    /// there is no way to tell "the system sent a command we ignored" from "the system never
    /// sent anything and paused the route itself" — and those need opposite fixes. Every
    /// command we register records itself here, including the ones that change no state.
    public private(set) var lastCommand: (name: String, at: Date)?

    public init() {}

#if canImport(MediaPlayer)

    /// Claim the Now Playing slot and start listening for transport presses. Idempotent.
    public func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        // Every one of these routes through `handle`, which is where the direction of the
        // press is actually decided — the accessory's own idea of it cannot be trusted.
        center.playCommand.isEnabled = true
        _ = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handle("play", .play) }
            return .success
        }
        center.pauseCommand.isEnabled = true
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handle("pause", .pause) }
            return .success
        }
        // Registered because Control Center and some accessories do send it. AirPods, as it
        // turns out, never do — see `handle`.
        center.togglePlayPauseCommand.isEnabled = true
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handle("play/pause", .toggle) }
            return .success
        }
        // A routed stop ends the now-playing session, so it is handled as a pause and
        // immediately followed by re-staking the claim. Leaving it UNhandled did not stop
        // the system routing one; it just meant the press vanished into a system-level
        // route pause while our own state stayed "playing".
        center.stopCommand.isEnabled = true
        _ = center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.handle("stop", .pause)
                self?.reassert()
            }
            return .success
        }
        // Registered ONLY to be observed: an AirPods double-press is "next track", and if a
        // single press is arriving as one of these we need to see it rather than infer it.
        // Deliberately no state change — skipping means nothing for a live stream.
        center.nextTrackCommand.isEnabled = true
        _ = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.record("next track") }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        _ = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.record("previous track") }
            return .success
        }
        // Everything else is explicitly OFF. A double-press is "next track" on AirPods; left
        // enabled by default it would either do something surprising here or leak to another
        // app. Disabled commands also drop their buttons from the Control Center / lock
        // screen presentation.
        //
        let unwanted: [MPRemoteCommand] = [
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackPositionCommand,
        ]
        for command in unwanted { command.isEnabled = false }

        // Returning to the app re-publishes the item verbatim. Nothing in this app clears
        // it, but the *system* can decide we are no longer the Now Playing app, and then a
        // press simply never arrives; without this, the change-gate in `update` means we can
        // never re-stake the claim and only a relaunch fixes it. Bringing the app forward is
        // exactly what a user does when the button stops working, so it is the right hook.
#if os(iOS)
        let activation = UIApplication.didBecomeActiveNotification
#else
        let activation = NSApplication.didBecomeActiveNotification
#endif
        activationObserver = NotificationCenter.default.addObserver(
            forName: activation, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassert() }
        }

#if os(iOS)
        // MPRemoteCommandCenter is documented to start delivery on its own once a handler is
        // registered; this is the older, still-supported half of the same contract and is
        // harmless when redundant. We cannot test remote control events on this machine, so
        // both halves go in.
        UIApplication.shared.beginReceivingRemoteControlEvents()
#endif
    }

    /// Release the Now Playing slot. Called when the receiver stops or the user turns the
    /// feature off — leaving stale info published would keep RemSound sitting in Control
    /// Center owning a play button that does nothing.
    public func deactivate() {
        guard isActive else { return }
        isActive = false

        let center = MPRemoteCommandCenter.shared()
        let ours: [MPRemoteCommand] = [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.stopCommand, center.nextTrackCommand, center.previousTrackCommand,
        ]
        for command in ours {
            command.removeTarget(nil) // nil = all targets this app registered
            command.isEnabled = false
        }

        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        published = nil

#if os(iOS)
        UIApplication.shared.endReceivingRemoteControlEvents()
#endif
    }

    /// Publish what the transport should show. `detail` is a plain sentence — it is read by
    /// VoiceOver from the lock screen and Control Center, so it says what the app is doing
    /// rather than naming a track.
    public func update(isPlaying: Bool, detail: String) {
        guard isActive else { return }
        if let published, published.playing == isPlaying, published.detail == detail { return }
        published = (isPlaying, detail)

        // NO `MPNowPlayingInfoPropertyIsLiveStream` here, however true it is of this audio:
        // for a live stream the system puts a **stop** button where pause would be, and a
        // stop ends the now-playing session — which cost us the resume press (see the
        // `unwanted` list in `activate`). Omitting it gets an ordinary play/pause pair.
        // Duration is omitted, so there is no scrubber to sit stuck at 0:00 either.
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "RemSound",
            MPMediaItemPropertyArtist: detail,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Required on macOS (the system does not infer state there the way iOS does from the
        // audio session), and on iOS it is what keeps us the Now Playing app while paused —
        // which is the whole point: the *resume* press has to reach us too.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func record(_ name: String) {
        lastCommand = (name, Date())
    }

    /// Which way a routed command asks the transport to move.
    private enum Press { case play, pause, toggle }

    /// When the last press was acted on, so one physical press that arrives as two commands
    /// only moves the state once.
    private var lastHandledAt: Date?

    /// Decide what a routed command means and apply it.
    ///
    /// Confirmed on hardware (AirPods, 2026-08-20): a single stem press always arrives as
    /// `pause`, in **every** state. The accessory never sends `play` or `togglePlayPause`,
    /// whatever we publish as our playback state. Taken literally that makes the button
    /// one-way — the first press pauses and every press after it is a no-op, which is
    /// exactly the "it disconnects but never reconnects" symptom. So a `pause` arriving
    /// while we are ALREADY paused is treated as the resume it can only have meant.
    ///
    /// Control Center and the lock screen are unaffected by that reinterpretation: they
    /// send a real `play` when paused, and never send `pause` twice in a row.
    private func handle(_ name: String, _ press: Press) {
        record(name)

        // One press can arrive as two commands (a stop *and* a pause). Only the first moves
        // anything; the window is short enough that two deliberate taps both land.
        let now = Date()
        if let lastHandledAt, now.timeIntervalSince(lastHandledAt) < 0.5 { return }
        lastHandledAt = now

        switch press {
        case .play:
            onPlay?()
        case .pause:
            if published?.playing == false { onPlay?() } else { onPause?() }
        case .toggle:
            onToggle?()
        }
    }

    /// Publish the current state again even though it has not changed, defeating the
    /// change-gate above. For reclaiming the Now Playing slot, not for routine updates.
    public func reassert() {
        guard isActive, let state = published else { return }
        published = nil
        update(isPlaying: state.playing, detail: state.detail)
    }

#else

    // No MediaPlayer on this platform (Linux CI): accept and ignore so the controller needs
    // no conditionals.
    public func activate() {}
    public func deactivate() {}
    public func update(isPlaying: Bool, detail: String) {}
    public func reassert() {}

#endif
}
