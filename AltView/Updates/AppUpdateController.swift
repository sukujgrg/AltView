import AppKit

struct AppUpdateState: Equatable {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = true
    var availableVersion: String?
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var state: AppUpdateState { get }
    var onStateChange: ((AppUpdateState) -> Void)? { get set }
    func start()
    func checkForUpdates()
    func setAutomaticChecks(_ enabled: Bool)
}

/// One updater shared by the app menu and workspace. Installation is explicit.
@MainActor
final class AppUpdateController: NSObject, NSMenuItemValidation {
    static let activityExplanation = "Close Output and stop presenting text before updating AltView."
    private(set) var state: AppUpdateState
    var onChange: (() -> Void)?
    private let driver: any AppUpdateDriving
    private let isPresenting: () -> Bool
    private var started = false

    init(driver: any AppUpdateDriving, isPresenting: @escaping () -> Bool) {
        self.driver = driver
        self.isPresenting = isPresenting
        state = driver.state
        super.init()
        driver.onStateChange = { [weak self] state in
            self?.state = state
            self?.onChange?()
        }
    }

    var canCheckForUpdates: Bool { state.canCheckForUpdates && !isPresenting() }
    var disabledReason: String? { isPresenting() ? Self.activityExplanation : nil }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    func activityDidChange() { onChange?() }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        driver.setAutomaticChecks(!state.automaticallyChecksForUpdates)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            menuItem.title = state.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…"
            menuItem.toolTip = disabledReason
            return canCheckForUpdates
        }
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = state.automaticallyChecksForUpdates ? .on : .off
        }
        return true
    }
}
