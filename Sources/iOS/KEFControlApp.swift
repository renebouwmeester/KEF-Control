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
            // Artwork tint over the whole screen — the same dominant-hue
            // color the Mac panel uses — with a whisper of darkening toward
            // the bottom for depth, so it never washes out to black.
            model.panelColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: model.panelColor)
            LinearGradient(colors: [.clear, .black.opacity(0.3)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            PlayerScreen(model: model)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    // Sits on the full-bleed artwork, so it needs its own
                    // contrast.
                    .background(.ultraThinMaterial, in: Circle())
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
