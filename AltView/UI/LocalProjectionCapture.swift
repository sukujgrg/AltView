import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import IOSurface
import QuartzCore
import os

enum ProjectionCaptureSizing {
    static func size(_ source: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else {
            return CGSize(width: 2, height: 2)
        }
        let factor = min(1920 / source.width, 1080 / source.height, 1)
        return CGSize(width: max(2, floor(source.width * factor / 2) * 2), height: max(2, floor(source.height * factor / 2) * 2))
    }
}

@available(macOS 12.3, *)
enum ProjectionCaptureConfiguration {
    // SCStreamConfiguration.backgroundColor is unowned(unsafe). Keep the colour
    // alive for native copies at stream creation and every later resize.
    private static let backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    static func make(sourceSize: CGSize, sourceScale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = ProjectionCaptureSizing.size(CGSize(width: sourceSize.width * sourceScale, height: sourceSize.height * sourceScale))
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6; config.showsCursor = false; config.scalesToFit = true
        config.backgroundColor = backgroundColor
        if #available(macOS 13.0, *) { config.capturesAudio = false }
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true; config.captureResolution = .best; config.ignoreShadowsSingleWindow = true
        }
        if #available(macOS 15.0, *) { config.captureDynamicRange = .SDR }
        return config
    }
}

extension ConfidenceMediaRequest {
    /// Revisions describe accepted control reports, not separate pixel streams.
    func hasSameSource(as other: Self) -> Bool {
        connection == other.connection && lease == other.lease && process == other.process
            && presentation == other.presentation
    }
}

/// Keep pool storage alive while queued or displayed; no consumer mutates it.
struct ProjectionFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let surface: IOSurface
    let time: CMTime
    let sourceScale: CGFloat?
    @available(macOS 12.3, *)
    init?(sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first else { return nil }
        self.init(sampleBuffer: sampleBuffer, metadata: metadata)
    }
    @available(macOS 12.3, *)
    init?(sampleBuffer: CMSampleBuffer, metadata: [SCStreamFrameInfo: Any]) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let rawStatus = metadata[.status] as? Int,
              rawStatus == SCFrameStatus.complete.rawValue || rawStatus == SCFrameStatus.started.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        pixelBuffer = buffer; self.surface = IOSurface(surface)
        time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scale = (metadata[.scaleFactor] as? NSNumber)?.doubleValue
        sourceScale = scale.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
    }
    init(pixelBuffer: CVPixelBuffer, surface: IOSurface, time: CMTime, sourceScale: CGFloat? = nil) {
        self.pixelBuffer = pixelBuffer; self.surface = surface; self.time = time; self.sourceScale = sourceScale
    }
}

enum ProjectionPictureState: Equatable { case blank, suspended, stopped }
enum ProjectionFrameEvent {
    case frame(ProjectionFrame)
    case clear(ProjectionPictureState)
    var frame: ProjectionFrame? { if case .frame(let frame) = self { return frame }; return nil }
}

