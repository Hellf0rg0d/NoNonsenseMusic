import Accelerate
import AVFoundation
import MediaToolbox
import Observation
import os

/// Settings › Playback › Equalizer (#37): 14 bands, off by default. On, every song's audio passes through an audio
/// processing tap on its AVPlayerItem: one peaking filter per band that is not at 0 dB, in Accelerate's biquad cascade,
/// then a preamp that lowers the whole curve by its own peak, so a boost never clips. Off, no tap is attached at all, and
/// it costs nothing. Stored as the Windows and Android apps will store it: on or off, and 14 gains in dB.
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

    /// Player.equalizerChanged: on or off, the playing song's tap is attached or taken away.
    @ObservationIgnored var changed: (() -> Void)?
    /// The taps of the songs loaded now, told of every change of gains.
    @ObservationIgnored private var processors: [WeakProcessor] = []

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
        processors.removeAll { $0.processor == nil }
        for weak in processors { weak.processor?.update(gains: values) }
    }

    /// The tap for `item` when the equalizer is on (none when off): attached once its audio track is known. Each item
    /// has its own filters' state; all follow the same gains.
    func apply(to item: AVPlayerItem) {
        guard on else { item.audioMix = nil; return }
        let processor = EQProcessor(gains: gains)
        processors.removeAll { $0.processor == nil }
        processors.append(WeakProcessor(processor: processor))
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first, on,
                  let tap = processor.makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    #if DEBUG
    /// Self-tests: the taps alive now.
    var liveProcessors: [EQProcessor] { processors.compactMap(\.processor) }
    #endif
}

private struct WeakProcessor { weak var processor: EQProcessor? }

