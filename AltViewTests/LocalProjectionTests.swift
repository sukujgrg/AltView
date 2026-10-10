import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit
import XCTest
@testable import AltView

@MainActor
final class LocalProjectionTests: XCTestCase {
    private func presentation(_ mode: ProjectionPresentation.Mode = .media) -> ProjectionPresentation {
        .init(sessionID: UUID(), mode: mode, windowID: 77, windowGeneration: UUID())
    }
    func testMediaSharesOwnershipAndRejectsStaleUpdates() throws {
        var state = ReceiverState()
        let connection = UUID(), other = UUID()
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
        XCTAssertTrue(state.register(connection: other, senderID: UUID(), name: "Other"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let media = DisplayContent(visible: false, projection: presentation())
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1, content: media, supportsProjection: true))
        XCTAssertNotNil(state.confidenceMedia)
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertNil(state.confidenceMedia?.process, "A remote/unverified sender cannot supply a capture source")
        XCTAssertFalse(state.apply(connection: connection, lease: lease, revision: 1, content: .lyrics, supportsProjection: true))
        XCTAssertFalse(state.apply(connection: other, lease: lease, revision: 2, content: .lyrics, supportsProjection: true))
        XCTAssertEqual(state.confidenceMedia?.presentation, media.projection)
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 2,
            content: DisplayContent(body: "Primary", confidence: .init(body: "Primary"), projection: presentation(.lyrics)),
            supportsProjection: true))
        XCTAssertNil(state.confidenceMedia); XCTAssertEqual(state.confidenceContent.body, "Primary")
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 3, content: media, supportsProjection: true))
        _ = state.take(connection: other)
        XCTAssertNil(state.confidenceMedia)
        XCTAssertFalse(state.apply(connection: connection, lease: lease, revision: 4, content: media, supportsProjection: true))
    }
    func testClearReleaseDisconnectAndUnsupportedExtensionClearMedia() throws {
        for action in 0..<4 {
            var state = ReceiverState(); let connection = UUID()
            XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
            let lease = try XCTUnwrap(state.take(connection: connection))
            XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                content: .init(visible: false, projection: presentation()), supportsProjection: true))
            switch action {
            case 0: _ = state.apply(connection: connection, lease: lease, revision: 2, content: .empty, supportsProjection: true)
            case 1: _ = state.release(connection: connection, lease: lease)
            case 2: state.disconnect(connection)
            default: _ = state.apply(connection: connection, lease: lease, revision: 2,
                content: .init(body: "Legacy", projection: presentation()), supportsProjection: false)
            }
            XCTAssertNil(state.confidenceMedia)
        }
    }
    func testIdentityValidationAndWireCompatibility() throws {
        let process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertTrue(process.isLiveLocalProcess)
        XCTAssertFalse(LocalProjectionProcess(processID: process.processID, startTime: process.startTime + 1, bootMarker: process.bootMarker).isLiveLocalProcess)
        XCTAssertFalse(LocalProjectionProcess(processID: process.processID, startTime: process.startTime, bootMarker: String(repeating: "0", count: 64)).isLiveLocalProcess)
        let content = DisplayContent(visible: false, projection: presentation())
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(.init(kind: .state, content: content))).first?.content, content)
        var invalid = content; invalid.projection?.windowGeneration = nil
        XCTAssertFalse(invalid.isValid)
        let legacy = try JSONDecoder().decode(DisplayContent.self, from: Data(#"{"body":"Legacy","visible":true}"#.utf8))
        XCTAssertNil(legacy.projection)
    }
    func testLocalIdentityFailuresStayDistinctAndNeverVerifyChangedProcesses() throws {
        let process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertNil(process.sourceIssue())
        XCTAssertEqual(process.sourceIssue(localMarker: nil), .bootMismatch)
        XCTAssertEqual(process.sourceIssue(localMarker: String(repeating: "0", count: 64)), .bootMismatch)
        XCTAssertEqual(process.sourceIssue(readStartTime: { _ in nil }), .processUnavailable)
        XCTAssertEqual(process.sourceIssue(readStartTime: { _ in process.startTime + 1 }), .processChanged)
        XCTAssertEqual(LocalProjectionProcess(processID: 0, startTime: 0, bootMarker: "").sourceIssue(), .invalidIdentity)
    }
    func testLocalVerificationRefreshCannotReplaceAnAcceptedOwnerOrReport() throws {
        var state = ReceiverState()
        let connection = UUID(), other = UUID(), process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
        XCTAssertTrue(state.register(connection: other, senderID: UUID(), name: "Other"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let report = presentation()
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                                  content: .init(visible: false, projection: report), supportsProjection: true,
                                  sourceIssue: .processUnavailable))
        XCTAssertFalse(state.refreshMediaSource(connection: other, process: process, sourceIssue: nil))
        XCTAssertTrue(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        XCTAssertEqual(state.confidenceMedia?.presentation, report); XCTAssertEqual(state.confidenceMedia?.revision, 1)
        XCTAssertFalse(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        _ = state.take(connection: other)
        XCTAssertFalse(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        XCTAssertNil(state.confidenceMedia)
    }
    func testAspectPreservingCaptureBounds() {
        XCTAssertEqual(ProjectionCaptureSizing.size(.init(width: 3840, height: 2160)), .init(width: 1920, height: 1080))
        XCTAssertEqual(ProjectionCaptureSizing.size(.init(width: 2000, height: 3000)), .init(width: 720, height: 1080))
        XCTAssertEqual(ProjectionCaptureSizing.size(.init(width: 1280, height: 720)), .init(width: 1280, height: 720))
        XCTAssertEqual(ProjectionCaptureSizing.size(.init(width: CGFloat.infinity, height: 720)), .init(width: 2, height: 2))
        XCTAssertEqual(ProjectionCaptureSizing.size(.init(width: -1, height: 0)), .init(width: 2, height: 2))
    }
    func testNativeCaptureConfigurationSurvivesAutoreleasePoolsAndRepeatedCopies() throws {
        guard #available(macOS 12.3, *) else { throw XCTSkip("ScreenCaptureKit requires macOS 12.3") }
        for _ in 0..<128 {
            weak var background: CGColor?
            let configuration = autoreleasepool {
                let configuration = ProjectionCaptureConfiguration.make(sourceSize: .init(width: 1280, height: 720), sourceScale: 2)
                background = configuration.backgroundColor
                return configuration
            }
            XCTAssertNotNil(background, "The configuration does not retain its background; its owner must outlive native copies")
            let copied = try XCTUnwrap(autoreleasepool { configuration.copy() as? SCStreamConfiguration })
            XCTAssertEqual(copied.width, 1920); XCTAssertEqual(copied.height, 1080)
            XCTAssertEqual(copied.backgroundColor.alpha, 1)
            XCTAssertEqual(copied.backgroundColor.components, [0, 0, 0, 1])
            XCTAssertFalse(copied.showsCursor)
            if #available(macOS 13.0, *) { XCTAssertFalse(copied.capturesAudio) }

            // A later resize also copies the same long-lived configuration.
            configuration.width = 640; configuration.height = 360
            let resized = try XCTUnwrap(autoreleasepool { configuration.copy() as? SCStreamConfiguration })
            XCTAssertEqual(resized.width, 640); XCTAssertEqual(resized.height, 360)
            XCTAssertEqual(resized.backgroundColor.alpha, 1)
        }
    }
    func testMailboxKeepsNewestFrameAndOneDrainThroughInvalidation() throws {
        let frame = try frame()
        var jobs: [() -> Void] = [], received: [CMTime] = []
        let mailbox = ProjectionFrameMailbox(schedule: { jobs.append($0) }, consume: { if let frame = $0.frame { received.append(frame.time) } })
        mailbox.reset(active: true, cutoff: .zero)
        for index in 1...10_000 {
            mailbox.offer(ProjectionFrame(pixelBuffer: frame.pixelBuffer, surface: frame.surface, time: CMTime(value: Int64(index), timescale: 60)))
        }
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(mailbox.replaced, 9_999)
        jobs.removeFirst()()
        XCTAssertEqual(received, [CMTime(value: 10_000, timescale: 60)])
        mailbox.reset(active: true, cutoff: .zero)
        mailbox.offer(frame)
        mailbox.reset(active: true, cutoff: CMTime(value: 100, timescale: 60))
        mailbox.offer(frame) // Captured before the newly accepted snapshot.
        XCTAssertEqual(jobs.count, 1)
        jobs.removeFirst()()
        XCTAssertEqual(received.count, 1)
        mailbox.offer(ProjectionFrame(pixelBuffer: frame.pixelBuffer, surface: frame.surface, time: CMTime(value: 101, timescale: 60)))
        mailbox.reset(active: false)
        jobs.removeFirst()()
        XCTAssertEqual(received.count, 1, "Stopping synchronously cancels pending surfaces")
    }
    private func frame() throws -> ProjectionFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue())
        return .init(pixelBuffer: pixelBuffer, surface: IOSurface(surface), time: CMTime(value: 1, timescale: 60))
    }
    func testLayerRetainsBufferUntilClearedAndMailboxReleasesReplacedBuffer() throws {
        let view = ConfidenceMediaView(frame: .init(x: 0, y: 0, width: 320, height: 180))
        weak var held: CVPixelBuffer?
        try autoreleasepool {
            var value: ProjectionFrame? = try frame()
            held = value?.pixelBuffer
            view.display(value)
            XCTAssertTrue((view.layer?.contents as? IOSurface) === value?.surface)
            value = nil
            XCTAssertNotNil(held, "Core Animation display must keep capture-pool storage retained")
            view.display(nil)
        }
        XCTAssertNil(held)
        var jobs: [() -> Void] = []
        let mailbox = ProjectionFrameMailbox(schedule: { jobs.append($0) }, consume: { _ in })
        mailbox.reset(active: true, cutoff: .zero)
        try autoreleasepool {
            var value: ProjectionFrame? = try frame()
            held = value?.pixelBuffer
            mailbox.offer(value!); value = nil
            XCTAssertNotNil(held)
            let next = try frame()
            mailbox.offer(.init(pixelBuffer: next.pixelBuffer, surface: next.surface, time: CMTime(value: 2, timescale: 60)))
        }
        XCTAssertNil(held, "Replacing a pending frame must release the old buffer before the UI drains")
        mailbox.reset(active: false)
        jobs.removeFirst()()
    }
    func testSyntheticMailboxThroughput() throws {
        let frame = try frame()
        let mailbox = ProjectionFrameMailbox(schedule: { $0() }, consume: { _ in })
        mailbox.reset(active: true, cutoff: .zero)
        var tick: Int64 = 0
        measure {
            for _ in 0..<10_000 {
                tick += 1
                mailbox.offer(ProjectionFrame(pixelBuffer: frame.pixelBuffer, surface: frame.surface, time: CMTime(value: tick, timescale: 60)))
            }
        }
        XCTAssertEqual(mailbox.committed, 100_000)
    }
    func testStartupMailboxRetainsFirstStillFrameWithoutDeliveringEarly() throws {
        var jobs: [() -> Void] = [], received: [CMTime] = []
        let mailbox = ProjectionFrameMailbox(schedule: { jobs.append($0) }, consume: { if let frame = $0.frame { received.append(frame.time) } })
        mailbox.reset(active: true, delivering: false, cutoff: .zero)
        mailbox.offer(try frame())
        XCTAssertTrue(jobs.isEmpty); XCTAssertTrue(received.isEmpty)
        mailbox.startDelivering()
        XCTAssertEqual(jobs.count, 1)
        jobs.removeFirst()()
        XCTAssertEqual(received, [CMTime(value: 1, timescale: 60)])
    }
    func testMailboxRejectsOutOfOrderFramesAndClearsPendingPicture() throws {
        let picture = try frame()
        var jobs: [() -> Void] = [], received: [ProjectionFrameEvent] = []
        let mailbox = ProjectionFrameMailbox(schedule: { jobs.append($0) }, consume: { received.append($0) })
        mailbox.reset(active: true, cutoff: .zero)
        mailbox.offer(.init(pixelBuffer: picture.pixelBuffer, surface: picture.surface, time: CMTime(value: 5, timescale: 60)))
        mailbox.offerClear(.blank, at: CMTime(value: 6, timescale: 60))
        mailbox.offer(picture)
        jobs.removeFirst()()
        XCTAssertEqual(received.count, 1)
        guard case .clear(.blank) = received[0] else { return XCTFail("A pending picture must not reappear after a newer blank") }
        mailbox.offer(.init(pixelBuffer: picture.pixelBuffer, surface: picture.surface, time: CMTime(value: 7, timescale: 60)))
        mailbox.offerClear(.suspended, at: CMTime(value: 6, timescale: 60))
        jobs.removeFirst()()
        XCTAssertEqual(received.last?.frame?.time, CMTime(value: 7, timescale: 60))
    }
}

@MainActor
final class ConfidenceCaptureLifecycleTests: XCTestCase {
    private final class Engine: ProjectionCaptureEngine {
        var requests: [ConfidenceMediaRequest?] = []
        var retries = 0
        func update(_ request: ConfidenceMediaRequest?) { requests.append(request) }
        func retry() { retries += 1 }
    }
    func testSavedMediaEnablementResumesOnlyWithFreshSourceAndVisibleDemand() throws {
        let suite = "ConfidenceMediaResume.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var asks = 0
        let first = ConfidenceMediaController(defaults: defaults, engine: Engine(), hasPermission: { true }, askPermission: { asks += 1 })
        XCTAssertFalse(first.enabled)
        first.toggleEnabled()
        first.shutdown()
        XCTAssertTrue(defaults.bool(forKey: "confidenceLocalMediaEnabled"), "Quitting must preserve the operator's choice")

        let engine = Engine()
        let resumed = ConfidenceMediaController(defaults: defaults, engine: engine, hasPermission: { true }, askPermission: { asks += 1 })
        defer { resumed.shutdown() }
        XCTAssertTrue(resumed.enabled)
        XCTAssertTrue(engine.requests.allSatisfy { $0 == nil }, "No source from a previous launch is restored")
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current)
        resumed.update(request)
        XCTAssertNil(engine.requests.last!, "A closed or hidden Confidence output must not capture")
        resumed.setDemand(true)
        XCTAssertEqual(engine.requests.last!, request, "A fresh accepted source starts without another Enable action")
        XCTAssertEqual(asks, 0)
        XCTAssertEqual(engine.retries, 0, "Restoring enablement is not an explicit Retry")
    }
    func testRestoredMediaWithMissingPermissionWaitsForExplicitAction() throws {
        let suite = "ConfidenceMediaPermission.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "confidenceLocalMediaEnabled")
        let engine = Engine()
        var allowed = false, asks = 0
        let controller = ConfidenceMediaController(defaults: defaults, engine: engine, hasPermission: { allowed },
            askPermission: { asks += 1; allowed = true })
        defer { controller.shutdown() }
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current)
        controller.update(request); controller.setDemand(true)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(asks, 0)
        XCTAssertEqual(engine.retries, 0)
        XCTAssertTrue(engine.requests.allSatisfy { $0 == nil })
        XCTAssertTrue(controller.status.contains("Screen Recording"))
        controller.requestPermission()
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(engine.requests.last!, request)
    }
    func testDisablingMediaKeepsItOffAfterRelaunch() throws {
        let suite = "ConfidenceMediaDisabled.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ConfidenceMediaController(defaults: defaults, engine: Engine(), hasPermission: { true })
        first.toggleEnabled(); first.toggleEnabled(); first.shutdown()
        XCTAssertFalse(defaults.bool(forKey: "confidenceLocalMediaEnabled"))
        let engine = Engine()
        var asks = 0
        let resumed = ConfidenceMediaController(defaults: defaults, engine: engine, hasPermission: { false }, askPermission: { asks += 1 })
        defer { resumed.shutdown() }
        resumed.update(.init(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current))
        resumed.setDemand(true)
        XCTAssertFalse(resumed.enabled)
        XCTAssertEqual(asks, 0)
        XCTAssertTrue(engine.requests.allSatisfy { $0 == nil })
    }
    func testReturningFromSettingsRechecksPermissionWithoutRequestOrRetry() throws {
        let suite = "ConfidenceMediaSettingsReturn.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "confidenceLocalMediaEnabled")
        let notifications = NotificationCenter(), engine = Engine()
        var allowed = false, asks = 0
        let controller = ConfidenceMediaController(defaults: defaults, engine: engine, hasPermission: { allowed },
            askPermission: { asks += 1 }, applicationNotifications: notifications)
        defer { controller.shutdown() }
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current)
        controller.update(request); controller.setDemand(true)
        XCTAssertEqual(controller.state, .permissionNeeded)
        allowed = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(engine.requests.last!, request)
        XCTAssertEqual(asks, 0); XCTAssertEqual(engine.retries, 0)
        allowed = false
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertNil(engine.requests.last!)
        XCTAssertEqual(controller.state, .permissionNeeded)
        XCTAssertEqual(asks, 0); XCTAssertEqual(engine.retries, 0)
    }
    func testEnablingRemoteMediaGivesLocalSetupGuidanceWithoutAskingPermission() {
        let engine = Engine()
        var asks = 0
        let controller = ConfidenceMediaController(engine: engine, hasPermission: { false }, askPermission: { asks += 1 })
        defer { controller.shutdown() }
        controller.update(.init(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: nil))
        controller.setDemand(true); controller.toggleEnabled()
        XCTAssertEqual(controller.state, .remote)
        XCTAssertNil(controller.state.action)
        XCTAssertEqual(asks, 0)
        XCTAssertTrue(engine.requests.allSatisfy { $0 == nil })
    }
    func testLocalVerificationFailureDoesNotClaimEucalyIsOnAnotherMacOrStartCapture() {
        let engine = Engine()
        var asks = 0
        let controller = ConfidenceMediaController(engine: engine, hasPermission: { false }, askPermission: { asks += 1 })
        defer { controller.shutdown() }
        controller.setDemand(true)
        for issue in [LocalProjectionSourceIssue.missingIdentity, .invalidIdentity, .bootMismatch, .processUnavailable, .processChanged] {
            controller.update(.init(connection: UUID(), lease: UUID(), revision: 1,
                                    presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()),
                                    process: nil, sourceIssue: issue))
            if !controller.enabled { controller.toggleEnabled() }
            XCTAssertEqual(controller.state, .unverified(issue))
            XCTAssertEqual(controller.state.title, "Cannot verify local Eucaly")
            XCTAssertTrue(controller.state.needsAttention)
            XCTAssertNil(controller.state.action)
        }
        XCTAssertEqual(asks, 0); XCTAssertTrue(engine.requests.allSatisfy { $0 == nil })
        XCTAssertTrue(ConfidenceMediaState.unverified(.processUnavailable).detail.contains("automatically"))
    }
    func testPermissionOnlyFromExplicitActionAndClosedHiddenOutputsPause() {
        let engine = Engine(); var allowed = false, asks = 0
        let controller = ConfidenceMediaController(engine: engine, hasPermission: { allowed }, askPermission: { asks += 1; allowed = true })
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 1, windowGeneration: UUID()), process: LocalProjectionProcess.current)
        controller.update(request); controller.setDemand(true)
        XCTAssertEqual(asks, 0); XCTAssertNil(engine.requests.last!)
        controller.toggleEnabled()
        XCTAssertEqual(asks, 1); XCTAssertEqual(engine.requests.last!, request)
        controller.setDemand(false)
        XCTAssertNil(engine.requests.last!)
        controller.setDemand(true)
        XCTAssertEqual(engine.requests.last!, request)
        controller.update(nil)
        XCTAssertNil(engine.requests.last!)
        controller.update(request); controller.shutdown()
        XCTAssertNil(engine.requests.last!)
        XCTAssertEqual(asks, 1)
    }
    func testMediaLayoutReplacesLyricsAndKeepsClockSpace() throws {
        _ = NSApplication.shared
        let presentation = ConfidencePresentation()
        let canvas = ConfidenceCanvas(presentation: presentation)
        canvas.frame = .init(x: 0, y: 0, width: 1920, height: 1080)
        presentation.update(.init(confidenceContent: .init(body: "Presented primary lyric")))
        let picture = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ConfidenceMediaView }.first)
        XCTAssertTrue(picture.isHidden)
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: nil)
        presentation.update(.init(confidenceMedia: request))
        canvas.layoutSubtreeIfNeeded()
        XCTAssertFalse(picture.isHidden)
        XCTAssertEqual(presentation.text, .empty)
        XCTAssertEqual(picture.frame, .init(x: 48, y: 216, width: 1824, height: 816))
        XCTAssertGreaterThan(picture.frame.minY, 188, "The local clock strip is outside the media surface")
        XCTAssertEqual(canvas.accessibilityLabel(), "Eucaly projection picture and local clock")
        presentation.setVisible(false)
        XCTAssertTrue(picture.isHidden)
        presentation.update(.init(confidenceContent: .init(body: "Next lyric")))
        presentation.setVisible(true)
        XCTAssertTrue(picture.isHidden)
        XCTAssertEqual(canvas.accessibilityLabel(), "\nNext lyric\n")
    }
    func testRemoteMediaHasNoCaptureAndDoesNotRevealRetainedLyrics() {
        let engine = Engine()
        let controller = ConfidenceMediaController(engine: engine, hasPermission: { true })
        controller.setDemand(true); controller.toggleEnabled()
        controller.update(.init(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 1, windowGeneration: UUID()), process: nil))
        XCTAssertTrue(controller.isMedia); XCTAssertNil(engine.requests.last!)
        XCTAssertEqual(controller.state, .remote)
        controller.update(nil)
        XCTAssertFalse(controller.isMedia)
    }
    func testSystemAndDisplaySleepOverlapAndDuplicateWakeDoesNotRestartStaticCapture() {
        let engine = Engine(), notifications = NotificationCenter()
        let controller = ConfidenceMediaController(engine: engine, hasPermission: { true }, powerNotifications: notifications)
        let request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current)
        controller.update(request); controller.setDemand(true); controller.toggleEnabled()
        XCTAssertEqual(engine.requests.last!, request)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(engine.requests.last!)
        let sleepingCount = engine.requests.count
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(engine.requests.count, sleepingCount, "Capture remains paused until both sleep states end")
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(engine.requests.last!, request)
        let awakeCount = engine.requests.count
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(engine.requests.count, awakeCount, "A redundant wake must not discard the only still frame")
        controller.shutdown()
    }
    func testMediaControlRevisionsDoNotInvalidateCanvasAndClockDoesNotRedrawEverySecond() {
        let presentation = ConfidencePresentation(), canvas = ConfidenceCanvas(presentation: ConfidencePresentation())
        var changes = 0
        _ = presentation.observe { changes += 1 }
        var request = ConfidenceMediaRequest(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: nil)
        presentation.update(.init(confidenceMedia: request))
        request = request.advancingRevision()
        presentation.update(.init(confidenceMedia: request))
        XCTAssertEqual(changes, 1, "Accepted metadata must not rebuild a 1080p text/clock canvas")
        canvas.frame = .init(x: 0, y: 0, width: 1920, height: 1080)
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(canvas.refreshClock(at: minute))
        XCTAssertFalse(canvas.refreshClock(at: minute.addingTimeInterval(5)))
        XCTAssertTrue(canvas.refreshClock(at: minute.addingTimeInterval(60)))
        XCTAssertTrue(canvas.refreshClock(at: minute), "Manual/NTP backward clock adjustment must update promptly")
    }
    func testHiddenMediaViewImmediatelyReleasesItsCaptureBuffer() throws {
        let view = ConfidenceMediaView(frame: .init(x: 0, y: 0, width: 320, height: 180))
        weak var retained: CVPixelBuffer?
        try autoreleasepool {
            let picture = try projectionTestFrame()
            retained = picture.pixelBuffer; view.display(picture)
        }
        XCTAssertNotNil(retained)
        view.isHidden = true
        XCTAssertNil(retained)
        XCTAssertNil(view.layer?.contents)
    }
}