/// One replaceable event and one drain. Startup can collect frames without
/// delivering them until startCapture succeeds and its source is still current.
final class ProjectionFrameMailbox {
    struct Statistics {
        var replaced: UInt64 = 0
        var committed: UInt64 = 0
        var samples: UInt64 = 0
        var lastActivity: TimeInterval = 0
        var hasPictureEvent = false
        var sourceScale: CGFloat?
    }
    private let lock = NSLock()
    private var active = false
    private var delivering = false
    private var terminal = false
    private var cutoff = CMTime.invalid
    private var latestTime = CMTime.invalid
    private var pending: ProjectionFrameEvent?
    private var scheduled = false
    private var stats = Statistics()
    private let schedule: (@escaping () -> Void) -> Void
    private let consume: (ProjectionFrameEvent) -> Void
    var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return stats }
    var replaced: UInt64 { statistics.replaced }
    var committed: UInt64 { statistics.committed }
    init(schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         consume: @escaping (ProjectionFrameEvent) -> Void) {
        self.schedule = schedule; self.consume = consume
    }
    func reset(active: Bool, delivering: Bool = true, cutoff: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.lock(); defer { lock.unlock() }
        self.active = active; self.delivering = delivering; self.cutoff = cutoff; terminal = false
        latestTime = .invalid; pending = nil
        // An already queued drain retires, or consumes only a new valid event.
    }
    func startDelivering() {
        lock.lock(); delivering = true
        let shouldSchedule = prepareDrain()
        lock.unlock()
        if shouldSchedule { enqueueDrain() }
    }
    func noteActivity() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        stats.samples &+= 1; stats.lastActivity = ProcessInfo.processInfo.systemUptime
    }
    func offer(_ frame: ProjectionFrame) { offer(.frame(frame), at: frame.time) }
    func offerClear(_ state: ProjectionPictureState, at time: CMTime) { offer(.clear(state), at: time) }
    private func offer(_ event: ProjectionFrameEvent, at time: CMTime) {
        lock.lock()
        guard active, !terminal else { lock.unlock(); return }
        if let frame = event.frame {
            guard time.isNumeric, time >= cutoff, !latestTime.isNumeric || time > latestTime else { lock.unlock(); return }
            stats.sourceScale = frame.sourceScale ?? stats.sourceScale
        } else if time.isNumeric, latestTime.isNumeric, time < latestTime {
            lock.unlock(); return
        }
        if time.isNumeric { latestTime = time }
        if case .clear(.stopped) = event { terminal = true }
        if pending != nil { stats.replaced &+= 1 }
        stats.hasPictureEvent = true; pending = event
        let shouldSchedule = prepareDrain()
        lock.unlock()
        if shouldSchedule { enqueueDrain() }
    }
    private func prepareDrain() -> Bool {
        guard active, delivering, pending != nil, !scheduled else { return false }
        scheduled = true; return true
    }
    private func enqueueDrain() { schedule { [weak self] in self?.drain() } }
    private func drain() {
        lock.lock()
        let event = active && delivering ? pending : nil
        if active && delivering { pending = nil }
        scheduled = false
        if event?.frame != nil { stats.committed &+= 1 }
        lock.unlock()
        if let event { consume(event) }
    }
}

