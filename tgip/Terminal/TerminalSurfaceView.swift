import AppKit
import GhosttyKit

class TerminalSurfaceView: NSView {
    var surface: ghostty_surface_t?
    weak var session: TerminalSession?
    private weak var runtime: GhosttyRuntime?

    private var trackingArea: NSTrackingArea?
    private var displayLink: CVDisplayLink?
    private var markedText = NSMutableAttributedString()

    /// When non-nil, we're inside a keyDown handler and insertText should
    /// accumulate text here instead of sending it directly.
    private var keyTextAccumulator: [String]?

    var initialWorkingDirectory: String?

    init(runtime: GhosttyRuntime, session: TerminalSession, workingDirectory: String? = nil) {
        self.runtime = runtime
        self.session = session
        self.initialWorkingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { stopDisplayLink(); return }
        if surface == nil { runtime?.createSurface(for: self) }
        let s = window.backingScaleFactor
        surface.map { ghostty_surface_set_content_scale($0, Double(s), Double(s)) }
        setupDisplayLink()
        refreshTrackingArea()
    }

    override func layout() {
        super.layout()
        guard let surface else { return }
        let s = window?.backingScaleFactor ?? 2.0
        let w = UInt32(bounds.width * s), h = UInt32(bounds.height * s)
        if w > 0 && h > 0 { ghostty_surface_set_size(surface, w, h) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let w = window else { return }
        let s = w.backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(s), Double(s))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    func destroySurface() {
        stopDisplayLink()
        if let surface { ghostty_surface_free(surface); self.surface = nil }
    }

    deinit { destroySurface() }

    // MARK: - Display Link

    private func setupDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let ud = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ud -> CVReturn in
            guard let ud else { return kCVReturnSuccess }
            Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
                .surface.map { ghostty_surface_refresh($0) }
            return kCVReturnSuccess
        }, ud)
        CVDisplayLinkStart(link)
        self.displayLink = link
        if let screen = window?.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            surface.map { ghostty_surface_set_display_id($0, id) }
        }
    }

    private func stopDisplayLink() {
        displayLink.map { CVDisplayLinkStop($0) }
        displayLink = nil
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        surface.map { ghostty_surface_set_focus($0, true) }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        surface.map { ghostty_surface_set_focus($0, false) }
        return r
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { super.keyDown(with: event); return }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        // Accumulate text from interpretKeyEvents → insertText
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        // Sync preedit state
        if markedText.length > 0 {
            markedText.string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(markedText.string.utf8.count))
            }
        } else if markedBefore {
            ghostty_surface_preedit(surface, nil, 0)
        }

        // Send key event to ghostty with accumulated text
        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = sendKey(action, event: event, text: text)
            }
        } else {
            _ = sendKey(action, event: event, text: ghosttyCharacters(from: event),
                        composing: markedText.length > 0 || markedBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_PRESS, event: event)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyMods(event.modifierFlags)
        key.composing = composing

        // consumed_mods: modifiers that contributed to producing the text
        // (exclude control and command, they don't produce text)
        key.consumed_mods = ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )

        // unshifted_codepoint: the character with no modifiers applied
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first {
                key.unshifted_codepoint = cp.value
            }
        }

        // Send with text if we have printable text (codepoint >= 0x20)
        if let text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            return ghostty_surface_key(surface, key)
        }
    }

    /// Get the text characters for a key event, filtering out control chars and PUA.
    private func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // Control character → use characters without control
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers:
                    event.modifierFlags.subtracting(.control))
            }
            // PUA range (function keys) → skip
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return chars
    }

    private func ghosttyMods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = 0
        if f.contains(.shift)    { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control)  { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option)   { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command)  { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    // MARK: - Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghosttyMods(e.modifierFlags))
    }
    override func mouseUp(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghosttyMods(e.modifierFlags))
    }
    override func rightMouseDown(with e: NSEvent) {
        guard let surface else { super.rightMouseDown(with: e); return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, ghosttyMods(e.modifierFlags))
    }
    override func rightMouseUp(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, ghosttyMods(e.modifierFlags))
    }
    override func mouseMoved(with e: NSEvent)   { reportMouse(e) }
    override func mouseDragged(with e: NSEvent) { reportMouse(e) }

    private func reportMouse(_ e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(p.x), Double(bounds.height - p.y), ghosttyMods(e.modifierFlags))
    }

    override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        let sm: ghostty_input_scroll_mods_t = e.hasPreciseScrollingDeltas ? 1 : 0
        ghostty_surface_mouse_scroll(surface, e.scrollingDeltaX, e.scrollingDeltaY, sm)
    }

    // MARK: - Tracking Area

    private func refreshTrackingArea() {
        trackingArea.map { removeTrackingArea($0) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        trackingArea = a
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: NSTextInputClient {
    override func doCommand(by selector: Selector) {
        // Ignore commands from interpretKeyEvents (deleteBackward:, insertNewline:, etc.)
        // These keys are handled via ghostty_surface_key in keyDown instead.
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedText = NSMutableAttributedString()

        if keyTextAccumulator != nil {
            // Inside a keyDown — accumulate, don't send directly.
            // keyDown will send it via ghostty_surface_key with the text field.
            keyTextAccumulator?.append(text)
        } else {
            // Outside keyDown (e.g. paste via menu, drag-drop) — send directly.
            guard let surface else { return }
            let len = text.utf8CString.count
            if len > 0 {
                text.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(len - 1))
                }
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: s) }
        else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length)
                              : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        return window.convertToScreen(convert(r, to: nil))
    }
}
