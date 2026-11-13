import AppKit

/// Detects a "clean" tap of the right-hand copy of one modifier key (right ⌘ for dictation, right ⌥ for
/// commands, right ⇧ for translating): pressed and released quickly with no other key, click or modifier in between.
/// The left keys are left alone, so normal shortcuts like ⌘C never count.
/// The controller decides what a tap means (double tap to start, single tap to stop).
@MainActor
final class ModifierTapMonitor {
    let modifier: NSEvent.ModifierFlags
    /// The device bits macOS sets for each side (NX_DEVICER/LCMDKEYMASK, NX_DEVICER/LALTKEYMASK, NX_DEVICER/LSHIFTKEYMASK).
    private let right: UInt
    private let left: UInt
    init(_ modifier: NSEvent.ModifierFlags) {
        self.modifier = modifier
        switch modifier {
        case .option: (right, left) = (0x40, 0x20)
        case .shift: (right, left) = (0x04, 0x02)
        default: (right, left) = (0x10, 0x08)
        }
    }

    var onTap: ((TimeInterval) -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var downAt: TimeInterval?
    private var dirty = false

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let key: (NSEvent) -> Void = { [weak self] e in self?.keyDown(e) }
        let click: (NSEvent) -> Void = { [weak self] _ in self?.interrupt() }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel], handler: click) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func flagsChanged(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let raw = e.modifierFlags.rawValue
        let cmd = raw & right != 0
        // The left copy of the same key counts as "another key", like Shift would.
        let others = !mods.intersection([.shift, .option, .control, .command]).subtracting(modifier).isEmpty
            || raw & left != 0

        if cmd, downAt == nil {
            downAt = e.timestamp
            dirty = others
        } else if cmd {
            if others { dirty = true }
        } else if let down = downAt {
            downAt = nil
            let quick = e.timestamp - down < 0.4
            if quick && !dirty && !others { onTap?(e.timestamp) }
            else { onTap?(-1) } // a non-clean use breaks any pending double tap
        } else if others {
            onTap?(-1)
        }
    }

    private func keyDown(_ e: NSEvent) {
        if e.keyCode == 53 { onEscape?() }
        interrupt()
    }

    private func interrupt() {
        if downAt != nil { dirty = true }
        onTap?(-1)
    }
}