/// AppKit notifications release occluded/minimized surfaces and restore the
/// newest shared frame when a canvas returns. No per-frame visibility polling.
@MainActor
final class ConfidenceMediaView: NSView {
    private var displayedFrame: ProjectionFrame?
    private var windowObservers: [NSObjectProtocol] = []
    private var closing = false
    var onVisibilityChange: (() -> Void)?
    var isDrawable: Bool {
        !closing && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect; layer?.masksToBounds = true
        layer?.contentsFormat = .RGBA8Uint
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll(); closing = false
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.closing = note.name == NSWindow.willCloseNotification
                        self.visibilityChanged()
                    }
                })
            }
        }
        updateContentsScale(); visibilityChanged()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateContentsScale() }
    override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }
    private func updateContentsScale() { layer?.contentsScale = window?.backingScaleFactor ?? 1 }
    private func visibilityChanged() {
        if !isDrawable { display(nil) }
        onVisibilityChange?()
    }
    func display(_ frame: ProjectionFrame?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = frame?.surface; displayedFrame = frame
        CATransaction.commit()
    }
    deinit { for observer in windowObservers { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor
protocol ProjectionCaptureEngine: AnyObject {
    func update(_ request: ConfidenceMediaRequest?)
    func retry()
}

/// Capture readiness is separate from the operator's saved On/Off choice.
enum ConfidenceMediaState: Equatable {
    case off, unsupported, permissionNeeded, waitingForMedia, paused, sleeping, remote, waitingForWindow
    case unverified(LocalProjectionSourceIssue)
    case connecting, waitingForPicture, live, blank, suspended, stopped, retrying, slow, holding

    var title: String {
        switch self {
        case .off: return "Off"
        case .unsupported: return "Unavailable on this macOS"
        case .permissionNeeded: return "Permission needed"
        case .waitingForMedia: return "Waiting for media"
        case .paused, .sleeping, .suspended: return "Paused"
        case .remote: return "Connection is not local"
        case .unverified: return "Cannot verify local Eucaly"
        case .waitingForWindow: return "Waiting for projection window"
        case .connecting, .slow: return "Connecting"
        case .waitingForPicture: return "Waiting for picture"
        case .live: return "Live"
        case .blank: return "Source is blank"
        case .stopped: return "Capture stopped"
        case .retrying: return "Retrying automatically"
        case .holding: return "Waiting for updates"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Turn on Show Eucaly media to include its projection on Confidence."
        case .unsupported: return "Local media requires macOS 12.3 or later. Lyrics and the clock remain available."
        case .permissionNeeded: return "Allow AltView in Privacy & Security → Screen Recording. Return here after granting access; macOS may require restarting AltView."
        case .waitingForMedia: return "Present a media slide from Eucaly’s Current pane. Browsing Preview stays private."
        case .paused: return "Capture resumes when Confidence’s preview or display is visible."
        case .sleeping: return "Capture resumes when this Mac’s displays wake."
        case .remote: return "In Eucaly’s AltView settings, reconnect using This Mac. Both apps must run here; media cannot be received over the network."
        case .unverified(let issue):
            switch issue {
            case .missingIdentity, .invalidIdentity:
                return "Eucaly connected locally but did not provide a usable media identity. Restart Eucaly, then reconnect using This Mac. Check that both apps are up to date."
            case .bootMismatch:
                return "Eucaly’s media identity does not match this Mac’s current session. Restart both apps, then reconnect using This Mac."
            case .processUnavailable:
                return "Eucaly connected locally, but macOS has not made its process information available. AltView will check again automatically. If this continues, restart both apps."
            case .processChanged:
                return "Eucaly’s media identity is from a process that is no longer running. Reconnect Eucaly using This Mac."
            case .remote: return ConfidenceMediaState.remote.detail
            }
        case .waitingForWindow: return "Open Eucaly’s projection and present the media slide."
        case .connecting: return "Connecting to Eucaly’s projection…"
        case .waitingForPicture: return "Waiting for Eucaly’s projection picture…"
        case .live: return "Eucaly’s projection is showing. Audio stays in Eucaly."
        case .blank: return "Eucaly’s capture source is blank. Its next visible picture will appear automatically."
        case .suspended: return "macOS has suspended capture. Waiting for the projection picture…"
        case .stopped: return "macOS stopped or declined capture. Choose Retry Capture to resume."
        case .retrying: return "Eucaly’s projection is unavailable. Retrying automatically; Eucaly can keep presenting."
        case .slow: return "macOS capture is slow to respond. Eucaly can keep presenting while capture finishes connecting."
        case .holding: return "Holding the last picture while waiting for updates. If Eucaly’s projection is moving, choose Retry Capture."
        }
    }
    enum Action: Equatable { case settings, retry }
    var action: Action? {
        switch self {
        case .permissionNeeded: return .settings
        case .stopped, .retrying, .holding: return .retry
        default: return nil
        }
    }
    var needsAttention: Bool {
        switch self {
        case .permissionNeeded, .remote, .unverified, .unsupported, .stopped, .retrying: return true
        default: return false
        }
    }
}

/// One app-local authority and one engine, shared by both canvases.
@MainActor
final class ConfidenceMediaController {
    private var engine: ProjectionCaptureEngine?
    private let targets = NSHashTable<ConfidenceMediaView>.weakObjects()
    private var request: ConfidenceMediaRequest?
    private var demand = false
    private var lastFrame: ProjectionFrame?
    private var systemSleeping = false, screensSleeping = false
    private var powerObservers: [NSObjectProtocol] = []
    private let powerNotifications: NotificationCenter
    private let applicationNotifications: NotificationCenter
    private var applicationObserver: NSObjectProtocol?
    private let defaults: UserDefaults?
    private static let enabledKey = "confidenceLocalMediaEnabled"
    private(set) var enabled = false
    private(set) var state = ConfidenceMediaState.off
    var status: String { state.detail }
    private let hasPermission: () -> Bool
    private let askPermission: () -> Void
    init(defaults: UserDefaults? = nil, engine: ProjectionCaptureEngine? = nil,
         hasPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         askPermission: @escaping () -> Void = { _ = CGRequestScreenCaptureAccess() },
         powerNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationNotifications: NotificationCenter = .default) {
        self.engine = engine; self.hasPermission = hasPermission; self.askPermission = askPermission
        self.powerNotifications = powerNotifications
        self.applicationNotifications = applicationNotifications
        self.defaults = defaults
        enabled = defaults?.bool(forKey: Self.enabledKey) ?? false
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            powerObservers.append(powerNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasSuspended = self.systemSleeping || self.screensSleeping
                    switch note.name {
                    case NSWorkspace.willSleepNotification: self.systemSleeping = true
                    case NSWorkspace.didWakeNotification: self.systemSleeping = false
                    case NSWorkspace.screensDidSleepNotification: self.screensSleeping = true
                    default: self.screensSleeping = false
                    }
                    if wasSuspended != (self.systemSleeping || self.screensSleeping) { self.clear(); self.refresh() }
                }
            })
        }
        applicationObserver = applicationNotifications.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPermission() }
        }
        // Restoring the preference can resume capture, but never asks for access
        // or resets an operator stop. A fresh accepted source is still required.
        if enabled { refresh() }
    }
    var onChange: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    var isMedia: Bool { request != nil }
    var hasPicture: Bool { lastFrame != nil }
    var hasDrawableTarget: Bool { targets.allObjects.contains { $0.isDrawable } }
    func attach(_ view: ConfidenceMediaView) {
        targets.add(view)
        view.onVisibilityChange = { [weak self] in self?.redisplay(); self?.onVisibilityChange?() }
        if view.isDrawable { view.display(lastFrame) }
        onVisibilityChange?()
    }
    func detach(_ view: ConfidenceMediaView) {
        targets.remove(view); view.onVisibilityChange = nil; view.display(nil); onVisibilityChange?()
    }
    func redisplay() {
        // Both consumers share one surface and one outer transaction. Nested
        // view transactions cannot force separate compositor commits per frame.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in targets.allObjects { view.display(view.isDrawable ? lastFrame : nil) }
        CATransaction.commit()
    }
    func update(_ request: ConfidenceMediaRequest?) {
        guard self.request != request else { return }
        let sameSource = request.flatMap { next in self.request.map { next.hasSameSource(as: $0) } } == true
        self.request = request
        if !sameSource { clear() }
        refresh()
    }
    func setDemand(_ demand: Bool) {
        guard demand != self.demand else { return }
        self.demand = demand
        if !demand { clear() }
        refresh()
    }
    /// Only an explicit operator action can request permission or undo macOS Stop.
    func toggleEnabled() {
        setEnabled(!enabled)
    }
    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        defaults?.set(enabled, forKey: Self.enabledKey)
        if enabled { requestPermission() } else { clear(); refresh() }
        onChange?()
    }
    func requestPermission() {
        guard enabled else { return }
        guard #available(macOS 12.3, *) else { refresh(); return }
        if let request, request.process == nil { refresh(); return }
        if !hasPermission() { askPermission() }
        engine?.retry(); refresh()
    }
    /// Register a first access request from an explicit Settings action without
    /// treating it as a Retry of capture stopped through macOS.
    func requestAccess() {
        guard enabled else { return }
        guard #available(macOS 12.3, *) else { return }
        if let request, request.process == nil { return }
        if !hasPermission() { askPermission() }
        refresh()
    }
    /// Returning from Settings checks existing access without requesting it or
    /// overriding a capture stopped through macOS.
    func recheckPermission() { if enabled { refresh() } }
    func shutdown() { demand = false; enabled = false; engine?.update(nil); clear() }
    private var wantsCapture: Bool { enabled && demand && !systemSleeping && !screensSleeping && request != nil }
    private func refresh() {
        guard enabled else { engine?.update(nil); setState(.off); return }
        guard #available(macOS 12.3, *) else { setState(.unsupported); return }
        guard !systemSleeping && !screensSleeping else { engine?.update(nil); setState(.sleeping); return }
        if let request, request.process == nil {
            engine?.update(nil)
            let issue = request.sourceIssue ?? .remote
            setState(issue == .remote ? .remote : .unverified(issue)); return
        }
        guard hasPermission() else {
            engine?.update(nil); clear()
            setState(.permissionNeeded); return
        }
        guard let request else { engine?.update(nil); setState(.waitingForMedia); return }
        guard request.presentation.windowID != nil else { engine?.update(nil); setState(.waitingForWindow); return }
        guard demand else { engine?.update(nil); setState(.paused); return }
        if engine == nil {
            engine = LocalProjectionCapture(onFrame: { [weak self] frame in
                guard let self, self.wantsCapture else { return }
                let hadPicture = self.hasPicture
                self.lastFrame = frame; self.redisplay()
                if !hadPicture { self.onChange?() }
            }, onStatus: { [weak self] status in
                guard let self, self.wantsCapture else { return }; self.setState(status)
            }, onClear: { [weak self] in self?.clear() })
        }
        engine?.update(request)
    }
    private func setState(_ value: ConfidenceMediaState) { guard state != value else { return }; state = value; onChange?() }
    private func clear() { let hadPicture = hasPicture; lastFrame = nil; redisplay(); if hadPicture { onChange?() } }
    deinit {
        for observer in powerObservers { powerNotifications.removeObserver(observer) }
        if let applicationObserver { applicationNotifications.removeObserver(applicationObserver) }
        let engine = engine
        Task { @MainActor in engine?.update(nil) }
    }
}

