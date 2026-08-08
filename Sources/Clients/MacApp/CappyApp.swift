import AppKit
import SwiftUI

@main
@MainActor
final class CappyApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let presentation = MenuPresentation()
    private let launchAtLogin = LaunchAtLoginController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    static func main() {
        if let flag = CommandLine.arguments.firstIndex(where: { $0 == "--render-preview" || $0 == "--render-preview-dark" }),
            CommandLine.arguments.indices.contains(flag + 1)
        {
            let colorScheme: ColorScheme = CommandLine.arguments[flag] == "--render-preview-dark" ? .dark : .light
            PreviewRenderer.render(to: CommandLine.arguments[flag + 1], colorScheme: colorScheme)
            return
        }

        let application = NSApplication.shared
        let delegate = CappyApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin.enableByDefaultIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: "Cappy"
            )?.withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Cappy"
            button.setAccessibilityLabel("Cappy")
        }

        let hostingController = NSHostingController(rootView: DashboardView(model: model, presentation: presentation))
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
            showPopover()
        }
    }

    @objc private func editAccounts() {
        presentation.isEditingAccounts = true
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.toggle()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t update Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitCappy() {
        model.quit()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()

        let editItem = NSMenuItem(title: "Edit Accounts…", action: #selector(editAccounts), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Cappy", action: #selector(quitCappy), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
}

@MainActor
private enum PreviewRenderer {
    static func render(to path: String, colorScheme: ColorScheme) {
        _ = NSApplication.shared
        let renderer = ImageRenderer(
            content: PreviewDashboardFixture()
                .frame(width: CappyLayout.popoverWidth)
                .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
