import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Setup Phase

/// Describes where the user is in the Input Monitoring setup flow for
/// system-wide auditory typing feedback.
/// Evaluated synchronously at launch so the correct screen is shown immediately
/// with no flash or delay.
enum SetupPhase: Equatable {
    /// No TCC entry exists yet. User must open System Settings and grant access.
    case needsPermission
    /// TCC permission is now detected but this process's event tap still cannot
    /// attach. macOS often requires a relaunch before newly granted permission
    /// takes effect for the running process.
    case needsRestart
    /// Event tap is active and TCC permission is confirmed.
    case complete
}

@MainActor
final class KeyboardSoundController: ObservableObject {
    private enum DefaultsKey {
        static let selectedPackID = "Tappy.selectedPackID"
        static let clickVolume = "Tappy.clickVolume"
        static let trialedPackIDs = "Tappy.trialedPackIDs"
        static let hasSeenWelcome = "Tappy.hasSeenWelcome"
        static let welcomeVersionSeen = "Tappy.welcomeVersionSeen"
    }

    private static let livePreviewDurationSeconds = 90
    private static let currentWelcomeVersion = 1

    @Published var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            updateMonitoringState()
        }
    }
    @Published private(set) var availablePacks = TechPack.all
    @Published private(set) var currentPack = TechPack.plasticTapping
    @Published var highlightedPackID = TechPack.plasticTapping.id
    @Published private(set) var backgroundCaptureState: KeyboardMonitor.CaptureState = .stopped
    @Published private(set) var premiumUnlocked = false
    @Published var directLicenseKeyEntry = ""
    @Published private(set) var trialedPackIDs: Set<String> = []
    @Published private(set) var setupPhase: SetupPhase
    @Published var clickVolume: Double {
        didSet {
            let clampedVolume = min(max(clickVolume, 0), 1)
            if clampedVolume != clickVolume {
                clickVolume = clampedVolume
                return
            }

            userDefaults.set(clampedVolume, forKey: DefaultsKey.clickVolume)
            audioEngine.setVolume(clampedVolume)
        }
    }

    @Published private(set) var statusMessage = "Preparing audio engine..."
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReloadedAt: Date?

    let permissionManager = InputMonitoringPermissionManager()
    let soundLibrary = SoundLibrary()
    let directLicenseStore: DirectLicenseStore

    private let keyboardMonitor = KeyboardMonitor()
    private let audioEngine = LowLatencyAudioEngine()
    private let userDefaults: UserDefaults
    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    private var appURLHandler: TappyAppURLHandler?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        directLicenseStore = DirectLicenseStore(userDefaults: userDefaults)

        premiumUnlocked = directLicenseStore.hasUnlockedPremium
        trialedPackIDs = Set(userDefaults.stringArray(forKey: DefaultsKey.trialedPackIDs) ?? [])
        if userDefaults.object(forKey: DefaultsKey.clickVolume) == nil {
            clickVolume = 1.0
        } else {
            clickVolume = min(max(userDefaults.double(forKey: DefaultsKey.clickVolume), 0), 1)
        }

        let trusted = CGPreflightListenEventAccess()
        setupPhase = Self.setupPhase(
            trusted: trusted,
            captureState: .stopped,
            allowTapProbe: true
        )

        let savedPackID = userDefaults.string(forKey: DefaultsKey.selectedPackID)

        if let savedPack = Self.startupPack(from: savedPackID, premiumUnlocked: premiumUnlocked) {
            currentPack = savedPack
            highlightedPackID = savedPack.id
        } else {
            persistSelectedPack(TechPack.plasticTapping)
        }

        directLicenseStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        directLicenseStore.onUnlockStateChange = { [weak self] _ in
            self?.reconcilePremiumUnlockState()
        }

        if directLicenseStore.hasSavedLicense {
            Task {
                await directLicenseStore.validateSavedLicense()
                reconcilePremiumUnlockState()
            }
        }

        permissionManager.onStatusChange = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                self.attemptListenerAttachIfNeeded()
                self.reconcileSetupPhase(allowTapProbe: true)
                self.statusMessage = self.monitoringSummary()
            }
        }

        keyboardMonitor.onCaptureStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.backgroundCaptureState = state
                self.reconcileSetupPhase(allowTapProbe: false)
                self.statusMessage = self.monitoringSummary()
            }
        }

        _ = try? soundLibrary.restoreBundledPack(packID: currentPack.id)
        audioEngine.setVolume(clickVolume)
        reloadSounds()
        updateMonitoringState()
        reconcileSetupPhase(allowTapProbe: true)
        setupMenuBarItem()
        appURLHandler = TappyAppURLHandler(controller: self)
        presentWelcomeIfNeeded()
    }

    deinit {
        keyboardMonitor.stop()
        appURLHandler?.invalidate()
        if let item = menuStatusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Menu bar status item (NSStatusItem-based)

    private var menuStatusItem: NSStatusItem?
    private var menuPopover: NSPopover?
    private var welcomeWindow: NSWindow?
    private var welcomeWindowDelegate: TappyWelcomeWindowDelegate?
    private var isWelcomePresentationScheduled = false

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuStatusItem = item

        if let button = item.button {
            updateMenuBarIcon()
            button.target = self
            button.action = #selector(handleStatusItemClick)
        }

        let hosting = NSHostingController(
            rootView: MenuBarView().environmentObject(self)
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        menuPopover = popover

        // Keep icon in sync with state changes.
        Publishers.CombineLatest($setupPhase, $isEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateMenuBarIcon() }
            .store(in: &cancellables)

        // Close the popover immediately when the app loses focus so it never
        // shows the inactive/glossy window appearance while dangling open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.menuPopover?.close()
            }
            .store(in: &cancellables)

    }

    @objc private func handleStatusItemClick(_ sender: AnyObject) {
        if menuPopover?.isShown == true {
            menuPopover?.performClose(nil)
        } else {
            showMenuPopover()
        }
    }

    private func showMenuPopover() {
        guard let button = menuStatusItem?.button else { return }
        guard let popover = menuPopover else { return }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateMenuBarIcon() {
        guard let button = menuStatusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Tappy")
        switch setupPhase {
        case .needsPermission, .needsRestart:
            button.contentTintColor = .systemOrange
        case .complete:
            button.contentTintColor = isEnabled ? nil : NSColor.secondaryLabelColor
        }
    }

    // MARK: - Setup

    var shouldShowSetupGate: Bool {
        setupPhase != .complete
    }

    var setupHeadline: String {
        switch setupPhase {
        case .needsPermission:
            return "Enable Auditory Feedback"
        case .needsRestart:
            return "Restart to activate"
        case .complete:
            return ""
        }
    }

    var setupDetail: String {
        switch setupPhase {
        case .needsPermission:
            return "Tappy needs Input Monitoring to detect physical key categories for local auditory feedback while you type in other apps. Tappy does not read, store, or transmit typed text."
        case .needsRestart:
            return "Permission is granted. Restart Tappy once so macOS applies auditory feedback to this running app."
        case .complete:
            return ""
        }
    }

    var setupPrimaryButtonTitle: String {
        switch setupPhase {
        case .needsPermission:
            return "Open Privacy Settings"
        case .needsRestart:
            return "Restart Tappy"
        case .complete:
            return ""
        }
    }

    func performSetupPrimaryAction() {
        switch setupPhase {
        case .needsPermission:
            openInputMonitoringSettings()
        case .needsRestart:
            relaunchApp()
        case .complete:
            break
        }
    }

    // MARK: - Status

    var soundsFolderPath: String {
        soundLibrary.soundsRootURL.path
    }

    var compactStatus: String {
        if !isEnabled { return "Paused" }
        if setupPhase == .complete { return "Active" }
        return "Setup"
    }

    // MARK: - Pack access

    var highlightedPack: TechPack {
        availablePacks.first(where: { $0.id == highlightedPackID }) ?? currentPack
    }

    var selectedPackID: String {
        currentPack.id
    }

    var highlightedPackIsLocked: Bool {
        isPackLocked(highlightedPack)
    }

    var freePacks: [TechPack] {
        availablePacks.filter { !$0.isPremium }
    }

    var premiumPacks: [TechPack] {
        availablePacks.filter(\.isPremium)
    }

    var premiumUnlockPrice: String {
        DirectPurchaseConfig.displayPrice
    }

    var premiumStoreMessage: String? {
        directLicenseStore.lastMessage
    }

    var premiumStoreStatusText: String? {
        if directLicenseStore.isActivating {
            return "Activating Tappy license..."
        }

        if directLicenseStore.isValidating {
            return "Checking Tappy license..."
        }

        return directLicenseStore.lastMessage
    }

    var isPremiumStoreLoading: Bool {
        directLicenseStore.isValidating
    }

    var isPremiumPurchaseInFlight: Bool {
        false
    }

    var isPremiumStoreBusy: Bool {
        directLicenseStore.isBusy
    }

    var shouldShowDirectLicenseBar: Bool {
        !premiumUnlocked
    }

    var canActivateDirectLicense: Bool {
        !directLicenseKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isPremiumStoreBusy
    }

    // MARK: - Public actions

    func reloadSounds() {
        do {
            try soundLibrary.reload(using: audioEngine)
            lastReloadedAt = Date()
            errorMessage = nil
            statusMessage = soundLibrary.totalSoundCount > 0 ? monitoringSummary() : soundLibrary.lastLoadMessage
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "The feedback library failed to load."
        }
    }

    func revealSoundsFolder() {
        soundLibrary.revealInFinder()
    }

    /// Spawns a fresh instance of the current app and quits this one.
    /// Required after granting Input Monitoring on some macOS versions.
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let escapedPath = bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open '\(escapedPath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    func importSounds(into category: SoundCategory = .standard) {
        let panel = NSOpenPanel()
        panel.title = "Import Feedback Cues"
        panel.message = "Choose audio files to copy into the app's \(category.displayName) feedback folder."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .wav, .aiff, .mp3, .mpeg4Audio,
            UTType("com.apple.coreaudio-format"),  // caf
        ].compactMap { $0 }

        guard panel.runModal() == .OK else { return }

        do {
            let importedCount = try soundLibrary.importFiles(panel.urls, into: category)
            reloadSounds()
            statusMessage = importedCount == 0
                ? "No compatible files were imported."
                : "Imported \(importedCount) file(s) into \(category.displayName)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPackFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import Feedback Pack Folder"
        panel.message = "Choose a folder that contains default, space, return, delete, and modifier cue subfolders."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let rootURL = panel.url else { return }

        do {
            let importedCounts = try soundLibrary.importPack(from: rootURL)
            reloadSounds()
            let importedTotal = importedCounts.values.reduce(0, +)
            statusMessage = importedTotal == 0
                ? "No compatible files were found in that pack folder."
                : "Imported \(importedTotal) file(s) from the pack folder."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreBuiltInPack(packID: String? = nil) {
        do {
            let selectedPackID = packID ?? currentPack.id
            let restored = try soundLibrary.restoreBundledPack(packID: selectedPackID)
            reloadSounds()
            statusMessage = restored == 0 ? "Built-in pack unavailable." : "\(currentPack.name) loaded."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func highlightPack(_ pack: TechPack) {
        highlightedPackID = pack.id

        guard pack.isAvailable else {
            statusMessage = "\(pack.name) is not installed yet."
            return
        }

        if isPackLocked(pack) {
            // Just highlight — user starts a trial explicitly via the Try Free button
            return
        }

        // Selecting a free pack cancels any active preview
        if previewPack != nil { cancelLivePreview() }

        guard pack.id != currentPack.id else {
            restoreBuiltInPack(packID: pack.id)
            return
        }

        currentPack = pack
        persistSelectedPack(pack)
        restoreBuiltInPack(packID: pack.id)
    }

    func previewHighlightedPack(category: SoundCategory) {
        let pack = highlightedPack
        if isPackLocked(pack) {
            playPremiumDemo()
            return
        }
        preview(category: category)
    }

    func playPremiumDemo() {
        let pack = highlightedPack
        guard isPackLocked(pack) else {
            preview(category: .standard)
            return
        }

        do {
            try soundLibrary.previewBundledDemo(packID: pack.id, using: audioEngine)
            statusMessage = "Playing \(pack.name) demo."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginUnlockPremiumFlow() {
        openDirectPurchasePage()
    }

    func openDirectPurchasePage() {
        cancelPendingCTA()
        NSWorkspace.shared.open(DirectPurchaseConfig.purchaseURL)
        statusMessage = "Opening secure Stripe checkout. Return here after payment to finish unlocking."
    }

    func activateDirectLicense() async {
        cancelPendingCTA()
        await directLicenseStore.activate(licenseKey: directLicenseKeyEntry)
        finishDirectLicenseActivation()
    }

    func validateDirectLicense() async {
        await directLicenseStore.validateSavedLicense()
        reconcilePremiumUnlockState()
        statusMessage = directLicenseStore.lastMessage ?? monitoringSummary()
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "tappy" else { return }

        let action = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: String...) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name == name })?.value,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        }

        switch action {
        case "checkout-complete", "activate-license", "unlock":
            cancelPendingCTA()
            showMenuPopover()

            if let sessionID = queryValue("session_id", "checkout_session_id", "session") {
                statusMessage = "Finishing Stripe checkout and unlocking Tappy..."
                Task {
                    await directLicenseStore.activate(checkoutSessionID: sessionID)
                    finishDirectLicenseActivation()
                    showMenuPopover()
                }
            } else if let licenseKey = queryValue("license_key", "license") {
                directLicenseKeyEntry = licenseKey
                statusMessage = "Activating Tappy license..."
                Task {
                    await activateDirectLicense()
                    showMenuPopover()
                }
            } else {
                statusMessage = "Tappy could not read the checkout activation link."
            }
        case "open", "menu":
            showMenuPopover()
        default:
            statusMessage = "Tappy did not recognize that link."
            showMenuPopover()
        }
    }

    func showWelcomeWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: WelcomeView().environmentObject(self)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let delegate = TappyWelcomeWindowDelegate(controller: self)
        window.title = "Welcome to Tappy"
        window.contentViewController = hostingController
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()

        welcomeWindow = window
        welcomeWindowDelegate = delegate
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func finishWelcome() {
        markWelcomeSeen()
        welcomeWindow?.close()
        showMenuPopover()
    }

    func markWelcomeSeen() {
        userDefaults.set(true, forKey: DefaultsKey.hasSeenWelcome)
        userDefaults.set(Self.currentWelcomeVersion, forKey: DefaultsKey.welcomeVersionSeen)
    }

    func requestKeyboardPermission() {
        permissionManager.requestListenAccessPrompt()
        statusMessage = monitoringSummary()
    }

    func refreshInputMonitoringStatus() {
        permissionManager.refreshStatus(forceNotify: true)
        permissionManager.scheduleRefreshBurst()
        attemptListenerAttachIfNeeded()
        reconcileSetupPhase(allowTapProbe: true)
        statusMessage = monitoringSummary()
    }

    func openInputMonitoringSettings() {
        permissionManager.openInputMonitoringSettings()
    }

    func openSoundSettings() {
        permissionManager.openSoundSettings()
    }

    /// Called when the setup bar appears. Triggers the macOS Input Monitoring
    /// prompt so users do not have to guess which privacy section to open.
    func requestStartupInputMonitoringPromptIfNeeded() {
        guard setupPhase == .needsPermission else { return }
        permissionManager.requestListenAccessPrompt()
        statusMessage = monitoringSummary()
    }

    func handleAppDidBecomeActive() {
        permissionManager.refreshStatus(forceNotify: true)
        permissionManager.scheduleRefreshBurst()
        attemptListenerAttachIfNeeded()
        reconcileSetupPhase(allowTapProbe: true)
        presentWelcomeIfNeeded(delay: 0.1)
    }

    func handleAppDidResignActive() {
        permissionManager.scheduleRefreshBurst()
    }

    func preview(category: SoundCategory) {
        audioEngine.play(category: category, keyCode: nil)
    }

    func isPackLocked(_ pack: TechPack) -> Bool {
        pack.isPremium && !premiumUnlocked
    }

    func hasTrialedPack(_ pack: TechPack) -> Bool {
        trialedPackIDs.contains(pack.id)
    }

    // MARK: - Live Preview (90-second trial)

    @Published private(set) var previewPack: TechPack? = nil
    @Published private(set) var previewSecondsRemaining: Int = 0
    @Published private(set) var showUpgradeCTA: Bool = false
    @Published private(set) var ctaPack: TechPack? = nil

    private var lastFreePack: TechPack = .plasticTapping
    private var previewTimerCancellable: AnyCancellable?
    private var pendingCTAWorkItem: DispatchWorkItem?

    var previewProgress: Double {
        guard previewPack != nil else { return 0 }
        return Double(previewSecondsRemaining) / Double(Self.livePreviewDurationSeconds)
    }

    var previewCountdownText: String {
        let minutes = previewSecondsRemaining / 60
        let seconds = previewSecondsRemaining % 60
        return String(format: "%d:%02d left", minutes, seconds)
    }

    var livePreviewDurationText: String {
        "\(Self.livePreviewDurationSeconds)-second"
    }

    func startLivePreview(_ pack: TechPack) {
        guard !hasTrialedPack(pack) else { return }

        cancelPendingCTA()
        stopRunningPreview()

        // Record this trial permanently so it can't be repeated
        trialedPackIDs.insert(pack.id)
        userDefaults.set(Array(trialedPackIDs), forKey: DefaultsKey.trialedPackIDs)

        // Remember the free pack to revert to
        if !currentPack.isPremium { lastFreePack = currentPack }

        previewPack = pack
        previewSecondsRemaining = Self.livePreviewDurationSeconds
        showUpgradeCTA = false
        ctaPack = nil

        // Switch sounds immediately — full quality, no degradation
        currentPack = pack
        restoreBuiltInPack(packID: pack.id)
        statusMessage = "Trying \(pack.name) for \(livePreviewDurationText)."

        // Countdown — fires on main thread, safe to mutate @MainActor state
        previewTimerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.previewSecondsRemaining -= 1
                if self.previewSecondsRemaining <= 0 { self.endLivePreview() }
            }
    }

    private func stopRunningPreview() {
        previewTimerCancellable?.cancel()
        previewTimerCancellable = nil
        previewPack = nil
        previewSecondsRemaining = 0
    }

    private func endLivePreview() {
        let previewed = previewPack
        stopRunningPreview()
        ctaPack = previewed

        // Revert to the free pack they were on
        currentPack = lastFreePack
        restoreBuiltInPack(packID: lastFreePack.id)
        if let previewed {
            statusMessage = "\(previewed.name) trial ended."
        }

        // Brief pause so the reversion is felt before the CTA appears
        cancelPendingCTA()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.ctaPack != nil, self.previewPack == nil, !self.premiumUnlocked else { return }
            self.showUpgradeCTA = true
        }
        pendingCTAWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    func dismissUpgradeCTA() {
        cancelPendingCTA()
        showUpgradeCTA = false
        ctaPack = nil
    }

    /// Cancels any active live preview and reverts to the last free pack.
    func cancelLivePreview() {
        guard previewPack != nil else { return }
        cancelPendingCTA()
        stopRunningPreview()
        currentPack = lastFreePack
        restoreBuiltInPack(packID: lastFreePack.id)
        statusMessage = monitoringSummary()
    }

    // MARK: - Private

    private func updateMonitoringState() {
        audioEngine.setEnabled(isEnabled)

        if isEnabled {
            attemptListenerAttachIfNeeded()
            statusMessage = monitoringSummary()
        } else {
            keyboardMonitor.stop()
            statusMessage = "Auditory feedback is paused."
        }
    }

    private func handle(trigger: KeyboardTrigger) {
        guard isEnabled else { return }
        audioEngine.play(category: trigger.category, keyCode: trigger.keyCode)
    }

    private func reconcilePremiumUnlockState() {
        let unlocked = directLicenseStore.hasUnlockedPremium
        premiumUnlocked = unlocked

        if unlocked {
            cancelPendingCTA()
            showUpgradeCTA = false
            ctaPack = nil

            if let previewPack {
                stopRunningPreview()
                selectUnlockedPremiumPack(previewPack)
            } else if highlightedPack.isPremium {
                selectUnlockedPremiumPack(highlightedPack)
            } else {
                let savedPackID = userDefaults.string(forKey: DefaultsKey.selectedPackID)
                if let savedPack = Self.startupPack(from: savedPackID, premiumUnlocked: true),
                   savedPack.isPremium {
                    selectUnlockedPremiumPack(savedPack)
                }
            }

            statusMessage = directLicenseStore.lastMessage ?? "Premium ASMR packs unlocked."
            return
        }

        if currentPack.isPremium {
            currentPack = .plasticTapping
            highlightedPackID = TechPack.plasticTapping.id
            persistSelectedPack(.plasticTapping)
            restoreBuiltInPack(packID: TechPack.plasticTapping.id)
        }

        statusMessage = monitoringSummary()
    }

    private func selectUnlockedPremiumPack(_ pack: TechPack) {
        guard pack.isAvailable else { return }
        currentPack = pack
        highlightedPackID = pack.id
        persistSelectedPack(pack)
        restoreBuiltInPack(packID: pack.id)
    }

    private func finishDirectLicenseActivation() {
        reconcilePremiumUnlockState()

        if directLicenseStore.hasUnlockedPremium {
            directLicenseKeyEntry = ""
            if highlightedPack.isPremium {
                highlightPack(highlightedPack)
            }
        }

        statusMessage = directLicenseStore.lastMessage ?? monitoringSummary()
    }

    private var hasSeenCurrentWelcome: Bool {
        let welcomeVersionSeen = userDefaults.integer(forKey: DefaultsKey.welcomeVersionSeen)
        return welcomeVersionSeen >= Self.currentWelcomeVersion
    }

    private func presentWelcomeIfNeeded(delay: TimeInterval = 0.6) {
        guard !hasSeenCurrentWelcome else { return }
        guard !isWelcomePresentationScheduled else { return }
        isWelcomePresentationScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isWelcomePresentationScheduled = false
            guard !self.hasSeenCurrentWelcome else { return }
            self.showWelcomeWindow()
        }
    }

    private func monitoringSummary() -> String {
        guard isEnabled else { return "Auditory typing feedback is paused." }
        guard soundLibrary.totalSoundCount > 0 else { return soundLibrary.lastLoadMessage }

        switch setupPhase {
        case .needsPermission:
            return "Waiting for permission. Tappy only uses physical key codes for local auditory feedback."
        case .needsRestart:
            return "Permission granted. Restart Tappy to activate system-wide auditory feedback."
        case .complete:
            if backgroundCaptureState == .unavailable {
                return "Input Monitoring appears available, but the listen-only event tap failed to start."
            }
            return "Auditory typing feedback is active system-wide."
        }
    }

    private func attemptListenerAttachIfNeeded() {
        guard isEnabled else { return }

        if keyboardMonitor.captureState == .ready {
            if backgroundCaptureState != .ready {
                backgroundCaptureState = .ready
                reconcileSetupPhase(allowTapProbe: false)
            }
            return
        }

        keyboardMonitor.start { [weak self] trigger in
            DispatchQueue.main.async {
                self?.handle(trigger: trigger)
            }
        }
    }

    private func reconcileSetupPhase(allowTapProbe: Bool) {
        setupPhase = Self.setupPhase(
            trusted: permissionManager.isTrusted,
            captureState: backgroundCaptureState,
            allowTapProbe: allowTapProbe
        )
    }

    private func persistSelectedPack(_ pack: TechPack) {
        userDefaults.set(pack.id, forKey: DefaultsKey.selectedPackID)
    }

    private func cancelPendingCTA() {
        pendingCTAWorkItem?.cancel()
        pendingCTAWorkItem = nil
    }

    /// Synchronously probes whether this process can create and enable a
    /// listen-only CGEvent tap. This is more reliable than TCC preflight alone
    /// because macOS can require a relaunch after newly granted permission.
    private static func canCreateEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        return isEnabled
    }

    private static func setupPhase(
        trusted: Bool,
        captureState: KeyboardMonitor.CaptureState,
        allowTapProbe: Bool
    ) -> SetupPhase {
        if captureState == .ready {
            return .complete
        }

        if allowTapProbe && Self.canCreateEventTap() {
            return .complete
        }

        guard trusted else { return .needsPermission }

        return .needsRestart
    }

    private static func startupPack(from savedPackID: String?, premiumUnlocked: Bool) -> TechPack? {
        guard
            let savedPackID,
            let savedPack = TechPack.all.first(where: { $0.id == savedPackID })
        else {
            return nil
        }

        guard savedPack.isAvailable else { return TechPack.plasticTapping }
        guard !savedPack.isPremium || premiumUnlocked else { return TechPack.plasticTapping }
        return savedPack
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var controller: KeyboardSoundController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Welcome to Tappy")
                    .font(.system(size: 28, weight: .bold))

                Text("Tappy will add a keyboard icon to the toolbar at the top of your Mac in a moment.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                controller.finishWelcome()
            } label: {
                Text("Continue")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private final class TappyWelcomeWindowDelegate: NSObject, NSWindowDelegate {
    private weak var controller: KeyboardSoundController?

    init(controller: KeyboardSoundController) {
        self.controller = controller
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak controller] in
            controller?.markWelcomeSeen()
        }
    }
}

private final class TappyAppURLHandler: NSObject {
    private weak var controller: KeyboardSoundController?
    private var isInstalled = false

    init(controller: KeyboardSoundController) {
        self.controller = controller
        super.init()
        install()
    }

    func invalidate() {
        guard isInstalled else { return }
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        isInstalled = false
    }

    private func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        isInstalled = true
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: rawURL)
        else {
            return
        }

        Task { @MainActor [weak controller] in
            controller?.handleIncomingURL(url)
        }
    }
}
