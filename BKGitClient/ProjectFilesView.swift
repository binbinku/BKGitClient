import AppKit
import SwiftUI
import WebKit

// Matches the bottom scroll padding in the bundled Monaco viewer.
let floatingFileInfoClearance: CGFloat = 56

struct FloatingFileInfo<Controls: View>: View {
    let path: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: path)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .textSelection(.enabled)
            controls()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .modifier(PanelGlass(shape: Capsule()))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingFileInfo")
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }
}

struct PanelGlass<Surface: Shape>: ViewModifier {
    let shape: Surface
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct ProjectTreePanel: View {
    @ObservedObject var model: ProjectFilesModel
    let root: Repository?

    private var hasDirectories: Bool {
        guard case .loaded(let entries) = model.folders[""] else { return false }
        return entries.contains { $0.kind == .directory }
    }

    var body: some View {
        VStack(spacing: 0) {
            FileTreeRootHeader(
                root: root, canExpand: hasDirectories && !model.expandingAll,
                canCollapse: model.expandingAll || !model.expanded.isEmpty,
                expanding: model.expandingAll, expand: model.expandAll, collapse: model.collapseAll
            )
            ScrollView {
                ProjectFolderRows(model: model, path: "")
                    .padding(12)
            }
        }
        .accessibilityIdentifier("projectFileTree")
        .onDisappear(perform: model.cancelScan)
    }
}

private struct ProjectFolderRows: View {
    @ObservedObject var model: ProjectFilesModel
    let path: String

    var body: some View {
        switch model.folders[path] ?? .idle {
        case .idle, .loading:
            ProgressView().controlSize(.small).padding(6)
                .accessibilityLabel("正在读取目录")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("重试") { model.loadFolder(path) }
            }
            .padding(6)
        case .loaded(let files):
            if files.isEmpty {
                Text("空目录").font(.caption).foregroundStyle(.secondary).padding(6)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        ProjectFileRow(model: model, file: file)
                    }
                }
            }
        }
    }
}

private struct ProjectFileRow: View {
    @ObservedObject var model: ProjectFilesModel
    @Environment(\.colorScheme) private var colorScheme
    let file: ProjectFile