private func projectionTestFrame(tick: Int64 = 1) throws -> ProjectionFrame {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixelBuffer = try XCTUnwrap(buffer)
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue())
    return .init(pixelBuffer: pixelBuffer, surface: IOSurface(surface), time: CMTime(value: tick, timescale: 60))
}

private extension ConfidenceMediaRequest {
    func advancingRevision(windowID: UInt32? = nil, windowGeneration: UUID? = nil) -> Self {
        var presentation = presentation
        if let windowID { presentation.windowID = windowID }
        if let windowGeneration { presentation.windowGeneration = windowGeneration }
        return .init(connection: connection, lease: lease, revision: revision + 1, presentation: presentation, process: process)
    }
}

@available(macOS 12.3, *)
@MainActor
final class LocalProjectionCaptureEngineTests: XCTestCase {
    private final class Stream: ProjectionCaptureStream {
        let output: ProjectionStreamOutput
        var starts = 0, stops = 0, reconciles = 0
        var onStart: (() -> Void)?
        var startError: Error?
        var pauseStart = false, pauseStop = false, pauseReconcile = false
        var reconcileError: Error?
        var startContinuation: CheckedContinuation<Void, Never>?
        var stopContinuation: CheckedContinuation<Void, Never>?
        var reconcileContinuation: CheckedContinuation<Void, Never>?
        init(_ output: ProjectionStreamOutput) { self.output = output }
        func start() async throws {
            starts += 1; onStart?()
            if pauseStart { await withCheckedContinuation { startContinuation = $0 } }
            if let startError { throw startError }
        }
        func stop() async {
            stops += 1
            if pauseStop { await withCheckedContinuation { stopContinuation = $0 } }
        }
        func reconcile(sourceScale: CGFloat?) async throws {
            reconciles += 1
            if pauseReconcile { await withCheckedContinuation { reconcileContinuation = $0 } }
            if let reconcileError { throw reconcileError }
        }
        func finishStart() { let value = startContinuation; startContinuation = nil; value?.resume() }
        func finishStop() { let value = stopContinuation; stopContinuation = nil; value?.resume() }
        func finishReconcile() { let value = reconcileContinuation; reconcileContinuation = nil; value?.resume() }
    }
    private func request() -> ConfidenceMediaRequest {
        .init(connection: UUID(), lease: UUID(), revision: 1,
              presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: LocalProjectionProcess.current)
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard predicate() else { XCTFail("Capture lifecycle condition timed out", file: file, line: line); throw TestFailure.timeout }
    }
    private enum TestFailure: Error { case timeout, startup }
    func testRetiredDelegateErrorDuringPendingStartCannotStopReplacementSource() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}) { _, output in
            let stream = Stream(output)
            stream.pauseStart = streams.isEmpty
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { streams.first?.startContinuation != nil }
        current = current.advancingRevision(windowID: 78, windowGeneration: UUID())
        capture.update(current)
        streams[0].output.reportFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(statuses.last, .connecting)
        streams[0].finishStart()
        try await eventually { streams.count == 2 && displayed == 1 }
        XCTAssertEqual(statuses.last, .live); XCTAssertEqual(streams[0].stops, 1)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testStartDeadlineAllowsExplicitRecoveryAndRejectsLateStartup() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 0.05) { _, output in
            let stream = Stream(output); stream.pauseStart = streams.isEmpty
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        capture.update(request())
        try await eventually { streams.first?.stops == 1 && statuses.last == .retrying }
        XCTAssertEqual(displayed, 0)
        capture.retry()
        try await eventually { streams.count == 2 && displayed == 1 }
        streams[0].finishStart()
        try await eventually { streams[0].stops == 2 }
        streams[0].output.reportFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        streams[0].output.mailbox.offer(try projectionTestFrame(tick: 2))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(statuses.last, .live); XCTAssertEqual(displayed, 1)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testRetryInterruptsUnfinishedStartWithoutWaitingForItsDeadline() async throws {
        var streams: [Stream] = []
        let capture = LocalProjectionCapture(onFrame: { _ in }, onStatus: { _ in }, onClear: {}, operationTimeout: 60) { _, output in
            let stream = Stream(output); stream.pauseStart = streams.isEmpty
            streams.append(stream); return stream
        }
        capture.update(request())
        try await eventually { streams.first?.startContinuation != nil }
        capture.retry()
        try await eventually { streams.count == 2 && streams[0].stops == 1 && streams[1].starts == 1 }
        streams[0].finishStart()
        try await eventually { streams[0].stops == 2 }
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testShutdownStopsCandidateWhileStartIsStillUnfinished() async throws {
        var stream: Stream?, displayed = 0
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { _ in }, onClear: {}, operationTimeout: 60) { _, output in
            let value = Stream(output); value.pauseStart = true; stream = value; return value
        }
        capture.update(request())
        try await eventually { stream?.startContinuation != nil }
        capture.update(nil)
        try await eventually { stream?.stops == 1 }
        XCTAssertNotNil(stream?.startContinuation)
        stream?.finishStart()
        try await eventually { stream?.stops == 2 }
        XCTAssertEqual(displayed, 0)
    }
    func testStopDeadlineAllowsSourceSwitchAndLateStopCannotClearNewPicture() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 0.05) { _, output in
            let stream = Stream(output); stream.pauseStop = streams.isEmpty
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { displayed == 1 }
        current = current.advancingRevision(windowID: 78, windowGeneration: UUID())
        capture.update(current)
        try await eventually { streams.count == 2 && displayed == 2 }
        XCTAssertNotNil(streams[0].stopContinuation)
        streams[0].finishStop()
        streams[0].output.reportFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(statuses.last, .live); XCTAssertEqual(streams[1].stops, 0)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testLateStartSharesUnfinishedStopWhileReplacementKeepsItsPicture() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 0.05) { _, output in
            let stream = Stream(output)
            if streams.isEmpty { stream.pauseStart = true; stream.pauseStop = true }
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { streams.first?.startContinuation != nil }
        current = current.advancingRevision(windowID: 78, windowGeneration: UUID())
        capture.update(current)
        try await eventually { streams.count == 2 && displayed == 1 }
        streams[0].finishStart()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(streams[0].stops, 1, "Late startup must share cleanup that is still in flight")
        streams[0].finishStop()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(statuses.last, .live); XCTAssertEqual(displayed, 1)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testFactoryDeadlineDiscardsAndStopsLateCreatedStream() async throws {
        let picture = try projectionTestFrame()
        var pending: CheckedContinuation<ProjectionCaptureStream, Error>?, oldOutput: ProjectionStreamOutput?
        var streams: [Stream] = [], calls = 0, displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 0.05) { _, output in
            calls += 1
            if calls == 1 {
                oldOutput = output
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            let stream = Stream(output); stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        capture.update(request())
        try await eventually { statuses.last == .retrying }
        capture.retry()
        try await eventually { streams.count == 1 && displayed == 1 }
        let old = Stream(try XCTUnwrap(oldOutput)), continuation = try XCTUnwrap(pending)
        pending = nil; continuation.resume(returning: old)
        try await eventually { old.stops == 1 }
        XCTAssertEqual(old.starts, 0); XCTAssertEqual(statuses.last, .live)
        capture.update(nil)
        try await eventually { streams[0].stops == 1 }
    }
    func testConfigurationDeadlineAndLateErrorDoNotBlockRetry() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 0.05) { _, output in
            let stream = Stream(output)
            if streams.isEmpty {
                stream.pauseReconcile = true
                stream.reconcileError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)
            }
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        capture.update(request())
        try await eventually { displayed == 1 }
        capture.checkHealth()
        try await eventually { streams[0].reconcileContinuation != nil }
        try await eventually { statuses.last == .retrying && streams[0].stops == 1 }
        capture.retry()
        try await eventually { streams.count == 2 && displayed == 2 }
        streams[0].finishReconcile()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(statuses.last, .live); XCTAssertEqual(streams[1].stops, 0)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testRepeatedRetryBoundsUnfinishedFrameworkWorkAndRecoversWhenSlotReturns() async throws {
        var pending: [(ProjectionStreamOutput, CheckedContinuation<ProjectionCaptureStream, Error>)] = []
        var calls = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in }, onStatus: { statuses.append($0) }, onClear: {}, operationTimeout: 60) { _, output in
            calls += 1
            return try await withCheckedThrowingContinuation { pending.append((output, $0)) }
        }
        capture.update(request())
        for count in 1...4 {
            try await eventually { calls == count }
            capture.retry()
        }
        try await eventually { statuses.last == .retrying }
        XCTAssertEqual(calls, 4, "Uncooperative framework calls must not accumulate without bound")
        var retired: [Stream] = []
        for (output, continuation) in pending {
            let stream = Stream(output); retired.append(stream); continuation.resume(returning: stream)
        }
        pending.removeAll()
        try await eventually { retired.allSatisfy { $0.stops == 1 } }
        // Completion releases the slots, even when the caller timed out long ago.
        try await Task.sleep(nanoseconds: 20_000_000)
        capture.retry()
        try await eventually { calls == 5 }
        capture.update(nil)
        for (output, continuation) in pending { continuation.resume(returning: Stream(output)) }
        pending.removeAll()
    }
    func testFirstStillFrameBeforeStartCompletionIsDeliveredAndRevisionKeepsIt() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed: [CMTime] = [], clears = 0
        let capture = LocalProjectionCapture(onFrame: { displayed.append($0.time) }, onStatus: { _ in }, onClear: { clears += 1 }) { _, output in
            let stream = Stream(output); stream.pauseStart = true
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { streams.first?.startContinuation != nil }
        XCTAssertTrue(displayed.isEmpty)
        streams[0].finishStart()
        try await eventually { displayed.count == 1 }
        let initialClears = clears
        current = current.advancingRevision(); capture.update(current); capture.checkHealth()
        try await eventually { streams[0].reconciles > 0 }
        XCTAssertEqual(clears, initialClears); XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0].starts, 1); XCTAssertEqual(streams[0].stops, 0)
        XCTAssertEqual(displayed, [picture.time])
        capture.update(nil)
        try await eventually { streams[0].stops == 1 }
    }
    func testSourceSwitchDuringStartDropsRetiredPictureAndStopsBeforeCreatingNewStream() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed: [CMTime] = []
        let capture = LocalProjectionCapture(onFrame: { displayed.append($0.time) }, onStatus: { _ in }, onClear: { displayed.removeAll() }) { _, output in
            let stream = Stream(output)
            if streams.isEmpty { stream.pauseStart = true; stream.pauseStop = true }
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { streams.first?.startContinuation != nil }
        current = current.advancingRevision(windowID: 78, windowGeneration: UUID())
        capture.update(current); streams[0].finishStart()
        try await eventually { streams[0].stopContinuation != nil }
        XCTAssertEqual(streams.count, 1); XCTAssertTrue(displayed.isEmpty)
        streams[0].finishStop()
        try await eventually { streams.count == 2 && displayed.count == 1 }
        XCTAssertEqual(streams[0].stops, 1)
        // A late userStopped delegate callback belongs to the retired source.
        streams[0].output.reportFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(displayed.count, 1); XCTAssertEqual(streams[1].stops, 0)
        capture.update(nil)
        try await eventually { streams[1].stops == 1 }
    }
    func testClearDuringPendingStartCannotCommitAndCleansUpPartialStartup() async throws {
        let picture = try projectionTestFrame()
        var stream: Stream?, displayed = 0
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { _ in }, onClear: {}) { _, output in
            let value = Stream(output); value.pauseStart = true; value.onStart = { output.mailbox.offer(picture) }
            stream = value; return value
        }
        capture.update(request())
        try await eventually { stream?.startContinuation != nil }
        capture.update(nil); stream?.finishStart()
        try await eventually { (stream?.stops ?? 0) >= 1 }
        XCTAssertEqual(displayed, 0)
    }
    func testFailedStartupStopsCandidateAndOperatorStopRequiresExplicitRetry() async throws {
        let picture = try projectionTestFrame()
        var streams: [Stream] = [], displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: {}) { _, output in
            let stream = Stream(output)
            if streams.isEmpty { stream.startError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue) }
            stream.onStart = { output.mailbox.offer(picture) }
            streams.append(stream); return stream
        }
        var current = request(); capture.update(current)
        try await eventually { streams.first?.stops == 1 && statuses.last == .stopped }
        XCTAssertEqual(statuses.last?.action, .retry)
        XCTAssertEqual(displayed, 0)
        current = current.advancingRevision(); capture.update(current); capture.checkHealth()
        capture.update(nil); capture.update(current); capture.checkHealth()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(streams.count, 1, "Visibility, source reports and wake must respect a macOS refusal")
        capture.retry()
        try await eventually { streams.count == 2 && displayed == 1 }
        XCTAssertEqual(statuses.last, .live)
        XCTAssertNil(statuses.last?.action, "A working stream has nothing to retry")
        streams[1].output.mailbox.offerClear(.stopped, at: CMTime(value: 2, timescale: 60))
        let latePicture = try projectionTestFrame(tick: 3)
        streams[1].output.mailbox.offer(latePicture)
        try await eventually { streams[1].stops == 1 && statuses.last == .stopped }
        XCTAssertEqual(displayed, 1, "A late frame must not coalesce away a terminal stopped sample")
        capture.checkHealth()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(streams.count, 2, "Stopped samples must not race the delegate and restart macOS capture")
        capture.update(nil)
    }
    func testTransientRecoveryBacksOffButDoesNotAutomaticallyUndoPermissionOrUserStop() {
        var recovery = ProjectionCaptureRecovery()
        for delay in [2.0, 4.0, 8.0, 15.0, 15.0] {
            recovery.failed(TestFailure.startup, now: 100)
            XCTAssertEqual(recovery.nextAttempt, 100 + delay); XCTAssertFalse(recovery.requiresOperator)
        }
        for code in [SCStreamError.Code.userDeclined, .userStopped, .missingEntitlements] {
            recovery.failed(NSError(domain: SCStreamErrorDomain, code: code.rawValue), now: 100)
            XCTAssertTrue(recovery.requiresOperator)
            recovery.reset()
            XCTAssertTrue(recovery.requiresOperator)
            recovery.reset(explicit: true)
            XCTAssertFalse(recovery.requiresOperator); XCTAssertEqual(recovery.failures, 0)
        }
    }
    func testIntentionallyBlankOrSuspendedSourceWaitsForNativeResumeWithoutRestart() async throws {
        for state in [ProjectionPictureState.blank, .suspended] {
            let picture = try projectionTestFrame(tick: 2)
            var stream: Stream?, clears = 0, displayed = 0
            let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { _ in }, onClear: { clears += 1 }) { _, output in
                let value = Stream(output)
                value.onStart = { output.mailbox.noteActivity(); output.mailbox.offerClear(state, at: CMTime(value: 1, timescale: 60)) }
                stream = value; return value
            }
            capture.update(request())
            try await eventually { clears == 2 }
            capture.checkHealth(now: ProcessInfo.processInfo.systemUptime + 11)
            try await eventually { stream?.reconciles == 1 }
            XCTAssertEqual(stream?.starts, 1); XCTAssertEqual(stream?.stops, 0)
            stream?.output.mailbox.offer(picture)
            try await eventually { displayed == 1 }
            capture.update(nil)
            try await eventually { stream?.stops == 1 }
        }
    }
    func testQuietStillPictureIsRetainedUntilNewFrameInsteadOfFalseStallRecovery() async throws {
        let picture = try projectionTestFrame()
        var stream: Stream?, clears = 0, displayed = 0, statuses: [ConfidenceMediaState] = []
        let capture = LocalProjectionCapture(onFrame: { _ in displayed += 1 }, onStatus: { statuses.append($0) }, onClear: { clears += 1 }) { _, output in
            let value = Stream(output)
            value.onStart = { output.mailbox.noteActivity(); output.mailbox.offer(picture) }
            stream = value; return value
        }
        capture.update(request())
        try await eventually { displayed == 1 }
        let initialClears = clears
        capture.checkHealth(now: ProcessInfo.processInfo.systemUptime + 11)
        try await eventually { stream?.reconciles == 1 }
        XCTAssertEqual(stream?.starts, 1); XCTAssertEqual(stream?.stops, 0)
        XCTAssertEqual(clears, initialClears); XCTAssertEqual(displayed, 1)
        XCTAssertEqual(statuses.last, .holding)
        stream?.output.mailbox.offer(try projectionTestFrame(tick: 2))
        try await eventually { displayed == 2 }
        XCTAssertEqual(statuses.last, .live)
        capture.update(nil)
        try await eventually { stream?.stops == 1 }
    }
    func testNativeStartedIdleBlankSuspendedAndCompleteSamples() async throws {
        var events: [ProjectionFrameEvent] = []
        let output = ProjectionStreamOutput(onEvent: { _, event in events.append(event) }, onFailure: { _, _ in XCTFail("Samples must not invoke the delegate") })
        output.mailbox.reset(active: true, cutoff: .zero)
        output.handleScreenSample(try sample(status: .started, tick: 1))
        try await eventually { events.count == 1 }
        XCTAssertNotNil(events[0].frame); XCTAssertEqual(events[0].frame?.sourceScale, 2)
        output.handleScreenSample(try sample(status: .idle, tick: 2))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(output.mailbox.statistics.samples, 2)
        output.handleScreenSample(try sample(status: .blank, tick: 3))
        try await eventually { events.count == 2 }
        guard case .clear(.blank) = events[1] else { return XCTFail("Blank source must clear its picture") }
        output.handleScreenSample(try sample(status: .suspended, tick: 4))
        try await eventually { events.count == 3 }
        guard case .clear(.suspended) = events[2] else { return XCTFail("Suspension must clear its picture") }
        output.handleScreenSample(try sample(status: .complete, tick: 5))
        try await eventually { events.count == 4 }
        XCTAssertEqual(events[3].frame?.time, CMTime(value: 5, timescale: 60))
        output.mailbox.reset(active: false)
    }
    private func sample(status: SCFrameStatus, tick: Int64) throws -> CMSampleBuffer {
        let frame = try projectionTestFrame(tick: tick)
        var format: CMVideoFormatDescription?, buffer: CMSampleBuffer?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &buffer), noErr)
        let sample = try XCTUnwrap(buffer)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)) as NSArray
        let metadata = try XCTUnwrap(attachments.firstObject as? NSMutableDictionary)
        metadata[SCStreamFrameInfo.status.rawValue] = status.rawValue
        metadata[SCStreamFrameInfo.scaleFactor.rawValue] = 2
        return sample
    }
}
