import AppKit
import Testing
@testable import NVXShowcase

@Suite(.serialized) @MainActor
struct TabWindowDragTests {
    private func window(movable: Bool = true) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isMovable = movable
        return window
    }
    private func strip(in window: NSWindow, count: Int = 2) -> CompactTabStripView {
        let strip = CompactTabStripView(frame: NSRect(x: 90, y: window.frame.height - 36, width: 500, height: 36))
        let items = (0..<count).map { CompactTabItem(id: UUID(), title: "Tab \($0)", address: "Tab \($0)") }
        strip.configure(items: items, selection: items[0].id)
        window.contentView!.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        return strip
    }
    private func down(in window: NSWindow, point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func attachmentProtectsWindowAndLastRemovalRestoresItsPolicy() {
        let window = window()
        let first = strip(in: window), second = strip(in: window)
        #expect(!window.isMovable)
        first.removeFromSuperview()
        #expect(!window.isMovable)
        second.removeFromSuperview()
        #expect(window.isMovable)
    }

    @Test func nonmovableHostRemainsNonmovableAfterRemoval() {
        let window = window(movable: false), strip = strip(in: window)
        strip.removeFromSuperview()
        #expect(!window.isMovable)
    }

    @Test func closingARetainedWindowKeepsItsTabProtectionForReopening() {
        let window = window(), strip = strip(in: window)
        window.close()
        #expect(!window.isMovable)
        strip.removeFromSuperview()
        #expect(window.isMovable)
    }

    @Test func screenChangesStillApplyTheHostsWindowConstraint() {
        final class ConstrainedWindow: NSWindow {
            var correctedFrame: NSRect?
            override var isVisible: Bool { true }
            override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
                correctedFrame ?? super.constrainFrameRect(frameRect, to: screen)
            }
        }
        _ = NSApplication.shared
        let window = ConstrainedWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let strip = strip(in: window)
        defer { strip.removeFromSuperview() }
        let corrected = window.frame.offsetBy(dx: 10, dy: 20)
        window.correctedFrame = corrected
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(window.frame == corrected)
        #expect(!window.isMovable)
    }

    @Test func wholeStripAndSingleTabNeverAllowWindowDragging() {
        for count in [1, 2] {
            let window = window(), strip = strip(in: window, count: count)
            let guardOwner = TabStripWindowDragGuard.attach(strip, to: window)
            defer { strip.removeFromSuperview() }
            for x: CGFloat in [1, 120, 250, 450, 499] {
                for y: CGFloat in [2, 18, 34] {
                    let point = strip.convert(NSPoint(x: x, y: y), to: nil)
                    #expect(!guardOwner.allowsWindowDrag(down(in: window, point: point)))
                }
            }
        }
    }

    @Test func blankTitlebarCanMoveButContentAndResizeBorderCannot() {
        let window = window(), strip = strip(in: window)
        let guardOwner = TabStripWindowDragGuard.attach(strip, to: window)
        defer { strip.removeFromSuperview() }
        #expect(guardOwner.allowsWindowDrag(down(in: window, point: NSPoint(x: 620, y: window.frame.height - 16))))
        #expect(!guardOwner.allowsWindowDrag(down(in: window, point: NSPoint(x: 620, y: 100))))
        #expect(!guardOwner.allowsWindowDrag(down(in: window, point: NSPoint(x: 620, y: window.frame.height - 1))))
    }

    @Test func nativeButtonsAndOtherWindowsKeepTheirEvents() {
        let window = window(), other = self.window(), strip = strip(in: window)
        let guardOwner = TabStripWindowDragGuard.attach(strip, to: window)
        defer { strip.removeFromSuperview() }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind) {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                #expect(!guardOwner.allowsWindowDrag(down(in: window, point: point)))
            }
        }
        #expect(!guardOwner.allowsWindowDrag(down(in: other, point: NSPoint(x: 620, y: other.frame.height - 16))))
        #expect(other.isMovable)
    }
}
