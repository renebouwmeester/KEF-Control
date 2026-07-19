// The iOS now-playing screen. Same SpeakerModel as the Mac panel, different
// body: where the Mac card is a dense 300pt popover, this follows the iOS
// grammar — inset artwork card, native scrubber with time labels, 44pt touch
// targets, haptics. Always dark, tinted from the artwork, like Apple Music's
// full-screen player.
import SwiftUI

struct PlayerScreen: View {
    @ObservedObject var model: SpeakerModel
    @ObservedObject private var artworkCache = PlayerView.ArtworkCache.shared

    @State private var scrubTarget: Double?   // finger position while scrubbing

    /// Which set the quick row shows; persisted so the app opens on the one
    /// you use.
    @AppStorage("BottomRowShowsRadio") private var showsRadio = false

    /// The quick row is hidden until summoned by the chevron in the source
    /// bar — the Mac panel's presets pattern, phone-sized. Persisted: leaving
    /// it open is a choice, not the layout's.
    @AppStorage("QuickRowVisible") private var quickRowVisible = false

    private let margin: CGFloat = 24

    var body: some View {
        // The hero square is sized from the container width explicitly —
        // letting aspectRatio(.fit) negotiate makes it fit the VStack's
        // proposed HEIGHT instead, shrinking the artwork.
        GeometryReader { geo in
        VStack(spacing: 0) {
            if !model.reachable {
                Spacer()
                statusView(icon: model.isConfigured ? "wifi.exclamationmark" : "hifispeaker.2",
                           title: model.isConfigured ? "Speaker unreachable" : "No speaker set",
                           detail: model.isConfigured ? model.speakerIP
                                                      : "Open Settings to choose a speaker")
                Spacer()
            } else if model.isStandby {
                Spacer()
                statusView(icon: "power", title: "Standby", detail: nil)
                Spacer()
            } else {
                artworkHero
                    .frame(width: geo.size.width, height: geo.size.width)
                    .padding(.top, 8)
                // Attached to the artwork's bottom edge, full width like the
                // artwork itself.
                scrubber
                Group {
                    metadata
                        .padding(.top, 26)
                    // All the slack lives above the controls block: the fixed
                    // gap below parks volume + transport near the quick row.
                    Spacer(minLength: 18)
                    volumeRow
                    transport
                        .padding(.top, 14)
                    Spacer(minLength: 14)
                        .frame(maxHeight: 24)
                }
                .padding(.horizontal, margin)
            }
            // Floating Liquid Glass control bar; the quick row morphs inside
            // the same capsule, so the screen above never moves.
            Group {
                if quickRowVisible {
                    quickOverlay
                        .transition(.blurReplace)
                } else {
                    bottomBar
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect()
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
        // The artwork starts at the top safe-area edge: below the Dynamic
        // Island, with the same breathing room the island has above it. The
        // bottom edge dips into the home-indicator area so the source bar
        // sits low, 16pt off the screen edge.
        .ignoresSafeArea(edges: .bottom)
        .sensoryFeedback(.impact(weight: .light), trigger: model.isPlaying)
    }

    // MARK: artwork

    /// Edge-to-edge while playing, anchored at the top under the Dynamic
    /// Island; recedes into a rounded inset card when paused, so the state
    /// change is unmissable.
    private var artworkHero: some View {
        ZStack {
            if let art = model.artwork {
                Image(platformImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.06))
                Image(systemName: "music.note")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
            }
        }
        // Concentric with the display's own corners, echoing iOS 26 — the
        // hard-cornered full bleed read as editorial rather than native.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(model.displayedIsPlaying ? 1 : 0.82)
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: model.displayedIsPlaying)
    }

    // MARK: metadata

    /// "Artist · Album" on one line; either alone when the other is missing.
    private var artistAlbumLine: String? {
        switch (model.displayArtist, model.displayAlbum) {
        case (nil, nil): return nil
        case let (artist?, nil): return artist
        case let (nil, album?): return album
        case let (artist?, album?): return album == artist ? artist : "\(artist) · \(album)"
        }
    }

    private var metadata: some View {
        VStack(spacing: 7) {
            Text(model.displayTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if let line = artistAlbumLine {
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Stream format as a quiet bordered badge, like Apple Music's
            // Lossless pill: "Roon · 96 kHz / 24-bit", "Spotify · Lossless".
            if let format = model.audioFormatText, model.showsKEFStream {
                Text(format)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 1))
                    .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    // MARK: scrubber

    private var fraction: Double {
        guard let length = model.displayLength, length > 0 else { return 0 }
        return min(1, max(0, (scrubTarget ?? model.displaySeek ?? 0) / length))
    }

    /// A thin line glued to the artwork's bottom edge, thickening downward
    /// under the finger; timestamps tucked right below. The touch target
    /// extends invisibly above and below the line. Read-only (no thickening,
    /// no gesture) when the source can't seek — Roon RAAT rejects the command.
    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(.white.opacity(0.8))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: model.isScrubbing ? 8 : 3)
                // Grow downward: the top edge stays flush with the artwork.
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.easeOut(duration: 0.15), value: model.isScrubbing)
                .contentShape(Rectangle().inset(by: -12))
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: 8)
            HStack {
                Text(timeLabel(scrubTarget ?? model.displaySeek ?? 0))
                Spacer()
                if let length = model.displayLength {
                    Text("-" + timeLabel(max(0, length - (scrubTarget ?? model.displaySeek ?? 0))))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        }
        .opacity(model.displayLength == nil ? 0 : 1)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.displayCanSeek, let length = model.displayLength else { return }
                model.isScrubbing = true
                scrubTarget = min(1, max(0, value.location.x / width)) * length
            }
            .onEnded { value in
                guard model.displayCanSeek, let length = model.displayLength else { return }
                let target = min(1, max(0, value.location.x / width)) * length
                model.isScrubbing = false
                scrubTarget = nil
                model.seekTo(target)
            }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: transport

    /// Same styling as the Mac panel: backward/forward.end.fill at .title2,
    /// circled play/pause at 38, 28pt gaps, tight centred cluster — just with
    /// iOS-sized touch targets around the glyphs.
    @State private var prevTap = 0
    @State private var nextTap = 0

    private var transport: some View {
        HStack(spacing: 28) {
            Button { prevTap += 1; model.control("previous") } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: prevTap)
            }
            Button { model.control("pause") } label: {
                Image(systemName: model.displayedIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { nextTap += 1; model.control("next") } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: nextTap)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(model.transportDisabled)
        .opacity(model.transportDisabled ? 0.4 : 1)
    }

    // MARK: volume

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Slider(
                value: Binding(
                    get: { Double(model.displayedVolume) },
                    set: { model.setVolume(Int($0)) }
                ),
                in: Double(model.effectiveMinVolume)...Double(max(model.effectiveMaxVolume,
                                                                  model.effectiveMinVolume + 1)),
                onEditingChanged: { model.isDraggingVolume = $0 }
            )
            // Quieter than the scrubber: the volume sits above the transport
            // as a supporting control, not the headline.
            .tint(.white.opacity(0.5))
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(model.displayedVolume)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(minWidth: 26, alignment: .trailing)
                // The number doubles as the mute toggle: red when muted.
                .foregroundStyle(model.displayedMuted ? .red : .secondary)
                .onTapGesture { model.toggleMute() }
        }
        .disabled(model.volumeControlDisabled)
    }

