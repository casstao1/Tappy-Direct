import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: KeyboardSoundController

    var body: some View {
        VStack(spacing: 0) {
            // Shown while a premium trial is active
            if let preview = controller.previewPack {
                previewBar(pack: preview)
                Divider()
            }

            // Shown after a trial expires
            if controller.showUpgradeCTA, let cta = controller.ctaPack {
                ctaBar(pack: cta)
                Divider()
            }

            header
            Divider()
            if let storeStatus = controller.premiumStoreStatusText {
                storeStatusBar(storeStatus)
                Divider()
            }
            if controller.shouldShowDirectLicenseBar {
                directLicenseBar
                Divider()
            }
            if controller.setupPhase != .complete {
                setupBar
                Divider()
            }
            statusBar
            Divider()
            packList
            Divider()
            volumeControl
            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tappy")
                    .font(.headline)
                Text("Auditory typing feedback")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDotColor: Color {
        switch controller.setupPhase {
        case .needsPermission, .needsRestart: return .orange
        case .complete: return controller.isEnabled ? .green : Color.secondary
        }
    }

    private var statusLabel: String {
        switch controller.setupPhase {
        case .needsPermission: return "Setup needed"
        case .needsRestart: return "Restart required"
        case .complete: return controller.isEnabled ? "Active" : "Paused"
        }
    }

    private func storeStatusBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .opacity(controller.isPremiumStoreBusy ? 1 : 0)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.04))
    }

    private var statusBar: some View {
        Text(controller.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.025))
    }

    private var directLicenseBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Unlock ASMR Packs", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))

                Spacer()

                Text(controller.premiumUnlockPrice)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Buy once with Stripe, then return to Tappy from the checkout page to unlock automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.openDirectPurchasePage()
            } label: {
                Label("Buy \(controller.premiumUnlockPrice)", systemImage: "cart.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(controller.isPremiumStoreBusy)

            HStack(spacing: 7) {
                TextField("Fallback license key", text: $controller.directLicenseKeyEntry)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Button {
                    Task { await controller.activateDirectLicense() }
                } label: {
                    Label("Activate", systemImage: "key.fill")
                }
                .labelStyle(.iconOnly)
                .help("Activate license")
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!controller.canActivateDirectLicense)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.04))
    }

    // MARK: - Setup bar

    private var setupBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(controller.setupHeadline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text(setupMenuDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(controller.setupPrimaryButtonTitle) {
                controller.performSetupPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.04))
        .onAppear {
            controller.requestStartupInputMonitoringPromptIfNeeded()
        }
    }

    private var setupMenuDetail: String {
        switch controller.setupPhase {
        case .needsPermission:
            return "Enable Input Monitoring so Tappy can provide auditory typing feedback in other apps. Tappy uses physical key codes only and never records typed text."
        case .needsRestart:
            return "Restart once so macOS applies the new permission."
        case .complete:
            return ""
        }
    }

    // MARK: - Live trial bar

    @ViewBuilder
    private func previewBar(pack: TechPack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                Text("Trying \(pack.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(controller.previewCountdownText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(controller.previewSecondsRemaining < 30 ? .orange : .secondary)
            }

            ProgressView(value: controller.previewProgress)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                Text("Ends automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Buy \(controller.premiumUnlockPrice)") {
                    controller.openDirectPurchasePage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(controller.isPremiumStoreBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: - Post-trial CTA bar

    @ViewBuilder
    private func ctaBar(pack: TechPack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep \(pack.name)?")
                    .font(.subheadline.weight(.semibold))
                Text("Unlock all premium feedback packs permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Buy \(controller.premiumUnlockPrice)") {
                    controller.openDirectPurchasePage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.isPremiumStoreBusy)

                Button("Not Now") {
                    controller.dismissUpgradeCTA()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: - Pack list

    private var packList: some View {
        VStack(spacing: 0) {
            ForEach(controller.availablePacks) { pack in
                PackRow(pack: pack)
                    .environmentObject(controller)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Volume

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Feedback Volume", systemImage: "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))

                Spacer()

                Text("\(Int((controller.clickVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $controller.clickVolume, in: 0...1)
                    .controlSize(.small)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Toggle(isOn: $controller.isEnabled) {
                Label("Feedback", systemImage: "keyboard")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(controller.setupPhase != .complete)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pack row

private struct PackRow: View {
    let pack: TechPack
    @EnvironmentObject private var controller: KeyboardSoundController
    @State private var isHovered = false
    @State private var showTrialConfirm = false

    private var isActive: Bool { pack.id == controller.currentPack.id }
    private var isLocked: Bool { controller.isPackLocked(pack) }
    private var isTrying: Bool { controller.previewPack?.id == pack.id }
    private var isHighlighted: Bool { pack.id == controller.highlightedPackID }

    private var iconColor: Color {
        switch pack.id {
        case TechPack.plasticTapping.id:  return Color(red: 0.48, green: 0.72, blue: 1.00)
        case TechPack.farming.id:         return Color(red: 0.38, green: 0.82, blue: 0.46)
        case TechPack.bubble.id:          return Color(red: 0.38, green: 0.88, blue: 0.88)
        case TechPack.stars.id:           return Color(red: 1.00, green: 0.82, blue: 0.30)
        case TechPack.woodBrush.id:       return Color(red: 0.85, green: 0.62, blue: 0.38)
        case TechPack.analogStopwatch.id: return Color(red: 0.72, green: 0.78, blue: 0.90)
        default:                          return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconColor.opacity(isActive || isTrying ? 0.20 : 0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: pack.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor.opacity(isActive || isTrying ? 1.0 : 0.8))

                if isLocked && !isTrying {
                    Circle()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(width: 13, height: 13)
                        .overlay(
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                        )
                        .offset(x: 9, y: 9)
                } else if isTrying {
                    Circle()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                        )
                        .offset(x: 9, y: 9)
                }
            }

            Text(pack.name)
                .font(.subheadline)
                .fontWeight(isActive || isTrying ? .semibold : .regular)

            Spacer()

            if isTrying {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                    Text(controller.previewCountdownText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(controller.previewSecondsRemaining < 30 ? .orange : .secondary)
            } else if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(rowBackgroundColor)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isLocked && !isTrying {
                controller.highlightPack(pack)
                showTrialConfirm = true
            } else {
                controller.highlightPack(pack)
            }
        }
        .alert(
            controller.hasTrialedPack(pack) ? "\(pack.name) — Trial Used" : "Try \(pack.name) free?",
            isPresented: $showTrialConfirm
        ) {
            if !controller.hasTrialedPack(pack) {
                Button("Start \(controller.livePreviewDurationText) Trial") {
                    controller.highlightPack(pack)
                    controller.startLivePreview(pack)
                }
            }
            Button("Buy All Packs — \(controller.premiumUnlockPrice)") {
                controller.highlightPack(pack)
                controller.openDirectPurchasePage()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            if controller.hasTrialedPack(pack) {
                Text("You've already used the free trial for \(pack.name). Unlock all premium feedback packs to keep it.")
            } else {
                Text("Try \(pack.name) feedback for \(controller.livePreviewDurationText). Your previous pack restores automatically when the trial ends.")
            }
        }
    }

    private var rowBackgroundColor: Color {
        if isTrying {
            return Color.accentColor.opacity(0.08)
        }
        if isHighlighted && !isActive {
            return Color.primary.opacity(0.07)
        }
        if isHovered && !isActive {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }
}
