import QuotaContracts

public enum AccountReadingPhase: Equatable, Sendable {
    case current
    case updating
    case waitingForQuota
    case cached
    case unavailable

    public init(freshness: SnapshotFreshness, isUpdating: Bool) {
        if isUpdating {
            self = .updating
            return
        }

        switch freshness {
        case .fresh: self = .current
        case .pending: self = .waitingForQuota
        case .stale: self = .cached
        case .unavailable: self = .unavailable
        }
    }

    public var deemphasizesReading: Bool {
        switch self {
        case .updating, .waitingForQuota, .cached: true
        case .current, .unavailable: false
        }
    }
}
