import AppKit
import Darwin
import SwiftUI

@main
@MainActor
final class CappyApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let didShowInitialPopoverKey = "onboarding.didShowInitialPopover.v1"

    private let model = AppModel()
    private let presentation = MenuPresentation()
    private let launchAtLogin = LaunchAtLoginController()
    private let softwareUpdates = SoftwareUpdateController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private weak var observedPopoverWindow: NSWindow?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var menuTrackingDepth = 0
    private var menuActionWasSent = false
    private var desktopOverlay: DesktopOverlayController?
    private var globalShortcut: GlobalShortcut?

    static func main() {
        if CommandLine.arguments.contains("--self-test-software-updates") {
            _ = NSApplication.shared
            do {
                try SoftwareUpdateController.validateConfiguration()
                print("Software-update startup check passed.")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fputs("Software-update startup check failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }

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
        installMainMenu()
        launchAtLogin.enableByDefaultIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusBar.system.thickness + 4)
        statusItem = item

        if let button = item.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
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

        let desktopOverlay = DesktopOverlayController(model: model) { [weak self] in
            self?.returnWidgetToMenuBar()
        }
        self.desktopOverlay = desktopOverlay
        updateGlobalShortcutRegistration()

        let hostingController = NSHostingController(
            rootView: DashboardView(model: model, presentation: presentation))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        observeMenuTracking()
        desktopOverlay.restoreVisibility()
        showInitialPopoverIfNeeded()
    }

    func popoverDidClose(_ notification: Notification) {
        stopObservingPopoverWindow()
        menuTrackingDepth = 0
        menuActionWasSent = false
        statusItem?.button?.highlight(false)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        observePopoverWindow(window)
        window.makeKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownServer()
        stopClickAwayMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    private func showInitialPopoverIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didShowInitialPopoverKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didShowInitialPopoverKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showPopover()
        }
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

    @objc private func editConnections() {
        presentation.isEditingConnections = true
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

    private func attachPopoverWindowWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                self.popover.isShown,
                let window = self.popover.contentViewController?.view.window
            else { return }
            self.observePopoverWindow(window)
            window.makeKey()
        }
    }

    private func observeMenuTracking() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(menuWillSendAction(_:)),
            name: NSMenu.willSendActionNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil)
    }

    private func observePopoverWindow(_ window: NSWindow) {
        if observedPopoverWindow === window,
            localClickMonitor != nil,
            globalClickMonitor != nil
        {
            return
        }
        stopObservingPopoverWindow()
        observedPopoverWindow = window
        startClickAwayMonitoring()
    }

    private func stopObservingPopoverWindow() {
        stopClickAwayMonitoring()
        observedPopoverWindow = nil
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard popover.isShown else { return }
        if menuTrackingDepth == 0 { menuActionWasSent = false }
        menuTrackingDepth += 1
    }

    @objc private func menuWillSendAction(_ notification: Notification) {
        guard popover.isShown, menuTrackingDepth > 0 else { return }
        menuActionWasSent = true
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard popover.isShown, menuTrackingDepth > 0 else { return }
        menuTrackingDepth -= 1
        guard menuTrackingDepth == 0 else { return }

        let actionWasSent = menuActionWasSent
        menuActionWasSent = false

        if !actionWasSent, currentPointerEventIsOutsidePopover {
            popover.performClose(nil)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.observedPopoverWindow?.makeKey()
        }
    }

    private func startClickAwayMonitoring() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self else { return event }
            if self.shouldClosePopoverForCurrentPointer { self.popover.performClose(nil) }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func stopClickAwayMonitoring() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    private var shouldClosePopoverForCurrentPointer: Bool {
        popover.isShown && menuTrackingDepth == 0 && currentPointerIsOutsidePopover
    }

    private var statusItemScreenFrame: NSRect? {
        guard let button = statusItem?.button,
            let window = button.window
        else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var currentPointerIsOutsidePopover: Bool {
        guard let window = observedPopoverWindow else { return false }
        let pointerLocation = NSEvent.mouseLocation
        return !window.frame.contains(pointerLocation)
            && statusItemScreenFrame?.contains(pointerLocation) != true
    }

    private var currentPointerEventIsOutsidePopover: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return currentPointerIsOutsidePopover
        default:
            return false
        }
    }

    @objc private func quitCappy() {
        model.quit()
    }

    @objc private func toggleDesktopOverlay() {
        desktopOverlay?.toggle()
    }

    @objc private func showDesktopOverlay() {
        desktopOverlay?.show()
    }

    @objc private func returnWidgetToMenuBar() {
        desktopOverlay?.hide()
        if popover.isShown { popover.performClose(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.showPopover() }
    }

    @objc private func toggleGlobalShortcut() {
        UserDefaults.standard.set(!GlobalShortcut.isEnabled, forKey: GlobalShortcut.enabledDefaultsKey)
        updateGlobalShortcutRegistration(showFailureAlert: true)
    }

    private func updateGlobalShortcutRegistration(showFailureAlert: Bool = false) {
        globalShortcut = nil
        guard GlobalShortcut.isEnabled else { return }

        guard let shortcut = GlobalShortcut(action: { [weak self] in self?.toggleDesktopOverlay() }) else {
            UserDefaults.standard.set(false, forKey: GlobalShortcut.enabledDefaultsKey)
            if showFailureAlert {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t Enable Global Shortcut"
                alert.informativeText = "\(GlobalShortcut.displayName) may already be registered by another app."
                alert.runModal()
            }
            return
        }
        globalShortcut = shortcut
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Cappy")
        applicationMenu.addItem(softwareUpdates.menuItem())
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Cappy", action: #selector(quitCappy), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(editItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(
            editItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(editItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(editItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(editItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(editItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func editItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        attachPopoverWindowWhenReady()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()

        let editItem = NSMenuItem(title: "Connections…", action: #selector(editConnections), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        let overlayIsVisible = desktopOverlay?.isVisible == true
        let overlayTitle = overlayIsVisible ? "Return Widget to Menu Bar" : "Show Desktop Widget"
        let overlayAction = overlayIsVisible ? #selector(returnWidgetToMenuBar) : #selector(showDesktopOverlay)
        let overlayItem = NSMenuItem(title: overlayTitle, action: overlayAction, keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let shortcutItem = NSMenuItem(
            title: "Global Shortcut \(GlobalShortcut.displayName)",
            action: #selector(toggleGlobalShortcut),
            keyEquivalent: ""
        )
        shortcutItem.target = self
        shortcutItem.state = GlobalShortcut.isEnabled ? .on : .off
        menu.addItem(shortcutItem)

        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(softwareUpdates.menuItem())

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