/// Backend boundary lets lifecycle tests exercise real startup/recovery logic
/// without granting permission or acquiring operator windows.
@MainActor
protocol ProjectionCaptureStream: AnyObject {
    func start() async throws
    func stop() async
    func reconcile(sourceScale: CGFloat?) async throws
}

@available(macOS 12.3, *)
struct ProjectionCaptureRecovery {
    private(set) var failures = 0
    private(set) var requiresOperator = false
    private(set) var nextAttempt: TimeInterval = 0
    mutating func reset(explicit: Bool = false) {
        failures = 0; nextAttempt = 0
        if explicit { requiresOperator = false }
    }
    mutating func failed(_ error: Error, now: TimeInterval) {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain,
           [SCStreamError.Code.userDeclined.rawValue, SCStreamError.Code.userStopped.rawValue,
            SCStreamError.Code.missingEntitlements.rawValue].contains(error.code) {
            requiresOperator = true; nextAttempt = .infinity; return
        }
        failures = min(failures + 1, 4)
        nextAttempt = now + min(15, pow(2, Double(failures)))
    }
}

private enum ProjectionOperationFailure: Error { case timedOut, busy }

/// A late start and normal retirement may both request cleanup. Share an
/// in-flight stop; after it completes a late start may require another stop.
@MainActor
private final class ProjectionCaptureLifetime: ProjectionCaptureStream {
    private let driver: ProjectionCaptureStream
    private var stopping: Task<Void, Never>?
    init(_ driver: ProjectionCaptureStream) { self.driver = driver }
    func start() async throws { try await driver.start() }
    func reconcile(sourceScale: CGFloat?) async throws { try await driver.reconcile(sourceScale: sourceScale) }
    func stop() async {
        if let stopping { await stopping.value; return }
        let driver = driver
        let task = Task { @MainActor [weak self] in
            await driver.stop()
            // Clear before waking callers. A start completing just after this
            // stop must request fresh cleanup, rather than reuse a finished task.
            self?.stopping = nil
        }
        stopping = task
        await task.value
    }
}

