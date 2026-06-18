import AVFoundation
import Foundation

struct LoadedSound {
    let category: SoundCategory
    let url: URL
    let buffer: AVAudioPCMBuffer
}

enum AudioEngineError: LocalizedError {
    case unreadableFile(URL)
    case unsupportedFormat(URL)
    case conversionFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(url):
            return "The app could not read \(url.lastPathComponent)."
        case let .unsupportedFormat(url):
            return "\(url.lastPathComponent) uses an unsupported format."
        case let .conversionFailed(url):
            return "The app could not convert \(url.lastPathComponent) into the low-latency playback format."
        }
    }
}

final class LowLatencyAudioEngine {
    static let maximumClickDuration: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "Tappy.LowLatencyAudioEngine", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat
    private let concurrentVoices: Int
    private let voiceReleasePadding: TimeInterval = 0.01

    private var players: [AVAudioPlayerNode] = []
    private var voiceNextAvailableAt: [TimeInterval] = []
    private var loadedSounds: [SoundCategory: [LoadedSound]] = [:]
    private var loadedKeySounds: [UInt16: [LoadedSound]] = [:]
    private var previewSounds: [SoundCategory: [LoadedSound]] = [:]
    private var previewKeySounds: [UInt16: [LoadedSound]] = [:]
    private var lastPlayedIndex: [SoundCategory: Int] = [:]
    private var lastPlayedKeyIndex: [UInt16: Int] = [:]
    private var lastPlayedPreviewIndex: [SoundCategory: Int] = [:]
    private var lastPlayedPreviewKeyIndex: [UInt16: Int] = [:]
    private var nextPlayerIndex = 0
    private var isEnabled = true
    private var outputVolume: Float = 1.0

    init(concurrentVoices: Int = 8) {
        self.concurrentVoices = concurrentVoices

        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        let channelCount = max(hardwareFormat.channelCount, 2)
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!

        configureEngine()
    }

    func makeBuffer(from url: URL, maximumDuration: TimeInterval? = nil) throws -> AVAudioPCMBuffer {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let frameCount = frameCountToRead(from: sourceFile, maximumDuration: maximumDuration)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioEngineError.unreadableFile(url)
        }

        try sourceFile.read(into: sourceBuffer)

        if sourceFormat == outputFormat {
            return durationLimitedBuffer(sourceBuffer, maximumDuration: maximumDuration)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioEngineError.unsupportedFormat(url)
        }

