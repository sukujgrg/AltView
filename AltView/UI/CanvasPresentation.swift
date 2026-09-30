import AppKit

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
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.clock = clock; self.reduceMotion = reduceMotion
    }
    var progress: Double { motion.progress(at: clock()) }

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func update(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate, artwork: PNGArtwork?, immediately: Bool = false) {
        let template = template.clamped()
        let changed = self.style != style || self.template != template || self.artwork?.id != artwork?.id
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
