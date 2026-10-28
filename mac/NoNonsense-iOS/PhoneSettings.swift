import SwiftUI

/// Sound (the same chain and settings as the Mac app's), the server, and your account.
struct PhoneSettings: View {
    @Environment(Account.self) private var account
    @Environment(Player.self) private var player
    @AppStorage("gapless") private var gapless = false
    @AppStorage("crossfeed") private var crossfeed = false
    @AppStorage("crossfadeSeconds") private var crossfade = 0.0
    @AppStorage("vocalClarity") private var vocalClarity = 0.0
    @AppStorage("loudnessCompensation") private var loudness = false
    private var leveller: Leveller { .shared }
    private var profiles: SoundProfiles { .shared }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { leveller.on }, set: { leveller.setOn($0) })) {
                    Text("Same volume for every song")
                    Text("Measures each song once, then plays it as loud as the rest.")
                }
                Toggle(isOn: Binding(get: { leveller.limiting }, set: { leveller.setLimiting($0) })) {
                    Text("Limiter")
                    Text("Equalizer boosts and quiet songs keep their volume; only peaks that would distort are caught.")
                }
                Toggle(isOn: $gapless) {
                    Text("No gaps between songs")
                    Text("Albums and mixes flow on without a pause.")
                }
                .onChange(of: gapless) { _, _ in player.gaplessChanged() }
                Picker("Crossfade", selection: $crossfade) {
                    Text("Off").tag(0.0)
                    ForEach([2.0, 4, 6, 8, 12], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                .onChange(of: crossfade) { _, _ in SoundChain.shared.settingChanged() }
                Toggle(isOn: $crossfeed) {
                    Text("Crossfeed for headphones")
                    Text("A little of each side's bass reaches the other ear, as from speakers.")
                }
                .onChange(of: crossfeed) { _, _ in SoundChain.shared.settingChanged() }
                Toggle(isOn: $loudness) {
                    Text("Fuller sound at low volume")
                    Text("Adds back the bass and treble your ears lose when the volume is down.")
                }
                .onChange(of: loudness) { _, _ in SoundChain.shared.loudnessChanged() }
                VStack(alignment: .leading) {
                    Text("Vocal clarity: " + (vocalClarity > 0 ? String(format: "+%g dB", vocalClarity) : "off"))
                    Slider(value: $vocalClarity, in: 0...6, step: 0.5)
                }
                .onChange(of: vocalClarity) { old, new in
                    if (old > 0) != (new > 0) { SoundChain.shared.settingChanged() } else { SoundChain.shared.vocalClarityChanged() }
                }
            } header: {
                Text("Sound")
            }

            Section {
                Toggle(isOn: Binding(get: { profiles.on }, set: { profiles.setOn($0) })) {
                    Text("Sound for each output")
                    Text(profiles.on ? "Now: \(profiles.output?.name ?? "this output"). AirPods, a cable and the speaker each keep their own."
                                     : "The same for every output.")
                }
                NavigationLink { HeadphonePicker() } label: {
                    LabeledContent("Headphone correction", value: HeadphoneCorrection.shared.model?.name ?? "None")
                }
                NavigationLink { EqualizerScreen() } label: {
                    LabeledContent("Equalizer", value: Equalizer.shared.on ? Equalizer.shared.preset.name : "Off")
                }
            } header: {
                Text("Equalizer and headphones")
            }

            Section {
                LabeledContent("Server", value: API.baseURL.host() ?? API.baseURL.absoluteString)
                LabeledContent("Signed in as", value: account.user?.username ?? "")
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
            } header: {
                Text("Account")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .navigationTitle("Settings")
    }
}

/// The 14 bands, a slider each, and the presets.
struct EqualizerScreen: View {
    private var eq: Equalizer { .shared }

    var body: some View {
        Form {
            Toggle("Equalizer", isOn: Binding(get: { eq.on }, set: { eq.setOn($0) }))
            if eq.on {
                Picker("Preset", selection: Binding(get: { eq.preset }, set: { eq.choose($0) })) {
                    ForEach(Equalizer.Preset.allCases) { Text($0.name).tag($0) }
                }
                Section {
                    ForEach(Equalizer.bands.indices, id: \.self) { band in
                        HStack {
                            Text(Self.frequency(Equalizer.bands[band])).frame(width: 52, alignment: .leading).monospacedDigit()
                            Slider(value: Binding(get: { eq.gains[band] }, set: { eq.set(band: band, to: $0) }), in: Equalizer.range)
                            Text(String(format: "%+.1f", eq.gains[band])).frame(width: 44, alignment: .trailing).monospacedDigit()
                        }
                        .font(.footnote)
                    }
                } footer: {
                    Text(Leveller.shared.limiting ? "A boost keeps its volume: the limiter catches the peaks."
                                                  : "A boost turns the rest of the song down by as much, so nothing distorts.")
                }
            }
        }
        .navigationTitle("Equalizer")
    }

    /// "31 Hz", "1.25k", "12.5k".
    static func frequency(_ hz: Double) -> String {
        guard hz >= 1000 else { return "\(Int(hz)) Hz" }
        var text = String(format: "%.2f", hz / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "k"
    }
}

/// AutoEq's models, searched; one chosen is fetched and used.
struct HeadphonePicker: View {
    @Environment(\.dismiss) private var dismiss
    private var correction: HeadphoneCorrection { .shared }
    @State private var typed = ""

    var body: some View {
        let words = typed.lowercased().split(separator: " ")
        let shown = (words.isEmpty ? correction.models
                     : correction.models.filter { m in words.allSatisfy { m.name.lowercased().contains($0) } }).prefix(200)
        List {
            if correction.model != nil {
                Button("No correction", role: .destructive) { Task { await correction.choose(nil); dismiss() } }
            }
            if let problem = correction.problem { Text(problem).foregroundStyle(.red) }
            ForEach(Array(shown)) { model in
                Button {
                    Task {
                        await correction.choose(model)
                        if correction.problem == nil { dismiss() }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text("Measured by \(model.measuredBy)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model == correction.model { Image(systemName: "checkmark") }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .overlay { if correction.loading && correction.models.isEmpty { ProgressView() } }
        .searchable(text: $typed, prompt: "Search 6,000 headphones")
        .navigationTitle("Headphones")
        .task { await correction.loadModels() }
    }
}
