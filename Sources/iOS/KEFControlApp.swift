// iOS shell: the player panel as a full-screen now-playing app. Everything it
// shows comes from Sources/Core — this file only provides the scene, the
// settings sheet, and foreground-refresh behaviour.
import SwiftUI

@main
struct KEFControlApp: App {
    @StateObject private var model = SpeakerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // The panel is designed dark, like the Mac card; the artwork
                // tint would fight a light chrome.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the poll loop in the background; don't show a
            // stale panel for up to 2s on return.
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SpeakerModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // The card's tint fills the whole screen behind it, so the 300pt
            // card reads as the app rather than a floating widget.
            model.panelColor.opacity(0.6)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: model.panelColor)
            PlayerView(model: model)
                .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .contentShape(Rectangle())
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
    }
}