    var body: some View {
        let isDirectory = file.kind == .directory
        let expanded = model.expanded.contains(file.path)
        let selected = model.selected == file
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isDirectory { model.toggle(file) } else { model.select(file) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(isDirectory ? 1 : 0)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    fileIcon(expanded: expanded, isDirectory: isDirectory)
                    Text(verbatim: file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isDirectory ? (expanded ? "已展开" : "已折叠") : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(file.path)

            if isDirectory, expanded {
                ProjectFolderRows(model: model, path: file.path)
                    .padding(.leading, 17)
            }
        }
    }

    private func fileIcon(expanded: Bool, isDirectory: Bool) -> some View {
        let id = FileNode.ID(path: Data(file.path.utf8), isDirectory: isDirectory)
        return Group {
            if file.kind == .symbolicLink {
                Image(systemName: "arrow.turn.up.right")
            } else if let image = MaterialTreeIcons.image(for: id, expanded: expanded, light: colorScheme == .light) {
                Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: isDirectory ? "folder" : "doc")
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct ProjectEditorPanel: View {
    @ObservedObject var model: ProjectFilesModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorStatus: MonacoStatus?
    @State private var markdownMode: ProjectDocumentMode = .preview
    @State private var outline: MarkdownOutline?
    @State private var outlineOpen = false

    private var document: ProjectDocument? {
        if case .loaded(let document) = model.document { return document }
        return nil
    }

    var body: some View {
        if let file = model.selected {
            let mode: ProjectDocumentMode = file.isMarkdown ? markdownMode : .source
            editor(mode: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if mode == .preview, let outline, document?.id == outline.documentID,
                       editorStatus == .ready(outline.documentID, .preview) {
                        MarkdownOutlineMenu(outline: outline, isOpen: $outlineOpen)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    FloatingFileInfo(path: file.path) {
                        fileControls(isMarkdown: file.isMarkdown)
                    }
                }
                .onChange(of: file, initial: true) { _, _ in markdownMode = .preview }
                .onChange(of: mode) { _, _ in outlineOpen = false }
                .onChange(of: document?.id) { _, _ in outlineOpen = false }
        } else {
            notice("选择一个文件查看", systemImage: "doc.text") { EmptyView() }
        }
    }

    private func fileControls(isMarkdown: Bool) -> some View {
        HStack(spacing: 8) {
            if isMarkdown {
                Picker("Markdown 视图", selection: $markdownMode) {
                    Text("预览").tag(ProjectDocumentMode.preview)
                    Text("源码").tag(ProjectDocumentMode.source)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 108)
                .accessibilityIdentifier("markdownViewMode")
            }
            Label("只读", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func editor(mode: ProjectDocumentMode) -> some View {
        ZStack {
            let ready = document.map { editorStatus == .ready($0.id, mode) } ?? false
            MonacoView(
                input: document.map { .file($0, mode) },
                dark: colorScheme == .dark,
                onOutline: { outline = $0 },
                dismissOutline: outlineOpen ? { outlineOpen = false } : nil
            ) { status in
                editorStatus = status
            }
            .opacity(ready ? 1 : 0)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)

            switch model.document {
            case .idle, .loading:
                progress("正在读取文件")
            case .failed(let message):
                notice(message, systemImage: "doc.text.magnifyingglass") {
                    Button("重试", action: model.retryFile)
                }
            case .loaded(let document):
                if editorStatus == .failed(document.id, mode) {
                    if mode == .preview {
                        notice("无法显示 Markdown 预览", systemImage: "doc.text.magnifyingglass") {
                            Button("查看源码") { markdownMode = .source }
                        }
                    } else {
                        VStack(spacing: 0) {
                            Text("Monaco 加载失败，正在显示纯文本")
                                .font(.caption).foregroundStyle(.secondary).padding(6)
                            ScrollView([.vertical, .horizontal]) {
                                Text(verbatim: document.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .contentMargins(.bottom, floatingFileInfoClearance, for: .scrollContent)
                        }
                    }
                } else if !ready {
                    progress(mode == .preview ? "正在生成 Markdown 预览" : "正在打开编辑器")
                }
            }
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func notice<Action: View>(
        _ title: String, systemImage: String, @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24)).accessibilityHidden(true)
            Text(title).multilineTextAlignment(.center)
            action()
        }
        .foregroundStyle(.secondary)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkdownHeading: Identifiable {
    let id: Int
    let title: String
    let level: Int
}

private struct MarkdownOutline {
    let documentID: UUID
    let headings: [MarkdownHeading]
    let jump: (Int) -> Void
}

private struct MarkdownOutlineMenu: View {
    let outline: MarkdownOutline
    @Binding var isOpen: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    isOpen.toggle()
                } label: {
                    Text("目录")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(PanelGlass(shape: Capsule(), interactive: true))
                .accessibilityValue(isOpen ? "已展开" : "已收起")
                .accessibilityIdentifier("markdownOutlineToggle")

                if isOpen {
                    entries(maxHeight: max(0, min(geometry.size.height * 0.65, geometry.size.height - 110)))
                        .frame(width: min(280, max(0, geometry.size.width - 28)))
                        .modifier(PanelGlass(shape: RoundedRectangle(cornerRadius: 16)))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("文档目录")
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder private func entries(maxHeight: CGFloat) -> some View {
        if outline.headings.isEmpty {
            Text("此文档没有标题")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            let rowHeight: CGFloat = 32
            let firstLevel = outline.headings.map(\.level).min() ?? 1
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(outline.headings) { heading in
                        Button {
                            isOpen = false
                            outline.jump(heading.id)
                        } label: {
                            Text(verbatim: heading.title)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(heading.level - firstLevel) * 10 + 8)
                                .padding(.trailing, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: rowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(heading.title)
                    }
                }
                .font(.callout)
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .frame(height: min(maxHeight, CGFloat(outline.headings.count) * rowHeight + 12))
        }
    }
}

struct MonacoDiffPanel<Fallback: View>: View {
    let document: DiffDocument
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.colorScheme) private var colorScheme
    @State private var status: MonacoStatus?

    var body: some View {
        let ready = status == .ready(document.id, .diff)
        ZStack {
            MonacoView(input: .comparison(document), dark: colorScheme == .dark) { status = $0 }
                .opacity(ready ? 1 : 0)
                .allowsHitTesting(ready)
                .accessibilityHidden(!ready)
            if status == .failed(document.id, .diff) {
                fallback()
            } else if !ready {
                ProgressView("正在加载 Diff").controlSize(.small)
            }
        }
    }
}

private enum ProjectDocumentMode: String, Hashable {
    case preview, source, diff
}

private enum MonacoInput {
    case file(ProjectDocument, ProjectDocumentMode)
    case comparison(DiffDocument)

    var id: UUID {
        switch self {
        case .file(let document, _): document.id
        case .comparison(let document): document.id
        }
    }

    var mode: ProjectDocumentMode {
        switch self {
        case .file(_, let mode): mode
        case .comparison: .diff
        }
    }
}

private enum MonacoStatus: Equatable {
    case ready(UUID, ProjectDocumentMode), failed(UUID, ProjectDocumentMode)
}

private struct MonacoView: NSViewRepresentable {
    let input: MonacoInput?
    let dark: Bool
    var onOutline: ((MarkdownOutline) -> Void)?
    var dismissOutline: (() -> Void)?
    let onStatus: (MonacoStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if onOutline != nil {
            configuration.userContentController.add(context.coordinator, name: Coordinator.dismissOutlineMessage)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        // The under-page color covers overscroll. Disable WebKit's default page fill as well.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        view.navigationDelegate = context.coordinator
        view.setAccessibilityIdentifier(input?.mode == .diff ? "monacoDiffEditor" : "monacoFileEditor")
        context.coordinator.load(in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(input: input, dark: dark, report: onStatus,
                                   reportOutline: onOutline, dismissOutline: dismissOutline)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let dismissOutlineMessage = "dismissMarkdownOutline"

        private weak var webView: WKWebView?
        private var page: URL?
        private var input: MonacoInput?
        private var dark = false
        private var report: ((MonacoStatus) -> Void)?
        private var reportOutline: ((MarkdownOutline) -> Void)?
        private var dismissOutline: (() -> Void)?
        private var ready = false
        private var failed = false
        private var revision = 0
        private var sent: (id: UUID, mode: ProjectDocumentMode, dark: Bool)?
        private var imageTask: Task<Void, Never>?

        func load(in view: WKWebView) {
            webView = view
            page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MonacoViewer")
            guard let page else {
                failed = true
                return
            }
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        func update(input: MonacoInput?, dark: Bool,
                    report: @escaping (MonacoStatus) -> Void,
                    reportOutline: ((MarkdownOutline) -> Void)?, dismissOutline: (() -> Void)?) {
            if self.input?.id != input?.id {
                imageTask?.cancel()
                imageTask = nil
            }
            self.input = input
            self.dark = dark
            self.report = report
            self.reportOutline = reportOutline
            self.dismissOutline = input?.mode == .preview ? dismissOutline : nil
            sendDocument()
        }

        func stop() {
            imageTask?.cancel()
            input = nil
            report = nil
            reportOutline = nil
            dismissOutline = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.dismissOutlineMessage)
            webView?.navigationDelegate = nil
            webView?.stopLoading()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.dismissOutlineMessage, message.frameInfo.isMainFrame,
                  message.webView === webView, input?.mode == .preview else { return }
            dismissOutline?()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url == page && action.targetFrame?.isMainFrame == true ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            sendDocument()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadFailed()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadFailed()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadFailed()
        }

        private func loadFailed() {
            failed = true
            sent = nil
            imageTask?.cancel()
            imageTask = nil
            sendDocument()
        }

        private func sendDocument() {
            guard let input, sent?.id != input.id || sent?.mode != input.mode || sent?.dark != dark else { return }
            let id = input.id
            let mode = input.mode
            if failed {
                sent = (id, mode, dark)
                Task {
                    guard self.input?.id == id, self.input?.mode == mode else { return }
                    report?(.failed(id, mode))
                }
                return
            }
            guard ready, let webView else { return }
            sent = (id, mode, dark)
            revision += 1
            let sentRevision = revision
            var arguments: [String: Any] = ["id": id.uuidString, "dark": dark, "revision": sentRevision]
            let script: String
            switch input {
            case .file(let document, let mode):
                arguments["text"] = document.text
                arguments["path"] = document.file.path
                arguments["mode"] = mode.rawValue
                script = "return window.bkViewer.show(text, path, id, dark, mode, revision)"
            case .comparison(let document):
                arguments["original"] = document.original
                arguments["modified"] = document.modified
                arguments["path"] = document.path
                script = "return await window.bkViewer.showDiff(original, modified, path, id, dark, revision)"
            }
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                guard let self, revision == sentRevision, self.input?.id == id, !failed else { return }
                switch result {
                case .success(let value):
                    report?(.ready(id, mode))
                    if case .file(let document, .preview) = input, let preview = value as? [String: Any] {
                        if let headings = preview["headings"] as? [[String: Any]] {
                            let entries = headings.compactMap { heading -> MarkdownHeading? in
                                guard let index = heading["id"] as? Int, let title = heading["title"] as? String,
                                      let level = heading["level"] as? Int else { return nil }
                                return MarkdownHeading(id: index, title: title, level: level)
                            }
                            reportOutline?(MarkdownOutline(documentID: id, headings: entries) { [weak webView] index in
                                webView?.callAsyncJavaScript(
                                    "window.bkViewer.jumpToHeading(id, index)",
                                    arguments: ["id": id.uuidString, "index": index], in: nil, in: .page,
                                    completionHandler: nil
                                )
                            })
                        }
                        if let references = preview["images"] as? [String], !references.isEmpty {
                            loadImages(references, for: document)
                        }
                    }
                case .failure(let error):
                    NSLog("Monaco viewer failed: %@", error.localizedDescription)
                    report?(.failed(id, mode))
                }
            }
        }

        private func loadImages(_ references: [String], for document: ProjectDocument) {
            guard imageTask == nil else { return }
            imageTask = Task { [weak self] in
                let reader = Task.detached(priority: .utility) {
                    var availableBytes = 24 * 1024 * 1024
                    var images: [(index: Int, url: String)] = []
                    for (index, reference) in references.prefix(64).enumerated() {
                        guard !Task.isCancelled, availableBytes > 0 else { break }
                        guard let image = try? ProjectFiles.markdownImage(reference, relativeTo: document),
                              image.data.count <= availableBytes else { continue }
                        availableBytes -= image.data.count
                        images.append((index, image.dataURL))
                    }
                    return images
                }
                let images = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
                guard !Task.isCancelled, self?.input?.id == document.id, let webView = self?.webView else { return }
                for image in images {
                    guard !Task.isCancelled, self?.input?.id == document.id else { return }
                    _ = try? await webView.callAsyncJavaScript(
                        "window.bkViewer.setImages(id, images)",
                        arguments: ["id": document.id.uuidString, "images": [["index": image.index, "url": image.url]]],
                        in: nil, contentWorld: .page
                    )
                }
            }
        }
    }
}
