import AppKit
import Testing
@testable import NVXShowcase

@Suite(.serialized) @MainActor
struct TabPresentationTests {
    private func fixture() -> (NSWindow, CompactTabStripView, CompactTabCell) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let strip = CompactTabStripView(frame: NSRect(x: 90, y: 240, width: 500, height: 36))
        window.contentView!.addSubview(strip)
        let item = CompactTabItem(id: UUID(), title: "Release build", address: "builds.example.test")
        strip.configure(items: [item], selection: item.id)
        strip.layoutSubtreeIfNeeded()
        func cell(_ view: NSView) -> CompactTabCell? {
            if let cell = view as? CompactTabCell { return cell }
            return view.subviews.lazy.compactMap(cell).first
        }
        return (window, strip, cell(strip)!)
    }

    @Test func fixedLabelsIgnoreClickAndProgrammaticEditing() {
        let (window, strip, cell) = fixture()
        defer { strip.removeFromSuperview() }
        #expect(cell.address.stringValue == "Release build")
        #expect(!cell.address.isEditable && !cell.address.isSelectable)
        let point = cell.convert(NSPoint(x: 100, y: 18), to: nil)
        for _ in 0..<2 {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { cell.mouseDown(with: event) }
                else { cell.mouseUp(with: event) }
            }
        }
        cell.focusAddress()
        #expect(!cell.address.becomeFirstResponder())
        #expect(cell.address.currentEditor() == nil && !cell.isEditingAddress)
        #expect(cell.address.stringValue == "Release build")
        #expect(strip.items[0].title == "Release build")
    }

    @Test func addressEditingRequiresExplicitOptInAndCanBeTurnedOff() {
        let (_, strip, cell) = fixture()
        defer { strip.removeFromSuperview() }
        strip.labelMode = .address
        #expect(cell.address.isEditable && cell.address.isSelectable)
        #expect(cell.address.stringValue == "builds.example.test")
        cell.focusAddress()
        #expect(cell.address.currentEditor() != nil && cell.isEditingAddress)
        cell.address.stringValue = "Uncommitted draft"
        strip.labelMode = .fixed
        #expect(cell.address.currentEditor() == nil && !cell.isEditingAddress)
        #expect(cell.address.stringValue == "Release build")
        #expect(strip.items[0].address == "builds.example.test")
    }

    @Test func emptyAddressKeepsTheApplicationsTitleAndIcon() {
        let (_, strip, cell) = fixture()
        defer { strip.removeFromSuperview() }
        var item = strip.items[0]
        item.address = ""; item.title = "Build artifacts"
        strip.configure(items: [item], selection: item.id)
        strip.layoutSubtreeIfNeeded()
        #expect(cell.address.stringValue == "Build artifacts")
        #expect(!cell.address.displaysTabAddress)
        #expect(!cell.isEditingAddress)
    }
}
