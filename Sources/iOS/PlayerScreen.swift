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

    private let margin: CGFloat = 24

    var body: some View {
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
                Spacer(minLength: 8)
                artworkCard
                Spacer(minLength: 20)
                metadata
                scrubber
                    .padding(.top, 16)
                transport
                    .padding(.top, 4)
                volumeRow
                    .padding(.top, 4)
                presetRow
                radioRow
                Spacer(minLength: 12)
            }
            bottomBar
        }
        .padding(.horizontal, margin)
        .sensoryFeedback(.impact(weight: .light), trigger: model.isPlaying)
    }

    // MARK: artwork

    private var artworkCard: some View {
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
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        // Paused artwork recedes — the Apple Music gesture vocabulary.
        .scaleEffect(model.displayedIsPlaying ? 1 : 0.82)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: model.displayedIsPlaying)
    }

    // MARK: metadata

    private var metadata: some View {
        VStack(spacing: 3) {
            Text(model.displayTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if let artist = model.displayArtist {
                Text(artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let album = model.displayAlbum {
                Text(album)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
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
                    .padding(.top, 4)
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

    /// Native-feeling scrubber: a capsule that thickens under the finger,
    /// elapsed/remaining labels underneath. Read-only (no thickening, no
    /// gesture) when the source can't seek — Roon RAAT rejects the command.
    private var scrubber: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.8))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: model.isScrubbing ? 10 : 6)
                .frame(maxHeight: .infinity)   // vertical centre of the hit area
                .animation(.easeOut(duration: 0.15), value: model.isScrubbing)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: 30)   // whole strip is the touch target
            HStack {
                Text(timeLabel(scrubTarget ?? model.displaySeek ?? 0))
                Spacer()
                if let length = model.displayLength {
                    Text("-" + timeLabel(max(0, length - (scrubTarget ?? model.displaySeek ?? 0))))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
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

    private var transport: some View {
        HStack {
            Spacer()
            Button { model.control("previous") } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button { model.control("pause") } label: {
                Image(systemName: model.displayedIsPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { model.control("next") } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(model.transportDisabled)
        .opacity(model.transportDisabled ? 0.4 : 1)
    }

    // MARK: volume

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.displayedVolume) },
                    set: { model.setVolume(Int($0)) }
                ),
                in: Double(model.effectiveMinVolume)...Double(max(model.effectiveMaxVolume,
                                                                  model.effectiveMinVolume + 1)),
                onEditingChanged: { model.isDraggingVolume = $0 }
            )
            .tint(.white.opacity(0.85))
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(model.displayedVolume)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
                // The number doubles as the mute toggle: red when muted.
                .foregroundStyle(model.displayedMuted ? .red : .secondary)
                .onTapGesture { model.toggleMute() }
        }
        .disabled(model.volumeControlDisabled)
    }

    private var presetRow: some View {
        Group {
            if !model.volumePresets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.volumePresets, id: \.self) { preset in
                        let active = model.displayedVolume == preset
                        Button { model.setVolume(preset) } label: {
                            Text("\(preset)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(active ? AnyShapeStyle(Color.appAccent)
                                                        : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(
                                    Capsule().fill(active ? Color.appAccent.opacity(0.22)
                                                          : Color.white.opacity(0.08))
                                )
                                .contentShape(Capsule())
                        }
                        .disabled(preset > model.effectiveMaxVolume)
                    }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: model.displayedVolume)
                .padding(.top, 14)
                .disabled(model.volumeControlDisabled)
            }
        }
    }

    // MARK: radio

    private var radioRow: some View {
        Group {
            if model.hasRadioSlots {
                HStack(spacing: 12) {
                    ForEach(Array(model.radioSlots.enumerated()), id: \.offset) { i, slot in
                        if let station = slot {
                            radioButton(i, station)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
        }
    }

    private func radioButton(_ index: Int, _ station: SpeakerModel.RadioStation) -> some View {
        let active = model.isPlayingRadio(station)
        return Button { model.playRadio(index) } label: {
            ZStack {
                Circle().fill(active ? Color.appAccent.opacity(0.26) : Color.white.opacity(0.1))
                if let art = artworkCache.image(for: station.iconURL) {
                    Image(platformImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .opacity(active ? 1 : 0.85)
                } else {
                    Text(Self.initials(station.title))
                        .font(.footnote)
                        .foregroundStyle(active ? AnyShapeStyle(Color.appAccent)
                                                : AnyShapeStyle(.secondary))
                }
                if active {
                    Circle().strokeBorder(Color.appAccent, lineWidth: 1.5)
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
            ForEach(model.visibleSources, id: \.id) { src in
                sourceButton(src)
            }
            Spacer(minLength: 8)
            if !model.currentEqName.isEmpty {
                eqMenu
            }
            powerButton
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: model.source)
    }

    private func sourceButton(_ src: SpeakerModel.Source) -> some View {
        let selected = model.source == src.id
        return Button { model.setSource(src.id) } label: {
            Group {
                if let glyph = src.glyph, let img = templateGlyph(named: glyph,
                                                                 size: CGSize(width: 15, height: 18)) {
                    Image(platformImage: img).renderingMode(.template)
                } else {
                    Image(systemName: src.icon)
                }
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.secondary))
            .frame(width: 40, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.appAccent.opacity(0.18) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!model.reachable)
    }

    private var eqMenu: some View {
        Menu {
            ForEach(model.eqProfiles) { profile in
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
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(model.currentEqName)
                    .lineLimit(1)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(height: 44)
            .frame(maxWidth: 110, alignment: .trailing)
        }
    }

    private var powerButton: some View {
        Button { model.togglePower() } label: {
            Image(systemName: "power")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(model.isStandby ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(Color.appAccent))
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
