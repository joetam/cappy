import AppKit
import QuotaContracts
import SwiftUI

@MainActor
final class DesktopOverlayController: NSObject, NSWindowDelegate {
    private enum Defaults {
        static let isVisible = "desktopOverlay.isVisible"
        static let windowFrame = "CappyDesktopOverlay"
    }

    private let model: AppModel
    private let onReturnToMenuBar: @MainActor () -> Void
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    init(model: AppModel, onReturnToMenuBar: @escaping @MainActor () -> Void) {
        self.model = model
        self.onReturnToMenuBar = onReturnToMenuBar
        super.init()
    }

    func restoreVisibility() {
        if UserDefaults.standard.bool(forKey: Defaults.isVisible) { show(persist: false) }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(persist: Bool = true) {
        let panel = panel ?? makePanel()
        panel.orderFrontRegardless()
        if persist { UserDefaults.standard.set(true, forKey: Defaults.isVisible) }
    }

    func hide(persist: Bool = true) {
        panel?.orderOut(nil)
        if persist { UserDefaults.standard.set(false, forKey: Defaults.isVisible) }
    }

    func windowDidMove(_ notification: Notification) {
        panel?.saveFrame(usingName: Defaults.windowFrame)
    }

    func windowDidResize(_ notification: Notification) {
        panel?.saveFrame(usingName: Defaults.windowFrame)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: CappyLayout.overlayWidth, height: CappyLayout.overlayHeight)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Cappy Desktop Widget"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentMinSize = NSSize(width: CappyLayout.overlayWidth, height: CappyLayout.overlayMinimumHeight)
        panel.contentMaxSize = NSSize(width: CappyLayout.overlayWidth, height: .greatestFiniteMagnitude)
        panel.delegate = self

        let rootView = DesktopOverlayView(
            model: model,
            onHide: { [weak self] in self?.hide() },
            onReturnToMenuBar: onReturnToMenuBar
        )
        let hostingController = NSHostingController(rootView: rootView)
        panel.contentViewController = hostingController

        let restoredFrame = panel.setFrameUsingName(Defaults.windowFrame)
        let isOnScreen = NSScreen.screens.contains { screen in
            let visiblePart = panel.frame.intersection(screen.visibleFrame)
            return visiblePart.width >= 80 && visiblePart.height >= 80
        }
        if (!restoredFrame || !isOnScreen), let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: visibleFrame.maxX - size.width - 24,
                    y: visibleFrame.maxY - size.height - 24
                ))
        }

        self.panel = panel
        return panel
    }
}

struct DesktopOverlayView: View {
    @ObservedObject var model: AppModel
    let onHide: () -> Void
    let onReturnToMenuBar: () -> Void
    @AppStorage(GlobalShortcut.enabledDefaultsKey) private var globalShortcutEnabled = false
    @AppStorage("dashboard.showsRenewalDates") private var showsRenewalDates = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            readings
            Divider().opacity(0.55)
            footer
        }
        .frame(width: CappyLayout.overlayWidth)
        .frame(minHeight: CappyLayout.overlayMinimumHeight, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .opacity(isHovered ? 0.22 : 0.04)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.13 : 0.05), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Return to Menu Bar", systemImage: "menubar.rectangle", action: onReturnToMenuBar)
            Button("Hide Desktop Widget", systemImage: "xmark", action: onHide)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cappy")
                    .font(.headline)
                if let observedAt = model.dashboardSnapshots.map(\.observedAt).max() {
                    Text("Updated \(observedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Usage at a glance")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh all accounts")
            .accessibilityLabel("Refresh all accounts")

            Button(action: onHide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide desktop widget")
            .accessibilityLabel("Hide desktop widget")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private var readings: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = model.errorMessage {
                    overlayMessage(icon: "exclamationmark.triangle.fill", text: error, color: .red)
                }
                if model.dashboardSnapshots.isEmpty {
                    overlayMessage(
                        icon: "gauge.with.dots.needle.0percent",
                        text: "No account readings yet. Open Cappy or refresh to get started.",
                        color: .secondary
                    )
                }
                ForEach(Array(model.dashboardSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                    DesktopAccountSection(snapshot: snapshot, showsRenewalDate: showsRenewalDates)
                    if index < model.dashboardSnapshots.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                            .opacity(0.55)
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.never)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Drag to move")
            Spacer()
            if globalShortcutEnabled {
                Text("\(GlobalShortcut.displayName) to toggle")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func overlayMessage(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
    }
}

private struct DesktopAccountSection: View {
    let snapshot: AccountSnapshot
    let showsRenewalDate: Bool

    private var detailLabel: String? {
        connectionDetailLabel(profileLabel: snapshot.profileLabel, snapshot: snapshot, provider: snapshot.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ProviderMark(provider: snapshot.provider)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.profileLabel)
                        .font(.subheadline.weight(.semibold))
                    if let detailLabel {
                        Text(detailLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if showsRenewalDate, let billingLabel = subscriptionBillingLabel(snapshot.subscription) {
                        Text(billingLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                freshnessProgress
            }

            if snapshot.authenticationState != .authenticated {
                Text(snapshot.message ?? "Sign in from the Cappy menu to read quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 31)
            } else if snapshot.meters.isEmpty {
                Text(snapshot.message ?? "No quota meters available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 31)
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.meters) { meter in MeterRow(meter: meter) }
                }
                .padding(.leading, 31)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder private var freshnessProgress: some View {
        if snapshot.freshness == .pending {
            ProgressView()
                .controlSize(.mini)
                .help("Waiting for quota")
        }
    }
}
