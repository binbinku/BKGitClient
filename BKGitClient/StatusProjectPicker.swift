import AppKit

@MainActor
final class StatusProjectPicker {
    private struct Press {
        let anchor: NSRect
        let screen: NSScreen
    }

    private weak var button: NSStatusBarButton?
    private let browser: BrowserModel
    private let selectProject: (Repository, NSScreen) -> Void
    private let showMenu: (NSStatusBarButton, NSRect) -> Void
    private var eventMonitor: Any?
    private var holdTimer: Timer?
    private var press: Press?
    private var pointer = NSPoint.zero
    private var list: ProjectPickerPanel?
    private weak var previousKeyWindow: NSWindow?

    init(button: NSStatusBarButton, browser: BrowserModel,
         selectProject: @escaping (Repository, NSScreen) -> Void,
         showMenu: @escaping (NSStatusBarButton, NSRect) -> Void) {
        self.button = button
        self.browser = browser
        self.selectProject = selectProject
        self.showMenu = showMenu
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        finish()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            guard press != nil, event.keyCode == 53 else { return event }
            finish()
            return nil
        }

        // Status item events can arrive through a proxy window with its own coordinates.
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let button, let window = button.window, event.windowNumber == window.windowNumber,
                  !event.modifierFlags.contains(.command),
                  NSApp.modalWindow == nil else { return event }
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let anchor = buttonFrame.contains(point) ? buttonFrame : NSRect(
                x: point.x - buttonFrame.width / 2, y: point.y - buttonFrame.height / 2,
                width: buttonFrame.width, height: buttonFrame.height
            )
            finish()
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                showMenu(button, anchor)
                return nil
            }
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? window.screen
            else { return event }
            pointer = point
            press = Press(anchor: anchor, screen: screen)
            button.highlight(true)
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showList() }
            }
            return nil

        case .leftMouseDragged:
            guard press != nil else { return event }
            pointer = point
            list?.highlight(at: point)
            return nil

        case .leftMouseUp:
            guard let press else { return event }
            let project = list?.project(at: point)
            let isClick = holdTimer != nil && press.anchor.contains(point)
            finish(restoreFocus: project == nil)
            if let project {
                selectProject(project, press.screen)
            } else if isClick, let button {
                button.sendAction(button.action, to: button.target)
            }
            return nil

        default:
            return event
        }
    }

    private func showList() {
        guard let press else { return }
        holdTimer = nil
        guard let picker = ProjectPickerPanel(
            projects: browser.repositoriesByRecency, selected: browser.repository,
            anchor: press.anchor, screen: press.screen
        ) else { return }
        list = picker
        previousKeyWindow = NSApp.keyWindow
        picker.orderFrontRegardless()
        picker.makeKey()
        picker.highlight(at: pointer)
    }

    private func finish(restoreFocus: Bool = true) {
        holdTimer?.invalidate()
        holdTimer = nil
        list?.clearHighlight()
        list?.orderOut(nil)
        list = nil
        press = nil
        button?.highlight(false)
        if restoreFocus, previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
    }
}

