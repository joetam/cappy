import AppKit
import QuotaContracts
import SwiftUI

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var isAddingAccount = false
    @State private var removalCandidateID: String?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if isAddingAccount {
                AddAccountView(model: model) { isAddingAccount = false }
            } else {
                dashboard
            }
        }
        .frame(width: 390)
        .background(.regularMaterial)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cappy")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Limits across your coding accounts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .opacity(model.isRefreshing ? 0.45 : 1)
                }
                .buttonStyle(.borderless)
                .help("Refresh all accounts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error = model.errorMessage {
                        MessageRow(icon: "exclamationmark.triangle.fill", text: error, color: Color(hex: "D95D73"))
                    }
                    if let notice = model.noticeMessage {
                        MessageRow(icon: "checkmark.circle.fill", text: notice, color: Color(hex: "3FBF8F"))
                    }
                    if let warning = model.duplicateWarning {
                        MessageRow(icon: "person.2.badge.gearshape", text: warning, color: Color(hex: "E6A23C"))
                    }
                    if model.snapshots.isEmpty {
                        MessageRow(
                            icon: "gauge.with.dots.needle.0percent", text: "No account readings yet. Refresh or add an account.",
                            color: .secondary)
                    }
                    ForEach(model.snapshots) { snapshot in
                        AccountCard(
                            snapshot: snapshot,
                            isConfirmingRemoval: removalCandidateID == snapshot.profileID,
                            isRemoving: removingProfileID == snapshot.profileID
                        ) {
                            model.login(profileID: snapshot.profileID)
                        } onConfigure: {
                            model.configure(profileID: snapshot.profileID)
                        } onRequestRemove: {
                            removalCandidateID = snapshot.profileID
                        } onCancelRemove: {
                            removalCandidateID = nil
                        } onConfirmRemove: {
                            let profileID = snapshot.profileID
                            removingProfileID = profileID
                            Task {
                                let removed = await model.removeAccount(profileID: profileID)
                                removingProfileID = nil
                                if removed { removalCandidateID = nil }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 520)

            Divider()
            HStack {
                Button {
                    isAddingAccount = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Quit") { model.quit() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct MessageRow: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AccountCard: View {
    let snapshot: AccountSnapshot
    let isConfirmingRemoval: Bool
    let isRemoving: Bool
    let onLogin: () -> Void
    let onConfigure: () -> Void
    let onRequestRemove: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void
    var showsMenu = true

    private var providerColor: Color { Color(hex: snapshot.provider.accentHex ?? "5B6CFF") }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                ProviderBadge(provider: snapshot.provider)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.profileLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(snapshot.identity?.organization ?? snapshot.identity?.email ?? snapshot.provider.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let plan = snapshot.subscription?.planName, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(providerColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(providerColor)
                }
                freshnessMark
                if showsMenu {
                    Menu {
                        Button("Remove account…", role: .destructive, action: onRequestRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if snapshot.authenticationState != .authenticated {
                HStack {
                    Text(snapshot.message ?? "Sign in to read quota.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign in", action: onLogin).controlSize(.small)
                }
            } else if snapshot.meters.isEmpty {
                HStack {
                    Text(snapshot.message ?? "No quota meters available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if canEnableClaudeQuota {
                        Button("Set up", action: onConfigure).controlSize(.small)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(snapshot.meters) { meter in MeterRow(meter: meter) }
                }
            }

            if isConfirmingRemoval {
                Divider()
                HStack(spacing: 8) {
                    Text("Remove \(snapshot.profileLabel)?")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Cancel", action: onCancelRemove)
                        .controlSize(.small)
                        .disabled(isRemoving)
                    Button(role: .destructive, action: onConfirmRemove) {
                        if isRemoving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Remove")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRemoving)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }
    }

    private var canEnableClaudeQuota: Bool {
        guard snapshot.provider.id == "anthropic-claude",
            let plan = snapshot.subscription?.planName?.lowercased()
        else { return false }
        return plan.contains("pro") || plan.contains("max")
    }

    @ViewBuilder private var freshnessMark: some View {
        if claudeQuotaIsUnsupported {
            Circle().fill(.secondary).frame(width: 6, height: 6)
                .help("Claude Code does not expose this plan’s quota through its documented status-line feed")
        } else {
            switch snapshot.freshness {
            case .fresh: Circle().fill(Color(hex: "3FBF8F")).frame(width: 6, height: 6).help("Fresh")
            case .stale: Circle().fill(Color(hex: "E6A23C")).frame(width: 6, height: 6).help("Stale")
            case .pending: Circle().stroke(.secondary, lineWidth: 1).frame(width: 6, height: 6).help("Waiting for quota")
            case .unavailable: Circle().fill(Color(hex: "D95D73")).frame(width: 6, height: 6).help("Unavailable")
            }
        }
    }

    private var claudeQuotaIsUnsupported: Bool {
        guard snapshot.provider.id == "anthropic-claude",
            snapshot.authenticationState == .authenticated,
            snapshot.meters.isEmpty,
            let plan = snapshot.subscription?.planName?.lowercased()
        else { return false }
        return !plan.contains("pro") && !plan.contains("max")
    }
}

private struct ProviderBadge: View {
    let provider: ProviderDescriptor

    private var providerColor: Color { Color(hex: provider.accentHex ?? "5B6CFF") }

    var body: some View {
        let resolvedImage = providerImage
        let showsBadgeChrome = resolvedImage == nil || provider.icon?.backgroundHex != nil
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(badgeBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(showsBadgeChrome ? 0.05 : 0), lineWidth: 0.5)
                }

            if let resolvedImage {
                Image(nsImage: resolvedImage)
                    .renderingMode(provider.icon?.renderingMode == "template" ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .padding(provider.icon?.applicationBundleIdentifier == nil ? 7 : 1)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: provider.symbolName ?? "circle.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(providerColor)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) provider")
    }

    private var badgeBackground: Color {
        if let hex = provider.icon?.backgroundHex { return Color(hex: hex) }
        if provider.icon != nil { return .clear }
        return providerColor.opacity(0.14)
    }

    private var providerImage: NSImage? {
        if let assetName = provider.icon?.bundledAssetName {
            let resourceURL =
                Bundle.main.url(forResource: assetName, withExtension: "svg")
                ?? Bundle.module.url(forResource: assetName, withExtension: "svg")
            if let resourceURL, let image = NSImage(contentsOf: resourceURL) { return image }
        }
        if let bundleIdentifier = provider.icon?.applicationBundleIdentifier,
            let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            if let resourceName = provider.icon?.applicationResourceName,
                let resourceURL = Bundle(url: applicationURL)?.url(
                    forResource: resourceName,
                    withExtension: provider.icon?.applicationResourceExtension
                ),
                let image = NSImage(contentsOf: resourceURL)
            {
                return image
            }
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return nil
    }
}

struct MeterRow: View {
    let meter: QuotaMeter
    private var remainingFraction: Double? { meter.usedFraction.map { max(0, 1 - $0) } }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.displayName).font(.caption).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(valueLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(capacityColor)
                if let reset = resetLabel {
                    Text(reset).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let remainingFraction {
                CapacityRail(remaining: remainingFraction, color: capacityColor)
                    .frame(height: 7)
            }
        }
    }

    private var valueLabel: String {
        if let remainingFraction { return "\(Int((remainingFraction * 100).rounded()))% left" }
        if meter.status == .unlimited { return "Unlimited" }
        if let remaining = meter.remaining {
            return "\(remaining.formatted(.number.precision(.fractionLength(0...2)))) \(meter.unit.rawValue)"
        }
        return meter.status.rawValue.capitalized
    }

    private var capacityColor: Color {
        guard let remainingFraction else { return .secondary }
        if remainingFraction <= 0.1 { return Color(hex: "D95D73") }
        if remainingFraction <= 0.3 { return Color(hex: "E6A23C") }
        return Color(hex: "3FBF8F")
    }

    private var resetLabel: String? {
        guard let date = meter.resetsAt else { return nil }
        return "· \(date.formatted(.relative(presentation: .numeric)))"
    }
}

struct CapacityRail: View {
    let remaining: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(3, geometry.size.width * remaining))
            }
        }
        .accessibilityLabel("\(Int((remaining * 100).rounded())) percent remaining")
    }
}

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var selectedProvider = "openai-codex"
    @State private var label = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
                Text("Add account")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Creates a separate sign-in for this account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").font(.caption).foregroundStyle(.secondary)
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(model.providers) { provider in Text(provider.displayName).tag(provider.id) }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Work or Personal", text: $label)
                }

                if let message = model.addAccountMessage {
                    Label(message, systemImage: isWorking ? "arrow.trianglehead.2.clockwise.rotate.90" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Divider()

            HStack {
                if isWorking {
                    Button("Cancel sign-in") {
                        Task {
                            await model.cancelAddAccount()
                            isWorking = false
                        }
                    }
                    .disabled(model.activeAddJobID == nil)
                }
                Spacer()
                Button("Sign in") {
                    isWorking = true
                    Task {
                        let added = await model.addAccount(providerID: selectedProvider, label: label)
                        isWorking = false
                        if added { onClose() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear {
            model.addAccountMessage = nil
            if selectedProvider.isEmpty { selectedProvider = model.providers.first?.id ?? "openai-codex" }
        }
    }
}

struct PreviewDashboardFixture: View {
    private let codex = AccountSnapshot(
        profileID: "codex-preview",
        provider: ProviderDescriptor(
            id: "openai-codex", displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right", accentHex: "5B6CFF",
            icon: ProviderIconDescriptor(
                applicationBundleIdentifier: "com.openai.codex",
                applicationResourceName: "icon-codex-light",
                applicationResourceExtension: "png")),
        profileLabel: "Personal Codex",
        authenticationState: .authenticated,
        identity: AccountIdentity(email: "developer@example.com"),
        subscription: Subscription(planName: "Pro"),
        meters: [
            QuotaMeter(
                id: "codex", displayName: "Codex", kind: .rollingWindow, unit: .percent, scope: .init(kind: "model-family", id: "codex"),
                usedFraction: 0.64, resetsAt: Date().addingTimeInterval(86_400), source: "preview"),
            QuotaMeter(
                id: "spark", displayName: "GPT-5.3-Codex-Spark", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "model-family", id: "spark"), usedFraction: 0.08, resetsAt: Date().addingTimeInterval(52_000),
                source: "preview"),
            QuotaMeter(
                id: "credits", displayName: "Usage credits", kind: .balance, unit: .credits, scope: .init(kind: "credits", id: "codex"),
                remaining: 12.5, source: "preview"),
        ],
        freshness: .fresh
    )

    private let claude = AccountSnapshot(
        profileID: "claude-preview",
        provider: ProviderDescriptor(
            id: "anthropic-claude", displayName: "Claude", symbolName: "sparkles", accentHex: "D97757",
            icon: ProviderIconDescriptor(bundledAssetName: "ProviderClaude")),
        profileLabel: "Work Claude",
        authenticationState: .authenticated,
        identity: AccountIdentity(organization: "Studio Team"),
        subscription: Subscription(planName: "Max"),
        meters: [
            QuotaMeter(
                id: "five", displayName: "Current session", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "five_hour"), usedFraction: 0.91, resetsAt: Date().addingTimeInterval(3_200),
                source: "preview"),
            QuotaMeter(
                id: "week", displayName: "Current week", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "seven_day"), usedFraction: 0.42, resetsAt: Date().addingTimeInterval(260_000),
                source: "preview"),
            QuotaMeter(
                id: "fable", displayName: "Fable · week", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "model-family", id: "fable"), usedFraction: 0.51, resetsAt: Date().addingTimeInterval(260_000),
                source: "preview"),
        ],
        freshness: .fresh
    )

    private let teamCodex = AccountSnapshot(
        profileID: "codex-team-preview",
        provider: ProviderDescriptor(
            id: "openai-codex", displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right", accentHex: "5B6CFF",
            icon: ProviderIconDescriptor(
                applicationBundleIdentifier: "com.openai.codex",
                applicationResourceName: "icon-codex-light",
                applicationResourceExtension: "png")),
        profileLabel: "Team Codex",
        authenticationState: .authenticated,
        identity: AccountIdentity(organization: "Northstar"),
        subscription: Subscription(planName: "Business"),
        meters: [
            QuotaMeter(
                id: "codex-team", displayName: "Codex", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "model-family", id: "codex"), usedFraction: 0.18,
                resetsAt: Date().addingTimeInterval(410_000), source: "preview"),
            QuotaMeter(
                id: "spark-team", displayName: "GPT-5.3-Codex-Spark", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "model-family", id: "spark"), usedFraction: 0.44,
                resetsAt: Date().addingTimeInterval(310_000), source: "preview"),
        ],
        freshness: .fresh
    )

    private let personalClaude = AccountSnapshot(
        profileID: "claude-personal-preview",
        provider: ProviderDescriptor(
            id: "anthropic-claude", displayName: "Claude", symbolName: "sparkles", accentHex: "D97757",
            icon: ProviderIconDescriptor(bundledAssetName: "ProviderClaude")),
        profileLabel: "Personal Claude",
        authenticationState: .authenticated,
        identity: AccountIdentity(email: "maker@example.com"),
        subscription: Subscription(planName: "Pro"),
        meters: [
            QuotaMeter(
                id: "five-personal", displayName: "Current session", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "five_hour"), usedFraction: 0.28,
                resetsAt: Date().addingTimeInterval(8_400), source: "preview"),
            QuotaMeter(
                id: "week-personal", displayName: "Current week", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "seven_day"), usedFraction: 0.73,
                resetsAt: Date().addingTimeInterval(175_000), source: "preview"),
        ],
        freshness: .fresh
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cappy").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Limits across your coding accounts").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            VStack(spacing: 10) {
                ForEach([codex, claude, teamCodex, personalClaude]) { snapshot in
                    AccountCard(
                        snapshot: snapshot,
                        isConfirmingRemoval: false,
                        isRemoving: false,
                        onLogin: {},
                        onConfigure: {},
                        onRequestRemove: {},
                        onCancelRemove: {},
                        onConfirmRemove: {},
                        showsMenu: false
                    )
                }
            }
            .padding(12)
            Divider()
            HStack {
                Text("Add account…")
                Spacer()
                Text("Quit").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
