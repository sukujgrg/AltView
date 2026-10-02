import Foundation

protocol TextSending: AnyObject {
    func submit(_ content: DisplayContent)
    func takeOutput()
    func releaseOutput()
    func disconnect()
}
extension SenderClient: TextSending {}

struct LocalReceiverConnection { let port: UInt16; let key: Data }
struct ComposerConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The editable draft and the submitted snapshot are deliberately separate.
/// All access is on the UI thread; the transport schedules its own network work.
final class TextComposerSession {
    private let sender: TextSending
    var draft: DisplayContent
    private(set) var status = SenderStatus()
    private(set) var submitted: DisplayContent?
    private(set) var pending: DisplayContent?
    private(set) var takingOutput = false
    var onChange: (() -> Void)?

    init(sender: TextSending, draft: DisplayContent = DisplayContent()) {
        self.sender = sender; self.draft = draft
    }
    var hasText: Bool { [draft.title, draft.body, draft.footer].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var canShow: Bool { draft.isValid && hasText && pending == nil && !takingOutput }
    var isVisible: Bool { status.ownsOutput && submitted?.visible == true }
    var hasUnpublishedChanges: Bool {
        guard let submitted else { return hasText }
        return draft.title != submitted.title || draft.body != submitted.body || draft.footer != submitted.footer
            || draft.emptyRegions != submitted.emptyRegions || draft.template != submitted.template
    }
    var primaryTitle: String { "Publish Text" }

    /// Returns true when the caller must establish a connection. Freeze exactly
    /// the draft requested by the click, even if editing continues while connecting.
    @discardableResult func show() -> Bool {
        guard canShow else { return false }
        var content = draft; content.visible = true
        if status.connected { publish(content); return false }
        pending = content; onChange?(); return true
    }
    func receive(_ status: SenderStatus) {
        self.status = status
        if status.ownsOutput || !status.connected { takingOutput = false }
        if status.connected, let pending {
            self.pending = nil
            publish(pending)
        }
        onChange?()
    }
    private func publish(_ content: DisplayContent) {
        submitted = content
        sender.submit(content)
        if !status.ownsOutput { takingOutput = true; sender.takeOutput() }
        onChange?()
    }
    func hide() {
        guard status.ownsOutput, var content = submitted else { return }
        content.visible = false
        submitted = content; sender.submit(content); onChange?()
    }
    func showSubmitted() {
        guard status.ownsOutput, var content = submitted else { return }
        content.visible = true
        submitted = content; sender.submit(content); onChange?()
    }
    func stop() {
        let cancelConnection = pending != nil || takingOutput
        pending = nil; takingOutput = false
        if cancelConnection {
            // A grant may be in flight. Disconnect prevents its late arrival
            // from showing text after the user has chosen Stop Presenting.
            sender.disconnect(); status = SenderStatus()
        } else if status.ownsOutput { sender.releaseOutput(); status.ownsOutput = false }
        onChange?()
    }
    func cancelPending() { pending = nil; takingOutput = false; onChange?() }
    func resetConnection() {
        stop(); status = SenderStatus(); submitted = nil; onChange?()
    }
}