/// Framework calls need not honor task cancellation. Resume the caller at its
/// deadline while retaining a slot for unfinished work and cleaning up late
/// results. A task group would also wait forever for an uncooperative child.
@MainActor
private final class ProjectionCaptureOperations {
    private var pending: [UUID: (interruptible: Bool, cancel: () -> Void)] = [:]
    var hasCapacity: Bool { pending.count < 4 }
    func cancelInterruptible() {
        for operation in Array(pending.values) where operation.interruptible { operation.cancel() }
    }
    func run<Value>(timeout: TimeInterval, interruptible: Bool = true,
                    operation: @escaping @MainActor () async throws -> Value,
                    onLateCompletion: @escaping @MainActor (Result<Value, Error>) async -> Void = { _ in }) async throws -> Value {
        let id = UUID(), gate = ProjectionOperationGate<Value>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation
            pending[id] = (interruptible, { gate.abandon(CancellationError()) })
            gate.operation = Task { @MainActor in
                let result: Result<Value, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if gate.complete(result) { await onLateCompletion(result) }
                self.pending.removeValue(forKey: id)
            }
            gate.deadline = Task { @MainActor [weak gate] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) }
                catch { return }
                gate?.abandon(ProjectionOperationFailure.timedOut)
            }
        }
    }
}

@MainActor
private final class ProjectionOperationGate<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var operation: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    func abandon(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        operation?.cancel()
        continuation.resume(throwing: error)
    }
    /// Returns true if the caller has already retired this operation.
    func complete(_ result: Result<Value, Error>) -> Bool {
        operation = nil; deadline?.cancel(); deadline = nil
        guard let continuation else { return true }
        self.continuation = nil; continuation.resume(with: result); return false
    }
}

