import AppKit
import ColorSync

enum DisplayRole: String, CaseIterable {
    case audience, confidence
    var title: String { rawValue.capitalized }
    var legacyKey: String { self == .audience ? "outputDisplayID" : "confidenceDisplayID" }
    var preferenceKey: String { "\(rawValue)MonitorAssignment" }
    var other: Self { self == .audience ? .confidence : .audience }
}

struct DisplayTarget: Codable, Equatable {
    let identity: String
    let name: String
    func resolve(in displays: [OutputDisplay]) -> OutputDisplay? {
        let matches = displays.filter { $0.identity == identity }
        return matches.count == 1 ? matches[0] : nil
    }
}

private struct MonitorLabel: Codable, Equatable {
    let number: Int
    var name = ""
}

struct OutputDisplay {
    let id: UInt32
    let name: String
    let frame: NSRect
    let identity: String
    var isBuiltIn = false
    var isMirrored = false
    init(id: UInt32, name: String, frame: NSRect, identity: String? = nil,
         isBuiltIn: Bool = false, isMirrored: Bool = false) {
        self.id = id; self.name = name; self.frame = frame
        self.identity = identity ?? "runtime:\(id)"
        self.isBuiltIn = isBuiltIn; self.isMirrored = isMirrored
    }
    var target: DisplayTarget { .init(identity: identity, name: name) }
    static var current: [Self] {
        NSScreen.screens.map { screen in
            let id = OutputWindowController.displayID(screen)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let identity = uuid.flatMap { CFUUIDCreateString(nil, $0) }.map { $0 as String }
            return Self(id: id, name: screen.localizedName, frame: screen.frame, identity: identity,
                        isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }
}

/// One authority for saved assignments, including monitors whose windows are closed.
final class DisplayAssignments {
    private let defaults: UserDefaults
    private let displaySource: () -> [OutputDisplay]
    private var targets: [DisplayRole: DisplayTarget] = [:]
    private var labels: [String: MonitorLabel] = [:]
    private let labelsKey = "monitorLabelsV1"
    private var locked: Set<DisplayRole> = []
    private var observers: [UUID: () -> Void] = [:]
    private var screenObserver: NSObjectProtocol?
    private(set) var displays: [OutputDisplay]
    init(defaults: UserDefaults, displays: @escaping () -> [OutputDisplay] = { OutputDisplay.current }) {
        self.defaults = defaults; displaySource = displays; self.displays = displays()
        if let data = defaults.data(forKey: labelsKey), let saved = try? JSONDecoder().decode([String: MonitorLabel].self, from: data) {
            var numbers = Set<Int>()
            for identity in saved.keys.sorted() {
                guard let label = saved[identity], label.number > 0, label.number < 1_000_000,
                      Self.isRememberedIdentity(identity), numbers.insert(label.number).inserted else { continue }
                labels[identity] = MonitorLabel(number: label.number, name: Self.normalizedName(label.name) ?? "")
            }
        }
        for role in DisplayRole.allCases {
            if defaults.object(forKey: role.preferenceKey) != nil {
                // A saved null is an explicit preview assignment; never revive an older monitor.
                do { targets[role] = try JSONDecoder().decode(DisplayTarget?.self, from: defaults.data(forKey: role.preferenceKey) ?? Data()) }
                catch { targets[role] = DisplayTarget(identity: "unreadable:\(role.rawValue)", name: "Saved monitor (choose again)") }
            } else {
                let old = UInt32(clamping: defaults.integer(forKey: role.legacyKey))
                if old != 0 {
                    targets[role] = self.displays.first { $0.id == old }?.target
                        ?? DisplayTarget(identity: "legacy:\(old)", name: "Saved monitor")
                }
                save(role)
            }
        }
        rememberMonitors()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func currentDisplays() -> [OutputDisplay] { displaySource() }
    func target(for role: DisplayRole) -> DisplayTarget? { targets[role] }
    func isLocked(_ role: DisplayRole) -> Bool { locked.contains(role) }
    func setLocked(_ role: DisplayRole, _ value: Bool) {
        guard locked.contains(role) != value else { return }
        if value { locked.insert(role) } else { locked.remove(role) }
        changed()
    }
    func refresh() { displays = displaySource(); rememberMonitors(); changed() }
    func number(for target: DisplayTarget) -> Int? { labels[target.identity]?.number }
    func nickname(for target: DisplayTarget) -> String? {
        guard let name = labels[target.identity]?.name, !name.isEmpty else { return nil }
        return name
    }
    func label(for target: DisplayTarget) -> String {
        let name = nickname(for: target) ?? target.name
        return number(for: target).map { "\($0) · \(name)" } ?? name
    }
    func canRename(_ target: DisplayTarget?) -> Bool {
        guard let target, labels[target.identity] != nil else { return false }
        return displays.filter { $0.identity == target.identity }.count <= 1
    }
    static func normalizedName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard name.count <= 40, name.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return name
    }
    @discardableResult
    func rename(_ target: DisplayTarget, to name: String) -> Bool {
        refresh()
        guard canRename(target), let name = Self.normalizedName(name), var label = labels[target.identity] else { return false }
        label.name = name; labels[target.identity] = label; saveLabels(); changed(); return true
    }
    private static func isRememberedIdentity(_ identity: String) -> Bool {
        !identity.isEmpty && !["runtime:", "legacy:", "unreadable:"].contains { identity.hasPrefix($0) }
    }
    private func rememberMonitors() {
        // First detection assigns an AltView number. Never reuse a disconnected monitor's number.
        for target in displays.map(\.target) + DisplayRole.allCases.compactMap({ targets[$0] }) {
            guard Self.isRememberedIdentity(target.identity), labels[target.identity] == nil else { continue }
            labels[target.identity] = MonitorLabel(number: (labels.values.map(\.number).max() ?? 0) + 1)
        }
        displays.sort { (number(for: $0.target) ?? Int.max) < (number(for: $1.target) ?? Int.max) }
        saveLabels()
    }
    private func saveLabels() { if let data = try? JSONEncoder().encode(labels) { defaults.set(data, forKey: labelsKey) } }
    func problem(for target: DisplayTarget?, role: DisplayRole) -> String? {
        guard let target else { return nil }
        if targets[role.other]?.identity == target.identity { return "Assigned to \(role.other.title). Choose another monitor." }
        let matches = displays.filter { $0.identity == target.identity }
        if matches.count > 1 { return "These monitors have the same identity. Choose a distinguishable monitor." }
        guard let display = matches.first else { return "\(label(for: target)) disconnected. Reconnect it or choose another monitor." }
        if display.identity.hasPrefix("runtime:") { return "Monitor identity is not ready. Try again when macOS finishes connecting it." }
        if display.isMirrored { return "This monitor is mirrored. Use extended displays in macOS." }
        return nil
    }
    @discardableResult
    func select(_ target: DisplayTarget?, for role: DisplayRole) -> Bool {
        guard !locked.contains(role), problem(for: target, role: role) == nil else { return false }
        targets[role] = target; save(role); changed(); return true
    }
    func canIdentify(_ role: DisplayRole) -> Bool {
        guard let target = targets[role], target.resolve(in: displays) != nil,
              problem(for: target, role: role) == nil else { return false }
        return !DisplayRole.allCases.contains { locked.contains($0) && targets[$0]?.identity == target.identity }
    }
    func observe(_ change: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = change; return id }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func save(_ role: DisplayRole) {
        if let data = try? JSONEncoder().encode(targets[role]) { defaults.set(data, forKey: role.preferenceKey) }
    }
    private func changed() { for change in Array(observers.values) { change() } }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

private final class MonitorIdentifier {
    private var window: NSWindow?
    private var dismissal: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in self?.close() }
    }
    func show(_ display: OutputDisplay, number: Int, name: String) {
        close()
        let window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
        window.level = .screenSaver; window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = NSView()
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.fillColor = NSColor.black.withAlphaComponent(0.85); box.cornerRadius = 18; box.borderWidth = 0
        box.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(box)
        NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                                     box.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                                     box.widthAnchor.constraint(equalToConstant: 420), box.heightAnchor.constraint(equalToConstant: 200)])
        let title = UI.label("AltView Monitor \(number)", size: 36, color: .white, bold: true)
        let nameLabel = UI.label(name, size: 20, color: .white)
        UI.fill(UI.column(title, nameLabel, spacing: 14), in: box.contentView!, padding: 24)
        window.contentView = root; self.window = window; window.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.close() }
        self.dismissal = dismissal; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }
    func close() { dismissal?.cancel(); dismissal = nil; window?.close(); window = nil }
    deinit { close(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

private final class MonitorNameEditor: NSView, NSTextFieldDelegate {
    let field: NSTextField
    var onValidityChange: ((Bool) -> Void)?
    private let error = UI.label("", size: 11, color: .systemOrange)
    init(name: String, target: DisplayTarget) {
        field = NSTextField(string: name)
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 120))
        field.placeholderString = "Front Left TV"; field.delegate = self
        field.setAccessibilityLabel("Monitor name"); field.setAccessibilityIdentifier("monitorName")
        let identity = UI.label(target.identity, size: 10, color: .secondaryLabelColor)
        identity.font = .monospacedSystemFont(ofSize: 10, weight: .regular); identity.isSelectable = true
        UI.fill(UI.column(field, error, UI.label("macOS display UUID", size: 11, color: .secondaryLabelColor), identity, spacing: 6), in: self, padding: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ obj: Notification) {
        let valid = DisplayAssignments.normalizedName(field.stringValue) != nil
        error.stringValue = valid ? "" : "Use up to 40 characters on one line."
        onValidityChange?(valid)
    }
}

/// The same assignment and lifecycle controls for both output roles.
final class MonitorControls: NSView {
    var onOpen: (() -> Void)?
    private let role: DisplayRole
    private let assignments: DisplayAssignments
    private let output: OutputWindowController
    private let picker = NSPopUpButton()
    private let status = UI.label("", size: 11, color: .secondaryLabelColor)
    private let note = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var openButton = UI.primaryButton("Open Display", target: self, action: #selector(openDisplay))
    private lazy var closeButton = UI.button("Close Display", target: self, action: #selector(closeDisplay))
    private lazy var identifyButton = UI.button("Identify", target: self, action: #selector(identify))
    private lazy var nameButton = UI.button("Name…", target: self, action: #selector(nameMonitor))
    private let monitorIdentifier = MonitorIdentifier()
    private var assignmentObservation: UUID?
    private var outputObservation: UUID?
    init(role: DisplayRole, assignments: DisplayAssignments, output: OutputWindowController) {
        self.role = role; self.assignments = assignments; self.output = output
        super.init(frame: .zero)
        picker.target = self; picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("\(role.title) monitor")
        picker.setAccessibilityIdentifier("\(role.rawValue)MonitorPicker")
        picker.autoenablesItems = false
        picker.toolTip = "AltView remembers its own monitor numbers and names by macOS display UUID. Use Identify to locate the TV."
        status.setAccessibilityIdentifier("\(role.rawValue)DisplayStatus")
        identifyButton.toolTip = "Briefly label the selected monitor. Available while its display is closed."
        nameButton.toolTip = "Save a name for this physical monitor in AltView, such as Front Left TV."
        for button in [identifyButton, nameButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        closeButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        let monitorActions = UI.row(identifyButton, nameButton, NSView())
        monitorActions.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let displayAction = UI.row(NSView(), openButton, closeButton)
        displayAction.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let content = UI.column(picker, monitorActions, status, note, displayAction, spacing: 8)
        content.setHuggingPriority(.required, for: .vertical)
        UI.fill(content, in: self, padding: 0)
        assignmentObservation = assignments.observe { [weak self] in self?.refresh() }
        outputObservation = output.observe { [weak self] in
            guard let self else { return }
            self.assignments.setLocked(self.role, self.output.isActive); self.refresh()
        }
        assignments.setLocked(role, output.isActive)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        monitorIdentifier.close()
        picker.removeAllItems(); picker.addItem(withTitle: "Preview Window · no monitor")
        picker.menu?.addItem(.separator())
        for display in assignments.displays {
            let target = display.target
            let occupied = assignments.target(for: role.other)?.identity == target.identity
            let suffix = occupied ? " · \(role.other.title)" : display.isMirrored ? " · Mirrored" : display.isBuiltIn ? " · Built-in" : ""
            picker.addItem(withTitle: "\(assignments.label(for: target))\(suffix)")
            picker.lastItem?.representedObject = target
            picker.lastItem?.isEnabled = assignments.problem(for: target, role: role) == nil
            picker.lastItem?.toolTip = assignments.problem(for: target, role: role)
                ?? "\(display.name)\nmacOS display UUID: \(target.identity)"
        }
        if let target = assignments.target(for: role) {
            if let item = picker.itemArray.first(where: { ($0.representedObject as? DisplayTarget)?.identity == target.identity }) { picker.select(item) }
            else {
                picker.addItem(withTitle: "\(assignments.label(for: target)) · Disconnected")
                picker.lastItem?.representedObject = target; picker.lastItem?.isEnabled = false
                picker.select(picker.lastItem)
            }
        } else { picker.selectItem(at: 0) }
        let problem = assignments.problem(for: assignments.target(for: role), role: role)
        picker.isEnabled = !output.isActive
        openButton.isEnabled = !output.isActive && problem == nil
        closeButton.isEnabled = output.isActive
        openButton.isHidden = output.isActive
        closeButton.isHidden = !output.isActive
        identifyButton.isEnabled = assignments.canIdentify(role)
        nameButton.isEnabled = assignments.canRename(assignments.target(for: role))
        status.stringValue = output.readiness == .asleep ? "Monitor asleep" : output.readiness == .minimized ? "Preview window minimized" : output.statusText
        if let target = assignments.target(for: role) {
            if output.readiness == .ready { status.stringValue = "\(role.title) on \(assignments.label(for: target))" }
            else if output.isActive && output.readiness == .displayMissing { status.stringValue = "\(assignments.label(for: target)) disconnected — waiting for that monitor" }
        }
        note.stringValue = problem ?? (output.isActive ? "Close this display before changing its monitor."
            : assignments.target(for: role) != nil ? "Identify this TV, then use Name… to save a label. AltView’s numbers are remembered."
            : "Choose a monitor, or use a separate preview window.")
        note.textColor = problem == nil ? .secondaryLabelColor : .systemOrange
    }
    @objc private func selectionChanged() {
        let selected = picker.selectedItem?.representedObject as? DisplayTarget
        if !assignments.select(selected, for: role) { refresh() }
    }
    @objc private func openDisplay() {
        monitorIdentifier.close()
        assignments.refresh()
        let target = assignments.target(for: role)
        guard !output.isActive, assignments.problem(for: target, role: role) == nil else { refresh(); return }
        let open = { [weak self] in
            guard let self, !self.output.isActive, self.assignments.target(for: self.role) == target else { return }
            self.assignments.refresh()
            guard self.assignments.problem(for: target, role: self.role) == nil else { return }
            self.onOpen?()
            if let target { self.output.show(target: target) } else { self.output.show(displayID: nil) }
        }
        if let target, let display = target.resolve(in: assignments.displays),
           let window, window.screen.map(OutputWindowController.displayID) == display.id {
            let alert = NSAlert(); alert.messageText = "Open \(role.title) on the controls monitor?"
            alert.informativeText = "This will cover AltView’s controls. You can close the display from the Window menu."
            alert.addButton(withTitle: "Open Display"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { open() } }
        } else { open() }
    }
    @objc private func closeDisplay() { output.stop() }
    @objc private func nameMonitor() {
        monitorIdentifier.close(); assignments.refresh()
        guard let window, let target = assignments.target(for: role), assignments.canRename(target) else { return }
        let editor = MonitorNameEditor(name: assignments.nickname(for: target) ?? "", target: target)
        let alert = NSAlert(); alert.messageText = "Name \(assignments.label(for: target))"
        alert.informativeText = "Use Identify to confirm the TV, then give it a name in AltView. Leave the name empty to use the model name again. Names follow macOS display identity; use Identify again after swapping cables or adapters."
        alert.accessoryView = editor
        let save = alert.addButton(withTitle: "Save Name"); alert.addButton(withTitle: "Cancel")
        editor.onValidityChange = { [weak save] valid in save?.isEnabled = valid }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.assignments.rename(target, to: editor.field.stringValue)
        }
        alert.window.makeFirstResponder(editor.field)
    }
    @objc private func identify() {
        assignments.refresh()
        guard assignments.canIdentify(role), let target = assignments.target(for: role),
              let display = target.resolve(in: assignments.displays), let number = assignments.number(for: target) else { return }
        monitorIdentifier.show(display, number: number, name: assignments.nickname(for: target) ?? display.name)
    }
    deinit {
        if let assignmentObservation { assignments.removeObserver(assignmentObservation) }
        if let outputObservation { output.removeObserver(outputObservation) }
    }
}
