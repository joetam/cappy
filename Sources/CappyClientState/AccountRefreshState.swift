public enum AccountRefreshState: Equatable, Sendable {
    case idle
    case refreshing(profileIDs: Set<String>)

    public var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }

    public func isUpdating(profileID: String) -> Bool {
        guard case .refreshing(let profileIDs) = self else { return false }
        return profileIDs.contains(profileID)
    }
}
