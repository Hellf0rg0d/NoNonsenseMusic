import Accelerate
import AVFoundation
import MediaToolbox
import os

/// What happens to a song's audio between its file and the speakers: one audio processing tap per AVPlayerItem, which
/// runs the equalizer's filters (Equalizer), then one gain: the equalizer's preamp times the song's levelling gain
/// (Leveller). Attached only while one of them is on; with both off a song has no tap and costs nothing.
@MainActor
final class SoundChain {
    static let shared = SoundChain()

    /// Player: the playing song's tap is attached again (or taken away) after a switch.
    var changed: (() -> Void)?
    /// The taps of the songs loaded now, with their copies' keys.
    private var processors: [(key: String, processor: Weak)] = []
    private struct Weak { weak var processor: SoundProcessor? }

    private init() {
        Equalizer.shared.changed = { [weak self] in self?.changed?() }
        Leveller.shared.changed = { [weak self] in self?.changed?() }
        Leveller.shared.measured = { [weak self] key in self?.measured(key) }
    }

    var active: Bool { Equalizer.shared.on || Leveller.shared.on }

    /// The tap for `item`, the copy `key`, when either is on (none when both are off): attached once its audio track is
    /// known. A copy playing from a file not measured yet is measured now.
    func apply(to item: AVPlayerItem, key: String) {
        guard active else { item.audioMix = nil; return }
        let eq = Equalizer.shared, leveller = Leveller.shared
        if leveller.on, let url = (item.asset as? AVURLAsset)?.url, url.isFileURL { leveller.measure(key, file: url) }
        let processor = SoundProcessor(gains: eq.on ? eq.gains : Self.flat, level: leveller.on ? leveller.gain(for: key) : 0)
        processors.removeAll { $0.processor.processor == nil }
        processors.append((key, Weak(processor: processor)))
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first, active,
                  let tap = processor.makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    private static let flat = Array(repeating: 0.0, count: Equalizer.bands.count)

    /// Equalizer: a band or preset changed; every tap follows.
    func equalizerChanged(_ gains: [Double]) {
        guard Equalizer.shared.on else { return }           // off, its taps (levelling's) stay flat
        for entry in processors { entry.processor.processor?.update(gains: gains) }
    }

    /// Leveller: a copy was measured (its name in the cache); its taps glide to its own gain.
    private func measured(_ name: String) {
        guard Leveller.shared.on else { return }
        for entry in processors where AudioCache.name(for: entry.key) == name {
            entry.processor.processor?.update(level: Leveller.shared.gain(for: entry.key))
        }
    }

    #if DEBUG
    /// Self-tests: the taps alive now.
    var liveProcessors: [SoundProcessor] { processors.compactMap(\.processor.processor) }
    #endif
}

/// The filters and gain of one item's tap. `update` (the main thread) builds a new cascade and swaps it in under the
/// lock; `process` (the audio thread) holds the lock for one buffer, so a cascade is never freed while in use.
nonisolated final class SoundProcessor: @unchecked Sendable {
    /// Each band's width: two-thirds of an octave (Q = √2^N / (2^N − 1), N = 2/3).
    static let q = sqrt(pow(2, 2.0 / 3)) / (pow(2, 2.0 / 3) - 1)
    /// How fast the gain moves to a new value: each 0.15 s closes all but 1/e of the gap, so any change settles in about
    /// 0.7 s and a song measured after it started glides to its level instead of jumping. (A fixed step per second,
    /// tried first, took 0.5 s to turn a song down 6 dB but 3 s to turn one up 23 dB.)
    static let glideSeconds = 0.15

    private let lock = OSAllocatedUnfairLock()
    private var gains: [Double]
    private var level: Float                       // the levelling gain, linear
    private var applied: Float?                    // the gain applied to the last buffer; nil before the first
    private var sampleRate = 44_100.0
    private var channels = 0
    private var usable = false                     // Float32, one buffer per channel: what AVFoundation's taps give
    private var cascade: Cascade?

    /// `level`: the levelling gain in dB.
    init(gains: [Double], level: Double = 0) {
        self.gains = gains
        self.level = Float(pow(10, level / 20))
    }

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

    /// The levelling gain, in dB: the audio glides to it.
    func update(level: Double) {
        let linear = Float(pow(10, level / 20))
        lock.withLockUnchecked { self.level = linear }
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

    /// The audio thread: each channel's buffer through the cascade, in place, then the gain (the preamp times the
    /// level). The first buffer starts at the gain; a later change glides there (`glideSeconds`). A flat curve at
    /// 0 dB leaves the audio untouched.
    fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.withLockUnchecked {
            #if DEBUG
            measure(buffers, frames: frames, into: &energyIn)
            #endif
            if usable, buffers.count == channels, frames > 0 {
                if let cascade, cascade.delays.count == channels {
                    for (buffer, delay) in zip(buffers, cascade.delays) {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        vDSP_biquad(cascade.setup, delay, samples, 1, samples, 1, vDSP_Length(frames))
                    }
                }
                let target = (cascade?.preamp ?? 1) * level
                let from = applied ?? target
                var to = target + (from - target) * Float(exp(-Double(frames) / (sampleRate * Self.glideSeconds)))
                if abs(to - target) <= target * 0.001 { to = target }
                applied = to
                if from != 1 || to != 1 {
                    for buffer in buffers {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        if from == to {
                            var gain = to
                            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
                        } else {
                            var start = from, step = (to - from) / Float(frames)
                            vDSP_vrampmul(samples, 1, &start, &step, samples, 1, vDSP_Length(frames))
                        }
                    }
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

    /// The gain the last buffer ended at, in dB (nil before any audio).
    var appliedForTests: Double? { lock.withLockUnchecked { applied.map { 20 * log10(Double($0)) } } }

    /// Self-tests: `seconds` of a sine at `frequency`, through these filters as the tap would run them, and the change
    /// in loudness in dB over the second half (no audio device involved). `meanwhile` runs at the half.
    func offline(frequency: Double, sampleRate rate: Double = 44_100, seconds: Double = 1, meanwhile: (() -> Void)? = nil) -> Double {
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
                if start == frames / 2 / 1024 * 1024 {                    // the second half: the filters have settled
                    _ = takeReading()
                    meanwhile?()
                }
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
            init: soundTapInit, finalize: soundTapFinalize, prepare: soundTapPrepare, unprepare: nil, process: soundTapProcess)
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

private nonisolated func soundTapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                                      _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storage.pointee = clientInfo
}

private nonisolated func soundTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private nonisolated func soundTapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                                         _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format: format.pointee)
}

private nonisolated func soundTapProcess(_ tap: MTAudioProcessingTap, _ frames: CMItemCount, _ flags: MTAudioProcessingTapFlags,
                                         _ buffers: UnsafeMutablePointer<AudioBufferList>, _ framesOut: UnsafeMutablePointer<CMItemCount>,
                                         _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
}
