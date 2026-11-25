import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

@main
@MainActor
final class BKGitClientApp: NSObject, NSApplicationDelegate {
    private let browser = BrowserModel()
    private var statusItem: NSStatusItem?
    private var projectPicker: StatusProjectPicker?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?

    static func main() {
        let lock: Int32
        do {
            guard let acquired = try acquireInstanceLock() else { return }
            lock = acquired
        } catch {
            NSLog("BKGitClient could not acquire its instance lock: %@", error.localizedDescription)
            return
        }
        defer { Darwin.close(lock) }

        let app = NSApplication.shared
        let delegate = BKGitClientApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func acquireInstanceLock() throws -> Int32? {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("com.baiwenbin.BKGitClient", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep the file in place so all launches lock the same inode. The OS releases the lock on exit.
        let path = directory.appendingPathComponent("instance.lock").path
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
        let descriptor = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
        if descriptor >= 0 { return descriptor }
        let error = errno
        if error == EWOULDBLOCK { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "BKGitClient")
            icon?.accessibilityDescription = "BKGitClient"
            button.image = icon
            button.toolTip = "BKGitClient"
            button.target = self
            button.action = #selector(toggleBrowser(_:))
            projectPicker = StatusProjectPicker(button: button, browser: browser, selectProject: { [weak self] project, screen in
                self?.openProject(project, on: screen)
            }) { [weak self] button, anchor in
                self?.showStatusMenu(button, anchor: anchor)
            }
        }
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectPicker?.stop()
    }

    private func showStatusMenu(_ button: NSStatusBarButton, anchor: NSRect) {
        let menu = NSMenu(title: "BKGitClient")
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 BKGitClient", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        button.highlight(true)
        defer { button.highlight(false) }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), in: nil)
    }

    @objc private func openSettings(_ sender: Any?) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        dismissBrowser()
        let window = settingsWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 132),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "BKGitClient 设置"
        window.isReleasedWhenClosed = false
        let layout = BrowserSplitLayout(width: Self.centeredFrame(in: screen.frame).width)
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(layout: layout))
        window.setContentSize(NSSize(width: 390, height: 132))
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleBrowser(_ sender: NSStatusBarButton) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? sender.window?.screen ?? NSScreen.main
        guard let screen else { return }

        let panel = self.panel ?? makePanel()
        let isOpening = !panel.isVisible
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if !isOpening && screen.frame.contains(center) {
            dismissBrowser()
            return
        }

        if isOpening { browser.refresh() }
        showBrowser(panel, on: screen)
    }

    private func openProject(_ project: Repository, on screen: NSScreen) {
        guard browser.repositories.contains(project) else { return }
        if browser.repository == project {
            browser.refresh()
        } else {
            browser.selectRepository(project)
        }
        showBrowser(panel ?? makePanel(), on: screen)
    }

    private func showBrowser(_ panel: NSPanel, on screen: NSScreen) {
        panel.setFrame(Self.centeredFrame(in: screen.frame), display: false)
        // A menu bar click can leave the accessory app inactive.
        panel.orderFrontRegardless()
        panel.makeKey()
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.dismissForOutsideClick()
            }
        }
    }

    private func dismissForOutsideClick() {
        guard NSApp.modalWindow == nil, panel?.attachedSheet == nil else { return }
        if let button = statusItem?.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(NSEvent.mouseLocation) { return }
        }
        dismissBrowser()
    }

    private func dismissBrowser() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = BrowserPanel(
            contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.title = "BKGitClient"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onTab = { [weak self] backwards in
            self?.browser.selectAdjacentPage(backwards: backwards)
        }
        panel.onEscape = { [weak self] in self?.dismissBrowser() }

        let view = NSHostingView(rootView: BrowserView(model: browser).ignoresSafeArea())
        view.sizingOptions = []
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 24
            glass.contentView = view
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            view.autoresizingMask = [.width, .height]
            view.frame = material.bounds
            material.addSubview(view)
            panel.contentView = material
        }
        self.panel = panel
        return panel
    }

    static func centeredFrame(in screen: NSRect) -> NSRect {
        let width = screen.width * 4 / 5
        let height = screen.height * 5 / 6
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }
}

@MainActor
private final class BrowserPanel: NSPanel {
    var onTab: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags
        guard event.type == .keyDown,
              modifiers.intersection([.command, .control, .option, .function]).isEmpty,
              NSApp.modalWindow == nil, attachedSheet == nil else {
            super.sendEvent(event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape), let onEscape {
            onEscape()
            return
        }

        let editingTextField = (firstResponder as? NSTextView)?.isFieldEditor == true
        guard event.keyCode == UInt16(kVK_Tab), !editingTextField, let onTab else {
            super.sendEvent(event)
            return
        }
        if !event.isARepeat { onTab(modifiers.contains(.shift)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct BrowserSettingsView: View {
    let layout: BrowserSplitLayout
    @AppStorage(BrowserSplitLayout.storageKey) private var fraction = BrowserSplitLayout.defaultFraction

    var body: some View {
        let range = layout.fractions
        let actual = min(max(fraction, range.lowerBound), range.upperBound)
        let percent = Int((actual * 100).rounded())
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分栏宽度").font(.headline)
                Spacer()
                Text("左栏 \(percent)%  ·  右栏 \(100 - percent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { actual }, set: { fraction = $0 }), in: range) {
                Text("左栏宽度")
            }
            .labelsHidden()
            .disabled(layout.minimum >= layout.maximum)
            HStack {
                Spacer()
                Button("恢复默认") { fraction = BrowserSplitLayout.defaultFraction }
                    .disabled(fraction == BrowserSplitLayout.defaultFraction)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
