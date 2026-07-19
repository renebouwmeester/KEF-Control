// The player panel. A 300pt column with full-bleed artwork — on macOS it fills
// the menu bar panel; on iOS it is already the shape of a now-playing screen.
import SwiftUI
import Combine

// MARK: - Popover UI

struct PlayerView: View {
    @ObservedObject var model: SpeakerModel
    /// The Mac panel is a fixed 300pt card; the iOS shell passes the screen
    /// width so the same layout renders as a full-bleed now-playing screen.
    var cardWidth: CGFloat = PanelMetrics.width
    @ObservedObject private var artwork = ArtworkCache.shared

    var body: some View {
        VStack(spacing: 0) {
            if !model.reachable {
                unreachableView
            } else if model.isStandby {
                standbyView
            } else {
                artworkView
                progressBar
                // Timestamps + format badge, like the iOS app; hidden with
                // the progress info when the source reports no duration.
                if model.displayLength != nil {
                    timeRow
                        .padding(.horizontal, 10)
                        .padding(.top, 5)
                }
            }
            VStack(spacing: 12) {
                if model.reachable && !model.isStandby {
                    metadataView
                    transportView
                }
                VStack(spacing: 12) {
                    volumeRow
                    // Presets belong with the volume they set, so they expand
                    // directly under that row.
                    if model.showPresets {
                        presetRow
                    }
                }
                radioRow
                Divider()
                bottomRow
            }
            .padding(14)
        }
        .frame(width: cardWidth)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        // The shadow lives here, not on the window, so it follows the card as
        // SwiftUI animates its height.
        .shadow(color: .black.opacity(0.44), radius: 11, x: 0, y: 4)
        // The panel window is a fixed-size transparent canvas that never
        // resizes, so this always matches the hosting view's bounds — nothing
        // ever overflows, and the card is simply pinned to the top. SwiftUI
        // animates the card's height on its own; no window/content sync exists
        // to get wrong.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.6), value: model.panelColor)
    }

    /// A heavily blurred, saturated copy of the artwork behind the card's
    /// content — the same treatment as the iOS app's backdrop. The dominant
    /// tint stays as base coat and no-artwork fallback; the dark overlay
    /// keeps the thin white text legible. Invisible behind the opaque
    /// artwork itself, so it effectively colours the lower half of the card.
    private var cardBackground: some View {
        ZStack {
            model.panelColor
            if let art = model.artwork {
                Image(platformImage: art)
                    .resizable()
                    .scaledToFill()
                    .saturation(1.5)
                    // Overscan so the blur never shows darkened edges.
                    .scaleEffect(1.4)
                    .blur(radius: 60)
                    .overlay(Color.black.opacity(0.45))
            }
        }
    }

