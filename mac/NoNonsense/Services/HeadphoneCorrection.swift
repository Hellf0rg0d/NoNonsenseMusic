import Foundation
import Observation

/// Settings › Playback › Headphones (28 Oct): your headphones' measured flaws corrected, from AutoEq
/// (github.com/jaakkopasanen/AutoEq, MIT): for 6,000 models, filters that bring a measurement by crinacle, oratory1990,
/// Rtings and others to a neutral target. The list (its recommended results) is fetched from GitHub when the picker
/// first opens and kept in the cache; the chosen model's filters are fetched once and kept in settings. Nothing is
/// bundled: the measurements are their measurers', and AutoEq states no terms for them. The filters run in the sound
/// chain's cascade, before the equalizer's.
@MainActor
@Observable
final class HeadphoneCorrection {
    static let shared = HeadphoneCorrection()

    struct Model: Hashable, Identifiable, Codable {
        let name: String        // "Apple AirPods Pro"
        let path: String        // "crinacle/711%20in-ear/Apple%20AirPods%20Pro", as the index links it
        var id: String { path }
        var measuredBy: String { path.split(separator: "/").first.map { $0.removingPercentEncoding ?? String($0) } ?? "" }
    }

    private struct Saved: Codable { let model: Model; let filters: [CorrectionFilter] }

    private(set) var model: Model?
    private(set) var filters: [CorrectionFilter] = []
    /// The models to choose from, once fetched.
    private(set) var models: [Model] = []
    private(set) var loading = false
    private(set) var problem: String?

    static let base = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!

    private init() {
        if let data = UserDefaults.standard.data(forKey: "headphoneCorrection"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            model = saved.model
            filters = saved.filters
        }
    }

    /// The picker opened: the list, from the cache or GitHub.
    func loadModels() async {
        guard models.isEmpty, !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        let cached = AudioCache.shared.folder.deletingLastPathComponent().appending(path: "autoeq-index.md")
        var text = try? String(contentsOf: cached, encoding: .utf8)
        if text == nil {
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.base.appending(path: "README.md"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                text = String(decoding: data, as: UTF8.self)
                try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cached)
            } catch {
                problem = "Couldn't reach GitHub for the list of headphones."
                return
            }
        }
        models = Self.models(in: text ?? "")
    }

    /// "- [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro)" lines of AutoEq's recommended results.
    nonisolated static func models(in index: String) -> [Model] {
        index.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- ["), let close = line.range(of: "](./"), line.hasSuffix(")") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let path = String(line[close.upperBound..<line.index(before: line.endIndex)])
            return name.isEmpty || path.isEmpty ? nil : Model(name: name, path: path)
        }
    }

    /// Fetches the model's filters and uses them; nil turns the correction off.
    func choose(_ chosen: Model?) async {
        problem = nil
        guard let chosen else {
            model = nil
            filters = []
            UserDefaults.standard.removeObject(forKey: "headphoneCorrection")
            SoundChain.shared.settingChanged()
            return
        }
        let file = (chosen.path.removingPercentEncoding ?? chosen.path) + "/" + (chosen.path.split(separator: "/").last
            .flatMap { $0.removingPercentEncoding } ?? chosen.name) + " ParametricEQ.txt"
        loading = true
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.base.appending(path: file))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let parsed = CorrectionFilter.parse(String(decoding: data, as: UTF8.self))
            guard !parsed.isEmpty else { problem = "AutoEq has no filters for \(chosen.name)."; return }
            use(chosen, parsed)
        } catch {
            problem = "Couldn't fetch the correction for \(chosen.name)."
        }
    }

    private func use(_ chosen: Model, _ parsed: [CorrectionFilter]) {
        model = chosen
        filters = parsed
        UserDefaults.standard.set(try? JSONEncoder().encode(Saved(model: chosen, filters: parsed)), forKey: "headphoneCorrection")
        SoundChain.shared.settingChanged()
    }

    #if DEBUG
    /// Self-tests: a correction used without fetching it.
    func useForTests(_ chosen: Model?, _ parsed: [CorrectionFilter]) {
        if let chosen { use(chosen, parsed) } else { Task { await choose(nil) } }
    }
    #endif
}

/// One of AutoEq's filters: "Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70". Peaking and shelves, as Robert
/// Bristow-Johnson's Audio EQ Cookbook defines them (the shelves by their Q), which is how AutoEq computes its curves.
nonisolated struct CorrectionFilter: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case peak = "PK", lowShelf = "LSC", highShelf = "HSC" }
    let kind: Kind
    let frequency: Double
    let gain: Double
    let q: Double

    /// The ON filters of a ParametricEQ.txt (its Preamp line is not used: the chain finds the curve's peak itself).
    static func parse(_ text: String) -> [CorrectionFilter] {
        text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ").map(String.init)
            guard words.first == "Filter", words.count >= 12, words[2] == "ON", let kind = Kind(rawValue: words[3]),
                  let frequency = Double(words[5]), let gain = Double(words[8]), let q = Double(words[11]),
                  frequency > 0, q > 0 else { return nil }
            return CorrectionFilter(kind: kind, frequency: frequency, gain: gain, q: q)
        }
    }

    /// b0, b1, b2, a1, a2 normalised by a0, as vDSP's biquad takes them; none at or above the Nyquist frequency.
    func coefficients(sampleRate rate: Double) -> [Double] {
        guard frequency < rate / 2 * 0.95, abs(gain) >= 0.05 else { return [] }
        // one typed step at a time: Xcode 26.6 (CI) times out on long arithmetic in one expression
        let a: Double = pow(10, gain / 40)
        let w: Double = 2 * Double.pi * frequency / rate
        let c: Double = cos(w)
        let alpha: Double = sin(w) / (2 * q)
        let r: Double = 2 * a.squareRoot() * alpha
        let up: Double = a + 1, down: Double = a - 1
        var b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a
        case .lowShelf:
            b0 = a * (up - down * c + r); b1 = 2 * a * (down - up * c); b2 = a * (up - down * c - r)
            a0 = up + down * c + r; a1 = -2 * (down + up * c); a2 = up + down * c - r
        case .highShelf:
            b0 = a * (up + down * c + r); b1 = -2 * a * (down + up * c); b2 = a * (up + down * c - r)
            a0 = up - down * c + r; a1 = 2 * (down - up * c); a2 = up - down * c - r
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}
