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
    static let overlayMinimumHeight: CGFloat = 180
}

private extension ProviderDescriptor {
    var cliDisplayName: String {
        switch id {
        case "anthropic-claude": return "Claude Code"
        case "openai-codex": return "Codex"
        default: return "\(displayName) CLI"
        }
    }
}

private func connectionDetailLabel(snapshot: AccountSnapshot?, provider: ProviderDescriptor) -> String {
    guard let snapshot else { return provider.displayName }

    var parts: [String] = []
    func appendDistinct(_ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        guard !parts.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        parts.append(value)
    }

    if let email = snapshot.identity?.email, !email.isEmpty {
        appendDistinct(email)
        appendDistinct(snapshot.identity?.organization)
    } else {
        appendDistinct(snapshot.identity?.displayName)
        appendDistinct(snapshot.identity?.organization)
    }
    if let plan = snapshot.subscription?.planName, !plan.isEmpty {
        appendDistinct(plan.prefix(1).uppercased() + String(plan.dropFirst()))
    }
    return parts.isEmpty ? provider.displayName : parts.joined(separator: " · ")
}

func subscriptionBillingLabel(_ subscription: Subscription?, relativeTo referenceDate: Date = Date()) -> String? {
    guard let date = subscription?.nextBillingDate else { return nil }
    let calendar = Calendar.current
    guard date >= calendar.startOfDay(for: referenceDate) else { return nil }

    let value: String
    if calendar.isDate(date, equalTo: referenceDate, toGranularity: .year) {
        value = date.formatted(.dateTime.month(.abbreviated).day())
    } else {
        value = date.formatted(.dateTime.month(.abbreviated).day().year())
    }
    return "Renews \(value)"
}

@MainActor
final class MenuPresentation: ObservableObject {
    @Published var isEditingConnections = false
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
    @AppStorage("dashboard.showsRenewalDates") private var showsRenewalDates = false
    @State private var onboardingSpecificAccount: CurrentCLIAccountContext?
    @State private var onboardingAddConnection: CurrentCLIAccountContext?
    @State private var expandedProfileIDs: Set<String> = []
    @State private var removalCandidateID: String?
    @State private var removingProfileID: String?