/// Stream operations normally run serially on MainActor. Timed-out work cannot
/// block recovery or commit a retired source; unfinished work remains bounded.
@available(macOS 12.3, *)
@MainActor
final class LocalProjectionCapture: ProjectionCaptureEngine {
    typealias Factory = (ConfidenceMediaRequest, ProjectionStreamOutput) async throws -> ProjectionCaptureStream
    private static let log = Logger(subsystem: "com.suku.AltView", category: "confidenceCapture")
    private let onFrame: (ProjectionFrame) -> Void
    private let onStatus: (ConfidenceMediaState) -> Void
    private var currentStatus: ConfidenceMediaState?
    private let onClear: () -> Void
    private let makeStream: Factory
    private let operations = ProjectionCaptureOperations()
    private let operationTimeout: TimeInterval
    private var desired: ConfidenceMediaRequest?
    private var epoch: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var stream: ProjectionCaptureStream?
    private var output: ProjectionStreamOutput?
    private var outputEpoch: UInt64?
    private var monitor: Timer?
    private var dirty = false
    private var recovery = ProjectionCaptureRecovery()
    private var startedAt: TimeInterval = 0, operationBegan: TimeInterval = 0
    private var displayCount: UInt64 = 0
    private var maxAge: Double = 0
    private var pictureState: ProjectionPictureState?
    private var waitingForUpdates = false
    init(onFrame: @escaping (ProjectionFrame) -> Void, onStatus: @escaping (ConfidenceMediaState) -> Void,
         onClear: @escaping () -> Void, operationTimeout: TimeInterval = 8, makeStream: Factory? = nil) {
        self.onFrame = onFrame; self.onStatus = onStatus; self.onClear = onClear
        self.makeStream = makeStream ?? { request, output in try await NativeProjectionCaptureStream.make(request: request, output: output) }
        self.operationTimeout = operationTimeout
    }
    func update(_ request: ConfidenceMediaRequest?) {
        guard desired != request else {
            if request != nil, let currentStatus { onStatus(currentStatus) }
            return
        }
        let sameSource = desired.flatMap { old in request.map { old.hasSameSource(as: $0) } } == true
        desired = request
        // A static source emits idle callbacks, not new surfaces. Its current
        // frame remains valid across control revisions for that exact source.
        if sameSource { return }
        epoch &+= 1; output?.mailbox.reset(active: false); onClear()
        if request == nil { operations.cancelInterruptible() }
        recovery.reset(); dirty = true
        if request != nil { reportStatus(recovery.requiresOperator ? .stopped : .connecting) }
        if request != nil { startMonitor() } else { monitor?.invalidate(); monitor = nil }
        runWorker()
    }
    func retry() {
        epoch &+= 1; recovery.reset(explicit: true)
        operations.cancelInterruptible()
        if desired != nil { reportStatus(.connecting) }
        output?.mailbox.reset(active: false); onClear(); dirty = true; runWorker()
    }
    private func runWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.dirty {
                self.dirty = false; self.operationBegan = ProcessInfo.processInfo.systemUptime
                let previous = self.stream, previousOutput = self.output
                self.stream = nil; self.output = nil; self.outputEpoch = nil
                previousOutput?.mailbox.reset(active: false)
                if let previous { await self.stop(previous); self.logMetrics(previousOutput) }
                guard let request = self.desired, !self.recovery.requiresOperator else { continue }
                guard ProcessInfo.processInfo.systemUptime >= self.recovery.nextAttempt else { continue }
                let token = self.epoch
                self.reportStatus(.connecting)
                let output = ProjectionStreamOutput(onEvent: { [weak self] output, event in self?.consume(event, from: output) },
                                                    onFailure: { [weak self] output, error in self?.captureFailed(output, error: error) })
                output.mailbox.reset(active: true, delivering: false, cutoff: .zero)
                self.output = output; self.outputEpoch = token
                var candidate: ProjectionCaptureStream?
                do {
                    guard self.operations.hasCapacity else { throw ProjectionOperationFailure.busy }
                    let factory = self.makeStream
                    let driver = try await self.operations.run(timeout: self.operationTimeout, operation: {
                        ProjectionCaptureLifetime(try await factory(request, output)) as ProjectionCaptureStream
                    }, onLateCompletion: { result in
                        if case .success(let driver) = result { await driver.stop() }
                    }); candidate = driver
                    guard self.epoch == token else { output.mailbox.reset(active: false); await self.stop(driver); continue }
                    try await self.operations.run(timeout: self.operationTimeout, operation: { try await driver.start() },
                                                  onLateCompletion: { _ in await driver.stop() })
                    guard self.epoch == token else { output.mailbox.reset(active: false); await self.stop(driver); continue }
                    self.stream = driver; self.startedAt = ProcessInfo.processInfo.systemUptime
                    self.displayCount = 0; self.maxAge = 0; self.pictureState = nil; self.waitingForUpdates = false
                    self.reportStatus(.waitingForPicture)
                    // The first still frame may have arrived before start returned.
                    output.mailbox.startDelivering()
                } catch {
                    output.mailbox.reset(active: false)
                    if self.output === output { self.output = nil; self.outputEpoch = nil }
                    if let candidate { await self.stop(candidate) }
                    guard self.epoch == token else { continue }
                    self.recordFailure(error)
                }
            }
            self.operationBegan = 0; self.worker = nil
        }
    }
    private func stop(_ stream: ProjectionCaptureStream) async {
        // Stop has its own deadline, including when capture never finished
        // starting. Late native completion still performs final cleanup.
        try? await operations.run(timeout: min(3, operationTimeout), interruptible: false, operation: { await stream.stop() })
    }
    private func consume(_ event: ProjectionFrameEvent, from output: ProjectionStreamOutput) {
        guard self.output === output, outputEpoch == epoch, stream != nil, desired != nil else { return }
        switch event {
        case .frame(let frame):
            if displayCount == 0 || pictureState != nil || waitingForUpdates {
                reportStatus(.live)
            }
            pictureState = nil; waitingForUpdates = false; recovery.reset(); displayCount &+= 1
            let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), frame.time))
            if age.isFinite && age >= 0 { maxAge = max(maxAge, age) }
            onFrame(frame)
        case .clear(let state):
            pictureState = state
            // A stopped sample has no reason attached. Respect it as an
            // operator stop; otherwise it can race the delegate's userStopped
            // error and accidentally restart capture from the macOS Stop menu.
            if state == .stopped {
                captureFailed(output, error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
            }
            else {
                onClear()
                reportStatus(state == .blank ? .blank : .suspended)
            }
        }
    }
    private func captureFailed(_ output: ProjectionStreamOutput, error: Error) {
        guard self.output === output, outputEpoch == epoch, desired != nil else { return }
        epoch &+= 1; output.mailbox.reset(active: false)
        recordFailure(error); dirty = true; runWorker()
    }
    private func recordFailure(_ error: Error) {
        recovery.failed(error, now: ProcessInfo.processInfo.systemUptime); onClear()
        let code = error as NSError
        Self.log.error("capture_failed domain=\(code.domain, privacy: .public) code=\(code.code) operator_retry=\(self.recovery.requiresOperator)")
        if recovery.requiresOperator {
            reportStatus(.stopped)
        } else {
            reportStatus(.retrying)
        }
    }
    private func startMonitor() {
        guard monitor == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        timer.tolerance = 0.2; monitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func checkHealth(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard desired != nil, !recovery.requiresOperator else { return }
        if worker != nil {
            if operationBegan > 0 && now - operationBegan > 8 {
                reportStatus(.slow)
            }
            return
        }
        guard let stream, let output else {
            if now >= recovery.nextAttempt { dirty = true; runWorker() }
            return
        }
        let stats = output.mailbox.statistics
        if !stats.hasPictureEvent && now - startedAt > 5 {
            captureFailed(output, error: CaptureFailure.noPicture); return
        }
        // An initial stream must deliver a picture or explicit blank state.
        // Samples arrive when available, not on a guaranteed heartbeat. Silence
        // cannot distinguish a static/paused window from a silent framework
        // stall. Preserve its valid picture and let source checks/delegate
        // errors drive recovery; give the operator an explicit Retry fallback.
        if pictureState == nil && stats.samples > 0 && now - stats.lastActivity > 10 && !waitingForUpdates {
            waitingForUpdates = true
            reportStatus(.holding)
        }
        let token = epoch
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            self.operationBegan = now
            do { try await self.operations.run(timeout: self.operationTimeout, operation: { try await stream.reconcile(sourceScale: stats.sourceScale) }) }
            catch { if self.epoch == token { self.captureFailed(output, error: error) } }
            self.operationBegan = 0; self.worker = nil
            if self.dirty { self.runWorker() }
        }
    }
    private func logMetrics(_ output: ProjectionStreamOutput?) {
        guard startedAt > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        Self.log.notice("capture_stopped elapsed_s=\(elapsed) displayed_frames=\(self.displayCount) replaced_pending=\(output?.mailbox.replaced ?? 0) max_commit_age_ms=\(self.maxAge * 1000)")
        startedAt = 0
    }
    private enum CaptureFailure: Error { case noPicture }
    private func reportStatus(_ state: ConfidenceMediaState) { currentStatus = state; onStatus(state) }
    deinit { monitor?.invalidate(); output?.mailbox.reset(active: false) }
}

