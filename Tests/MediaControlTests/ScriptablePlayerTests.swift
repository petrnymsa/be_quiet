import MediaControl
import Testing

@Suite("ScriptablePlayerController")
struct ScriptablePlayerTests {
    @Test("the two players differ only in identity")
    func identities() {
        #expect(ScriptablePlayerController.spotify.id == .spotify)
        #expect(ScriptablePlayerController.spotify.displayName == "Spotify")
        #expect(ScriptablePlayerController.appleMusic.id == .appleMusic)
        #expect(ScriptablePlayerController.appleMusic.displayName == "Apple Music")
    }

    @Test("player states parse the AppleScript wording")
    func playerStates() {
        #expect(PlayerState(rawValue: "playing") == .playing)
        #expect(PlayerState(rawValue: "paused") == .paused)
        #expect(PlayerState(rawValue: "stopped") == .stopped)
        #expect(PlayerState(rawValue: "fast forwarding") == .fastForwarding)
        #expect(PlayerState(rawValue: "rewinding") == .rewinding)
        #expect(PlayerState(rawValue: "buffering") == nil)
    }

    @Test("a receipt from another controller is ignored")
    @MainActor
    func foreignReceipt() async {
        // Must not touch the player; with no player running this is a no-op either way.
        await ScriptablePlayerController.appleMusic.resume(PauseReceipt(controller: .spotify))
    }
}
