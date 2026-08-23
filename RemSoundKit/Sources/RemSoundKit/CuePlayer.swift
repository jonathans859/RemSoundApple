import AVFAudio
import Foundation

/// Plays the app's cue sounds — peers connecting and disconnecting (the same WAVs the
/// Windows app ships), plus confirmation of the actions a user can trigger from anywhere:
/// receiving on/off, sending on/off, and saving a profile. Cues are an accessibility
/// feature: a screen-reader user hears what happened without having to poll the UI, which
/// matters most when the change came from outside the app (a headset press, a Shortcut,
/// the menu bar) and there is no focused control to announce it.
public final class CuePlayer {
    public enum Cue: String, CaseIterable {
        case connect
        case disconnect
        case receiveOn = "receive-on"
        case receiveOff = "receive-off"
        case sendOn = "send-on"
        case sendOff = "send-off"
        case profileSaved = "save"
    }

    private var players: [Cue: AVAudioPlayer] = [:]
    public var enabled = true

    public init(bundle: Bundle = .main) {
        for cue in Cue.allCases {
            if let url = bundle.url(forResource: cue.rawValue, withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[cue] = player
            }
        }
    }

    public func play(_ cue: Cue) {
        guard enabled, let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }
}
