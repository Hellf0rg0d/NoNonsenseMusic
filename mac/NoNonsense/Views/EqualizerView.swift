import SwiftUI

/// Settings › Playback › Equalizer: the switch, a preset, and the 14 bands. A band you move makes the curve Custom;
/// double-click a band to put it back to 0 dB.
struct EqualizerSection: View {
    private var eq: Equalizer { .shared }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { eq.on }, set: { eq.setOn($0) })) {
                Text("Equalizer")
                Text("Uses about 0.1% of one core while music plays, and nothing while it is off.")
                    .foregroundStyle(.secondary)
            }
            .selfTestFrame("eq.switch")
            if eq.on {
                Picker("Preset", selection: Binding(get: { eq.preset }, set: { eq.choose($0) })) {
                    ForEach(Equalizer.Preset.allCases) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                EqualizerBands()
            }
        } header: {
            Text("Equalizer")
        } footer: {
            Text(Leveller.shared.limiting ? "Boosts keep their volume. The limiter, above, catches the peaks."
                                          : "A boost lowers the whole song by as much, so nothing clips. The limiter, above, avoids that.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The 14 bands side by side, each a vertical slider from −12 to +12 dB with its frequency under it.
private struct EqualizerBands: View {
    private var eq: Equalizer { .shared }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Equalizer.bands.indices, id: \.self) { band in
                VStack(spacing: 4) {
                    Text(Self.decibels(eq.gains[band]))
                        .textStyle(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    BandSlider(value: eq.gains[band]) { eq.set(band: band, to: $0) }
                        .frame(height: 120)
                        .help("\(Self.frequency(Equalizer.bands[band])): \(Self.decibels(eq.gains[band])) dB")
                        .accessibilityLabel(Self.frequency(Equalizer.bands[band]))
                        .accessibilityValue("\(Self.decibels(eq.gains[band])) decibels")
                        .accessibilityAdjustableAction { direction in
                            eq.set(band: band, to: eq.gains[band] + (direction == .increment ? 0.5 : -0.5))
                        }
                    Text(Self.frequency(Equalizer.bands[band]))
                        .textStyle(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .selfTestFrame("eq.bands")
    }

    /// "31", "1.25k", "3.15k", "12.5k": the band's centre in full (two digits read 1250 Hz as "1.2k", 28 Oct).
    static func frequency(_ hz: Double) -> String {
        guard hz >= 1000 else { return "\(Int(hz))" }
        var text = String(format: "%.2f", hz / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "k"
    }

    static func decibels(_ gain: Double) -> String {
        gain == 0 ? "0" : String(format: gain.truncatingRemainder(dividingBy: 1) == 0 ? "%+.0f" : "%+.1f", gain)
    }
}

/// One band: a thin track with a line at 0 dB and a knob, dragged up or down. Double-click: back to 0 dB.
private struct BandSlider: View {
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height, range = Equalizer.range
            let place = (1 - (value - range.lowerBound) / (range.upperBound - range.lowerBound)) * height
            ZStack(alignment: .top) {
                Capsule().fill(.quaternary).frame(width: 4)
                Rectangle().fill(.tertiary).frame(width: 12, height: 1).offset(y: height / 2)
                Capsule().fill(.tint)
                    .frame(width: 4, height: abs(place - height / 2))
                    .offset(y: min(place, height / 2))
                Circle().fill(.white).shadow(radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .offset(y: place - 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let share = 1 - min(max(drag.location.y / height, 0), 1)
                set(range.lowerBound + share * (range.upperBound - range.lowerBound))
            })
            .onTapGesture(count: 2) { set(0) }
        }
    }
}

/// Settings › Playback › Headphones: the model chosen for correction (HeadphoneCorrection), and the picker.
struct HeadphoneSection: View {
    private var correction: HeadphoneCorrection { .shared }
    @State private var picking = false

    var body: some View {
        Section {
            LabeledContent {
                Button(correction.model == nil ? "Choose…" : "Change…") { picking = true }
            } label: {
                Text(correction.model?.name ?? "No correction")
                if let model = correction.model {
                    Text("Measured by \(model.measuredBy), \(correction.filters.count) filters").foregroundStyle(.secondary)
                }
            }
            if correction.model != nil {
                Button("Turn off correction") { Task { await correction.choose(nil) } }
            }
            if let problem = correction.problem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Headphones")
        } footer: {
            Text("Evens out your headphones' sound. Corrections are AutoEq's, fetched from GitHub when you pick a model. Your equalizer applies on top.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $picking) { HeadphonePicker(done: { picking = false }) }
    }
}

private struct HeadphonePicker: View {
    let done: () -> Void
    private var correction: HeadphoneCorrection { .shared }
    @State private var typed = ""

    private var shown: [HeadphoneCorrection.Model] {
        let words = typed.lowercased().split(separator: " ")
        let all = words.isEmpty ? correction.models
                                : correction.models.filter { model in words.allSatisfy { model.name.lowercased().contains($0) } }
        return Array(all.prefix(200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your headphones").font(.headline)
            TextField("Search 6,000 models", text: $typed)
                .textFieldStyle(.roundedBorder)
            if correction.loading && correction.models.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = correction.problem, correction.models.isEmpty {
                Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { model in
                    Button {
                        Task {
                            await correction.choose(model)
                            if correction.problem == nil { done() }
                        }
                    } label: {
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text(model.measuredBy).foregroundStyle(.secondary)
                            if model == correction.model { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                if correction.loading && !correction.models.isEmpty { ProgressView().controlSize(.small) }
                if let problem = correction.problem, !correction.models.isEmpty { Text(problem).foregroundStyle(.red) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 460, height: 480)
        .task { await correction.loadModels() }
    }
}
