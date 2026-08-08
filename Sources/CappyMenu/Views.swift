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

enum CappyLayout {
    static let popoverWidth: CGFloat = 372
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var isEditingAccounts = false
    @State private var removalCandidateID: String?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if isEditingAccounts {
                AccountEditorView(model: model) { isEditingAccounts = false }
            } else {
                dashboard
            }
        }
        .frame(width: CappyLayout.popoverWidth)
        .background(.regularMaterial)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = model.errorMessage {
                        MessageRow(icon: "exclamationmark.triangle.fill", text: error, color: .red)
                    }
                    if let notice = model.noticeMessage {
                        MessageRow(icon: "checkmark.circle", text: notice, color: .secondary)
                    }
                    if let warning = model.duplicateWarning {
                        MessageRow(icon: "person.2.badge.gearshape", text: warning, color: .orange)
                    }
                    if model.snapshots.isEmpty {
                        MessageRow(
                            icon: "gauge.with.dots.needle.0percent", text: "No account readings yet. Refresh or add an account.",
                            color: .secondary)
                    }
                    ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        AccountSection(
                            snapshot: snapshot,
                            isConfirmingRemoval: removalCandidateID == snapshot.profileID,
                            isRemoving: removingProfileID == snapshot.profileID,
                            isSigningIn: model.isSigningIn(profileID: snapshot.profileID)
                        ) {
                            model.login(profileID: snapshot.profileID)
                        } onCancelLogin: {
                            model.cancelLogin(profileID: snapshot.profileID)
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
                        if index < model.snapshots.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 520)

            Divider()
            HStack {
                Button {
                    isEditingAccounts = true
                } label: {
                    Label("Edit Accounts…", systemImage: "person.2")
                }
                .buttonStyle(.borderless)
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
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.bar)
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
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(color.opacity(0.07))
    }
}

struct AccountSection: View {
    let snapshot: AccountSnapshot
    let isConfirmingRemoval: Bool
    let isRemoving: Bool
    let isSigningIn: Bool
    let onLogin: () -> Void
    let onCancelLogin: () -> Void
    let onRequestRemove: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void
    var showsMenu = true

    private var detailLabel: String {
        let identity = snapshot.identity?.organization ?? snapshot.identity?.email ?? snapshot.provider.displayName
        guard let plan = displayPlan else { return identity }
        return "\(identity) · \(plan)"
    }

