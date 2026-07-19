// iOS shell: the player panel as a full-screen now-playing app. Everything it
// shows comes from Sources/Core — this file only provides the scene, the
// settings sheet, and foreground-refresh behaviour.
import SwiftUI

/// The iOS accent: plain white on the tinted background. The Mac apps keep
/// their shared blue (`Color.appAccent` in Core) — deliberately not reused
/// here.
extension Color {
    static let phoneAccent = Color.white
}

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
            background
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
                    .glassEffect()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
    }

    /// A heavily blurred, saturated copy of the artwork behind everything —
    /// the Apple Music full-player treatment. It shifts with the cover
    /// instead of being one computed color; the panel tint stays as the base
    /// coat and the no-artwork fallback.
    private var background: some View {
        GeometryReader { geo in
            ZStack {
                model.panelColor
                if let art = model.artwork {
                    Image(platformImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .saturation(1.5)
                        // Overscan so the blur never shows darkened edges.
                        .scaleEffect(1.4)
                        .blur(radius: 70)
                        // Legibility: everything on top is thin white text.
                        .overlay(Color.black.opacity(0.45))
                }
            }
        }
        .ignoresSafeArea()
    }
}