    var body: some View {
        Group {
            if presentation.isEditingConnections {
                ConnectionEditorView(model: model) { presentation.isEditingConnections = false }
            } else if let onboardingSpecificAccount {
                SpecificAccountConnectionView(
                    model: model,
                    profile: onboardingSpecificAccount.profile,
                    snapshot: onboardingSpecificAccount.snapshot,
                    onClose: { self.onboardingSpecificAccount = nil },
                    onComplete: {
                        model.useSpecificAccountConnection(profileID: onboardingSpecificAccount.profile.id)
                        self.onboardingSpecificAccount = nil
                    }
                )
            } else if let onboardingAddConnection {
                AddConnectionView(
                    model: model,
                    onClose: { self.onboardingAddConnection = nil },
                    initialProviderID: onboardingAddConnection.profile.providerID,
                    onComplete: {
                        model.useSpecificAccountConnection(profileID: onboardingAddConnection.profile.id)
                        self.onboardingAddConnection = nil
                    }
                )
            } else if let choice = model.initialCLIAccountChoices.first {
                InitialConnectionChoiceView(
                    context: choice,
                    remainingCount: model.initialCLIAccountChoices.count,
                    onConnectSpecificAccount: { onboardingSpecificAccount = choice },
                    onUseCurrentSignIn: { model.useCurrentCLISignIn(profileID: choice.profile.id) },
                    onConnectDifferentAccount: { onboardingAddConnection = choice }
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
                            onReview: { presentation.isEditingConnections = true },
                            onDismiss: { model.dismissCLIAccountChange(profileID: notice.current.profile.id) }
                        )
                    }
                    if model.dashboardSnapshots.isEmpty {
                        MessageRow(
                            icon: "gauge.with.dots.needle.0percent",
                            text: "No active connections. Open Connections to connect through Cappy or a provider CLI.",
                            color: .secondary)
                    }
                    ForEach(Array(model.dashboardSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        AccountSection(
                            snapshot: snapshot,
                            isConfirmingRemoval: removalCandidateID == snapshot.profileID,
                            isRemoving: removingProfileID == snapshot.profileID,
                            isSigningIn: model.isSigningIn(profileID: snapshot.profileID),
                            showsAllMeters: showsAllMeters,
                            showsRenewalDate: showsRenewalDates,
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
                    presentation.isEditingConnections = true
                } label: {
                    Label("Connections…", systemImage: "link")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Picker("Quota details", selection: $showsAllMeters) {
                        Text("Compact").tag(false)
                        Text("All Limits").tag(true)
                    }
                    Divider()
                    Toggle("Show renewal dates", isOn: $showsRenewalDates)
                    Text("Renewal dates are currently available for Codex only")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Configure quota details")
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

private struct InitialConnectionChoiceView: View {
    let context: CurrentCLIAccountContext
    let remainingCount: Int
    let onConnectSpecificAccount: () -> Void
    let onUseCurrentSignIn: () -> Void
    let onConnectDifferentAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Choose Connection Type")
                        .font(.headline)
                    if remainingCount > 1 {
                        Text("\(context.snapshot.provider.displayName) · \(remainingCount) providers to review")
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
                        Text("Signed in to \(context.snapshot.provider.cliDisplayName)")
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
                        Text("Connect through Cappy")
                            .font(.callout.weight(.medium))
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(
                        "Cappy signs in separately to \(context.displayIdentity). This connection always points to "
                            + "that account, even if you switch accounts in \(context.snapshot.provider.cliDisplayName)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Connect through Cappy", action: onConnectSpecificAccount)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect through \(context.snapshot.provider.cliDisplayName)")
                        .font(.callout.weight(.medium))
                    Text(
                        "Uses whichever account is signed in to \(context.snapshot.provider.cliDisplayName). "
                            + "No additional login."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Connect through \(context.snapshot.provider.cliDisplayName)", action: onUseCurrentSignIn)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)

            Divider()

            HStack {
                Button("Connect a different account", action: onConnectDifferentAccount)
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
                    Text("\(notice.current.snapshot.provider.cliDisplayName) sign-in changed")
                        .fontWeight(.medium)
                    Text(changeDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("Review connections", action: onReview).controlSize(.small)
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
            return
                "This connection now points to \(current). \(notice.previousIdentity) is still connected through Cappy."
        }
        return "This connection now points to \(current) instead of \(notice.previousIdentity)."
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
    let showsRenewalDate: Bool
    let isExpanded: Bool
    var showsMenu = true
    let onToggleExpanded: () -> Void
    let onLogin: () -> Void
    let onCancelLogin: () -> Void
    let onRequestRemove: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void

    private var detailLabel: String {
        connectionDetailLabel(snapshot: snapshot, provider: snapshot.provider)
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsRenewalDate,
                        let billingLabel = subscriptionBillingLabel(snapshot.subscription)
                    {
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
                    Text("Remove the \(snapshot.profileLabel) connection?")
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
                Button("Remove connection…", role: .destructive, action: onRequestRemove)
            }
        }
    }

    private var additionalLimitsLabel: String {
        "\(additionalMeterCount) more \(additionalMeterCount == 1 ? "limit" : "limits")"
    }

    @ViewBuilder private var freshnessProgress: some View {
        if snapshot.freshness == .pending {
            ProgressView()
                .controlSize(.mini)
                .help("Waiting for quota")
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

private struct ConnectionEditorView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @AppStorage("dashboard.showsRenewalDates") private var showsRenewalDates = false
    @State private var isAddingConnection = false
    @State private var isEditingAccountOrder = false
    @State private var specificAccountCandidate: ProfileSummary?
    @State private var removalCandidate: ProfileSummary?
    @State private var removingProfileID: String?
    @State private var renameCandidate: ProfileSummary?
    @State private var renameLabel = ""
    @State private var renamingProfileID: String?

    var body: some View {
        Group {
            if isAddingConnection {
                AddConnectionView(model: model) { isAddingConnection = false }
            } else if let specificAccountCandidate,
                let snapshot = model.snapshot(profileID: specificAccountCandidate.id)
            {
                SpecificAccountConnectionView(model: model, profile: specificAccountCandidate, snapshot: snapshot) {
                    self.specificAccountCandidate = nil
                }
            } else {
                connectionList
            }
        }
    }

    private var connectionList: some View {
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(model.isReorderingAccounts)
                .help("Back")

                Text("Connections")
                    .font(.headline)
                Spacer()
                if model.isReorderingAccounts {
                    ProgressView()
                        .controlSize(.small)
                        .help("Saving account order")
                }
                Button(isEditingAccountOrder ? "Done" : "Edit") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditingAccountOrder.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isReorderingAccounts)
                .help(isEditingAccountOrder ? "Finish reordering accounts" : "Edit account order")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let error = model.errorMessage {
                MessageRow(icon: "exclamationmark.triangle.fill", text: error, color: .red)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if isEditingAccountOrder {
                AccountOrderEditor(model: model)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ConnectionGroup(
                            title: "Connected through Cappy",
                            explanation:
                                "Cappy signs in separately for each account. These connections stay with the same accounts "
                                + "when you switch accounts in Codex or Claude Code."
                        ) {
                            if model.managedProfiles.isEmpty {
                                Text("No accounts connected through Cappy.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(model.managedProfiles) { profile in
                                    SpecificAccountConnectionRow(
                                        profile: profile,
                                        provider: provider(for: profile),
                                        snapshot: snapshot(for: profile),
                                        isWorking: removingProfileID == profile.id || renamingProfileID == profile.id,
                                        showsRenewalDate: showsRenewalDates,
                                        onRename: { beginRenaming(profile) },
                                        onRemove: { removalCandidate = profile }
                                    )
                                }
                            }
                        }

                        ConnectionGroup(
                            title: "Connected through provider CLIs",
                            explanation:
                                "Uses whichever accounts are signed in to Codex and Claude Code. A connection changes when "
                                + "you switch accounts in its provider CLI."
                        ) {
                            ForEach(model.defaultProfiles) { profile in
                                CurrentCLIConnectionRow(
                                    profile: profile,
                                    provider: provider(for: profile),
                                    snapshot: snapshot(for: profile),
                                    hasDirectConnection: snapshot(for: profile).flatMap {
                                        model.matchingManagedProfile(for: $0)
                                    } != nil,
                                    isSelected: model.usesCurrentCLISignIn(providerID: profile.providerID),
                                    showsRenewalDate: showsRenewalDates,
                                    onUse: { model.useCurrentCLISignIn(profileID: profile.id) },
                                    onStop: { model.stopUsingCurrentCLISignIn(providerID: profile.providerID) },
                                    onConnectSpecificAccount: { specificAccountCandidate = profile }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .frame(
                    height: min(
                        max(CGFloat(max(2, model.managedProfiles.count + model.defaultProfiles.count)) * 76 + 162, 320),
                        460
                    ))

                Divider()

                HStack {
                    Button {
                        isAddingConnection = true
                    } label: {
                        Label("Add Connection…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isReorderingAccounts)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert(
            "Remove \(removalCandidate?.label ?? "connection")?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { removalCandidate = nil }
            Button("Remove", role: .destructive) { removeCandidate() }
        } message: {
            Text(
                "This removes the Cappy connection and its local sign-in from this Mac. It does not delete the provider account."
            )
        }
        .alert(
            "Rename connection",
            isPresented: Binding(
                get: { renameCandidate != nil },
                set: { if !$0 { renameCandidate = nil } }
            )
        ) {
            TextField("Connection name", text: $renameLabel)
            Button("Cancel", role: .cancel) { renameCandidate = nil }
            Button("Rename", action: renameConnection)
                .disabled(renameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Use a name that distinguishes this account in Cappy.")
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

    private func removeCandidate() {
        guard let profile = removalCandidate else { return }
        removalCandidate = nil
        removingProfileID = profile.id
        Task {
            _ = await model.removeAccount(profileID: profile.id)
            removingProfileID = nil
        }
    }

    private func beginRenaming(_ profile: ProfileSummary) {
        renameLabel = profile.label
        renameCandidate = profile
    }

    private func renameConnection() {
        guard let profile = renameCandidate else { return }
        let label = renameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        renameCandidate = nil
        renamingProfileID = profile.id
        Task {
            _ = await model.renameAccount(profileID: profile.id, label: label)
            renamingProfileID = nil
        }
    }
}

private struct AccountOrderEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snapshots = model.dashboardSnapshots
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drag accounts into the order they should appear on the quota screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only accounts currently shown on the quota screen appear here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if snapshots.isEmpty {
                Text("No accounts are currently shown on the quota screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                List {
                    ForEach(snapshots) { snapshot in
                        AccountOrderRow(snapshot: snapshot)
                            .moveDisabled(model.isReorderingAccounts)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: moveAccounts)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: min(max(CGFloat(snapshots.count) * 58 + 24, 180), 420))
            }
        }
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        guard !model.isReorderingAccounts else { return }
        var ordered = model.dashboardSnapshots
        ordered.move(fromOffsets: source, toOffset: destination)
        model.reorderDashboardAccounts(profileIDs: ordered.map(\.profileID))
    }
}

private struct AccountOrderRow: View {
    let snapshot: AccountSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            ProviderMark(provider: snapshot.provider)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.profileLabel)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(connectionDetailLabel(snapshot: snapshot, provider: snapshot.provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private struct ConnectionGroup<Content: View>: View {
    let title: String
    let explanation: String
    let content: Content

    init(title: String, explanation: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.explanation = explanation
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpecificAccountConnectionRow: View {
    let profile: ProfileSummary
    let provider: ProviderDescriptor
    let snapshot: AccountSnapshot?
    let isWorking: Bool
    let showsRenewalDate: Bool
    let onRename: () -> Void
    let onRemove: () -> Void

    private var detailLabel: String {
        connectionDetailLabel(snapshot: snapshot, provider: provider)
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showsRenewalDate, let billingLabel = subscriptionBillingLabel(snapshot?.subscription) {
                    Text(billingLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Rename connection…", action: onRename)
                    Button("Remove connection…", role: .destructive, action: onRemove)
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
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private struct CurrentCLIConnectionRow: View {
    let profile: ProfileSummary
    let provider: ProviderDescriptor
    let snapshot: AccountSnapshot?
    let hasDirectConnection: Bool
    let isSelected: Bool
    let showsRenewalDate: Bool
    let onUse: () -> Void
    let onStop: () -> Void
    let onConnectSpecificAccount: () -> Void

    private var identityLabel: String {
        connectionDetailLabel(snapshot: snapshot, provider: provider)
    }

    private var isAuthenticated: Bool { snapshot?.authenticationState == .authenticated }
    private var canConnectSpecificAccount: Bool {
        isAuthenticated && !hasDirectConnection && snapshot?.identity?.email?.isEmpty == false
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.cliDisplayName)
                    .font(.body.weight(.medium))
                if isAuthenticated {
                    Text(identityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsRenewalDate, let billingLabel = subscriptionBillingLabel(snapshot?.subscription) {
                        Text(billingLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if hasDirectConnection {
                        Text("Also connected through Cappy")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if canConnectSpecificAccount {
                        Button("Connect through Cappy…", action: onConnectSpecificAccount)
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text("No account currently signed in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "Use \(provider.cliDisplayName) sign-in",
                isOn: Binding(
                    get: { isSelected },
                    set: { $0 ? onUse() : onStop() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(isSelected ? "Disconnect from \(provider.cliDisplayName)" : "Connect through \(provider.cliDisplayName)")
        }
        .padding(.vertical, 5)
    }
}

private struct SpecificAccountConnectionView: View {
    @ObservedObject var model: AppModel
    let profile: ProfileSummary
    let snapshot: AccountSnapshot
    let onClose: () -> Void
    let onComplete: () -> Void
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
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                Text("Connect Through Cappy")
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
                        Text("Signed in to \(snapshot.provider.cliDisplayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    ProviderMark(provider: snapshot.provider)
                }

                Text(
                    "Sign in with this same account. Cappy creates a separate local sign-in that always points to this "
                        + "account, even if you switch accounts in \(snapshot.provider.cliDisplayName). Existing "
                        + "credentials are not copied. The verified email becomes the connection name."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Button("Connect through Cappy") {
                    isWorking = true
                    Task {
                        let added = await model.addAccount(
                            providerID: profile.providerID,
                            sourceProfileID: profile.id,
                            expectedSourceEmail: snapshot.identity?.email
                        )
                        isWorking = false
                        if added { onComplete() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    snapshot.identity?.email?.isEmpty != false
                        || isWorking
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { model.addAccountMessage = nil }
    }
}

struct AddConnectionView: View {
    private enum ConnectionMethod: Hashable {
        case cappy
        case providerCLI
    }

    @ObservedObject var model: AppModel
    let onClose: () -> Void
    let onComplete: () -> Void
    @State private var selectedProvider = ""
    @State private var connectionMethod: ConnectionMethod = .cappy
    @State private var isWorking = false

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

    private var selectedProviderDescriptor: ProviderDescriptor {
        model.providers.first(where: { $0.id == selectedProvider })
            ?? ProviderDescriptor(id: selectedProvider, displayName: selectedProvider)
    }

    private var currentCLISnapshot: AccountSnapshot? {
        guard let profile = model.defaultProfiles.first(where: { $0.providerID == selectedProvider }),
            let snapshot = model.snapshot(profileID: profile.id),
            snapshot.authenticationState == .authenticated
        else { return nil }
        return snapshot
    }

    private var currentCLIProfile: ProfileSummary? {
        return model.defaultProfiles.first { $0.providerID == selectedProvider }
    }

    private var usesCurrentCLISignIn: Bool {
        model.usesCurrentCLISignIn(providerID: selectedProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
                Text("Add Connection")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").font(.caption).foregroundStyle(.secondary)
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(model.providers) { provider in Text(provider.displayName).tag(provider.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .leading)
                    .disabled(isWorking)
                }

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect using")
                            .font(.callout.weight(.semibold))
                        Text("Choose which account Cappy should use for this connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox {
                        Picker("Connection method", selection: $connectionMethod) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("Connect through Cappy")
                                        .font(.callout.weight(.medium))
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(
                                    "Cappy signs in separately and keeps this connection tied to one account, even "
                                        + "when you switch accounts in \(selectedProviderDescriptor.cliDisplayName). "
                                        + "After verification, Cappy uses the account email as its name when available."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                            .tag(ConnectionMethod.cappy)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("Connect through \(selectedProviderDescriptor.cliDisplayName)")
                                        .font(.callout.weight(.medium))
                                    if usesCurrentCLISignIn {
                                        Label("Connected", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(
                                    "Uses whichever account is currently signed in to "
                                        + "\(selectedProviderDescriptor.cliDisplayName)."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                if let currentCLISnapshot {
                                    Text(currentCLISnapshot.identity?.email ?? currentCLISnapshot.provider.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("No account is currently signed in.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(ConnectionMethod.providerCLI)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .disabled(isWorking)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    if isWorking {
                        Task {
                            await model.cancelAddAccount()
                            isWorking = false
                        }
                    } else {
                        onClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking && model.activeAddJobID == nil)

                Button(action: performPrimaryAction) {
                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…")
                        }
                    } else {
                        Text(primaryActionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryActionDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear {
            model.addAccountMessage = nil
            if selectedProvider.isEmpty { selectedProvider = model.providers.first?.id ?? "openai-codex" }
        }
    }

    private var primaryActionTitle: String {
        switch connectionMethod {
        case .cappy:
            return "Connect"
        case .providerCLI:
            return usesCurrentCLISignIn ? "Done" : "Use Account"
        }
    }

    private var primaryActionDisabled: Bool {
        if isWorking || selectedProvider.isEmpty { return true }
        switch connectionMethod {
        case .cappy:
            return false
        case .providerCLI:
            return !usesCurrentCLISignIn && currentCLIProfile == nil
        }
    }

    private func performPrimaryAction() {
        switch connectionMethod {
        case .cappy:
            isWorking = true
            Task {
                let added = await model.addAccount(providerID: selectedProvider)
                isWorking = false
                if added { onComplete() }
            }
        case .providerCLI:
            guard !usesCurrentCLISignIn else {
                onClose()
                return
            }
            guard let currentCLIProfile else { return }
            model.useCurrentCLISignIn(profileID: currentCLIProfile.id)
            onClose()
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
        subscription: Subscription(
            planName: "Pro",
            nextBillingDate: Date().addingTimeInterval(2 * 86_400)
        ),
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
        subscription: Subscription(
            planName: "Max",
            nextBillingDate: Date().addingTimeInterval(6 * 86_400)
        ),
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
        subscription: Subscription(
            planName: "Business",
            nextBillingDate: Date().addingTimeInterval(18 * 86_400)
        ),
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
        subscription: Subscription(
            planName: "Team",
            nextBillingDate: Date().addingTimeInterval(86_400)
        ),
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
                        showsRenewalDate: true,
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
                Label("Connections…", systemImage: "link")
                Spacer()
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
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
