import Foundation
import QuotaContracts

public enum BuiltinProviders {
    public static let codex = ProviderDescriptor(
        id: "openai-codex",
        displayName: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        accentHex: "5B6CFF",
        icon: ProviderIconDescriptor(
            bundledAssetName: "ProviderCodex",
            applicationBundleIdentifier: "com.openai.codex",
            applicationResourceName: "icon-codex-light",
            applicationResourceExtension: "png"
        )
    )

    public static let claude = ProviderDescriptor(
        id: "anthropic-claude",
        displayName: "Claude",
        symbolName: "sparkles",
        accentHex: "D97757",
        icon: ProviderIconDescriptor(bundledAssetName: "ProviderClaude")
    )
}

enum NormalizerHelpers {
    static func humanize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func meterStatus(usedFraction: Double?) -> MeterStatus {
        guard let usedFraction else { return .unavailable }
        if usedFraction >= 1 { return .exhausted }
        if usedFraction >= 0.8 { return .warning }
        return .available
    }

    static func number(_ value: JSONValue?) -> Double? {
        if let number = value?.doubleValue, number.isFinite { return number }
        if let string = value?.stringValue, let number = Double(string), number.isFinite { return number }
        return nil
    }

    static func integer(_ value: JSONValue?, range: ClosedRange<Int>) -> Int? {
        guard let number = number(value),
            number >= Double(range.lowerBound), number <= Double(range.upperBound)
        else { return nil }
        return Int(number)
    }

    static func date(epoch value: Double?) -> Date? {
        guard let value, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func date(_ value: JSONValue?) -> Date? {
        if let epoch = number(value) {
            let seconds = epoch > 100_000_000_000 ? epoch / 1_000 : epoch
            return date(epoch: seconds)
        }
        guard let string = value?.stringValue else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