    /// Doubles as the first-run screen: with no address saved there is nothing
    /// to be "unreachable" yet, so say where to set one instead of showing a
    /// dead end.
    private var unreachableView: some View {
        VStack(spacing: 6) {
            Image(systemName: model.isConfigured ? "wifi.exclamationmark" : "hifispeaker.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.isConfigured ? "Speaker unreachable" : "No speaker set")
                .foregroundStyle(.secondary)
            Text(model.isConfigured
                 ? model.api.ip
                 : "Right-click the menu bar icon →\nSettings…")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 20)
    }

    private var standbyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "power")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Standby")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    private var artworkView: some View {
        Group {
            if let art = model.artwork {
                Image(platformImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: cardWidth, height: cardWidth)
        .clipped()
    }

    /// Display-only: the KEF HTTP API exposes play position read-only.
    /// With no track duration it renders as an all-grey separator line.
    /// Tinted with a light pastel of the artwork's own hue, like the iOS
    /// app; mono covers fall back to white.
    private var progressBar: some View {
        GeometryReader { geo in
            let length = model.displayLength ?? 0
            let fraction: CGFloat = length > 0 ? max(0, min(1, (model.displaySeek ?? 0) / length)) : 0
            let barTint = model.accentTint ?? .white
            ZStack(alignment: .leading) {
                Rectangle().fill(barTint.opacity(0.25))
                Rectangle().fill(barTint.opacity(0.9)).frame(width: geo.size.width * fraction)
            }
            .contentShape(Rectangle().inset(by: -8))   // easier to grab than 2 pt
            .gesture(model.displayCanSeek && length > 0 ? scrubGesture(width: geo.size.width, length: length) : nil)
        }
        .frame(height: 2)
    }

    /// Elapsed / remaining under the progress line, with the stream format as
    /// a bordered capsule centred between them — mirrors the iOS app.
    private var timeRow: some View {
        ZStack {
            HStack {
                Text(Self.timeLabel(model.displaySeek ?? 0))
                Spacer()
                if let length = model.displayLength {
                    Text("-" + Self.timeLabel(max(0, length - (model.displaySeek ?? 0))))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            // Centred between the timestamps, independent of their widths.
            if let format = model.audioFormatText, model.showsKEFStream {
                Text(format)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 1))
            }
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func scrubGesture(width: CGFloat, length: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.isScrubbing = true
                model.seek = max(0, min(1, value.location.x / width)) * length
            }
            .onEnded { value in
                let target = max(0, min(1, value.location.x / width)) * length
                model.isScrubbing = false
                model.seekTo(target)
            }
    }

    private var metadataView: some View {
        VStack(spacing: 3) {
            // 100 / 75 / 50 white — the same ramp as the iOS app.
            Text(model.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            if let artist = model.displayArtist {
                Text(artist)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let album = model.displayAlbum {
                Text(album)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transportView: some View {
        HStack(spacing: 28) {
            Button { model.control("previous") } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            Button { model.control("pause") } label: {
                Image(systemName: model.displayedIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            Button { model.control("next") } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.transportDisabled)
    }

    private var volumeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // Chevron + speaker form one tight group mirroring the number +
            // chevron group at the far right — same frames ([14][3][20] vs
            // [20][3][14]), same 3pt gap — so the row reads symmetrically and
            // the slider claims the freed width.
            HStack(spacing: 3) {
                // Mirrors the volume-presets chevron at the far right of this
                // row: same glyph, same size, pointing at the row it opens.
                // Only shown once stations are configured — otherwise it would
                // toggle a row that has nothing in it.
                if model.hasRadioSlots {
                    Button {
                        withAnimation(.easeInOut(duration: PanelAnim.duration)) {
                            model.showRadioRow.toggle()
                        }
                    } label: {
                        Image(systemName: model.showRadioRow ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.showRadioRow ? "Hide radio presets" : "Show radio presets")
                }
                Button { model.toggleMute() } label: {
                    Image(systemName: model.displayedMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body)
                        // Leading, as the mirror of the volume number's
                        // trailing alignment: each hugs its chevron.
                        .frame(width: 20, height: 20, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.displayedMuted ? .red : .secondary)
            }

            Button { model.setVolume(max(model.effectiveMinVolume, model.displayedVolume - 1)) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.volumeControlDisabled)

            Slider(
                value: Binding(
                    get: { Double(model.displayedVolume) },
                    set: { model.setVolume(Int($0)) }
                ),
                in: Double(model.effectiveMinVolume)...Double(max(model.effectiveMaxVolume, model.effectiveMinVolume + 1)),
                onEditingChanged: { model.isDraggingVolume = $0 }
            )
            .controlSize(.small)
            .tint(Color.appAccent)
            .disabled(model.volumeControlDisabled)

            Button { model.setVolume(min(model.effectiveMaxVolume, model.displayedVolume + 1)) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.volumeControlDisabled)

            Button {
                withAnimation(.easeInOut(duration: PanelAnim.duration)) {
                    model.showPresets.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    // Reserve two digits so the slider can't resize mid-drag as
                    // the value crosses 9→10. The old minWidth-40 on the whole
                    // block parked ~4pt of slack LEFT of the digits, which made
                    // the +→number gap visibly wider than the speaker→− gap.
                    Text("\(model.displayedVolume)")
                        .font(.body.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Image(systemName: model.showPresets ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.showPresets ? "Hide volume presets" : "Show volume presets")
            .disabled(model.volumeControlDisabled)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleSources, id: \.id) { src in
                sourceButton(src)
            }
            Spacer(minLength: 6)
            // Second EQ picker, alongside the one on the format line, to
            // compare the two placements. Sized for six inputs; with seven it
            // is the only flexible item here so it truncates rather than
            // overflowing.
            if !model.currentEqName.isEmpty {
                eqMenu(maxWidth: 78)
            }
            powerButton
        }
    }

    private var powerButton: some View {
        Button { model.togglePower() } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isStandby ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.appAccent))
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(model.isStandby ? "Wake speaker" : "Standby")
        .disabled(!model.reachable)
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(model.volumePresets, id: \.self) { preset in
                let active = model.displayedVolume == preset
                Button { model.setVolume(preset) } label: {
                    Text("\(preset)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(active ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(active ? Color.appAccent.opacity(0.18) : Color.white.opacity(0.07))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(preset > model.effectiveMaxVolume)
            }
        }
        .disabled(model.volumeControlDisabled)
    }

    private func eqMenu(maxWidth: CGFloat) -> some View {
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
            // Icons stay INSIDE the Text via interpolation: a standalone Image
            // in a Menu label gets tinted white by the menu style.
            // Chevron is size 9 semibold, matching the volume row's — the two
            // were once stacked and the sizes should stay in step.
            // NOTE when re-tuning position: .menuStyle(.borderlessButton)
            // carries its own trailing inset, which a plain-Text mock does NOT
            // reproduce. Measure with a real Menu or the answer is ~1.5pt out.
            Text("\(Image(systemName: "slider.horizontal.3")) \(model.currentEqName) \(Text(Image(systemName: "chevron.down")).font(.system(size: 9, weight: .semibold)))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        // Purely visual nudge — keeps the width negotiation above untouched.
        // Kept from when this sat under the volume row; it also reads correctly
        // against the power button, so it stays rather than shifting a layout
        // that was already signed off.
        .offset(x: 1.5, y: 0)
        .help("EQ profile")
    }


    /// Station artwork, fetched once per URL and kept for the app's lifetime.
    /// Slots are few and the icons tiny, so no eviction policy is warranted.
    @MainActor
    final class ArtworkCache: ObservableObject {
        static let shared = ArtworkCache()
        @Published private(set) var images: [String: PlatformImage] = [:]
        private var inFlight: Set<String> = []

        func image(for url: String) -> PlatformImage? {
            guard !url.isEmpty else { return nil }
            if let img = images[url] { return img }
            guard !inFlight.contains(url), let u = URL(string: url) else { return nil }
            inFlight.insert(url)
            Task { @MainActor in
                defer { inFlight.remove(url) }
                guard let (data, _) = try? await URLSession.shared.data(from: u),
                      let img = PlatformImage(data: data) else { return }
                images[url] = img
            }
            return nil
        }
    }

    /// Up to five radio stations, as artwork circles matching the volume-preset
    /// row's rhythm. Hidden entirely when no slot is set, so the panel is
    /// unchanged for anyone not using it.
    @ViewBuilder private var radioRow: some View {
        if model.hasRadioSlots && model.showRadioRow {
            // Fixed spacing, centred as a group: a full row of 7 lands
            // symmetrically edge to edge (7×30 + 6×10 = 270 of 272), and a
            // partial row stays a tight cluster in the middle rather than
            // spreading to the corners.
            HStack(spacing: 10) {
                ForEach(Array(model.radioSlots.enumerated()), id: \.offset) { i, slot in
                    if let station = slot {
                        radioButton(i, station)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func radioButton(_ index: Int, _ station: SpeakerModel.RadioStation) -> some View {
        let active = model.isPlayingRadio(station)
        return Button { model.playRadio(index) } label: {
            ZStack {
                Circle()
                    .fill(active ? Color.appAccent.opacity(0.26) : Color.white.opacity(0.11))
                if let art = artwork.image(for: station.iconURL) {
                    Image(platformImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .opacity(active ? 1 : 0.85)
                } else {
                    // Initials until the artwork arrives (or if it never does).
                    Text(Self.initials(station.title))
                        .font(.system(size: 11))
                        .foregroundStyle(active ? AnyShapeStyle(Color.appAccent)
                                               : AnyShapeStyle(.secondary))
                }
                if active {
                    Circle().strokeBorder(Color.appAccent, lineWidth: 1.5)
                }
            }
            .frame(width: 30, height: 30)
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

    /// Bundled template PNGs for inputs SF Symbols doesn't cover — Bluetooth's
    /// rune is a trademark, so there is no system symbol for it. The loading
    /// (and template tinting) lives in Platform.swift.
    private static let bundledGlyphs: [String: PlatformImage] = {
        var out: [String: PlatformImage] = [:]
        for (name, size) in [("bluetooth-glyph", CGSize(width: 12, height: 14))] {
            if let img = templateGlyph(named: name, size: size) { out[name] = img }
        }
        return out
    }()

    @ViewBuilder
    private func sourceIcon(_ src: SpeakerModel.Source) -> some View {
        if let glyph = src.glyph, let img = Self.bundledGlyphs[glyph] {
            Image(platformImage: img).renderingMode(.template)
        } else {
            Image(systemName: src.icon)
        }
    }

    private func sourceButton(_ src: SpeakerModel.Source) -> some View {
        let selected = model.source == src.id
        return Button { model.setSource(src.id) } label: {
            sourceIcon(src)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.secondary))
                // 24pt buys the room the bottom-row EQ picker needs: six inputs
                // at 28 leave only 54pt and the "Expert" label wants 68; at 24
                // there is 78pt. (Measured — scratchpad/eqfit.swift.)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.appAccent.opacity(0.18) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(src.name)
        .disabled(!model.reachable)
    }
}