@available(macOS 12.3, *)
@MainActor
private final class NativeProjectionCaptureStream: ProjectionCaptureStream {
    private static let log = Logger(subsystem: "com.suku.AltView", category: "confidenceCapture")
    private static let sampleQueue = DispatchQueue(label: "com.suku.AltView.confidence.frames", qos: .userInteractive)
    private let process: LocalProjectionProcess
    private let windowID: UInt32
    private let stream: SCStream
    private let output: ProjectionStreamOutput
    private let configuration: SCStreamConfiguration
    private var sourceScale: CGFloat
    private var sourceSize: CGSize
    private init(process: LocalProjectionProcess, window: SCWindow, output: ProjectionStreamOutput) {
        self.process = process; windowID = window.windowID; self.output = output
        let filter = SCContentFilter(desktopIndependentWindow: window)
        sourceSize = window.frame.size; sourceScale = 1
        if #available(macOS 14.0, *) { sourceScale = max(CGFloat(filter.pointPixelScale), 1) }
        let config = ProjectionCaptureConfiguration.make(sourceSize: sourceSize, sourceScale: sourceScale)
        configuration = config
        stream = SCStream(filter: filter, configuration: config, delegate: output)
    }
    static func make(request: ConfidenceMediaRequest, output: ProjectionStreamOutput) async throws -> NativeProjectionCaptureStream {
        // Shareable-content enumeration itself can prompt. Check first on
        // every attempt so revocation never becomes an implicit permission ask.
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
        guard let process = request.process, process.isLiveLocalProcess, let id = request.presentation.windowID,
              NSRunningApplication(processIdentifier: process.processID)?.bundleIdentifier == "com.suku.eucaly" else { throw SourceFailure.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard process.isLiveLocalProcess, let window = content.windows.first(where: {
            $0.windowID == id && $0.owningApplication?.processID == process.processID
                && $0.owningApplication?.bundleIdentifier == "com.suku.eucaly"
        }) else { throw SourceFailure.unavailable }
        return NativeProjectionCaptureStream(process: process, window: window, output: output)
    }
    func start() async throws {
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: Self.sampleQueue)
        try await stream.startCapture()
        Self.log.notice("capture_started width=\(self.configuration.width) height=\(self.configuration.height) requested_fps=60 audio=false color_space=sRGB")
    }
    func stop() async {
        // Detach delivery before awaiting framework cleanup, which can stall.
        try? stream.removeStreamOutput(output, type: .screen)
        try? await stream.stopCapture()
    }
    func reconcile(sourceScale: CGFloat?) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
        guard process.isLiveLocalProcess,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let row = rows.first, row[kCGWindowOwnerPID as String] as? Int32 == process.processID,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { throw SourceFailure.unavailable }
        let scale = sourceScale ?? self.sourceScale
        guard rect.size != sourceSize || scale != self.sourceScale else { return }
        let size = ProjectionCaptureSizing.size(CGSize(width: rect.width * scale, height: rect.height * scale))
        if configuration.width != Int(size.width) || configuration.height != Int(size.height) {
            configuration.width = Int(size.width); configuration.height = Int(size.height)
            try await stream.updateConfiguration(configuration)
            Self.log.notice("capture_resized width=\(self.configuration.width) height=\(self.configuration.height)")
        }
        sourceSize = rect.size; self.sourceScale = scale
    }
    private enum SourceFailure: Error { case unavailable }
}

