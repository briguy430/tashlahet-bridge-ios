import SwiftUI

@main
struct TashlahetBridgeApp: App {
    @StateObject private var service = TranslationService()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ConversationView()
            }
            .environmentObject(service)
        }
    }
}