@MainActor
private final class ProjectPickerPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 42
    private static let verticalPadding: CGFloat = 6
    private static let cornerRadius: CGFloat = 16
    private let projects: ArraySlice<Repository>
    private let selected: Repository?
    private let table = NSTableView()

    override var canBecomeKey: Bool { true }

    init?(projects: [Repository], selected: Repository?, anchor: NSRect, screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let width = min(360, visibleFrame.width - 12)
        let top = min(anchor.minY - 4, visibleFrame.maxY - 4)
        let maxHeight = min(screen.frame.height * 3 / 4, top - visibleFrame.minY - 6)
        let padding = 2 * Self.verticalPadding
        let rowCapacity = Int((maxHeight - padding) / Self.rowHeight)
        guard width > 0, rowCapacity > 0 else { return nil }

        let visibleProjects = projects.prefix(rowCapacity)
        self.projects = visibleProjects
        self.selected = selected
        let height = CGFloat(max(1, visibleProjects.count)) * Self.rowHeight + padding
        let left = min(max(anchor.maxX - width, visibleFrame.minX + 6), visibleFrame.maxX - width - 6)
        let frame = NSRect(x: left, y: top - height, width: width, height: height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        title = "快速切换项目"
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.width = width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("快速切换项目")
        table.dataSource = self
        table.delegate = self

        let surface = NSView(frame: NSRect(origin: .zero, size: frame.size))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.masksToBounds = true

        let content = NSView(frame: surface.bounds)
        content.autoresizingMask = [.width, .height]
        table.frame = content.bounds.insetBy(dx: 0, dy: Self.verticalPadding)
        table.autoresizingMask = [.width, .height]
        content.addSubview(table)

        let effect: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: surface.bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            effect = glass
        } else {
            let material = NSVisualEffectView(frame: surface.bounds)
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            effect = material
        }
        effect.autoresizingMask = [.width, .height]
        surface.addSubview(effect)
        contentView = surface
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        max(1, projects.count)
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard projects.indices.contains(row) else {
            let empty = NSTextField(labelWithString: "暂无项目")
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            return empty
        }

        return ProjectPickerCell(project: projects[row], isCurrent: projects[row] == selected)
    }

    func project(at point: NSPoint) -> Repository? {
        let row = projectRow(at: point)
        return projects.indices.contains(row) ? projects[row] : nil
    }

    func highlight(at point: NSPoint) {
        let row = projectRow(at: point)
        setHighlightedRow(projects.indices.contains(row) ? row : -1)
    }

    func clearHighlight() {
        setHighlightedRow(-1)
    }

    private func setHighlightedRow(_ row: Int) {
        let previous = table.selectedRow
        guard row != previous else { return }
        if previous >= 0 {
            let cell = table.view(atColumn: 0, row: previous, makeIfNecessary: false) as? ProjectPickerCell
            cell?.setPathPreview(false)
        }
        guard row >= 0 else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ProjectPickerCell
        cell?.setPathPreview(true)
    }

    private func projectRow(at point: NSPoint) -> Int {
        let position = table.convert(convertPoint(fromScreen: point), from: nil)
        guard frame.contains(point), table.visibleRect.contains(position) else { return -1 }
        return table.row(at: position)
    }
}

@MainActor
private final class ProjectPickerCell: NSTableCellView {
    private static let pathAnimationKey = "pathMarquee"
    private let fullPath: String
    private let shortPath: String
    private let pathClip = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private var isPreviewingPath = false

    init(project: Repository, isCurrent: Bool) {
        fullPath = project.path
        let components = project.path.split(separator: "/")
        shortPath = components.count > 4 ? "…/" + components.suffix(4).joined(separator: "/") : project.path
        super.init(frame: .zero)

        let checkmark = NSImageView()
        if isCurrent {
            checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "当前项目")
        }

        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        pathLabel.stringValue = shortPath
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.usesSingleLineMode = true
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setAccessibilityLabel(fullPath)
        pathClip.wantsLayer = true
        pathClip.layer?.masksToBounds = true
        pathClip.addSubview(pathLabel)
        pathLabel.wantsLayer = true

        let labels = NSStackView(views: [name, pathClip])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let content = NSStackView(views: [checkmark, labels])
        content.spacing = 8
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            pathClip.widthAnchor.constraint(equalTo: labels.widthAnchor),
            pathClip.heightAnchor.constraint(equalToConstant: pathLabel.intrinsicContentSize.height)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setPathPreview(_ isPreviewing: Bool) {
        guard isPreviewingPath != isPreviewing else { return }
        isPreviewingPath = isPreviewing
        pathLabel.stringValue = isPreviewing ? fullPath : shortPath
        pathLabel.lineBreakMode = isPreviewing ? .byClipping : .byTruncatingHead
        updatePathLayout()
    }

    override func layout() {
        super.layout()
        updatePathLayout()
    }

    private func updatePathLayout() {
        let width = pathClip.bounds.width
        let textWidth = isPreviewingPath ? ceil(pathLabel.intrinsicContentSize.width) : width
        let frame = NSRect(x: 0, y: 0, width: max(width, textWidth), height: pathClip.bounds.height)
        if pathLabel.frame != frame { pathLabel.frame = frame }

        guard let layer = pathLabel.layer else { return }
        let overflow = textWidth - width
        let key = Self.pathAnimationKey
        guard isPreviewingPath, width > 0, overflow > 0 else {
            layer.removeAnimation(forKey: key)
            return
        }
        if let animation = layer.animation(forKey: key) as? CAKeyframeAnimation,
           (animation.values?.last as? CGFloat) == -overflow { return }

        let pauseBefore = 0.45
        let travel = Double(overflow) / 55
        let duration = pauseBefore + travel + 0.9
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -overflow, -overflow]
        animation.keyTimes = [0, NSNumber(value: pauseBefore / duration), NSNumber(value: (pauseBefore + travel) / duration), 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        layer.add(animation, forKey: key)
    }
}
