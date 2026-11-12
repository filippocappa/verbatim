import Network
import Observation

/// Whether the cloud engine is reachable. Drives the choice between Groq and Apple's on-device engine.
@Observable
final class Connectivity {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity", qos: .utility))
    }
}
