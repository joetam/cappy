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
    static let overlayWidth: CGFloat = 340
    static let overlayHeight: CGFloat = 420
}

@MainActor
final class MenuPresentation: ObservableObject {
    @Published var isEditingAccounts = false
}

private struct RendersNativeProgressKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var rendersNativeProgress: Bool {
        get { self[RendersNativeProgressKey.self] }
        set { self[RendersNativeProgressKey.self] = newValue }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: MenuPresentation
    @AppStorage("dashboard.showsAllMeters") private var showsAllMeters = false
    @State private var onboardingPreservation: CurrentCLIAccountContext?
    @State private var onboardingAddContext: CurrentCLIAccountContext?
    @State private var expandedProfileIDs: Set<String> = []
    var onToggleDesktopOverlay: () -> Void = {}
    @State private var removalCandidateID: String?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if presentation.isEditingAccounts {
                AccountEditorView(model: model) { presentation.isEditingAccounts = false }
            } else if let onboardingPreservation {
                PreserveAccountView(
                    model: model,
                    profile: onboardingPreservation.profile,
                    snapshot: onboardingPreservation.snapshot,
                    onClose: { self.onboardingPreservation = nil },
                    onComplete: { self.onboardingPreservation = nil }
                )
            } else if let onboardingAddContext {
                AddAccountView(
                    model: model,
                    onClose: { self.onboardingAddContext = nil },
                    initialProviderID: onboardingAddContext.profile.providerID,
                    onComplete: {
                        model.acknowledgeCurrentCLIAccount(profileID: onboardingAddContext.profile.id)
                        self.onboardingAddContext = nil
                    }
                )
            } else if let choice = model.initialCLIAccountChoices.first {
                InitialCLIAccountView(
                    context: choice,
                    remainingCount: model.initialCLIAccountChoices.count,
                    onKeepAvailable: { onboardingPreservation = choice },
                    onUseCurrent: { model.useCurrentCLIAccount(profileID: choice.profile.id) },
                    onAddAnother: { onboardingAddContext = choice }
                )
            } else {
                dashboard
            }
        }
        .frame(width: CappyLayout.popoverWidth)
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
                    ForEach(model.cliAccountChangeNotices) { notice in
                        CLIAccountChangeRow(
                            notice: notice,
                            onReview: { presentation.isEditingAccounts = true },
                            onDismiss: { model.dismissCLIAccountChange(profileID: notice.current.profile.id) }
                        )
                    }
                    if model.dashboardSnapshots.isEmpty {
                        MessageRow(
                            icon: "gauge.with.dots.needle.0percent", text: "No signed-in accounts found. Add an account to begin.",
                            color: .secondary)
                    }
                    ForEach(Array(model.dashboardSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        AccountSection(
                            snapshot: snapshot,
                            isConfirmingRemoval: removalCandidateID == snapshot.profileID,
                            isRemoving: removingProfileID == snapshot.profileID,
                            isSigningIn: model.isSigningIn(profileID: snapshot.profileID),
                            showsAllMeters: showsAllMeters,
                            isExpanded: expandedProfileIDs.contains(snapshot.profileID),
                            showsMenu: model.profiles.first(where: { $0.id == snapshot.profileID })?.isManaged == true,
                            onToggleExpanded: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if expandedProfileIDs.contains(snapshot.profileID) {
                                        expandedProfileIDs.remove(snapshot.profileID)
                                    } else {
                                        expandedProfileIDs.insert(snapshot.profileID)
                                    }
                                }
                            }
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
                        if index < model.dashboardSnapshots.count - 1 {
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
                    presentation.isEditingAccounts = true
                } label: {
                    Label("Edit Accounts…", systemImage: "person.2")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Picker("Quota details", selection: $showsAllMeters) {
                        Text("Compact").tag(false)
                        Text("All Limits").tag(true)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(showsAllMeters ? "Showing all quota limits" : "Showing compact quota limits")
                Button(action: onToggleDesktopOverlay) {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Show desktop widget")
                .accessibilityLabel("Show desktop widget")
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
        }
    }
}

private struct InitialCLIAccountView: View {
    let context: CurrentCLIAccountContext
    let remainingCount: Int
    let onKeepAvailable: () -> Void
    let onUseCurrent: () -> Void
    let onAddAnother: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set Up Accounts")
                        .font(.headline)
                    if remainingCount > 1 {
                        Text("Reviewing \(context.snapshot.provider.displayName) · \(remainingCount) sign-ins found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("We found your current \(context.snapshot.provider.displayName) sign-in")
                            .font(.callout.weight(.semibold))
                        Text(context.displayIdentity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    ProviderMark(provider: context.snapshot.provider)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Keep this account available")
                            .font(.callout.weight(.medium))
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(
                        "Sign in once to create a separate local session. This account will remain in Cappy after you switch "
                            + "CLI accounts."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Keep this account available", action: onKeepAvailable)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Use the current CLI sign-in")
                        .font(.callout.weight(.medium))
                    Text(
                        "No login is needed. This connection will follow whichever account is signed in to the "
                            + "\(context.snapshot.provider.displayName) CLI."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Use current CLI sign-in", action: onUseCurrent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)

            Divider()

            HStack {
                Button("Add another account", action: onAddAnother)
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct CLIAccountChangeRow: View {
    let notice: CLIAccountChangeNotice
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(notice.current.snapshot.provider.displayName) CLI account changed")
                        .fontWeight(.medium)
                    Text(changeDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("Review accounts", action: onReview).controlSize(.small)
                Button("Dismiss", action: onDismiss).controlSize(.small).buttonStyle(.borderless)
                Spacer()
            }
            .padding(.leading, 24)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.07))
    }

    private var changeDescription: String {
        let current = notice.current.displayIdentity
        if notice.previousAccountWasKept {
            return "Cappy now follows \(current). \(notice.previousIdentity) remains available separately."
        }
        return "Cappy now follows \(current). \(notice.previousIdentity) was not kept in Cappy."
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
    let showsAllMeters: Bool
    let isExpanded: Bool
    var showsMenu = true
    let onToggleExpanded: () -> Void
    let onLogin: () -> Void
    let onCancelLogin: () -> Void
    let onRequestRemove: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void

    private var detailLabel: String {
        let identity = snapshot.identity?.organization ?? snapshot.identity?.email ?? snapshot.provider.displayName
        guard let plan = displayPlan else { return identity }
        return "\(identity) · \(plan)"
    }

    private var displayPlan: String? {
        guard let plan = snapshot.subscription?.planName, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + String(plan.dropFirst())
    }

    private var compactMeters: [QuotaMeter] {
        let core: [QuotaMeter]
        switch snapshot.provider.id {
        case "openai-codex":
            core = snapshot.meters.filter { $0.scope.id == "codex" && $0.id.hasSuffix(".primary") }
        case "anthropic-claude":
            core = snapshot.meters.filter { $0.scope.id == "five_hour" || $0.scope.id == "seven_day" }
        default:
            core = Array(snapshot.meters.prefix(1))
        }

        let resolvedCore = core.isEmpty ? Array(snapshot.meters.prefix(1)) : core
        let coreIDs = Set(resolvedCore.map(\.id))
        let coreIsLow = resolvedCore.contains { meter in
            meter.usedFraction.map { 1 - $0 <= 0.25 } ?? false
        }
        let relevantSupplemental = snapshot.meters.filter { meter in
            guard !coreIDs.contains(meter.id) else { return false }
            switch meter.kind {
            case .balance, .count:
                return (meter.remaining ?? 0) > 0 || coreIsLow
            case .spend:
                switch meter.status {
                case .warning, .exhausted: return true
                default: return false
                }
            default:
                switch meter.status {
                case .warning, .exhausted: return true
                default: return false
                }
            }
        }
        let visibleIDs = Set((resolvedCore + relevantSupplemental).map(\.id))
        return snapshot.meters.filter { visibleIDs.contains($0.id) }
    }

    private var displayedMeters: [QuotaMeter] {
        showsAllMeters || isExpanded ? snapshot.meters : compactMeters
    }

    private var additionalMeterCount: Int {
        max(0, snapshot.meters.count - compactMeters.count)
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
                    ForEach(displayedMeters) { meter in MeterRow(meter: meter) }
                    if additionalMeterCount > 0 && !showsAllMeters {
                        Button(action: onToggleExpanded) {
                            HStack(spacing: 5) {
                                Text(isExpanded ? "Show fewer limits" : additionalLimitsLabel)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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
        .contentShape(Rectangle())
        .contextMenu {
            if showsMenu {
                Button("Remove account…", role: .destructive, action: onRequestRemove)
            }
        }
    }

    private var additionalLimitsLabel: String {
        "\(additionalMeterCount) more \(additionalMeterCount == 1 ? "limit" : "limits")"
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

struct ProviderMark: View {
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
                // Provider assets are app resources installed by package-app.sh.
                // Avoid SwiftPM's Bundle.module here: its generated accessor embeds
                // a developer-machine build path in the executable.
                let resourceURL = Bundle.main.url(forResource: assetName, withExtension: fileExtension)
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
    @Environment(\.rendersNativeProgress) private var rendersNativeProgress
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
                Group {
                    if rendersNativeProgress {
                        ProgressView(value: remainingFraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(capacityColor)
                    } else {
                        PreviewCapacityRail(remaining: remainingFraction, color: capacityColor)
                            .frame(height: 4)
                    }
                }
                .accessibilityLabel("\(Int((remainingFraction * 100).rounded())) percent remaining")
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

private struct PreviewCapacityRail: View {
    let remaining: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                Capsule().fill(color).frame(width: max(0, geometry.size.width * remaining))
            }
        }
    }
}

private struct AccountEditorView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var isAddingAccount = false
    @State private var preservationCandidate: ProfileSummary?
    @State private var removalCandidate: ProfileSummary?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if isAddingAccount {
                AddAccountView(model: model) { isAddingAccount = false }
            } else if let preservationCandidate,
                let snapshot = model.snapshot(profileID: preservationCandidate.id)
            {
                PreserveAccountView(model: model, profile: preservationCandidate, snapshot: snapshot) {
                    self.preservationCandidate = nil
                }
            } else {
                accountList
            }
        }
    }

    private var accountList: some View {
        let rowCount = max(2, model.managedProfiles.count + model.defaultProfiles.count)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accounts")
                        .font(.headline)
                    Text("Available accounts and current CLI sign-ins")
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

            List {
                Section("Added to Cappy") {
                    if model.managedProfiles.isEmpty {
                        Text("No separate accounts yet. Added accounts stay available when you switch CLI sign-ins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(Array(model.managedProfiles.enumerated()), id: \.element.id) { index, profile in
                            AccountEditorRow(
                                profile: profile,
                                provider: provider(for: profile),
                                snapshot: snapshot(for: profile),
                                isCurrentInCLI: isCurrentInCLI(profile),
                                isRemoving: removingProfileID == profile.id,
                                isOrderSaving: model.isReorderingAccounts,
                                canMoveUp: index > model.managedProfiles.startIndex && !model.isReorderingAccounts,
                                canMoveDown: index < model.managedProfiles.index(before: model.managedProfiles.endIndex)
                                    && !model.isReorderingAccounts,
                                onMoveUp: { move(profileID: profile.id, offset: -1) },
                                onMoveDown: { move(profileID: profile.id, offset: 1) },
                                onRemove: { removalCandidate = profile }
                            )
                            .moveDisabled(model.isReorderingAccounts)
                        }
                        .onMove(perform: moveProfiles)
                    }
                }

                Section("Current CLI sign-ins") {
                    ForEach(model.defaultProfiles) { profile in
                        CurrentCLIConnectionRow(
                            profile: profile,
                            provider: provider(for: profile),
                            snapshot: snapshot(for: profile),
                            keptAs: snapshot(for: profile).flatMap { model.matchingManagedProfile(for: $0) },
                            onPreserve: { preservationCandidate = profile }
                        )
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(height: min(max(CGFloat(rowCount) * 72 + 56, 230), 440))

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
            Text("This removes its separate local sign-in from this Mac. It does not delete the provider account.")
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
        var ordered = model.managedProfiles
        ordered.move(fromOffsets: source, toOffset: destination)
        model.reorderManagedAccounts(profileIDs: ordered.map(\.id))
    }

    private func move(profileID: String, offset: Int) {
        guard !model.isReorderingAccounts,
            let index = model.managedProfiles.firstIndex(where: { $0.id == profileID })
        else { return }
        let destination = index + offset
        guard model.managedProfiles.indices.contains(destination) else { return }
        var ordered = model.managedProfiles
        ordered.swapAt(index, destination)
        model.reorderManagedAccounts(profileIDs: ordered.map(\.id))
    }

    private func isCurrentInCLI(_ profile: ProfileSummary) -> Bool {
        model.defaultProfiles.contains { current in
            guard let snapshot = model.snapshot(profileID: current.id) else { return false }
            return model.matchingManagedProfile(for: snapshot)?.id == profile.id
        }
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
    let isCurrentInCLI: Bool
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
                Text(isCurrentInCLI ? "Added to Cappy · Currently active in the CLI" : "Added to Cappy · Available independently")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

private struct CurrentCLIConnectionRow: View {
    let profile: ProfileSummary
    let provider: ProviderDescriptor
    let snapshot: AccountSnapshot?
    let keptAs: ProfileSummary?
    let onPreserve: () -> Void

    private var identityLabel: String {
        snapshot?.identity?.organization ?? snapshot?.identity?.email ?? provider.displayName
    }

    private var isAuthenticated: Bool { snapshot?.authenticationState == .authenticated }
    private var canPreserve: Bool { isAuthenticated && keptAs == nil && snapshot?.identity?.email?.isEmpty == false }
    private var sourceStatus: String {
        if let keptAs { return "Currently active · Kept as \(keptAs.label)" }
        if snapshot?.identity?.email?.isEmpty != false { return "Identity unavailable · Refresh before keeping this account" }
        return "Follows whichever account the CLI is using"
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                if isAuthenticated {
                    Text(identityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(sourceStatus)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Not signed in · Cappy will detect the next CLI sign-in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if canPreserve {
                Button("Keep available", action: onPreserve)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct PreserveAccountView: View {
    @ObservedObject var model: AppModel
    let profile: ProfileSummary
    let snapshot: AccountSnapshot
    let onClose: () -> Void
    let onComplete: () -> Void
    @State private var label: String
    @State private var isWorking = false

    init(
        model: AppModel,
        profile: ProfileSummary,
        snapshot: AccountSnapshot,
        onClose: @escaping () -> Void,
        onComplete: (() -> Void)? = nil
    ) {
        self.model = model
        self.profile = profile
        self.snapshot = snapshot
        self.onClose = onClose
        self.onComplete = onComplete ?? onClose
        let suggestedLabel = snapshot.identity?.email ?? snapshot.identity?.organization ?? "\(snapshot.provider.displayName) account"
        _label = State(initialValue: suggestedLabel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                Text("Keep Account Available")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.identity?.email ?? snapshot.identity?.organization ?? snapshot.provider.displayName)
                            .font(.callout.weight(.medium))
                        Text("Currently found through \(snapshot.provider.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    ProviderMark(provider: snapshot.provider)
                }

                Text(
                    "Sign in with this same account once. Cappy will create a separate local session so it remains available "
                        + "after you switch or sign out in the CLI. Existing credentials are not copied."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name in Cappy").font(.caption).foregroundStyle(.secondary)
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
                Button("Sign in and keep available") {
                    isWorking = true
                    Task {
                        let added = await model.addAccount(
                            providerID: profile.providerID,
                            label: label,
                            sourceProfileID: profile.id,
                            expectedSourceEmail: snapshot.identity?.email
                        )
                        isWorking = false
                        if added { onComplete() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || snapshot.identity?.email?.isEmpty != false
                        || isWorking
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { model.addAccountMessage = nil }
    }
}

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    let onComplete: () -> Void
    @State private var selectedProvider = ""
    @State private var label = ""
    @State private var isWorking = false
    @State private var preservationCandidate: ProfileSummary?

    init(
        model: AppModel,
        onClose: @escaping () -> Void,
        initialProviderID: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        self.model = model
        self.onClose = onClose
        self.onComplete = onComplete ?? onClose
        _selectedProvider = State(initialValue: initialProviderID ?? "")
    }

    private var currentCLISnapshot: AccountSnapshot? {
        guard let profile = model.defaultProfiles.first(where: { $0.providerID == selectedProvider }),
            let snapshot = model.snapshot(profileID: profile.id),
            snapshot.authenticationState == .authenticated
        else { return nil }
        return snapshot
    }

    private var currentCLIProfile: ProfileSummary? {
        guard currentCLISnapshot != nil else { return nil }
        return model.defaultProfiles.first { $0.providerID == selectedProvider }
    }

    var body: some View {
        Group {
            if let preservationCandidate,
                let snapshot = model.snapshot(profileID: preservationCandidate.id)
            {
                PreserveAccountView(
                    model: model,
                    profile: preservationCandidate,
                    snapshot: snapshot,
                    onClose: { self.preservationCandidate = nil },
                    onComplete: onComplete
                )
            } else {
                addAccountForm
            }
        }
    }

    private var addAccountForm: some View {
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").font(.caption).foregroundStyle(.secondary)
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(model.providers) { provider in Text(provider.displayName).tag(provider.id) }
                    }
                    .labelsHidden()
                }

                if let currentCLISnapshot {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Current CLI sign-in")
                            .font(.callout.weight(.medium))
                        Label {
                            Text(currentCLISnapshot.identity?.email ?? currentCLISnapshot.provider.displayName)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "terminal")
                        }
                        .font(.caption)
                        Text("Use it as-is with no login, or keep it available before switching accounts in the CLI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let kept = model.matchingManagedProfile(for: currentCLISnapshot) {
                            Label("Already available as \(kept.label)", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if currentCLISnapshot.identity?.email?.isEmpty == false {
                            VStack(alignment: .leading, spacing: 6) {
                                Button("Use current CLI sign-in") {
                                    if let currentCLIProfile {
                                        model.useCurrentCLIAccount(profileID: currentCLIProfile.id)
                                    }
                                    onClose()
                                }
                                Button("Keep current account available") {
                                    preservationCandidate = currentCLIProfile
                                }
                            }
                            .controlSize(.small)
                        } else {
                            Text("Refresh the account before keeping it; Cappy needs its email to verify the new sign-in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(currentCLISnapshot == nil ? "Sign in to add an account" : "Add a different account")
                        .font(.callout.weight(.medium))
                    Text("This creates a separate local sign-in that remains available when you switch CLI accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Name in Cappy").font(.caption).foregroundStyle(.secondary)
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
                Button(currentCLISnapshot == nil ? "Sign in to add account" : "Sign in to a different account") {
                    isWorking = true
                    Task {
                        let added = await model.addAccount(providerID: selectedProvider, label: label)
                        isWorking = false
                        if added { onComplete() }
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
                        showsAllMeters: false,
                        isExpanded: false,
                        showsMenu: false,
                        onToggleExpanded: {},
                        onLogin: {},
                        onCancelLogin: {},
                        onRequestRemove: {},
                        onCancelRemove: {},
                        onConfirmRemove: {}
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
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Image(systemName: "macwindow.on.rectangle").foregroundStyle(.secondary)
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        // The production view inherits NSPopover's surface. The standalone
        // renderer supplies material only so documentation previews have one.
        .background(.regularMaterial)
        .environment(\.rendersNativeProgress, false)
    }
}
