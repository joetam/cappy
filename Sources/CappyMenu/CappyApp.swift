import AppKit
import SwiftUI

@main
@MainActor
final class CappyApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    static func main() {
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"),
            CommandLine.arguments.indices.contains(flag + 1)
        {
            PreviewRenderer.render(to: CommandLine.arguments[flag + 1])
            return
        }

        let application = NSApplication.shared
        let delegate = CappyApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: "Cappy")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Cappy"
            button.setAccessibilityLabel("Cappy")
        }

        let hostingController = NSHostingController(rootView: DashboardView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isContextClick =
            event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isContextClick {
            popover.performClose(sender)
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: sender)
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            sender.highlight(true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func quitCappy() {
        model.quit()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Cappy", action: #selector(quitCappy), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
}

@MainActor
private enum PreviewRenderer {
    static func render(to path: String) {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: PreviewDashboardFixture().frame(width: 390))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
