import AppKit
import AVFoundation
import CoreAudio
import Darwin
import CryptoKit
import os

@MainActor
final class EucalyMediaPresentation {
    let playback = SRTMediaPlayback()
    private let canvases = NSHashTable<EucalyMediaCanvas>.weakObjects()
    init() {
        playback.onFrame = { [weak self] frame in self?.canvases.allObjects.forEach { $0.display(frame) } }
        playback.onVideoTimelineReset = { [weak self] in self?.canvases.allObjects.forEach { $0.flushVideoTimeline() } }
    }
    func attach(_ canvas: EucalyMediaCanvas) { canvases.add(canvas); canvas.display(playback.frame) }
    func detach(_ canvas: EucalyMediaCanvas) { canvases.remove(canvas) }
}

@MainActor
final class EucalyMediaCanvas: NSView {
    private static let logger = Logger(subsystem: "com.suku.AltView", category: "media-video")
    let presentation: EucalyMediaPresentation
    private let picture: AVSampleBufferDisplayLayer
    // The native readiness flag is advisory for real-time input. Keep a
    // separate bound so brief decoder bursts are admitted without allowing
    // a stalled renderer to retain an unbounded number of pixel buffers.
    private var pendingPresentationTimes: [CMTime] = []
    private(set) var enqueuedFrameCount = 0
    private(set) var backpressuredEnqueueCount = 0
    private(set) var overloadFlushCount = 0
    init(presentation: EucalyMediaPresentation, picture displayLayer: AVSampleBufferDisplayLayer? = nil) {
        self.presentation = presentation
        self.picture = displayLayer ?? AVSampleBufferDisplayLayer()
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        picture.videoGravity = .resizeAspect; picture.backgroundColor = NSColor.black.cgColor
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1); picture.controlTimebase = timebase
        }
        layer?.addSublayer(picture)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("eucaly Media video output")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { presentation.detach(self); display(nil) } else { presentation.attach(self) }
    }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = bounds; CATransaction.commit()
    }
    func display(_ buffer: CMSampleBuffer?) {
        guard let buffer else {
            pendingPresentationTimes.removeAll(keepingCapacity: true)
            picture.flushAndRemoveImage(); return
        }
        if picture.status == .failed {
            let code = (picture.error as NSError?)?.code ?? 0
            Self.logger.notice("video_renderer_recovery error_code=\(code)")
            flushVideoTimeline()
        }
        let now = picture.controlTimebase.map { CMTimebaseGetTime($0) }
            ?? CMClockGetTime(CMClockGetHostTimeClock())
        pendingPresentationTimes.removeAll { $0 <= now }
        if pendingPresentationTimes.count >= 24 {
            overloadFlushCount += 1
            Self.logger.notice("video_renderer_recovery reason=queue_limit")
            flushVideoTimeline()
        }
        if !picture.isReadyForMoreMediaData { backpressuredEnqueueCount += 1 }
        picture.enqueue(buffer)
        pendingPresentationTimes.append(buffer.presentationTimeStamp)
        enqueuedFrameCount += 1
    }
    func flushVideoTimeline() {
        pendingPresentationTimes.removeAll(keepingCapacity: true)
        picture.flush()
    }
}

