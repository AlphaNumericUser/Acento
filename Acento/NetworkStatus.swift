import Combine
import Foundation
import Network

/// Tracks whether the Mac has a usable network path so online-only steps can be skipped instantly.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// Optimistic until the first path update arrives, so a slow start never blocks AI polishing.
    @Published private(set) var isOnline = true
    var onReconnect: (() -> Void)?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.useacento.acento.network", qos: .utility))
    }

    /// Offline notices that don't need action are shown once per outage, not on every dictation.
    private var offlineNoticeShown = false

    func claimOfflineNotice() -> Bool {
        guard !offlineNoticeShown else { return false }
        offlineNoticeShown = true
        return true
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        offlineNoticeShown = false
        if online { onReconnect?() }
    }

    /// Errors that mean the request never reached the provider, as opposed to the provider rejecting it.
    nonisolated static func isConnectivityError(_ error: Error) -> Bool {
        if error is OfflineFailure { return true }
        guard let error = error as? URLError else { return false }
        return connectivityCodes.contains(error.code)
    }

    /// Like `isConnectivityError`, but a timeout only counts as offline when the system also reports no network;
    /// otherwise the provider is just slow and the user should see the real error.
    func isOfflineError(_ error: Error) -> Bool {
        guard Self.isConnectivityError(error) else { return false }
        return (error as? URLError)?.code != .timedOut || !isOnline
    }

    nonisolated static let connectivityCodes: Set<URLError.Code> = [
        .timedOut, .notConnectedToInternet, .networkConnectionLost,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]
}

/// An API transcription that could not reach its provider.
nonisolated struct OfflineFailure: LocalizedError {
    let provider: String
    var errorDescription: String? { L10n.format("Could not reach %@. Check your connection.", provider) }
}

/// Failed dictations recorded without a connection; they are transcribed when the network returns.
@MainActor
final class OfflineQueue: ObservableObject {
    static let shared = OfflineQueue()
    private static let key = "offlinePendingEntries"

    @Published private(set) var ids: Set<UUID>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        ids = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    func add(_ id: UUID) {
        guard ids.insert(id).inserted else { return }
        save()
    }

    func remove(_ id: UUID) {
        guard ids.remove(id) != nil else { return }
        save()
    }

    private func save() {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: Self.key)
    }
}
