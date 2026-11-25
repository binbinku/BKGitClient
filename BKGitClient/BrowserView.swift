import AppKit
import SwiftUI

struct BrowserSplitLayout {
    static let storageKey = "historyPaneFraction"
    static let defaultFraction = 0.5
    static let dividerWidth: CGFloat = 9

    let available: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat

    init(width: CGFloat) {
        available = max(0, width - Self.dividerWidth)
        maximum = available - min(260, available / 2)
        minimum = min(300, maximum)
    }

    var fractions: ClosedRange<Double> {
        guard available > 0, minimum < maximum else { return 0...1 }
        return Double(minimum / available)...Double(maximum / available)
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.openURL) private var openURL
    @AppStorage(BrowserSplitLayout.storageKey) private var historyPaneFraction = BrowserSplitLayout.defaultFraction
    @GestureState private var dividerTranslation: CGFloat = 0

    private static let relativeDateFormatter = RelativeDateTimeFormatter()
    private static let toolbarButtonWidth: CGFloat = 36

    var body: some View {
        splitPanels
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("无法添加项目", isPresented: Binding(
                get: { model.addError != nil },
                set: { if !$0 { model.addError = nil } }
            )) {
                Button("好", role: .cancel) { model.addError = nil }
            } message: {
                Text(model.addError ?? "")
            }
            .alert("无法获取远程更新", isPresented: Binding(
                get: { model.fetchError != nil },
                set: { if !$0 { model.fetchError = nil } }
            )) {
                Button("好", role: .cancel) { model.fetchError = nil }
            } message: {
                Text(model.fetchError ?? "")
            }
            .alert("无法打开 GitHub 仓库", isPresented: Binding(
                get: { model.githubError != nil },
                set: { if !$0 { model.githubError = nil } }
            )) {
                Button("好", role: .cancel) { model.githubError = nil }
            } message: {
                Text(model.githubError ?? "")
            }
    }

