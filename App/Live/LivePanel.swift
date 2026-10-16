import AppKit
import EarshotKit
import SwiftUI

/// The floating, non-activating panel (spec 4.5): above other windows on every Space, over full-screen call apps,
/// and never activating Earshot when clicked, so the call app keeps focus.
final class FloatingPanel: NSPanel {
    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: LivePanelView.width, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        contentViewController = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel grows and shrinks with its content; its top edge stays where it is.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if isVisible, frame.size != self.frame.size {
            frame.origin.y = self.frame.maxY - frame.height
        }
        super.setFrame(frame, display: flag)
    }
}

/// Shows and hides the panel. One panel for the app's lifetime, so it reopens where the user left it.
@MainActor
final class LivePanel {
    static let margin: CGFloat = 16

    private weak var controller: LiveController?
    private var panel: FloatingPanel?
    private var placed = false

    init(controller: LiveController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(hidingFromCapture hidden: Bool) {
        guard let controller else { return }
        let panel = self.panel ?? Self.makePanel(controller)
        self.panel = panel
        hideFromCapture(hidden)
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        if !placed, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - LivePanelView.width - Self.margin,
                                               y: visible.maxY - Self.margin))
            placed = true
        }
        panel.orderFrontRegardless()
    }

    private static func makePanel(_ controller: LiveController) -> FloatingPanel {
        let host = NSHostingController(rootView: LivePanelHost(controller: controller))
        // The window follows the view's size, so the panel grows with the to-dos and shrinks to the pill.
        host.sizingOptions = [.minSize, .maxSize, .intrinsicContentSize, .preferredContentSize]
        return FloatingPanel(content: host)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Earshot only tries: `sharingType = .none` is not verified against every screen sharing app.
    func hideFromCapture(_ hidden: Bool) {
        panel?.sharingType = hidden ? .none : .readOnly
    }
}

/// Connects the panel view to the live controller.
struct LivePanelHost: View {
    let controller: LiveController

    var body: some View {
        LivePanelView(state: controller.panelState(), actions: controller.panelActions())
    }
}