struct MediaAudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    static func outputs() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
            var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?; var count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &count, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        return ids.compactMap { id in
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &count) == noErr, count > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Self(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class EucalyMediaViewController: NSViewController {
    let presentation = EucalyMediaPresentation()
    private let secrets: any SRTMediaSecretStoring
    private let defaults: UserDefaults
    private let assignments: DisplayAssignments
    private var receiverTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var session: SRTMediaSession?
    private var sink: SRTMediaDecodedOutput?
    private var generation = UUID()
    private var lastVideo: TimeInterval = 0
    private(set) var receiving = false
    private let port = NSTextField(string: "10000")
    private var mediaSecret: String?
    private var receiverID: UUID?
    private var credentialTask: Task<Void, Never>?
    private var credentialGeneration = UUID()
    private var listenerReady = false
    var onMediaOfferChange: ((MediaOffer?) -> Void)?
    private func publishMediaOffer() {
        guard let mediaSecret, let receiverID else { onMediaOfferChange?(nil); return }
        onMediaOfferChange?(MediaOffer(receiverID: receiverID, port: port.integerValue,
            ready: listenerReady, passphrase: mediaSecret))
    }
    /// A new pairing code creates a new independent random media credential.
    /// Saving must succeed before it can be provisioned or used by SRT.
    func invalidatePairing() {
        stopReceiving(); credentialTask?.cancel(); credentialTask = nil
        credentialGeneration = UUID(); mediaSecret = nil; receiverID = nil
        publishMediaOffer(); receiveButton.isEnabled = false
    }
    func configurePairing(key: Data, receiverID: UUID) {
        invalidatePairing()
        guard PairingKey.isValid(key) else { return }
        self.receiverID = receiverID
        let token = UUID(); credentialGeneration = token
        publishMediaOffer(); receiveButton.isEnabled = false
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let account = "receiver-v3-\(receiverID)-\(digest)"
        credentialTask = Task { [weak self] in
            do {
                let saved = try await secrets.read(account)
                let secret = saved ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
                guard SRTMediaSettings.validPassphrase(secret) else { throw SRTMediaError.invalidSettings }
                if saved == nil { try await secrets.save(secret, account: account) }
                guard let self, !Task.isCancelled, self.credentialGeneration == token else { return }
                self.mediaSecret = secret; self.setControls(); self.publishMediaOffer()
                self.status.stringValue = "Stopped · receiver paired for Lyrics and Media"
            } catch {
                guard let self, self.credentialGeneration == token else { return }
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    private let latency = NSPopUpButton()
    private let audio = NSPopUpButton()
    private lazy var refreshAudio = UI.button("Refresh Audio Devices", target: self, action: #selector(refreshAudioDevices))
    private var audioDevices: [MediaAudioDevice] = []
    private let status = UI.label("Stopped", size: 12, bold: true)
    private let detail = UI.label("", size: 11, color: .secondaryLabelColor)
    private let audioStatus = UI.label("", size: 11, color: .secondaryLabelColor)
    private let mute = NSButton(checkboxWithTitle: "Mute received audio", target: nil, action: nil)
    private lazy var receiveButton = UI.button("Start Receiving", target: self, action: #selector(toggleReceiving))
    lazy var output = OutputWindowController(name: "eucaly Media",
        makeCanvas: { [presentation] in EucalyMediaCanvas(presentation: presentation) },
        displays: { [assignments] in assignments.currentDisplays() })
    private lazy var monitors = MonitorControls(role: .confidence, assignments: assignments, output: output)
    var onActivityChange: (() -> Void)?
    init(defaults: UserDefaults, assignments: DisplayAssignments? = nil, secrets: any SRTMediaSecretStoring = SRTMediaSecrets.shared) {
        self.secrets = secrets
        self.defaults = defaults; self.assignments = assignments ?? DisplayAssignments(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let savedPort = defaults.integer(forKey: "mediaSRTport")
        port.stringValue = String((1...65535).contains(savedPort) ? savedPort : 10000)
        port.setAccessibilityLabel("Media listening port")
        latency.addItems(withTitles: ["20 ms · Wired LAN", "40 ms", "80 ms", "120 ms", "200 ms"])
        let savedLatency = defaults.integer(forKey: "mediaSRTlatency")
        if savedLatency == 20 { latency.selectItem(at: 0) }
        else { latency.selectItem(withTitle: "\([40,80,120,200].contains(savedLatency) ? savedLatency : 80) ms") }
        audioDevices = MediaAudioDevice.outputs()
        audio.addItems(withTitles: ["System default"] + audioDevices.map(\.name))
        if let uid = defaults.string(forKey: "mediaAudioDevice"), let index = audioDevices.firstIndex(where: { $0.uid == uid }) {
            audio.selectItem(at: index + 1)
        } else if defaults.string(forKey: "mediaAudioDevice") != nil {
            audio.addItem(withTitle: "Saved audio output · unavailable"); audio.selectItem(at: audio.numberOfItems - 1)
        }
        audio.setAccessibilityLabel("Received audio output")
        mute.target = self; mute.action = #selector(muteChanged)
        presentation.playback.onError = { [weak self] message in self?.audioStatus.stringValue = message }
        let controls = UI.column(UI.card("Media display", content: monitors),
            UI.card("Receive from eucaly", content: UI.column(
                UI.label("Pair this receiver in eucaly’s Settings → Manage Outputs using the 8-character code from Connections. Media encryption is automatic. Start Receiving here, then Show Slides in eucaly to send Media. Ethernet is recommended.", size: 11, color: .secondaryLabelColor),
                UI.row(UI.label("Port", size: 12), port),
                UI.row(UI.label("Recovery buffer", size: 12), latency), receiveButton, status, detail)),
            UI.card("Audio", content: UI.column(audio, refreshAudio, mute, audioStatus,
                UI.label("Choose the HDMI audio device connected to ATEM. Audio plays once, shared by preview and display.", size: 11, color: .secondaryLabelColor))), spacing: 14)
        let stage = UI.canvasStage(EucalyMediaCanvas(presentation: presentation))
        let heading = UI.row(UI.label("EUCALY MEDIA PREVIEW", size: 11, color: .secondaryLabelColor, bold: true), NSView(),
            PreviewAspectRatioPicker(stage: stage, defaults: defaults, role: "eucaly Media"))
        let monitor = UI.monitorPreview(heading: heading, stage: stage, footer: UI.column(
            UI.label("Live Audience picture from eucaly · 1080p H.264 with audio", size: 12),
            UI.label("eucaly Lyrics receives text separately. Stop Receiving clears only this media output.", size: 11, color: .secondaryLabelColor)))
        let body = UI.row(monitor, UI.scrolling(controls)); body.alignment = .top; body.spacing = UI.previewColumnGap
        body.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: UI.previewInspectorWidth).isActive = true
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -(UI.previewInspectorWidth + UI.previewColumnGap)).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        body.arrangedSubviews[1].heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        UI.fill(UI.column(UI.pageHeading("eucaly Media", subtitle: "Receive eucaly’s Audience picture and audio over SRT, then send it to HDMI."), body, spacing: 20), in: view, padding: 0)
        output.onChange = { [weak self] _ in self?.onActivityChange?() }
    }
    @objc private func muteChanged() { presentation.playback.muted = mute.state == .on }
    @objc private func refreshAudioDevices() {
        guard !receiving else { return }
        let index = audio.indexOfSelectedItem - 1
        let uid = audioDevices.indices.contains(index) ? audioDevices[index].uid
            : index >= audioDevices.count ? defaults.string(forKey: "mediaAudioDevice") : nil
        audioDevices = MediaAudioDevice.outputs()
        audio.removeAllItems(); audio.addItems(withTitles: ["System default"] + audioDevices.map(\.name))
        if let uid, let index = audioDevices.firstIndex(where: { $0.uid == uid }) { audio.selectItem(at: index + 1) }
        else if uid != nil { audio.addItem(withTitle: "Saved audio output · unavailable"); audio.selectItem(at: audio.numberOfItems - 1) }
    }
    @objc private func toggleReceiving() {
        if receiving { stopReceiving(); return }
        var settings = SRTMediaSettings(); settings.port = port.integerValue
        settings.latency = Int(latency.titleOfSelectedItem?.split(separator: " ").first ?? "80") ?? 80
        guard let passphrase = mediaSecret else { status.stringValue = "Prepare receiver pairing in Connections first."; return }
        do { _ = try settings.url(passphrase: passphrase, listening: true) }
        catch { status.stringValue = error.localizedDescription; return }
        let deviceIndex = audio.indexOfSelectedItem - 1
        if deviceIndex >= audioDevices.count { status.stringValue = "Reconnect the saved audio output or choose another device."; return }
        presentation.playback.audioDevice = deviceIndex >= 0 ? audioDevices[deviceIndex].id : nil
        defaults.set(deviceIndex >= 0 ? audioDevices[deviceIndex].uid : nil, forKey: "mediaAudioDevice")
        defaults.set(settings.port, forKey: "mediaSRTport"); defaults.set(settings.latency, forKey: "mediaSRTlatency")
        receiving = true; let token = UUID(); generation = token
        audioStatus.stringValue = ""
        setControls(); status.stringValue = "Starting receiver…"; onActivityChange?()
        receiverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.generation == token {
                let session = SRTMediaSession(), sink = SRTMediaDecodedOutput()
                self.session = session; self.sink = sink
                self.lastVideo = ProcessInfo.processInfo.systemUptime
                self.status.stringValue = "Waiting for eucaly"; self.detail.stringValue = "Listening on UDP port \(settings.port)"
                let drainTask = Task { [weak self] in
                    for await _ in sink.ingest.signals {
                        guard let self, self.generation == token, !Task.isCancelled else { break }
                        for sample in sink.ingest.drain() {
                            self.presentation.playback.consume(sample)
                            if case .video = sample {
                                self.lastVideo = ProcessInfo.processInfo.systemUptime
                                if self.status.stringValue != "Receiving" { self.status.stringValue = "Receiving" }
                            }
                        }
                    }
                }
                self.drainTask = drainTask
                do {
                    try await session.receive(settings: settings, passphrase: passphrase, output: sink, onListening: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.session === session else { return }
                            self.listenerReady = true; self.publishMediaOffer()
                        }
                    })
                    while !Task.isCancelled && self.generation == token {
                        guard await session.isConnected() else { break }
                        if ProcessInfo.processInfo.systemUptime - self.lastVideo > 3 {
                            self.presentation.playback.reset()
                            self.status.stringValue = "Waiting for video"
                        }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                } catch { if self.generation == token { self.status.stringValue = "Receiver unavailable: \(error.localizedDescription) · retrying…" } }
                // A stopped task can finish after its replacement has started.
                // Retire only this attempt's resources and readiness.
                sink.ingest.finish(); drainTask.cancel()
                if self.generation == token {
                    self.session = nil; self.sink = nil; self.drainTask = nil
                    self.listenerReady = false; self.publishMediaOffer()
                }
                await session.close()
                guard self.generation == token && !Task.isCancelled else { break }
                self.presentation.playback.reset()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private func setControls() {
        receiveButton.title = receiving ? "Stop Receiving" : "Start Receiving"
        receiveButton.isEnabled = mediaSecret != nil
        for control in [port, latency, audio, refreshAudio] as [NSControl] { control.isEnabled = !receiving }
    }
    func stopReceiving() {
        generation = UUID(); receiving = false
        listenerReady = false; publishMediaOffer()
        receiverTask?.cancel(); receiverTask = nil; drainTask?.cancel(); drainTask = nil
        sink?.ingest.finish(); sink = nil
        let retired = session; session = nil
        Task { await retired?.close() }
        presentation.playback.reset(); status.stringValue = "Stopped"; detail.stringValue = ""
        setControls(); onActivityChange?()
    }
    func setPreviewActive(_ active: Bool) {}
    func stop() { output.stop() }
    func shutdown() { invalidatePairing(); output.stop() }
}
