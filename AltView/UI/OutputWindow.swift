import AppKit

final class OutputWindowController: NSObject, NSWindowDelegate {
    private var output: NSWindow?
    private var canvas: NSView?
    private var requestedDisplay: DisplayTarget?
    private var windowed = false
    private let makeCanvas: () -> NSView
    private let backgroundColor: () -> NSColor
    private let outputName: String
    private let displays: () -> [OutputDisplay]
    private var screenObserver: NSObjectProtocol?
    private var reposition: DispatchWorkItem?
    var isActive: Bool { windowed || requestedDisplay != nil }
    var activeDisplayID: UInt32? { requestedDisplay?.resolve(in: displays())?.id }
    private(set) var statusText = "Display window closed"
    private var observers: [UUID: () -> Void] = [:]
    var onChange: ((String) -> Void)?
    var onReadinessChange: ((OutputReadiness) -> Void)?
    private(set) var readiness = OutputReadiness.closed
    private var displayAsleep = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?
    private let beginActivity: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void

    private func publishReadiness() {
        let next: OutputReadiness
        if !isActive { next = .closed }
        else if let requestedDisplay, displays().filter({ $0.identity == requestedDisplay.identity }).count > 1 { next = .unavailable }
        else if let requestedDisplay, requestedDisplay.resolve(in: displays()) == nil { next = .displayMissing }
        else if requestedDisplay?.resolve(in: displays())?.isMirrored == true { next = .unavailable }
        else if displayAsleep { next = .asleep }
        else if output?.isMiniaturized == true { next = .minimized }
        else if output?.isVisible != true { next = .closed }
        else { next = windowed ? .preview : .ready }
        // An open output keeps its keying background active even when text is hidden.
        // Release while minimized or disconnected; resume when output returns.
        let needsActivity = next == .ready || next == .preview || (next == .asleep && output?.isVisible == true && output?.isMiniaturized == false)
        if needsActivity && activity == nil {
            activity = beginActivity([.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled], "Presenting AltView output")
        } else if !needsActivity { releaseActivity() }
        guard next != readiness else { return }
        readiness = next
        onReadinessChange?(next)
        changed()
    }

    convenience init(presentation: CanvasPresentation,
         displays: @escaping () -> [OutputDisplay] = { OutputDisplay.current },
         beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
         endActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.init(name: "Audience", makeCanvas: { OutputCanvas(presentation: presentation) },
                  backgroundColor: { presentation.style.backgroundColor }, displays: displays,
                  beginActivity: beginActivity, endActivity: endActivity)
    }
    init(name: String, makeCanvas: @escaping () -> NSView, backgroundColor: @escaping () -> NSColor = { .black },
         displays: @escaping () -> [OutputDisplay] = { OutputDisplay.current },
         beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
         endActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.outputName = name; self.makeCanvas = makeCanvas; self.backgroundColor = backgroundColor; self.displays = displays
        statusText = "\(name) window closed"
        self.beginActivity = beginActivity; self.endActivity = endActivity
        super.init()
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.displayAsleep = notification.name == NSWorkspace.screensDidSleepNotification
                self?.publishReadiness()
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publishReadiness()
            if let self, let requested = self.requestedDisplay,
               requested.resolve(in: self.displays()) == nil || requested.resolve(in: self.displays())?.isMirrored == true {
                self.reconcile() // Close immediately; macOS must not leave it on another screen.
            }
            self?.reposition?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            self?.reposition = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private func releaseActivity() {
        guard let activity else { return }
        self.activity = nil
        endActivity(activity)
    }
    func show(displayID: UInt32?) {
        stop()
        requestedDisplay = displayID.map { id in displays().first { $0.id == id }?.target
            ?? DisplayTarget(identity: "runtime:\(id)", name: "Selected monitor") }
        windowed = displayID == nil
        reconcile()
    }
    func show(target: DisplayTarget) { stop(); requestedDisplay = target; reconcile() }
    func stop() {
        reposition?.cancel(); reposition = nil
        requestedDisplay = nil; windowed = false
        output?.delegate = nil; output?.close(); output = nil; canvas = nil
        report("\(outputName) window closed")
        publishReadiness()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === output else { return }
        output = nil; canvas = nil; windowed = false; requestedDisplay = nil
        report("\(outputName) window closed")
        publishReadiness()
    }
    func windowDidMiniaturize(_ notification: Notification) { publishReadiness() }
    func windowDidDeminiaturize(_ notification: Notification) { publishReadiness() }
    func reconcile() {
        defer { publishReadiness() }
        let screen = requestedDisplay?.resolve(in: displays())
        guard windowed || (screen != nil && screen?.isMirrored != true) else {
            output?.delegate = nil; output?.close(); output = nil; canvas = nil
            if let requestedDisplay {
                if displays().filter({ $0.identity == requestedDisplay.identity }).count > 1 {
                    report("Monitor identity ambiguous — waiting for a distinguishable monitor")
                } else {
                    report(screen?.isMirrored == true ? "Monitor mirrored — waiting for extended displays"
                        : "\(requestedDisplay.name) disconnected — waiting for that monitor")
                }
            }
            return
        }
        if let output, let screen { output.setFrame(screen.frame, display: true); return }
        guard output == nil else { return }
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 960, height: 540)
        let mask: NSWindow.StyleMask = windowed ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        let window = NSWindow(contentRect: frame, styleMask: mask, backing: .buffered, defer: false)
        window.title = windowed ? "AltView — Preview \(outputName)" : "AltView \(outputName)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = backgroundColor()
        window.colorSpace = .sRGB
        window.tabbingMode = .disallowed
        let canvas = makeCanvas()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor), canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        if windowed { window.contentAspectRatio = NSSize(width: 16, height: 9); window.center() }
        else {
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(frame, display: false)
        }
        self.output = window; self.canvas = canvas
        window.orderFrontRegardless()
        report(windowed ? "Preview \(outputName.lowercased()) window open" : "\(outputName) on \(screen!.name)")
    }
    func observe(_ change: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = change; return id }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func changed() { for change in Array(observers.values) { change() } }
    private func report(_ text: String) { statusText = text; onChange?(text); changed() }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        reposition?.cancel()
        releaseActivity()
    }
}