        let conversionRatio = outputFormat.sampleRate / sourceFormat.sampleRate
        let estimatedFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * conversionRatio) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: estimatedFrameCapacity
        ) else {
            throw AudioEngineError.conversionFailed(url)
        }

        var didSupplyInput = false
        var conversionError: NSError?

        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didSupplyInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error || conversionError != nil {
            throw AudioEngineError.conversionFailed(url)
        }

        return durationLimitedBuffer(convertedBuffer, maximumDuration: maximumDuration)
    }

    func setLoadedSounds(_ sounds: [SoundCategory: [LoadedSound]], keySounds: [UInt16: [LoadedSound]]) throws {
        try queue.sync {
            loadedSounds = sounds
            loadedKeySounds = keySounds
            lastPlayedIndex.removeAll()
            lastPlayedKeyIndex.removeAll()
            if isEnabled {
                try startEngineIfNeeded()
            }
        }
    }

    func setPreviewSounds(_ sounds: [SoundCategory: [LoadedSound]], keySounds: [UInt16: [LoadedSound]]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.previewSounds = sounds
            self.previewKeySounds = keySounds
            self.lastPlayedPreviewIndex.removeAll()
            self.lastPlayedPreviewKeyIndex.removeAll()
        }
    }

    func clearPreviewSounds() {
        queue.async { [weak self] in
            guard let self else { return }
            self.previewSounds.removeAll()
            self.previewKeySounds.removeAll()
            self.lastPlayedPreviewIndex.removeAll()
            self.lastPlayedPreviewKeyIndex.removeAll()
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled

            if enabled {
                do {
                    try self.startEngineIfNeeded()
                } catch {
                    NSLog("Tappy audio engine enable failed: \(error.localizedDescription)")
                }
            } else {
                self.stopPlayback()
            }
        }
    }

    func setVolume(_ volume: Double) {
        let clampedVolume = Float(min(max(volume, 0), 1))

        queue.async { [weak self] in
            guard let self else { return }
            self.outputVolume = clampedVolume
            for player in self.players {
                player.volume = clampedVolume
            }
        }
    }

    func play(category: SoundCategory, keyCode: UInt16? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isEnabled else { return }
            guard let sound = self.pickSound(
                for: category,
                keyCode: keyCode,
                sounds: self.loadedSounds,
                keySounds: self.loadedKeySounds,
                categoryHistory: &self.lastPlayedIndex,
                keyHistory: &self.lastPlayedKeyIndex
            ) else { return }

            do {
                try self.startEngineIfNeeded()
                self.playBuffer(sound.buffer)
            } catch {
                NSLog("Tappy audio engine start failed: \(error.localizedDescription)")
            }
        }
    }

    func playPreview(category: SoundCategory, keyCode: UInt16? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isEnabled else { return }
            guard let sound = self.pickSound(
                for: category,
                keyCode: keyCode,
                sounds: self.previewSounds,
                keySounds: self.previewKeySounds,
                categoryHistory: &self.lastPlayedPreviewIndex,
                keyHistory: &self.lastPlayedPreviewKeyIndex
            ) else { return }

            do {
                try self.startEngineIfNeeded()
                self.playBuffer(sound.buffer)
            } catch {
                NSLog("Tappy audio engine preview failed: \(error.localizedDescription)")
            }
        }
    }

    func play(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isEnabled else { return }

            do {
                try self.startEngineIfNeeded()
                self.playBuffer(buffer)
            } catch {
                NSLog("Tappy audio engine preview failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureEngine() {
        players = (0..<concurrentVoices).map { _ in
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            player.volume = outputVolume
            return player
        }
        voiceNextAvailableAt = Array(repeating: 0, count: concurrentVoices)

        engine.mainMixerNode.outputVolume = 1.0
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        startPlayersIfNeeded()
    }

    private func startPlayersIfNeeded() {
        for player in players where !player.isPlaying {
            player.play()
        }
    }

    private func stopPlayback() {
        for player in players {
            player.stop()
        }
        voiceNextAvailableAt = Array(repeating: 0, count: players.count)

        if engine.isRunning {
            engine.pause()
        }
    }

    private func pickSound(
        for category: SoundCategory,
        keyCode: UInt16?,
        sounds: [SoundCategory: [LoadedSound]],
        keySounds: [UInt16: [LoadedSound]],
        categoryHistory: inout [SoundCategory: Int],
        keyHistory: inout [UInt16: Int]
    ) -> LoadedSound? {
        let keyOptions = keyCode.flatMap { keySounds[$0] }
        let options = candidateSounds(for: category, keyCode: keyCode, sounds: sounds, keySounds: keySounds)
        guard !options.isEmpty else { return nil }

        if let keyCode, let keyOptions, !keyOptions.isEmpty {
            if options.count == 1 {
                keyHistory[keyCode] = 0
                return options[0]
            }

            var nextIndex = Int.random(in: 0..<options.count)
            if let lastIndex = keyHistory[keyCode], nextIndex == lastIndex {
                nextIndex = (nextIndex + 1) % options.count
            }

            keyHistory[keyCode] = nextIndex
            return options[nextIndex]
        }

        if options.count == 1 {
            categoryHistory[category] = 0
            return options[0]
        }

        var nextIndex = Int.random(in: 0..<options.count)
        if let lastIndex = categoryHistory[category], nextIndex == lastIndex {
            nextIndex = (nextIndex + 1) % options.count
        }

        categoryHistory[category] = nextIndex
        return options[nextIndex]
    }

    private func candidateSounds(
        for category: SoundCategory,
        keyCode: UInt16?,
        sounds: [SoundCategory: [LoadedSound]],
        keySounds: [UInt16: [LoadedSound]]
    ) -> [LoadedSound] {
        if let keyCode, let keySounds = keySounds[keyCode], !keySounds.isEmpty {
            return keySounds
        }

        if let categorySounds = sounds[category], !categorySounds.isEmpty {
            return categorySounds
        }

        return sounds[.standard] ?? []
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !players.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard let playerIndex = firstIdlePlayerIndex(at: now) else {
            return
        }

        let player = players[playerIndex]
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        voiceNextAvailableAt[playerIndex] = now + bufferDuration(buffer) + voiceReleasePadding
        nextPlayerIndex = (playerIndex + 1) % players.count
    }

    private func firstIdlePlayerIndex(at now: TimeInterval) -> Int? {
        guard !players.isEmpty else { return nil }

        for offset in 0..<players.count {
            let index = (nextPlayerIndex + offset) % players.count
            if voiceNextAvailableAt[index] <= now {
                return index
            }
        }

        return nil
    }

    private func bufferDuration(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : outputFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / sampleRate
    }

    private func frameCountToRead(from sourceFile: AVAudioFile, maximumDuration: TimeInterval?) -> AVAudioFrameCount {
        let availableFrames = min(max(sourceFile.length, 0), AVAudioFramePosition(UInt32.max))
        guard let maximumDuration, maximumDuration > 0, sourceFile.processingFormat.sampleRate > 0 else {
            return AVAudioFrameCount(availableFrames)
        }

        let limitedFrames = AVAudioFramePosition(ceil(maximumDuration * sourceFile.processingFormat.sampleRate))
        return AVAudioFrameCount(max(1, min(availableFrames, limitedFrames)))
    }

    private func durationLimitedBuffer(
        _ buffer: AVAudioPCMBuffer,
        maximumDuration: TimeInterval?
    ) -> AVAudioPCMBuffer {
        guard let maximumDuration, maximumDuration > 0, buffer.format.sampleRate > 0 else {
            return buffer
        }

        let maximumFrames = AVAudioFrameCount(ceil(maximumDuration * buffer.format.sampleRate))
        guard maximumFrames > 0, buffer.frameLength > maximumFrames else {
            return buffer
        }

        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: maximumFrames) else {
            return buffer
        }

        copyFrames(maximumFrames, from: buffer, to: trimmedBuffer)
        trimmedBuffer.frameLength = maximumFrames
        applyFadeOut(to: trimmedBuffer)
        return trimmedBuffer
    }

    private func copyFrames(
        _ frameCount: AVAudioFrameCount,
        from source: AVAudioPCMBuffer,
        to destination: AVAudioPCMBuffer
    ) {
        let frameCount = Int(frameCount)
        let channelCount = Int(source.format.channelCount)
        let sampleCount = source.format.isInterleaved ? frameCount * channelCount : frameCount
        let planeCount = source.format.isInterleaved ? 1 : channelCount

        switch source.format.commonFormat {
        case .pcmFormatFloat32:
            guard let sourceData = source.floatChannelData, let destinationData = destination.floatChannelData else { return }
            for plane in 0..<planeCount {
                destinationData[plane].update(from: sourceData[plane], count: sampleCount)
            }
        case .pcmFormatInt16:
            guard let sourceData = source.int16ChannelData, let destinationData = destination.int16ChannelData else { return }
            for plane in 0..<planeCount {
                destinationData[plane].update(from: sourceData[plane], count: sampleCount)
            }
        case .pcmFormatInt32:
            guard let sourceData = source.int32ChannelData, let destinationData = destination.int32ChannelData else { return }
            for plane in 0..<planeCount {
                destinationData[plane].update(from: sourceData[plane], count: sampleCount)
            }
        default:
            break
        }
    }

    private func applyFadeOut(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return
        }

        let sampleRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : outputFormat.sampleRate
        let fadeFrameCount = min(Int(buffer.frameLength), max(1, Int(sampleRate * 0.01)))
        let startFrame = Int(buffer.frameLength) - fadeFrameCount
        let channelCount = Int(buffer.format.channelCount)
        let planeCount = buffer.format.isInterleaved ? 1 : channelCount

        for plane in 0..<planeCount {
            let samples = channelData[plane]
            for frameOffset in 0..<fadeFrameCount {
                let gain = Float(fadeFrameCount - frameOffset) / Float(fadeFrameCount)
                let frame = startFrame + frameOffset
                if buffer.format.isInterleaved {
                    for channel in 0..<channelCount {
                        samples[frame * channelCount + channel] *= gain
                    }
                } else {
                    samples[frame] *= gain
                }
            }
        }
    }
}