    // MARK: quick row — volume presets / radio stations, switchable

    /// The quick row with its closing chevron, sitting where the source bar
    /// was — the chevron mirrors the one that opened it.
    private var quickOverlay: some View {
        HStack(spacing: 10) {
            quickRow
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) { quickRowVisible = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// One row carries both quick-action sets, directly above the source bar.
    /// The leading button flips between them and always shows the icon of the
    /// set it would switch TO.
    private var quickRow: some View {
        let hasPresets = !model.volumePresets.isEmpty
        let hasRadio = model.hasRadioSlots
        let radioNow = hasRadio && (showsRadio || !hasPresets)
        return Group {
            if hasPresets || hasRadio {
                HStack(spacing: 10) {
                    if hasPresets && hasRadio {
                        Button {
                            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { showsRadio.toggle() }
                        } label: {
                            Image(systemName: radioNow ? "dial.medium" : "radio")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 44)
                                .contentShape(Rectangle())
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    }
                    ZStack {
                        if radioNow {
                            radioContent
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            presetContent
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipped()
                }
                .frame(height: 44)
            }
        }
    }

    private var presetContent: some View {
        HStack(spacing: 8) {
            ForEach(model.volumePresets, id: \.self) { preset in
                let active = model.displayedVolume == preset
                Button { model.setVolume(preset) } label: {
                    Text("\(preset)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(active ? AnyShapeStyle(Color.phoneAccent)
                                                : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            Capsule().fill(active ? Color.phoneAccent.opacity(0.22)
                                                  : Color.white.opacity(0.08))
                        )
                        .contentShape(Capsule())
                }
                .disabled(preset > model.effectiveMaxVolume)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: model.displayedVolume)
        .disabled(model.volumeControlDisabled)
    }

    private var radioContent: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.radioSlots.enumerated()), id: \.offset) { i, slot in
                if let station = slot {
                    radioButton(i, station)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func radioButton(_ index: Int, _ station: SpeakerModel.RadioStation) -> some View {
        let active = model.isPlayingRadio(station)
        return Button { model.playRadio(index) } label: {
            ZStack {
                Circle().fill(active ? Color.phoneAccent.opacity(0.26) : Color.white.opacity(0.1))
                if let art = artworkCache.image(for: station.iconURL) {
                    Image(platformImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .opacity(active ? 1 : 0.85)
                } else {
                    Text(Self.initials(station.title))
                        .font(.footnote)
                        .foregroundStyle(active ? AnyShapeStyle(Color.phoneAccent)
                                                : AnyShapeStyle(.secondary))
                }
                if active {
                    Circle().strokeBorder(Color.phoneAccent, lineWidth: 1.5)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.reachable || model.isStandby)
    }

    /// "NPO Radio 1" -> "N1", "Jazz24" -> "J2", "Classic FM" -> "CF".
    private static func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.compactMap { $0.first }.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    // MARK: bottom bar — sources, EQ, power

    private var bottomBar: some View {
        HStack(spacing: 0) {
            powerButton
            Spacer(minLength: 4)
            ForEach(model.visibleSources, id: \.id) { src in
                sourceButton(src)
            }
            Spacer(minLength: 8)
            if !model.currentEqName.isEmpty {
                eqMenu
            }
            if !model.volumePresets.isEmpty || model.hasRadioSlots {
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) { quickRowVisible = true }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: model.source)
    }

    private func sourceButton(_ src: SpeakerModel.Source) -> some View {
        let selected = model.source == src.id
        return Button { model.setSource(src.id) } label: {
            Group {
                if let glyph = src.glyph, let img = templateGlyph(named: glyph,
                                                                 size: CGSize(width: 17, height: 20)) {
                    Image(platformImage: img).renderingMode(.template)
                } else {
                    Image(systemName: src.icon)
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(Color.phoneAccent) : AnyShapeStyle(.secondary))
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.phoneAccent.opacity(0.18) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!model.reachable)
    }

    private var eqMenu: some View {
        Menu {
            ForEach(model.eqProfiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) { profile in
                Button {
                    model.applyEqProfile(profile)
                } label: {
                    if profile.id == model.currentEqId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            if !model.eqProfiles.isEmpty { Divider() }
            Button("Re-capture current") { model.recaptureCurrentProfile() }
        } label: {
            // Icon only, sized like a source button; the active profile shows
            // as the checkmark inside the menu. buttonStyle(.plain) keeps the
            // menu's default tint from recolouring it.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Bottom-anchored menus open upward and iOS reverses their items by
        // default, which flipped the alphabetical order; keep it as declared.
        .menuOrder(.fixed)
    }

    private var powerButton: some View {
        Button { model.togglePower() } label: {
            Image(systemName: "power")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.isStandby ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(Color.phoneAccent))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.reachable)
    }

    // MARK: shared bits

    private func statusView(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
