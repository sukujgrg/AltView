import AppKit
import AVFoundation
import CoreAudio
import Darwin

@MainActor
final class EucalyMediaPresentation {
    let playback = SRTMediaPlayback()
    private let canvases = NSHashTable<EucalyMediaCanvas>.weakObjects()
    init() {
        playback.onFrame = { [weak self] frame in self?.canvases.allObjects.forEach { $0.display(frame) } }
    }
    func attach(_ canvas: EucalyMediaCanvas) { canvases.add(canvas); canvas.display(playback.frame) }
    func detach(_ canvas: EucalyMediaCanvas) { canvases.remove(canvas) }
}

@MainActor
final class EucalyMediaCanvas: NSView {
    let presentation: EucalyMediaPresentation
    private let picture = AVSampleBufferDisplayLayer()
    init(presentation: EucalyMediaPresentation) {
        self.presentation = presentation
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
        guard let buffer else { picture.flushAndRemoveImage(); return }
        if picture.status == .failed { picture.flushAndRemoveImage() }
        if picture.isReadyForMoreMediaData { picture.enqueue(buffer) }
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
    private let secret = NSSecureTextField(string: "")
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
    init(defaults: UserDefaults, assignments: DisplayAssignments? = nil) {
        self.defaults = defaults; self.assignments = assignments ?? DisplayAssignments(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let savedPort = defaults.integer(forKey: "mediaSRTport")
        port.stringValue = String((1...65535).contains(savedPort) ? savedPort : 10000)
        port.setAccessibilityLabel("Media listening port")
        secret.placeholderString = "10–79 letters, numbers, - or _"; secret.setAccessibilityLabel("Media passphrase")
        latency.addItems(withTitles: ["40 ms", "80 ms", "120 ms", "200 ms"])
        let savedLatency = defaults.integer(forKey: "mediaSRTlatency")
        latency.selectItem(withTitle: "\([40,80,120,200].contains(savedLatency) ? savedLatency : 80) ms")
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
        let addresses = UI.label(Self.localAddresses(), size: 11, color: .secondaryLabelColor)
        addresses.isSelectable = true
        let controls = UI.column(UI.card("Media display", content: monitors),
            UI.card("Receive from eucaly", content: UI.column(
                UI.label("In eucaly, add an AltView Media output in Manage Outputs. Enter this Mac’s local address, this port and this passphrase. Use wired Ethernet on both Macs.", size: 11, color: .secondaryLabelColor),
                addresses,
                UI.row(UI.label("Port", size: 12), port),
                UI.row(UI.label("Passphrase", size: 12), secret),
                UI.button("Copy Passphrase", target: self, action: #selector(copyPassphrase)),
                UI.row(UI.label("Recovery buffer", size: 12), latency), receiveButton, status, detail)),
            UI.card("Audio", content: UI.column(audio, refreshAudio, mute, audioStatus,
                UI.label("Choose the HDMI audio device connected to ATEM. Audio plays once, shared by preview and display.", size: 11, color: .secondaryLabelColor))), spacing: 14)
        let stage = UI.canvasStage(EucalyMediaCanvas(presentation: presentation))
        let heading = UI.row(UI.label("EUCALY MEDIA PREVIEW", size: 11, color: .secondaryLabelColor, bold: true), NSView(),
            PreviewAspectRatioPicker(stage: stage, defaults: defaults, role: "eucaly Media"))
        let monitor = UI.monitorPreview(heading: heading, stage: stage, footer: UI.column(
            UI.label("Live Audience picture from eucaly · 1080p H.264 with audio", size: 12),
            UI.label("Audience’s text receiver is independent. Stop Receiving clears only this media output.", size: 11, color: .secondaryLabelColor)))
        let body = UI.row(monitor, UI.scrolling(controls)); body.alignment = .top; body.spacing = UI.previewColumnGap
        body.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: UI.previewInspectorWidth).isActive = true
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -(UI.previewInspectorWidth + UI.previewColumnGap)).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        body.arrangedSubviews[1].heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        UI.fill(UI.column(UI.pageHeading("eucaly Media", subtitle: "Receive eucaly’s Audience picture and audio over SRT, then send it to HDMI."), body, spacing: 20), in: view, padding: 0)
        output.onChange = { [weak self] _ in self?.onActivityChange?() }
        Task { [weak self] in
            do {
                let saved = try await SRTMediaSecrets.shared.read("receiver")
                guard let self, self.secret.stringValue.isEmpty else { return }
                self.secret.stringValue = saved ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
            } catch { self?.status.stringValue = error.localizedDescription }
        }
    }
    @objc private func copyPassphrase() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(secret.stringValue, forType: .string)
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
        let passphrase = secret.stringValue
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
            do { try await SRTMediaSecrets.shared.save(passphrase, account: "receiver") }
            catch { if self.generation == token { self.stopReceiving(); self.status.stringValue = error.localizedDescription }; return }
            while !Task.isCancelled && self.generation == token {
                let session = SRTMediaSession(), sink = SRTMediaDecodedOutput()
                self.session = session; self.sink = sink
                self.lastVideo = ProcessInfo.processInfo.systemUptime
                self.status.stringValue = "Waiting for eucaly"; self.detail.stringValue = "Listening on UDP port \(settings.port)"
                self.drainTask = Task { [weak self] in
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
                do {
                    try await session.receive(settings: settings, passphrase: passphrase, output: sink)
                    while !Task.isCancelled && self.generation == token {
                        guard await session.isConnected() else { break }
                        if ProcessInfo.processInfo.systemUptime - self.lastVideo > 3 {
                            self.presentation.playback.reset()
                            self.status.stringValue = "Waiting for video"
                        }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                } catch { if self.generation == token { self.status.stringValue = "Connection ended · waiting to retry" } }
                sink.ingest.finish(); self.drainTask?.cancel(); self.drainTask = nil
                await session.close()
                guard self.generation == token && !Task.isCancelled else { break }
                self.presentation.playback.reset()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private func setControls() {
        receiveButton.title = receiving ? "Stop Receiving" : "Start Receiving"
        for control in [port, secret, latency, audio, refreshAudio] as [NSControl] { control.isEnabled = !receiving }
    }
    func stopReceiving() {
        generation = UUID(); receiving = false
        receiverTask?.cancel(); receiverTask = nil; drainTask?.cancel(); drainTask = nil
        sink?.ingest.finish(); sink = nil
        let retired = session; session = nil
        Task { await retired?.close() }
        presentation.playback.reset(); status.stringValue = "Stopped"; detail.stringValue = ""
        setControls(); onActivityChange?()
    }
    func setPreviewActive(_ active: Bool) {}
    func stop() { output.stop() }
    func shutdown() { stopReceiving(); output.stop() }
    private static func localAddresses() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "Find this Mac’s Ethernet address in System Settings → Network." }
        defer { freeifaddrs(list) }
        var values: [String] = [], cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.append("\(String(cString: entry.pointee.ifa_name)): \(String(cString: host))")
            }
        }
        return values.isEmpty ? "Connect Ethernet to obtain a local address." : "Local addresses · choose Ethernet:\n" + values.joined(separator: "\n")
    }
}
