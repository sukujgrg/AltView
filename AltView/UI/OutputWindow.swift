import AppKit

final class OutputWindowController: NSObject, NSWindowDelegate {
    private var output: NSWindow?
    private var canvas: OutputCanvas?
    private var requestedDisplay: UInt32?
    private var windowed = false
    private let presentation: CanvasPresentation
    private var screenObserver: NSObjectProtocol?
    private var reposition: DispatchWorkItem?
    var isActive: Bool { windowed || requestedDisplay != nil }
    var onChange: ((String) -> Void)?

    init(presentation: CanvasPresentation) {
        self.presentation = presentation
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            self?.reposition = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    func show(displayID: UInt32?) {
        stop()
        requestedDisplay = displayID
        windowed = displayID == nil
        reconcile()
    }
    func stop() {
        reposition?.cancel(); reposition = nil
        requestedDisplay = nil; windowed = false
        output?.delegate = nil; output?.close(); output = nil; canvas = nil
        onChange?("Output window closed")
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === output else { return }
        output = nil; canvas = nil; windowed = false; requestedDisplay = nil
        onChange?("Output window closed")
    }
    private func reconcile() {
        let screen = requestedDisplay.flatMap { id in NSScreen.screens.first { Self.displayID($0) == id } }
        guard windowed || screen != nil else {
            output?.delegate = nil; output?.close(); output = nil; canvas = nil
            if requestedDisplay != nil { onChange?("Selected display disconnected — waiting for it to return") }
            return
        }
        if let output, let screen { output.setFrame(screen.frame, display: true); return }
        guard output == nil else { return }
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 960, height: 540)
        let mask: NSWindow.StyleMask = windowed ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        let window = NSWindow(contentRect: frame, styleMask: mask, backing: .buffered, defer: false)
        window.title = windowed ? "AltView — Preview Output" : "AltView Output"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = presentation.style.backgroundColor
        window.colorSpace = .sRGB
        window.tabbingMode = .disallowed
        let canvas = OutputCanvas(presentation: presentation)
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
        onChange?(windowed ? "Preview output window open" : "Output on \(screen!.localizedName)")
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; reposition?.cancel() }
}