    private var splitPanels: some View {
        GeometryReader { geometry in
            let layout = BrowserSplitLayout(width: geometry.size.width)
            let available = layout.available
            let minimum = layout.minimum
            let maximum = layout.maximum
            let start = min(max(available * CGFloat(historyPaneFraction), minimum), maximum)
            let width = min(max(start + dividerTranslation, minimum), maximum)

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    leftToolbar(width: width)
                    Divider()
                    if model.repository == nil {
                        Spacer(minLength: 0)
                    } else {
                        switch model.page {
                        case .commits:
                            commitPanel(historyPanel(width: width), detail: commitDiffFilesPanel)
                        case .worktree: worktreeFilesPanel
                        case .files: ProjectTreePanel(model: model.projectFiles, root: model.repository)
                        }
                    }
                }
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
                Rectangle()
                    .fill(.clear)
                    .frame(width: BrowserSplitLayout.dividerWidth)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovered in
                        (hovered ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($dividerTranslation) { value, translation, _ in
                            translation = value.translation.width
                        }
                        .onEnded { value in
                            guard available > 0 else { return }
                            let adjusted = min(max(start + value.translation.width, minimum), maximum)
                            historyPaneFraction = Double(adjusted / available)
                        })
                    .accessibilityLabel("调整两栏宽度")
                    .accessibilityValue("\(Int((available > 0 ? width / available : 0.5) * 100))%")
                    .accessibilityAdjustableAction { direction in
                        guard available > 0 else { return }
                        let adjusted = min(max(start + (direction == .increment ? 20 : -20), minimum), maximum)
                        historyPaneFraction = Double(adjusted / available)
                    }
                Group {
                    if model.repository == nil {
                        emptyPanel("添加第一个项目", systemImage: "folder.badge.plus",
                                   detail: "选择本机 Git 仓库或其中的目录，即可浏览提交历史。") {
                            Button("添加本地仓库…", action: chooseRepository)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.addingRepository)
                        }
                    } else {
                        switch model.page {
                        case .commits:
                            commitPanel(detailsPanel, detail: commitDiffPanel)
                        case .worktree: worktreeDiffPanel
                        case .files: ProjectEditorPanel(model: model.projectFiles)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func commitPanel<Summary: View, Detail: View>(
        _ summary: Summary, @ViewBuilder detail: (CommitDiffSelection) -> Detail
    ) -> some View {
        let showingDiff = model.commitDiff != nil
        return ZStack {
            summary
                .opacity(showingDiff ? 0 : 1)
                .allowsHitTesting(!showingDiff)
                .accessibilityHidden(showingDiff)
            if let selection = model.commitDiff {
                detail(selection)
            }
        }
    }

    private func leftToolbar(width: CGFloat) -> some View {
        let leadingPadding: CGFloat = 10
        let trailingPadding: CGFloat = 4
        let spacing: CGFloat = 4
        let showsCommitActions = model.page == .commits && model.repository != nil && model.commitDiff == nil
        let actionSpace = showsCommitActions ? 2 * (Self.toolbarButtonWidth + spacing) : 0
        let available = max(0, width - leadingPadding - trailingPadding - spacing - actionSpace)
        let tabWidth = min(available, 144)
        let projectWidth = available - tabWidth
        let projectActions = HStack(spacing: 4) {
            projectControls
            if model.addingRepository {
                ProgressView().controlSize(.small).accessibilityLabel("正在添加项目")
            }
        }
        return HStack(spacing: spacing) {
            ViewThatFits(in: .horizontal) {
                projectActions.fixedSize(horizontal: true, vertical: false)
                projectActions
            }
            .frame(width: projectWidth, alignment: .leading)
            .clipped()
            Picker("浏览范围", selection: Binding(get: { model.page }, set: { model.selectPage($0) })) {
                ForEach(BrowserPage.allCases, id: \.self) { page in
                    Text(page.title).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: tabWidth)
            .layoutPriority(1)
            .accessibilityIdentifier("browserPages")

            if showsCommitActions {
                fetchButton
                githubButton
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: 48)
    }

    @ViewBuilder private var projectControls: some View {
        if model.commitDiff != nil {
            Button(action: model.closeCommitDiff) {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .help("返回提交历史")
            .accessibilityIdentifier("commitDiffBack")
        } else {
            projectMenu
        }
    }

    private var projectMenu: some View {
        Menu {
            if let head = model.head {
                let branchLabel = head.branch.map { "当前分支 · \($0)" }
                    ?? "游离 HEAD · \(head.commitID?.prefix(8) ?? "")"
                Button {} label: {
                    Label(branchLabel, systemImage: "arrow.triangle.branch")
                }
                .disabled(true)
                Divider()
            }
            ForEach(model.repositories) { repository in
                Button {
                    model.selectRepository(repository)
                } label: {
                    Label("\(repository.name) — \(repository.path)",
                          systemImage: model.repository == repository ? "checkmark" : "folder")
                }
            }
            if !model.repositories.isEmpty { Divider() }
            Button("添加本地仓库…", action: chooseRepository)
                .disabled(model.addingRepository)
            if model.repository != nil {
                Button("移除当前项目", role: .destructive, action: model.removeCurrentRepository)
            }
        } label: {
            Label(model.repository?.name ?? "项目", systemImage: "folder")
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(model.repository?.path ?? "管理本地项目")
        .accessibilityIdentifier("projectMenu")
    }

    private func historyPanel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let upstream = model.head?.upstream, upstream.commitID == nil {
                Label("上游引用不可用", systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .help(upstream.name)
                Divider()
            }
            switch model.history {
            case .idle, .loading:
                loadingPanel("正在读取提交")
            case .failed(let message):
                emptyPanel("无法读取提交", systemImage: "exclamationmark.circle", detail: message) {
                    Button("重试", action: model.refresh)
                }
            case .loaded(let graph):
                if graph.rows.isEmpty {
                    emptyPanel("暂无提交", systemImage: "clock", detail: nil)
                } else {
                    commitList(graph, width: width)
                }
            }
        }
    }

    private var fetchButton: some View {
        let fetching = model.fetchingRepository != nil && model.fetchingRepository == model.repository
        return toolbarButton(
            fetching ? "正在获取远程更新" : "获取远程更新",
            help: fetching ? "正在获取远程更新…" : "Fetch · 获取远程更新",
            identifier: "fetchUpstream", action: model.fetchUpstream
        ) {
            if fetching {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(model.fetchingRepository != nil)
    }

    private var githubButton: some View {
        toolbarButton("在 GitHub 打开仓库", identifier: "openGitHubRepository", action: {
            Task {
                if let url = await model.githubRepositoryURL() { openURL(url) }
            }
        }) {
            Image(systemName: "arrow.up.right.square")
        }
        .disabled(model.openingGitHub)
    }

    private func toolbarButton<Icon: View>(
        _ title: String, help: String? = nil, identifier: String, action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return Button(action: action) {
            icon()
                .font(.system(size: 15, weight: .semibold))
                .frame(width: Self.toolbarButtonWidth, height: 28)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .modifier(PanelGlass(shape: shape, interactive: true))
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func commitList(_ graph: CommitGraph, width: CGFloat) -> some View {
        let graphWidth = min(68, CGFloat(graph.laneCount) * 12 + 6)
        let badgeSpace = max(48, width - graphWidth - 76)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(graph.rows) { row in
                    let commit = row.commit
                    let selected = commit.id == model.selectedCommit?.id
                    let localName = model.head?.commitID == commit.id ? model.head?.branch ?? "HEAD" : nil
                    let remoteName = model.head?.upstream?.commitID == commit.id ? model.head?.upstream?.name : nil
                    let badgeWidth = min(108, badgeSpace / (localName != nil && remoteName != nil ? 2 : 1))
                    Button {
                        if !selected { model.selectCommit(commit) }
                    } label: {
                        HStack(spacing: 5) {
                            CommitGraphMark(row: row, laneCount: graph.laneCount,
                                            showsBothHeads: localName != nil && remoteName != nil)
                                .frame(width: graphWidth)
                            Text(commitTitle(commit))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let localName {
                                branchBadge(localName, remote: false, maxWidth: badgeWidth)
                            }
                            if let remoteName {
                                branchBadge(remoteName, remote: true, maxWidth: badgeWidth)
                            }
                        }
                        .padding(.trailing, 6)
                        .frame(height: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }

                if let message = model.pageError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(6)
                }
                if model.hasMore {
                    if model.loadingMore {
                        ProgressView().controlSize(.small).padding(8)
                    } else {
                        Button(model.pageError == nil ? "加载更多" : "重试加载", action: model.loadMore)
                            .padding(6)
                    }
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("commitList")
        .id(model.repository?.id)
    }

    private func branchBadge(_ name: String, remote: Bool, maxWidth: CGFloat) -> some View {
        let color = (remote ? CommitGraph.LaneColor.remoteHead : .localHead).tint
        return HStack(spacing: 3) {
            Image(systemName: remote ? "cloud" : "arrow.triangle.branch")
                .foregroundStyle(color)
                .fixedSize()
            Text(name).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.primary)
        .background(color.opacity(0.27), in: RoundedRectangle(cornerRadius: 4))
        .help(remote ? "远程上游 \(name)" : "本地 HEAD \(name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remote ? "远程上游 \(name)" : "本地 HEAD \(name)")
    }

    private var detailsPanel: some View {
        VStack(spacing: 0) {
            if let commit = model.selectedCommit {
                VStack(alignment: .leading, spacing: 4) {
                    Text(commitTitle(commit))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            metadataBadge(commit.author, icon: "person", tint: .blue)
                                .lineLimit(1)
                                .help(commit.author)
                            metadataBadge(commit.shortID, icon: "number", tint: .purple)
                                .monospaced()
                                .fixedSize()
                                .help(commit.id)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            let date = commit.authoredAt.formatted(.dateTime.year().month().day().hour().minute())
                            let relative = Self.relativeDateFormatter.localizedString(for: commit.authoredAt,
                                                                                      relativeTo: context.date)
                            metadataBadge("\(date) · \(relative)", icon: "clock", tint: .teal)
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                Divider()
            }

            switch model.changes {
            case .idle:
                emptyPanel("选择一个提交", systemImage: "list.bullet.indent", detail: nil)
            case .loading:
                loadingPanel("正在读取文件改动")
            case .failed(let message):
                emptyPanel("无法读取文件改动", systemImage: "exclamationmark.circle", detail: message) {
                    if let commit = model.selectedCommit {
                        Button("重试") { model.selectCommit(commit) }
                    }
                }
            case .loaded(let nodes):
                if nodes.isEmpty {
                    emptyPanel("此提交没有文件改动", systemImage: "checkmark.circle", detail: nil)
                } else {
                    fileTree(nodes, interaction: FileTreeInteraction(select: model.openCommitDiff))
                    .accessibilityIdentifier("fileTree")
                    .id(model.selectedCommit?.id)
                }
            }
        }
    }

    private func commitDiffFilesPanel(_ selection: CommitDiffSelection) -> some View {
        VStack(spacing: 0) {
            diffHeader(commitTitle(selection.commit)) {
                Label(selection.commit.shortID, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(selection.commit.id)
            }
            fileTree(selection.nodes, interaction: FileTreeInteraction(
                selectedPath: selection.file.path, select: model.selectCommitDiffFile
            ))
            .accessibilityIdentifier("commitDiffFileTree")
        }
    }

    private func commitDiffPanel(_ selection: CommitDiffSelection) -> some View {
        diffContent(model.commitPatch, retry: model.reloadCommitPatch)
            .overlay(alignment: .bottomTrailing) {
                FloatingFileInfo(path: FileNode.displayPath(selection.file.path)) {
                    Label(selection.file.kind.title, systemImage: selection.file.kind.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("commitFileDiff")
    }

    private func fileTree(_ nodes: [FileNode], interaction: FileTreeInteraction) -> some View {
        FileTreeView(root: model.repository, nodes: nodes, interaction: interaction)
    }

    private var worktreeFilesPanel: some View {
        Group {
            switch model.worktree {
            case .idle, .loading:
                loadingPanel("正在读取未提交改动")
            case .failed(let message):
                emptyPanel("无法读取未提交改动", systemImage: "exclamationmark.circle", detail: message) {
                    Button("重试", action: model.reloadWorktree)
                }
            case .loaded(let tree):
                if tree.nodes.isEmpty {
                    emptyPanel("没有未提交改动", systemImage: "checkmark.circle", detail: nil)
                } else {
                    fileTree(tree.nodes, interaction: FileTreeInteraction(
                        selectedPath: model.worktreeFile?.change.path, versions: tree.versions,
                        select: { model.selectWorktreePath($0.path) }
                    ))
                    .accessibilityIdentifier("worktreeFileTree")
                    .id(model.repository?.id)
                }
            }
        }
    }

    private var worktreeDiffPanel: some View {
        diffContent(model.worktreePatch) {
            if let file = model.worktreeFile { model.selectWorktreeFile(file) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let file = model.worktreeFile {
                let versions = model.worktreeVersions(at: file.change.path)
                FloatingFileInfo(path: FileNode.displayPath(file.change.path)) {
                    if versions.count > 1 {
                        Picker("Diff 范围", selection: Binding(
                            get: { model.worktreeFile?.section ?? file.section },
                            set: { model.selectWorktreeVersion($0) }
                        )) {
                            ForEach(versions, id: \.section) { version in
                                Text(version.section.title).tag(version.section)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .accessibilityIdentifier("worktreeDiffVersions")
                    } else {
                        Label(file.section.title, systemImage: file.section.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func diffHeader<Subtitle: View>(_ title: String, @ViewBuilder subtitle: () -> Subtitle) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                    .textSelection(.enabled)
                subtitle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
        }
    }

    @ViewBuilder private func diffContent(_ state: LoadState<FilePatch>, retry: @escaping () -> Void) -> some View {
        switch state {
        case .idle:
            emptyPanel("选择一个文件查看 Diff", systemImage: "doc.text.magnifyingglass", detail: nil)
        case .loading:
            loadingPanel("正在读取 Diff")
        case .failed(let message):
            emptyPanel("无法读取 Diff", systemImage: "exclamationmark.circle", detail: message) {
                Button("重试", action: retry)
            }
        case .loaded(let patch):
            if patch.lines.isEmpty {
                emptyPanel("此文件没有可显示的 Diff", systemImage: "doc.text", detail: nil)
            } else if let document = patch.document {
                MonacoDiffPanel(document: document) { PatchView(patch: patch) }
            } else {
                PatchView(patch: patch)
            }
        }
    }

    private func metadataBadge(_ value: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    private func loadingPanel(_ title: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyPanel(_ title: String, systemImage: String, detail: String?) -> some View {
        emptyPanel(title, systemImage: systemImage, detail: detail) { EmptyView() }
    }

    private func emptyPanel<Action: View>(
        _ title: String, systemImage: String, detail: String?, @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            action()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitTitle(_ commit: Commit) -> String {
        commit.subject.isEmpty ? "（无标题）" : commit.subject
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "添加 Git 项目"
        panel.prompt = "添加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await model.addRepository(at: directory) }
    }
}

private struct FileTreeInteraction {
    var selectedPath: Data? = nil
    var versions: (Data) -> [WorktreeFile] = { _ in [] }
    let select: (FileChange) -> Void
}

struct FileTreeRootHeader: View {
    let root: Repository?
    let canExpand: Bool
    let canCollapse: Bool
    var expanding = false
    let expand: () -> Void
    let collapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(root?.name ?? "项目", systemImage: "folder")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root?.path ?? "项目根目录")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if expanding {
                    ProgressView().controlSize(.small).accessibilityLabel("正在展开目录")
                }
                treeButton("全部展开", pointsOutward: true, action: expand)
                    .disabled(!canExpand)
                    .accessibilityIdentifier("expandAllDirectories")
                treeButton("全部折叠", pointsOutward: false, action: collapse)
                    .disabled(!canCollapse)
                    .accessibilityIdentifier("collapseAllDirectories")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func treeButton(_ title: String, pointsOutward: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: pointsOutward ? "chevron.left" : "chevron.right")
                Image(systemName: pointsOutward ? "chevron.right" : "chevron.left")
            }
            .font(.system(size: 8, weight: .semibold))
            .rotationEffect(.degrees(90))
            .frame(width: 14, height: 14)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct FileTreeView: View {
    let root: Repository?
    let nodes: [FileNode]
    let interaction: FileTreeInteraction
    @State private var expanded: Set<FileNode.ID>

    init(root: Repository?, nodes: [FileNode], interaction: FileTreeInteraction) {
        self.root = root
        self.nodes = nodes
        self.interaction = interaction
        var ancestors: Set<FileNode.ID> = []
        var path = Data()
        for component in (interaction.selectedPath ?? Data()).split(separator: 47).dropLast() {
            if !path.isEmpty { path.append(47) }
            path.append(component)
            ancestors.insert(FileNode.ID(path: path, isDirectory: true))
        }
        _expanded = State(initialValue: ancestors)
    }

    var body: some View {
        VStack(spacing: 0) {
            FileTreeRootHeader(
                root: root, canExpand: nodes.contains { $0.id.isDirectory },
                canCollapse: !expanded.isEmpty, expand: expandAll, collapse: { expanded.removeAll() }
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(nodes) { FileTreeRow(node: $0, interaction: interaction, expanded: $expanded) }
                }
                .padding(12)
            }
        }
    }

    private func expandAll() {
        var pending = nodes.filter { $0.id.isDirectory }
        var directories: Set<FileNode.ID> = []
        while let directory = pending.popLast() {
            directories.insert(directory.id)
            pending.append(contentsOf: directory.children.filter { $0.id.isDirectory })
        }
        expanded = directories
    }
}

private struct FileTreeRow: View {
    let node: FileNode
    let interaction: FileTreeInteraction
    @Binding var expanded: Set<FileNode.ID>
    @Environment(\.colorScheme) private var colorScheme

    private var isExpanded: Bool {
        expanded.contains(node.id)
    }

    var body: some View {
        if let change = node.change {
            let selected = interaction.selectedPath == change.path
            Button { interaction.select(change) } label: {
                fileLabel(change, versions: interaction.versions(change.path))
                    .padding(.horizontal, 5)
                    .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(helpText(change))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if isExpanded {
                        expanded.remove(node.id)
                    } else {
                        expanded.insert(node.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        nodeLabel.font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                .help(FileNode.displayPath(node.id.path))

                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(node.children) { FileTreeRow(node: $0, interaction: interaction, expanded: $expanded) }
                    }
                    .padding(.leading, 17)
                }
            }
        }
    }

    private func fileLabel(_ change: FileChange, versions: [WorktreeFile]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                nodeLabel
                if let original = change.previousPath {
                    Text("原路径 \(FileNode.displayPath(original))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if versions.isEmpty {
                Label(change.kind.title, systemImage: change.kind.icon)
                    .font(.caption)
                    .foregroundStyle(change.kind.color)
                    .fixedSize()
            } else {
                HStack(spacing: 3) {
                    ForEach(versions, id: \.section) { file in
                        worktreeTag(file)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
    }

    private func worktreeTag(_ file: WorktreeFile) -> some View {
        let title = file.section.title
        let description = file.section == .untracked ? title : "\(title) · \(file.change.kind.title)"
        return Label(title, systemImage: file.section == .untracked ? file.section.icon : file.change.kind.icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(file.section.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.primary)
            .help(description)
            .accessibilityLabel(description)
    }

    private var nodeLabel: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Group {
                if let image = MaterialTreeIcons.image(for: node.id, expanded: isExpanded, light: colorScheme == .light) {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: node.id.isDirectory ? "folder" : "doc")
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
    }

    private func helpText(_ change: FileChange) -> String {
        let path = FileNode.displayPath(change.path)
        guard let original = change.previousPath else { return path }
        return "\(FileNode.displayPath(original)) → \(path)"
    }
}

private extension ChangeKind {
    var title: String {
        switch self {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .renamed: "重命名"
        case .typeChanged: "类型变更"
        case .copied: "复制"
        case .conflicted: "冲突"
        case .other: "其他"
        }
    }

    var icon: String {
        switch self {
        case .added: "plus.circle"
        case .modified: "pencil.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right.circle"
        case .typeChanged: "arrow.triangle.2.circlepath.circle"
        case .copied: "plus.square.on.square"
        case .conflicted: "exclamationmark.triangle"
        case .other: "circle"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed, .copied: .blue
        case .typeChanged: .purple
        case .conflicted: .orange
        case .other: .secondary
        }
    }
}

private extension WorktreeSection {
    var title: String {
        switch self {
        case .staged: "已暂存"
        case .unstaged: "未暂存"
        case .untracked: "未跟踪"
        case .conflicted: "合并冲突"
        }
    }

    var icon: String {
        switch self {
        case .staged: "tray.full"
        case .unstaged: "pencil"
        case .untracked: "doc.badge.plus"
        case .conflicted: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .staged: .blue
        case .unstaged: .orange
        case .untracked: .secondary
        case .conflicted: .red
        }
    }
}

private struct PatchView: View {
    let patch: FilePatch

    var body: some View {
        Group {
            if let diff = patch.inlineDiff {
                inlineView(diff)
            } else {
                rawView
            }
        }
        .accessibilityIdentifier("worktreeDiff")
    }

    private func inlineView(_ diff: InlineDiff) -> some View {
        let gutterWidth = max(32, CGFloat(diff.lineNumberDigits) * 7 + 10)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("旧").frame(width: gutterWidth, alignment: .trailing)
                Text("新").frame(width: gutterWidth, alignment: .trailing)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.35))
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.rows.indices, id: \.self) { index in
                        switch diff.rows[index] {
                        case .hunk(let header):
                            Label(header, systemImage: "ellipsis")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.09))
                        case .code(let line):
                            codeRow(line, gutterWidth: gutterWidth)
                        case .note(let note):
                            Text(verbatim: note)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        }
                    }
                    truncationNotice
                }
                .textSelection(.enabled)
            }
            .contentMargins(.bottom, floatingFileInfoClearance, for: .scrollContent)
        }
    }

    private func codeRow(_ line: InlineDiff.CodeLine, gutterWidth: CGFloat) -> some View {
        let marker = line.kind == .addition ? "+" : (line.kind == .removal ? "−" : "")
        let tint: Color = line.kind == .addition ? .green : .red
        return HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldNumber, width: gutterWidth, label: "旧行号")
            lineNumber(line.newNumber, width: gutterWidth, label: "新行号")
            Text(marker)
                .foregroundStyle(tint)
                .frame(width: 21)
                .accessibilityHidden(true)
            Text(codeText(line, tint: tint))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 8)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .background(background(for: line.kind))
    }

    private func lineNumber(_ number: Int?, width: CGFloat, label: String) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .accessibilityLabel("\(label) \(number.map(String.init) ?? "")")
            .accessibilityHidden(number == nil)
    }

    private func codeText(_ line: InlineDiff.CodeLine, tint: Color) -> AttributedString {
        guard let emphasis = line.emphasis else {
            return AttributedString(line.text.isEmpty ? " " : line.text)
        }
        var text = AttributedString(String(line.text[..<emphasis.lowerBound]))
        var changed = AttributedString(String(line.text[emphasis]))
        changed[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = tint.opacity(0.32)
        text += changed
        text += AttributedString(String(line.text[emphasis.upperBound...]))
        return text
    }

    private var rawView: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(patch.lines.indices, id: \.self) { index in
                        let line = patch.lines[index]
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.kind == .metadata ? .secondary : .primary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .frame(minWidth: geometry.size.width, maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                    truncationNotice
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .contentMargins(.bottom, floatingFileInfoClearance, for: .scrollContent)
        }
    }

    @ViewBuilder private var truncationNotice: some View {
        if patch.truncated {
            Text("Diff 较长，仅显示前 512 KiB")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private func background(for kind: FilePatch.Line.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.15)
        case .removal: .red.opacity(0.15)
        case .hunk: .accentColor.opacity(0.1)
        case .context, .metadata: .clear
        }
    }
}

private struct CommitGraphMark: View {
    let row: CommitGraph.Row
    let laneCount: Int
    let showsBothHeads: Bool

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let spacing = size.width / CGFloat(laneCount)
            func point(_ lane: Int, _ height: CGFloat) -> CGPoint {
                CGPoint(x: (CGFloat(lane) + 0.5) * spacing, y: height)
            }
            func stroke(_ start: CGPoint, _ end: CGPoint, _ color: CommitGraph.LaneColor) {
                let centerY = (start.y + end.y) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: centerY),
                              control2: CGPoint(x: end.x, y: centerY))
                context.stroke(path, with: .color(color.tint), lineWidth: 1.5)
            }

            for edge in row.passing {
                stroke(point(edge.fromLane, 0), point(edge.toLane, size.height), edge.color)
            }
            let node = point(row.lane, middle)
            if let incoming = row.incomingColor { stroke(point(row.lane, 0), node, incoming) }
            for edge in row.parents {
                stroke(node, point(edge.toLane, size.height), edge.color)
            }

            func fillNode(radius: CGFloat, color: CommitGraph.LaneColor) {
                let circle = CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: circle), with: .color(color.tint))
            }
            if showsBothHeads { fillNode(radius: min(5.5, spacing / 2), color: .remoteHead) }
            let radius = min(3.5, showsBothHeads ? spacing * 0.32 : spacing / 2)
            fillNode(radius: radius, color: row.color)
        }
        .accessibilityHidden(true)
    }
}

private extension CommitGraph.LaneColor {
    var tint: Color {
        switch self {
        case .localHead: .blue
        case .remoteHead: .orange
        case .branch(let index): Self.branchTints[index % Self.branchTints.count]
        }
    }

    static let branchTints: [Color] = [.mint, .purple, .pink, .gray]
}
