import AppKit
import Foundation

@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var soundsRootURL: URL
    @Published private(set) var soundCounts: [SoundCategory: Int] = [:]
    @Published private(set) var totalSoundCount = 0
    @Published private(set) var lastLoadMessage = "No sounds loaded yet."

    private let fileManager: FileManager
    private let supportedExtensions = Set(["wav", "aiff", "aif", "caf", "mp3", "m4a"])
    private let keyFolderName = "keys"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        soundsRootURL = SoundLibrary.makeSoundsRootURL(fileManager: fileManager)

        for category in SoundCategory.allCases {
            soundCounts[category] = 0
        }
    }

    func reload(using audioEngine: LowLatencyAudioEngine) throws {
        try prepareFolderStructure()
        try installBundledSoundsIfNeeded()

        var newCounts: [SoundCategory: Int] = [:]
        var loadedSounds: [SoundCategory: [LoadedSound]] = [:]
        var loadedKeySounds: [UInt16: [LoadedSound]] = [:]

        for category in SoundCategory.allCases {
            let urls = try soundURLs(in: soundFolderURL(for: category))
            let sounds = try urls.map { url in
                LoadedSound(
                    category: category,
                    url: url,
                    buffer: try audioEngine.makeBuffer(from: url, maximumDuration: LowLatencyAudioEngine.maximumClickDuration)
                )
            }

            newCounts[category] = sounds.count
            loadedSounds[category] = sounds
        }

        for url in try soundURLs(in: keySoundsFolderURL()) {
            guard let keyCode = keyCode(from: url) else { continue }
            let sound = LoadedSound(
                category: .standard,
                url: url,
                buffer: try audioEngine.makeBuffer(from: url, maximumDuration: LowLatencyAudioEngine.maximumClickDuration)
            )
            loadedKeySounds[keyCode, default: []].append(sound)
        }

        try audioEngine.setLoadedSounds(loadedSounds, keySounds: loadedKeySounds)

        soundCounts = newCounts
        totalSoundCount = newCounts.values.reduce(0, +) + loadedKeySounds.values.reduce(0) { $0 + $1.count }

        if totalSoundCount == 0 {
            lastLoadMessage = "No feedback cues found. Add files and reload."
        } else {
            lastLoadMessage = "Loaded \(totalSoundCount) sound file(s) into memory for immediate playback."
        }
    }

    func prepareFolderStructure() throws {
        try fileManager.createDirectory(at: soundsRootURL, withIntermediateDirectories: true)

        for category in SoundCategory.allCases {
            try fileManager.createDirectory(at: soundFolderURL(for: category), withIntermediateDirectories: true)
        }

        try fileManager.createDirectory(at: keySoundsFolderURL(), withIntermediateDirectories: true)

        try writeInstructionsFileIfNeeded()
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: soundsRootURL.path)
    }

    func importFiles(_ urls: [URL], into category: SoundCategory) throws -> Int {
        try prepareFolderStructure()

        let destinationFolder = soundFolderURL(for: category)
        var importedCount = 0

        for url in urls {
            let pathExtension = url.pathExtension.lowercased()
            guard supportedExtensions.contains(pathExtension) else { continue }

            let destinationURL = uniqueDestinationURL(for: url.lastPathComponent, in: destinationFolder)
            try fileManager.copyItem(at: url, to: destinationURL)
            importedCount += 1
        }

        return importedCount
    }

    func importPack(from rootURL: URL) throws -> [SoundCategory: Int] {
        try prepareFolderStructure()

        var importedCounts: [SoundCategory: Int] = [:]
        for category in SoundCategory.allCases {
            importedCounts[category] = 0
        }

        for category in SoundCategory.allCases {
            let categoryFolder = rootURL.appendingPathComponent(category.folderName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: categoryFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let urls = try soundURLs(in: categoryFolder)
            let imported = try importFiles(urls, into: category)
            importedCounts[category] = imported
        }

        let keyFolder = rootURL.appendingPathComponent(keyFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: keyFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let keyURLs = try soundURLs(in: keyFolder)
            let destinationFolder = keySoundsFolderURL()
            for url in keyURLs where keyCode(from: url) != nil {
                let destinationURL = uniqueDestinationURL(for: url.lastPathComponent, in: destinationFolder)
                try fileManager.copyItem(at: url, to: destinationURL)
            }
        }

        return importedCounts
    }

    func restoreBundledPack(packID: String = TechPack.plasticTapping.id) throws -> Int {
        try prepareFolderStructure()

        guard let bundledPackURL = bundledPackURL(for: packID) else {
            return 0
        }

        for category in SoundCategory.allCases {
            let folder = soundFolderURL(for: category)
            let existingFiles = try soundURLs(in: folder)
            for url in existingFiles {
                try fileManager.removeItem(at: url)
            }
        }

        for url in try soundURLs(in: keySoundsFolderURL()) {
            try fileManager.removeItem(at: url)
        }

        let counts = try importPack(from: bundledPackURL)
        return counts.values.reduce(0, +)
    }

    func loadBundledPreviewPack(
        packID: String,
        using audioEngine: LowLatencyAudioEngine
    ) throws -> (
        sounds: [SoundCategory: [LoadedSound]],
        keySounds: [UInt16: [LoadedSound]]
    ) {
        try prepareFolderStructure()
        return try bundledPackContents(packID: packID, using: audioEngine)
    }

    func previewBundledSound(packID: String, category: SoundCategory, using audioEngine: LowLatencyAudioEngine) throws {
        guard let bundledPackURL = bundledPackURL(for: packID) else { return }

        let categoryFolder = bundledPackURL.appendingPathComponent(category.folderName, isDirectory: true)
        let urls = try soundURLs(in: categoryFolder)
        guard let url = urls.randomElement() else { return }

        let buffer = try audioEngine.makeBuffer(from: url, maximumDuration: LowLatencyAudioEngine.maximumClickDuration)
        audioEngine.play(buffer: buffer)
    }

    func previewBundledDemo(packID: String, using audioEngine: LowLatencyAudioEngine) throws {
        guard let bundledPackURL = bundledPackURL(for: packID) else { return }

        let demoURL = bundledPackURL
            .appendingPathComponent("demo", isDirectory: true)
            .appendingPathComponent("demo.wav", isDirectory: false)

        guard fileManager.fileExists(atPath: demoURL.path) else { return }

        let buffer = try audioEngine.makeBuffer(from: demoURL)
        audioEngine.play(buffer: buffer)
    }

    func soundFolderURL(for category: SoundCategory) -> URL {
        soundsRootURL.appendingPathComponent(category.folderName, isDirectory: true)
    }

    func keySoundsFolderURL() -> URL {
        soundsRootURL.appendingPathComponent(keyFolderName, isDirectory: true)
    }

    private func soundURLs(in folderURL: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func bundledPackContents(
        packID: String,
        using audioEngine: LowLatencyAudioEngine
    ) throws -> (
        sounds: [SoundCategory: [LoadedSound]],
        keySounds: [UInt16: [LoadedSound]]
    ) {
        guard let bundledPackURL = bundledPackURL(for: packID) else {
            return ([:], [:])
        }

        var loadedSounds: [SoundCategory: [LoadedSound]] = [:]
        var loadedKeySounds: [UInt16: [LoadedSound]] = [:]

        for category in SoundCategory.allCases {
            let urls = try soundURLs(in: bundledPackURL.appendingPathComponent(category.folderName, isDirectory: true))
            loadedSounds[category] = try urls.map { url in
                LoadedSound(
                    category: category,
                    url: url,
                    buffer: try audioEngine.makeBuffer(from: url, maximumDuration: LowLatencyAudioEngine.maximumClickDuration)
                )
            }
        }

        let keyFolderURL = bundledPackURL.appendingPathComponent(keyFolderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: keyFolderURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for url in try soundURLs(in: keyFolderURL) {
                guard let keyCode = keyCode(from: url) else { continue }
                let sound = LoadedSound(
                    category: .standard,
                    url: url,
                    buffer: try audioEngine.makeBuffer(from: url, maximumDuration: LowLatencyAudioEngine.maximumClickDuration)
                )
                loadedKeySounds[keyCode, default: []].append(sound)
            }
        }

        return (loadedSounds, loadedKeySounds)
    }

    private func installBundledSoundsIfNeeded() throws {
        guard currentSoundCount() == 0 else { return }
        guard let bundledPackURL = bundledPackURL(for: TechPack.plasticTapping.id) else { return }
        _ = try importPack(from: bundledPackURL)
    }

    private func currentSoundCount() -> Int {
        SoundCategory.allCases.reduce(0) { partialResult, category in
            let count = (try? soundURLs(in: soundFolderURL(for: category)).count) ?? 0
            return partialResult + count
        } + ((try? soundURLs(in: keySoundsFolderURL()).count) ?? 0)
    }

    private func bundledPackURL(for packID: String) -> URL? {
        guard let rootURL = Bundle.main.resourceURL?.appendingPathComponent("BundledSounds", isDirectory: true) else {
            return nil
        }

        let nestedPackURL = rootURL.appendingPathComponent(packID, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: nestedPackURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nestedPackURL
        }

        if packID == TechPack.plasticTapping.id {
            return rootURL
        }

        return nil
    }

    private func uniqueDestinationURL(for fileName: String, in folder: URL) -> URL {
        let originalURL = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: originalURL.path) else { return originalURL }

        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        var counter = 2

        while true {
            let candidate = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }

            counter += 1
        }
    }

    private func writeInstructionsFileIfNeeded() throws {
        let instructionsURL = soundsRootURL.appendingPathComponent("README.txt")
        guard !fileManager.fileExists(atPath: instructionsURL.path) else { return }

        let contents = """
        Tappy Feedback Cues

        Put your audio cue files into these folders:
        - default: used for most keys
        - space: used for the space bar
        - return: used for return and enter
        - delete: used for delete and forward delete
        - modifier: used for shift, command, option, control, caps lock, and fn

        Supported audio formats:
        - wav
        - aiff / aif
        - caf
        - mp3
        - m4a

        For the best responsiveness, use very short uncompressed files such as wav, aiff, or caf.
        After replacing files, return to the app and click Reload Sounds.
        """

        try contents.write(to: instructionsURL, atomically: true, encoding: .utf8)
    }

    private static func makeSoundsRootURL(fileManager: FileManager) -> URL {
        let baseURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let bundleComponent = Bundle.main.bundleIdentifier ?? "Tappy"
        return (baseURL ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent(bundleComponent, isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private func keyCode(from url: URL) -> UInt16? {
        UInt16(url.deletingPathExtension().lastPathComponent)
    }
}
