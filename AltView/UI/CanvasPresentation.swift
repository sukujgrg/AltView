import AppKit

/// Bounded, main-thread cache shared by the output and private preview scenes.
/// Every canvas fits in the same 1920 × 1080 coordinate space.
final class CanvasTextLayoutCache {
    private struct Key: Equatable {
        var content: DisplayContent
        var style: OutputStyle
        var template: LowerThirdTemplate
        init(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate) {
            self.content = content; self.content.visible = true
            self.style = style.clamped(); self.style.background = "000000"
            self.template = template.clamped()
            // These affect compositing or motion, never text fitting.
            self.template.artwork = .builtIn; self.template.assetID = nil; self.template.assetName = nil
            self.template.showsArtwork = true; self.template.artworkRegion = LowerThirdTemplate().artworkRegion
            self.template.animation = .none; self.template.duration = 0.45
        }
    }
    private var entries: [(key: Key, layout: CanvasTextLayout)] = []
    private let capacity: Int
    private let makeLayout: (DisplayContent, OutputStyle, LowerThirdTemplate) -> CanvasTextLayout
    init(capacity: Int = 8,
         makeLayout: @escaping (DisplayContent, OutputStyle, LowerThirdTemplate) -> CanvasTextLayout = { content, style, template in
             template.enabled ? .lowerThird(content: content, style: style, template: template)
                 : .make(content: content, style: style, template: template)
         }) {
        self.capacity = max(1, capacity); self.makeLayout = makeLayout
    }
    func layout(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate) -> CanvasTextLayout {
        let key = Key(content: content, style: style, template: template)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.layout
        }
        let layout = makeLayout(key.content, key.style, key.template)
        if entries.count == capacity { entries.removeFirst() }
        entries.append((key, layout))
        return layout
    }
}

/// One presentation and one animation clock shared by receiver preview and HDMI output.
/// All access is on the main thread. Network queues only deliver complete snapshots.
final class CanvasPresentation {
    private(set) var content = DisplayContent.empty
    private(set) var displayedContent = DisplayContent.empty
    private(set) var style = OutputStyle()
    private(set) var template = LowerThirdTemplate()
    private(set) var artwork: PNGArtwork?
    private(set) var motion = LowerThirdMotion()
    private(set) var revision: UInt64 = 0
    private var observers: [UUID: () -> Void] = [:]
    private var timer: Timer?
    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool
    let layoutCache: CanvasTextLayoutCache
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         layoutCache: CanvasTextLayoutCache = CanvasTextLayoutCache()) {
        self.clock = clock; self.reduceMotion = reduceMotion; self.layoutCache = layoutCache
    }
    var progress: Double { motion.progress(at: clock()) }
    var textLayout: CanvasTextLayout { layoutCache.layout(content: content, style: style, template: template) }
    // Keep the exiting text's layout even if the sender hides with an empty snapshot.
    var displayedTextLayout: CanvasTextLayout { layoutCache.layout(content: displayedContent, style: style, template: template) }

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func update(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate, artwork: PNGArtwork?, immediately: Bool = false) {
        let template = template.clamped()
        let changed = self.style != style || self.template != template || self.artwork?.id != artwork?.id
        let running = motion.isRunning(at: clock())
        let finishTransition = (running && (immediately || reduceMotion()))
            || (!content.visible && displayedContent != .empty && !running)
        guard changed || self.content != content || finishTransition else { return }
        let changedMotion = self.template.enabled != template.enabled || self.template.animation != template.animation
        let oldDisplayed = displayedContent
        self.content = content; self.style = style; self.template = template; self.artwork = artwork
        if content.visible { displayedContent = content }
        let animated = template.enabled && template.animation != .none && !immediately && !changedMotion
            && !reduceMotion()
        motion.set(visible: content.visible, at: clock(), duration: template.duration, animated: animated)
        if motion.target == 0 && !motion.isRunning(at: clock()) { displayedContent = .empty }
        if changed || oldDisplayed != displayedContent { revision &+= 1 }
        notify()
        scheduleAnimation()
    }
    /// Local template preview only: no receiver or sender state is changed.
    func replay() {
        guard content.visible else { return }
        let now = clock()
        motion.set(visible: false, at: now, duration: 0, animated: false)
        motion.set(visible: true, at: now, duration: template.duration,
                   animated: template.enabled && template.animation != .none && !reduceMotion())
        notify(); scheduleAnimation()
    }
    func stopAnimation() {
        timer?.invalidate(); timer = nil
        motion.set(visible: content.visible, at: clock(), duration: 0, animated: false)
        finishHidden(); notify()
    }
    private func scheduleAnimation() {
        guard motion.isRunning(at: clock()) else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        if !motion.isRunning(at: clock()) {
            timer?.invalidate(); timer = nil
            finishHidden()
        }
        notify()
    }
    private func finishHidden() {
        if motion.target == 0 && displayedContent != .empty { displayedContent = .empty; revision &+= 1 }
    }
    private func notify() { for callback in Array(observers.values) { callback() } }
    deinit { timer?.invalidate() }
}
