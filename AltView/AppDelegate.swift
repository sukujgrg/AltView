import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var receiver: ReceiverWindowController?
    private lazy var updates = AppUpdateController(
        driver: SparkleUpdateDriver(isPresenting: { [weak self] in self?.receiver?.isPresenting == true }),
        isPresenting: { [weak self] in self?.receiver?.isPresenting == true }
    )
    private var customTextMenuItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let receiver = ReceiverWindowController()
        self.receiver = receiver
        receiver.onCustomTextSettingChange = { [weak self] in self?.updateCustomTextMenu() }
        receiver.onPresentationActivityChange = { [weak self] in self?.updates.activityDidChange() }
        receiver.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates(nil) }
        updates.onChange = { [weak self] in
            guard let self else { return }
            self.receiver?.showUpdateState(self.updates.state, canCheck: self.updates.canCheckForUpdates,
                                           disabledReason: self.updates.disabledReason)
        }
        installMenus()
        updates.start()
        receiver.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        receiver?.showWindow(nil)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { receiver?.confirmTermination() ?? .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { receiver?.shutdown() }
    @objc private func showReceiver() { receiver?.showReceiverPage() }
    @objc private func showDesign() { receiver?.showDesignPage() }
    @objc private func showComposer() { receiver?.showComposerPage() }
    @objc private func showSettings() { receiver?.showSettings() }
    @objc private func showConnections() { receiver?.showConnectionsPage() }
    @objc private func showConfidence() { receiver?.showConfidencePage() }
    @objc private func closeConfidence() { receiver?.closeConfidence() }
    @objc private func closeOutput() { receiver?.closeOutput() }
    private func updateCustomTextMenu() {
        let enabled = receiver?.customTextEnabled == true
        customTextMenuItem?.isHidden = !enabled
        customTextMenuItem?.keyEquivalent = enabled ? "1" : ""
    }
    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About AltView", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let check = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdateController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updates
        let automatic = appMenu.addItem(withTitle: "Automatically Check for Updates", action: #selector(AppUpdateController.toggleAutomaticChecks(_:)), keyEquivalent: "")
        automatic.target = updates
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AltView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit AltView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let file = NSMenu(title: "File"); fileItem.submenu = file
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let view = NSMenu(title: "View"); viewItem.submenu = view
        let output = view.addItem(withTitle: "Show Audience", action: #selector(showReceiver), keyEquivalent: "3"); output.target = self
        let design = view.addItem(withTitle: "Show Audience Design", action: #selector(showDesign), keyEquivalent: "2"); design.target = self
        let confidence = view.addItem(withTitle: "Show Confidence", action: #selector(showConfidence), keyEquivalent: "4"); confidence.target = self
        let connections = view.addItem(withTitle: "Show Connections", action: #selector(showConnections), keyEquivalent: "5"); connections.target = self
        customTextMenuItem = view.addItem(withTitle: "Show Text", action: #selector(showComposer), keyEquivalent: "1")
        customTextMenuItem?.target = self
        updateCustomTextMenu()
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windows = NSMenu(title: "Window"); windowItem.submenu = windows
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        let close = windows.addItem(withTitle: "Close Audience Display", action: #selector(closeOutput), keyEquivalent: "o")
        close.keyEquivalentModifierMask = [.command, .shift]; close.target = self
        let stopConfidence = windows.addItem(withTitle: "Close Confidence Display", action: #selector(closeConfidence), keyEquivalent: "o")
        stopConfidence.keyEquivalentModifierMask = [.command, .option, .shift]; stopConfidence.target = self
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}
