import Foundation
import ServiceManagement

/// Registers Lanki as a macOS login item via `SMAppService`.
/// The system item is the source of truth — nothing is mirrored into UserDefaults.
enum LoginItemService {
    private static var service: SMAppService { .mainApp }

    /// True when the item is enabled or waiting for the user to approve it.
    static var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = service.status
        if enabled {
            switch status {
            case .enabled, .requiresApproval:
                return
            default:
                try service.register()
            }
        } else if status != .notRegistered {
            try service.unregister()
        }
    }
}
