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
            // Artwork-tinted wash fading toward black — the Apple Music
            // full-player treatment, driven by the same dominant-hue tint the
            // Mac panel uses.
            LinearGradient(colors: [model.panelColor, Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: model.panelColor)
            PlayerScreen(model: model)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
    }
}
