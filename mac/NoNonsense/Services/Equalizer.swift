import Foundation
import Observation

/// Settings › Playback › Equalizer (#37): 14 bands, off by default. On, every song's audio passes through the sound
/// chain's tap (SoundChain): one peaking filter per band that is not at 0 dB, in Accelerate's biquad cascade, then a
/// preamp that lowers the whole curve by its own peak, so a boost never clips. Off, it adds nothing to the chain. Stored
/// as the Windows and Android apps will store it: on or off, and 14 gains in dB.
@MainActor
@Observable
final class Equalizer {
    static let shared = Equalizer()

    /// The bands' centres, in Hz: two-thirds of an octave apart, from the lowest bass to the top of what most people hear.
    nonisolated static let bands: [Double] = [31, 50, 80, 125, 200, 315, 500, 800, 1250, 2000, 3150, 5000, 8000, 12500]
    nonisolated static let range = -12.0 ... 12.0

    enum Preset: String, CaseIterable, Identifiable {
        case flat, bassBoost, vocal, treble, custom
        var id: String { rawValue }
        var name: String {
            switch self { case .flat: "Flat"; case .bassBoost: "Bass Boost"; case .vocal: "Vocal"; case .treble: "Treble"; case .custom: "Custom" }
        }
        /// The gains, band by band; Custom has none of its own (it is whatever you set).
        var gains: [Double]? {
            switch self {
            case .flat: Array(repeating: 0, count: 14)
            case .bassBoost: [6, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]
            case .vocal: [-2, -2, -1, 0, -1, 0, 1, 2, 3, 3.5, 3, 1.5, 0, 0]
            case .treble: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 1.5, 3, 4.5, 5.5]
            case .custom: nil
            }
        }
    }

    private(set) var on: Bool
    private(set) var gains: [Double]
    private(set) var preset: Preset

    /// SoundChain: on or off, the playing song's tap is attached or taken away.
    @ObservationIgnored var changed: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        on = defaults.bool(forKey: "eqOn")
        let saved = (defaults.array(forKey: "eqGains") as? [Double]) ?? []
        gains = saved.count == Self.bands.count ? saved.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) }
                                                : Array(repeating: 0, count: Self.bands.count)
        preset = Preset(rawValue: defaults.string(forKey: "eqPreset") ?? "") ?? .flat
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        UserDefaults.standard.set(value, forKey: "eqOn")
        changed?()
    }

    func choose(_ chosen: Preset) {
        preset = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: "eqPreset")
        if let values = chosen.gains { store(values) }
    }

    /// One band moved: the curve is yours now (Custom).
    func set(band: Int, to gain: Double) {
        guard Self.bands.indices.contains(band) else { return }
        var values = gains
        values[band] = (min(max(gain, Self.range.lowerBound), Self.range.upperBound) * 2).rounded() / 2   // 0.5 dB steps
        guard values != gains else { return }
        if preset != .custom { preset = .custom; UserDefaults.standard.set(Preset.custom.rawValue, forKey: "eqPreset") }
        store(values)
    }

    private func store(_ values: [Double]) {
        gains = values
        UserDefaults.standard.set(values, forKey: "eqGains")
        SoundChain.shared.equalizerChanged(values)
    }
}