@available(macOS 12.3, *)
final class ProjectionStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let mailbox: ProjectionFrameMailbox
    private let onFailure: @MainActor (ProjectionStreamOutput, Error) -> Void
    init(onEvent: @escaping @MainActor (ProjectionStreamOutput, ProjectionFrameEvent) -> Void,
         onFailure: @escaping @MainActor (ProjectionStreamOutput, Error) -> Void) {
        // Avoid capturing a partly initialized self in the mailbox consumer.
        let box = WeakProjectionOutput()
        mailbox = ProjectionFrameMailbox { event in
            MainActor.assumeIsolated { if let output = box.value { onEvent(output, event) } }
        }
        self.onFailure = onFailure
        super.init(); box.value = self
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handleScreenSample(sampleBuffer)
    }
    func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        mailbox.noteActivity()
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first, let raw = metadata[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete, .started:
            if let frame = ProjectionFrame(sampleBuffer: sampleBuffer, metadata: metadata) { mailbox.offer(frame) }
        case .blank: mailbox.offerClear(.blank, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .suspended: mailbox.offerClear(.suspended, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .stopped: mailbox.offerClear(.stopped, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        default: break // Idle carries no new IOSurface; retain the current picture.
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        reportFailure(error)
    }
    func reportFailure(_ error: Error) {
        mailbox.reset(active: false)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { self.onFailure(self, error) } }
        }
    }
    private final class WeakProjectionOutput { weak var value: ProjectionStreamOutput? }
}