    private var displayPlan: String? {
        guard let plan = snapshot.subscription?.planName, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + String(plan.dropFirst())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderMark(provider: snapshot.provider)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.profileLabel)
                        .font(.headline)
                    Text(detailLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                freshnessMark
                if showsMenu {
                    Menu {
                        Button("Remove account…", role: .destructive, action: onRequestRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if snapshot.authenticationState != .authenticated {
                HStack {
                    Text(
                        isSigningIn
                            ? "Finish signing in with \(snapshot.provider.displayName)."
                            : (snapshot.message ?? "Sign in to read quota.")
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: onCancelLogin).controlSize(.small)
                    } else {
                        Button("Sign in", action: onLogin).controlSize(.small)
                    }
                }
                .padding(.leading, 32)
            } else if snapshot.meters.isEmpty {
                Text(snapshot.message ?? "No quota meters available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            } else {
                VStack(spacing: 9) {
                    ForEach(snapshot.meters) { meter in MeterRow(meter: meter) }
                }
                .padding(.leading, 32)
            }

            if isConfirmingRemoval {
                Divider()
                HStack(spacing: 8) {
                    Text("Remove \(snapshot.profileLabel)?")
                        .font(.callout)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var freshnessMark: some View {
        switch snapshot.freshness {
        case .fresh:
            EmptyView()
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Reading is out of date")
        case .pending:
            ProgressView()
                .controlSize(.mini)
                .help("Waiting for quota")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .help("Quota unavailable")
        }
    }
}

private struct ProviderMark: View {
    let provider: ProviderDescriptor

    private var providerColor: Color { Color(hex: provider.accentHex ?? "5B6CFF") }

    var body: some View {
        let resolvedImage = providerImage
        ZStack {
            if let resolvedImage {
                Image(nsImage: resolvedImage)
                    .renderingMode(provider.icon?.renderingMode == "template" ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .padding(provider.icon?.applicationBundleIdentifier == nil ? 2 : 0)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: provider.symbolName ?? "circle.grid.2x2")
                    .font(.body.weight(.medium))
                    .foregroundStyle(providerColor)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) provider")
    }

    private var providerImage: NSImage? {
        if let assetName = provider.icon?.bundledAssetName {
            for fileExtension in ["svg", "png"] {
                let resourceURL =
                    Bundle.main.url(forResource: assetName, withExtension: fileExtension)
                    ?? Bundle.module.url(forResource: assetName, withExtension: fileExtension)
                if let resourceURL, let image = NSImage(contentsOf: resourceURL) { return image }
            }
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
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                if let reset = resetLabel {
                    Text(reset)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            if let remainingFraction {
                CapacityRail(remaining: remainingFraction, color: capacityColor)
                    .frame(height: 4)
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
        if remainingFraction <= 0.1 { return .red }
        if remainingFraction <= 0.25 { return .orange }
        return .accentColor
    }

    private var valueColor: Color {
        guard let remainingFraction, remainingFraction <= 0.25 else { return .secondary }
        return remainingFraction <= 0.1 ? .red : .orange
    }

    private var resetLabel: String? {
        guard let date = meter.resetsAt else { return nil }
        return "· \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
    }
}

struct CapacityRail: View {
    let remaining: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                Capsule().fill(color).frame(width: max(0, geometry.size.width * remaining))
            }
        }
        .accessibilityLabel("\(Int((remaining * 100).rounded())) percent remaining")
    }
}

private struct AccountEditorView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var isAddingAccount = false
    @State private var removalCandidate: ProfileSummary?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if isAddingAccount {
                AddAccountView(model: model) { isAddingAccount = false }
            } else {
                accountList
            }
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accounts")
                        .font(.headline)
                    Text("Drag to set the menu order")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isReorderingAccounts {
                    ProgressView()
                        .controlSize(.small)
                        .help("Saving account order")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let error = model.errorMessage {
                MessageRow(icon: "exclamationmark.triangle.fill", text: error, color: .red)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if model.profiles.isEmpty {
                ContentUnavailableView(
                    "No accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add an account to start tracking its limits.")
                )
                .frame(height: 210)
            } else {
                List {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                        AccountEditorRow(
                            profile: profile,
                            provider: provider(for: profile),
                            snapshot: snapshot(for: profile),
                            isRemoving: removingProfileID == profile.id,
                            isOrderSaving: model.isReorderingAccounts,
                            canMoveUp: index > model.profiles.startIndex && !model.isReorderingAccounts,
                            canMoveDown: index < model.profiles.index(before: model.profiles.endIndex)
                                && !model.isReorderingAccounts,
                            onMoveUp: { move(profileID: profile.id, offset: -1) },
                            onMoveDown: { move(profileID: profile.id, offset: 1) },
                            onRemove: { removalCandidate = profile }
                        )
                        .moveDisabled(model.isReorderingAccounts)
                    }
                    .onMove(perform: moveProfiles)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: min(max(CGFloat(model.profiles.count) * 58 + 18, 180), 410))
            }

            Divider()

            HStack {
                Button {
                    isAddingAccount = true
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(model.isReorderingAccounts)
                Spacer()
                if model.isReorderingAccounts {
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .alert(
            "Remove \(removalCandidate?.label ?? "account")?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { removalCandidate = nil }
            Button("Remove", role: .destructive) { removeCandidate() }
        } message: {
            Text("This removes it from Cappy.")
        }
    }

    private func provider(for profile: ProfileSummary) -> ProviderDescriptor {
        snapshot(for: profile)?.provider
            ?? model.providers.first(where: { $0.id == profile.providerID })
            ?? ProviderDescriptor(id: profile.providerID, displayName: profile.providerID)
    }

    private func snapshot(for profile: ProfileSummary) -> AccountSnapshot? {
        model.snapshots.first { $0.profileID == profile.id }
    }

    private func moveProfiles(from source: IndexSet, to destination: Int) {
        var ordered = model.profiles
        ordered.move(fromOffsets: source, toOffset: destination)
        model.reorderAccounts(profileIDs: ordered.map(\.id))
    }

    private func move(profileID: String, offset: Int) {
        guard !model.isReorderingAccounts,
            let index = model.profiles.firstIndex(where: { $0.id == profileID })
        else { return }
        let destination = index + offset
        guard model.profiles.indices.contains(destination) else { return }
        var ordered = model.profiles
        ordered.swapAt(index, destination)
        model.reorderAccounts(profileIDs: ordered.map(\.id))
    }

    private func removeCandidate() {
        guard let profile = removalCandidate else { return }
        removalCandidate = nil
        removingProfileID = profile.id
        Task {
            _ = await model.removeAccount(profileID: profile.id)
            removingProfileID = nil
        }
    }
}

private struct AccountEditorRow: View {
    let profile: ProfileSummary
    let provider: ProviderDescriptor
    let snapshot: AccountSnapshot?
    let isRemoving: Bool
    let isOrderSaving: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    private var detailLabel: String {
        let identity = snapshot?.identity?.organization ?? snapshot?.identity?.email ?? provider.displayName
        guard let plan = snapshot?.subscription?.planName, !plan.isEmpty else { return identity }
        return "\(identity) · \(plan.prefix(1).uppercased())\(plan.dropFirst())"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            ProviderMark(provider: provider)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isRemoving {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                        .disabled(!canMoveUp)
                    Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                        .disabled(!canMoveDown)
                    Divider()
                    Button("Remove account…", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isOrderSaving)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var selectedProvider = ""
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
                Text("Add Account")
                    .font(.headline)
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
                bundledAssetName: "ProviderCodex",
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
                bundledAssetName: "ProviderCodex",
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

    private let teamClaude = AccountSnapshot(
        profileID: "claude-team-preview",
        provider: ProviderDescriptor(
            id: "anthropic-claude", displayName: "Claude", symbolName: "sparkles", accentHex: "D97757",
            icon: ProviderIconDescriptor(bundledAssetName: "ProviderClaude")),
        profileLabel: "Research Claude",
        authenticationState: .authenticated,
        identity: AccountIdentity(organization: "Lab Team"),
        subscription: Subscription(planName: "Team"),
        meters: [
            QuotaMeter(
                id: "five-research", displayName: "Current session", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "five_hour"), usedFraction: 0.34,
                resetsAt: Date().addingTimeInterval(6_200), source: "preview"),
            QuotaMeter(
                id: "week-research", displayName: "Current week", kind: .rollingWindow, unit: .percent,
                scope: .init(kind: "account", id: "seven_day"), usedFraction: 0.19,
                resetsAt: Date().addingTimeInterval(340_000), source: "preview"),
        ],
        freshness: .fresh
    )

    var body: some View {
        let snapshots = [codex, claude, teamCodex, personalClaude, teamClaude]
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    AccountSection(
                        snapshot: snapshot,
                        isConfirmingRemoval: false,
                        isRemoving: false,
                        isSigningIn: false,
                        onLogin: {},
                        onCancelLogin: {},
                        onRequestRemove: {},
                        onCancelRemove: {},
                        onConfirmRemove: {},
                        showsMenu: false
                    )
                    if index < snapshots.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(.vertical, 4)
            Divider()
            HStack {
                Label("Edit Accounts…", systemImage: "person.2")
                Spacer()
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.bar)
        }
        .background(.regularMaterial)
    }
}
