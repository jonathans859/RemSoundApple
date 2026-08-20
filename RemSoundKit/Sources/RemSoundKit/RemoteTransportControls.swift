import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import UIKit
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
@MainActor
public final class RemoteTransportControls {
    /// Play pressed (resume receiving).
    public var onPlay: (() -> Void)?
    /// Pause/stop pressed (pause receiving).
    public var onPause: (() -> Void)?
    /// A press the accessory did not resolve to a direction — flip whatever we are doing.
    public var onToggle: (() -> Void)?

    private var isActive = false
    /// Last published (playing, detail) pair, so an unchanged update does no IPC.
    private var published: (playing: Bool, detail: String)?

    public init() {}

#if canImport(MediaPlayer)

    /// Claim the Now Playing slot and start listening for transport presses. Idempotent.
    public func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        _ = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        // The one AirPods actually send for a single stem press in most states; some
        // firmware/route combinations send play or pause instead, which is why all three
        // are registered rather than just this one.
        center.togglePlayPauseCommand.isEnabled = true
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onToggle?() }
            return .success
        }
        center.stopCommand.isEnabled = true
        _ = center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }

        // Everything else is explicitly OFF. A double-press is "next track" on AirPods; left
        // enabled by default it would either do something surprising here or leak to another
        // app. Disabled commands also drop the buttons from the Control Center / lock screen
        // presentation, which is what we want for a live stream.
        let unwanted: [MPRemoteCommand] = [
            center.nextTrackCommand, center.previousTrackCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackPositionCommand,
        ]
        for command in unwanted { command.isEnabled = false }

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
            center.playCommand, center.pauseCommand,
            center.togglePlayPauseCommand, center.stopCommand,
        ]
        for command in ours {
            command.removeTarget(nil) // nil = all targets this app registered
            command.isEnabled = false
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

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "RemSound",
            MPMediaItemPropertyArtist: detail,
            // A live stream has no duration and no scrub position; saying so removes the
            // scrubber instead of leaving it stuck at 0:00.
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Required on macOS (the system does not infer state there the way iOS does from the
        // audio session), and on iOS it is what keeps us the Now Playing app while paused —
        // which is the whole point: the *resume* press has to reach us too.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

#else

    // No MediaPlayer on this platform (Linux CI): accept and ignore so the controller needs
    // no conditionals.
    public func activate() {}
    public func deactivate() {}
    public func update(isPlaying: Bool, detail: String) {}

#endif
}