/// The filters of one item's tap. `update` (the main thread) builds a new cascade and swaps it in under the lock;
/// `process` (the audio thread) holds the lock for one buffer, so a cascade is never freed while in use.
nonisolated final class EQProcessor: @unchecked Sendable {
    /// Each band's width: two-thirds of an octave (Q = √2^N / (2^N − 1), N = 2/3).
    static let q = sqrt(pow(2, 2.0 / 3)) / (pow(2, 2.0 / 3) - 1)

    private let lock = OSAllocatedUnfairLock()
    private var gains: [Double]
    private var sampleRate = 44_100.0
    private var channels = 0
    private var usable = false                     // Float32, one buffer per channel: what AVFoundation's taps give
    private var cascade: Cascade?

    init(gains: [Double]) { self.gains = gains }

    /// The filters of one sample rate: the biquad setup, each channel's delay line, and the preamp.
    final class Cascade {
        let setup: vDSP_biquad_Setup
        let sections: Int
        let delays: [UnsafeMutablePointer<Float>]
        var preamp: Float
        init?(coefficients: [Double], sections: Int, channels: Int, preamp: Float) {
            guard sections > 0, let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections)) else { return nil }
            self.setup = setup
            self.sections = sections
            self.preamp = preamp
            delays = (0..<channels).map { _ in
                let line = UnsafeMutablePointer<Float>.allocate(capacity: 2 * sections + 2)
                line.initialize(repeating: 0, count: 2 * sections + 2)
                return line
            }
        }
        deinit {
            vDSP_biquad_DestroySetup(setup)
            delays.forEach { $0.deallocate() }
        }
    }

    /// Peaking filters (Robert Bristow-Johnson's Audio EQ Cookbook), normalised by a0, as vDSP takes them: b0, b1, b2,
    /// a1, a2 per band, for each band not at 0 dB and below the Nyquist frequency.
    static func coefficients(gains: [Double], sampleRate: Double) -> [Double] {
        var out: [Double] = []
        for (centre, gain) in zip(Equalizer.bands, gains) where abs(gain) >= 0.05 && centre < sampleRate / 2 * 0.95 {
            let a = pow(10, gain / 40), w = 2 * .pi * centre / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha / a
            out += [(1 + alpha * a) / a0, -2 * c / a0, (1 - alpha * a) / a0, -2 * c / a0, (1 - alpha / a) / a0]
        }
        return out
    }

    /// The cascade's loudest point, in dB (0 for a curve with no boost), read at 240 frequencies from 20 Hz to 20 kHz:
    /// bands next to each other add up, so the peak can be above the highest band's own gain.
    static func peak(coefficients: [Double], sampleRate: Double) -> Double {
        var loudest = 0.0
        for i in 0..<240 {
            let f = 20 * pow(1000, Double(i) / 239), w = 2 * .pi * min(f, sampleRate / 2) / sampleRate
            var magnitude = 1.0
            for s in stride(from: 0, to: coefficients.count, by: 5) {
                let (b0, b1, b2, a1, a2) = (coefficients[s], coefficients[s + 1], coefficients[s + 2], coefficients[s + 3], coefficients[s + 4])
                func size(_ k0: Double, _ k1: Double, _ k2: Double) -> Double {
                    let re = k0 + k1 * cos(w) + k2 * cos(2 * w), im = -(k1 * sin(w) + k2 * sin(2 * w))
                    return (re * re + im * im).squareRoot()
                }
                magnitude *= size(b0, b1, b2) / size(1, a1, a2)
            }
            loudest = max(loudest, 20 * log10(magnitude))
        }
        return loudest
    }

    func update(gains: [Double]) {
        let (rate, count) = lock.withLockUnchecked { () -> (Double, Int) in
            self.gains = gains
            return (sampleRate, channels)
        }
        install(Self.build(gains: gains, sampleRate: rate, channels: count))
    }

    /// The tap's prepare: the format is known now.
    fileprivate func prepare(format: AudioStreamBasicDescription) {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let separate = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 || format.mChannelsPerFrame == 1
        let current = lock.withLockUnchecked { () -> [Double] in
            sampleRate = format.mSampleRate
            channels = Int(format.mChannelsPerFrame)
            usable = float && separate
            return gains
        }
        install(Self.build(gains: current, sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame)))
    }

    private static func build(gains: [Double], sampleRate: Double, channels: Int) -> Cascade? {
        guard channels > 0 else { return nil }
        let coefficients = coefficients(gains: gains, sampleRate: sampleRate)
        let preamp = Float(pow(10, -peak(coefficients: coefficients, sampleRate: sampleRate) / 20))
        return Cascade(coefficients: coefficients, sections: coefficients.count / 5, channels: channels, preamp: preamp)
    }

    /// Swapped in under the lock; the old one is let go here, never on the audio thread.
    private func install(_ new: Cascade?) {
        let old = lock.withLockUnchecked { () -> Cascade? in
            let old = cascade
            cascade = new
            return old
        }
        _ = old
    }

    /// The audio thread: each channel's buffer through the cascade, in place, then the preamp. A flat curve (no cascade)
    /// leaves the audio untouched.
    fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.withLockUnchecked {
            #if DEBUG
            measure(buffers, frames: frames, into: &energyIn)
            #endif
            if usable, let cascade, buffers.count == cascade.delays.count {
                for (buffer, delay) in zip(buffers, cascade.delays) {
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    vDSP_biquad(cascade.setup, delay, samples, 1, samples, 1, vDSP_Length(frames))
                    var gain = cascade.preamp
                    vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
                }
            }
            #if DEBUG
            measure(buffers, frames: frames, into: &energyOut)
            processedFrames += frames
            #endif
        }
    }

    #if DEBUG
    /// Self-tests: frames through the tap, and the audio's energy (sum of squares) before and after the filters.
    private var energyIn = 0.0, energyOut = 0.0, processedFrames = 0
    private func measure(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, into total: inout Double) {
        for buffer in buffers {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var sum: Float = 0
            vDSP_svesq(samples, 1, &sum, vDSP_Length(frames))
            total += Double(sum)
        }
    }
    /// Frames so far, and the change in loudness since the last reading in dB (nil before any audio), then starts over.
    func takeReading() -> (frames: Int, change: Double?) {
        lock.withLockUnchecked {
            defer { energyIn = 0; energyOut = 0 }
            let change = energyIn > 0 && energyOut > 0 ? 10 * log10(energyOut / energyIn) : nil
            return (processedFrames, change)
        }
    }

    /// Self-tests: `seconds` of a sine at `frequency`, through these filters as the tap would run them, and the change
    /// in loudness in dB (no audio device involved).
    func offline(frequency: Double, sampleRate rate: Double = 44_100, seconds: Double = 1) -> Double {
        let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        prepare(format: format)
        _ = takeReading()
        let frames = Int(rate * seconds)
        var samples = (0..<frames).map { Float(0.25 * sin(2 * .pi * frequency * Double($0) / rate)) }
        samples.withUnsafeMutableBufferPointer { pointer in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            for start in stride(from: 0, to: frames, by: 1024) {          // as the tap is called: a buffer at a time
                let count = min(1024, frames - start)
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: pointer.baseAddress! + start)
                if start == frames / 2 { _ = takeReading() }               // the second half: the filters have settled
                process(list, frames: count)
            }
        }
        return takeReading().change ?? 0
    }
    #endif

    /// The tap that runs these filters (MTAudioProcessingTap); it holds this processor until it is let go.
    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: eqTapInit, finalize: eqTapFinalize, prepare: eqTapPrepare, unprepare: nil, process: eqTapProcess)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
                                         &tap) == noErr else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        return tap
    }
}

// The tap's callbacks, called by MediaToolbox on its own threads: C functions, with the processor as the tap's storage.

private nonisolated func eqTapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                                   _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storage.pointee = clientInfo
}

private nonisolated func eqTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<EQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private nonisolated func eqTapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                                      _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<EQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format: format.pointee)
}

private nonisolated func eqTapProcess(_ tap: MTAudioProcessingTap, _ frames: CMItemCount, _ flags: MTAudioProcessingTapFlags,
                                      _ buffers: UnsafeMutablePointer<AudioBufferList>, _ framesOut: UnsafeMutablePointer<CMItemCount>,
                                      _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    Unmanaged<EQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
}
