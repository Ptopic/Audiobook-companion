import SwiftUI

@main
struct AudiobookCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = PlayerModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(player: player)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.persistNow() }
                }
        }
    }
}
