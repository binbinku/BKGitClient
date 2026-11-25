import Foundation
import Combine

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

extension LoadState: Sendable where Value: Sendable {}

enum BrowserPage: CaseIterable, Hashable, Sendable {
    case files, commits, worktree

    var title: String {
        switch self {
        case .files: "文件"
        case .commits: "提交"
        case .worktree: "更改"
        }
    }
}

struct CommitDiffSelection {
    let commit: Commit
    let nodes: [FileNode]
    var file: FileChange
}

@MainActor
final class BrowserModel: ObservableObject {
    private static let repositoriesKey = "repositories"
    private static let selectionKey = "selectedRepository"
    private static let recentRepositoriesKey = "recentRepositoryIDs"

    private let git = GitService()
    let projectFiles = ProjectFilesModel()
    private let defaults: UserDefaults
    private var recentRepositoryIDs: [String]
    private var historyTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var worktreeTask: Task<Void, Never>?
    private var patchTask: Task<Void, Never>?
    private var commitPatchTask: Task<Void, Never>?

    @Published private(set) var repositories: [Repository]
    @Published private(set) var repository: Repository?
    @Published private(set) var head: Head?
    @Published private(set) var history: LoadState<CommitGraph> = .idle
    @Published private(set) var selectedCommit: Commit?
    @Published private(set) var changes: LoadState<[FileNode]> = .idle
    @Published private(set) var commitDiff: CommitDiffSelection?
    @Published private(set) var commitPatch: LoadState<FilePatch> = .idle
    @Published private(set) var page: BrowserPage = .commits
    @Published private(set) var worktree: LoadState<WorktreeTree> = .idle
    @Published private(set) var worktreeFile: WorktreeFile?
    @Published private(set) var worktreePatch: LoadState<FilePatch> = .idle
    @Published private(set) var hasMore = false
    @Published private(set) var loadingMore = false
    @Published private(set) var addingRepository = false
    @Published private(set) var fetchingRepository: Repository?
    @Published private(set) var openingGitHub = false
    @Published private(set) var pageError: String?
    @Published var addError: String?
    @Published var fetchError: String?
    @Published var githubError: String?

    var repositoriesByRecency: [Repository] {
        var unopened = Dictionary(repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recentRepositoryIDs.compactMap { unopened.removeValue(forKey: $0) }
        return recent + repositories.filter { unopened[$0.id] != nil }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.repositoriesKey)
        let repositories = stored.flatMap { try? JSONDecoder().decode([Repository].self, from: $0) } ?? []
        let selection = defaults.string(forKey: Self.selectionKey)
        let current = repositories.first { $0.id == selection } ?? repositories.first
        let recent = defaults.stringArray(forKey: Self.recentRepositoriesKey) ?? []
        self.repositories = repositories
        repository = current
        // For preferences saved before recency tracking, the selected project is the only known recent one.
        recentRepositoryIDs = current.map { selected in
            [selected.id] + recent.filter { $0 != selected.id }
        } ?? []
    }

    func addRepository(at url: URL) async {
        guard !addingRepository else { return }
        addingRepository = true
        addError = nil
        defer { addingRepository = false }

        do {
            let candidate = try await git.repository(at: url)
            if !repositories.contains(candidate) { repositories.append(candidate) }
            selectRepository(candidate)
        } catch {
            addError = error.localizedDescription
        }
    }

    func selectRepository(_ candidate: Repository?) {
        guard repository != candidate else { return }
        closeCommitDiff()
        fetchError = nil
        githubError = nil
        repository = candidate
        projectFiles.open(page == .files ? candidate : nil)
        if let candidate {
            recentRepositoryIDs.removeAll { $0 == candidate.id }
            recentRepositoryIDs.insert(candidate.id, at: 0)
        }
        persist()
        reloadHistory(preserving: nil)
        if page == .worktree { reloadWorktree() }
    }

    func removeCurrentRepository() {
        guard let repository else { return }
        repositories.removeAll { $0 == repository }
        recentRepositoryIDs.removeAll { $0 == repository.id }
        selectRepository(repositories.first)
    }

    func refresh() {
        reloadHistory(preserving: selectedCommit?.id)
        if page == .worktree { reloadWorktree() }
        if page == .files { projectFiles.refresh() }
    }

    func fetchUpstream() {
        guard let repository, fetchingRepository == nil else { return }
        fetchingRepository = repository
        fetchError = nil
        Task {
            defer { fetchingRepository = nil }
            do {
                try await git.fetchUpstream(in: repository)
                if self.repository == repository {
                    reloadHistory(preserving: selectedCommit?.id)
                }
            } catch {
                if self.repository == repository { fetchError = error.localizedDescription }
            }
        }
    }

    func githubRepositoryURL() async -> URL? {
        guard let repository, !openingGitHub else { return nil }
        openingGitHub = true
        githubError = nil
        defer { openingGitHub = false }
        do {
            let url = try await git.githubRepositoryURL(in: repository)
            guard self.repository == repository else { return nil }
            if url == nil { githubError = "当前项目没有 github.com 的远程仓库地址。" }
            return url
        } catch {
            if self.repository == repository { githubError = error.localizedDescription }
            return nil
        }
    }

    func selectPage(_ page: BrowserPage) {
        guard self.page != page else { return }
        closeCommitDiff()
        self.page = page
        reloadWorktree()
        if page == .files { projectFiles.open(repository) }
    }

    func selectAdjacentPage(backwards: Bool) {
        let pages = BrowserPage.allCases
        guard let current = pages.firstIndex(of: page) else { return }
        let offset = backwards ? pages.count - 1 : 1
        selectPage(pages[(current + offset) % pages.count])
    }

    func reloadWorktree() {
        worktreeTask?.cancel()
        patchTask?.cancel()
        worktreeFile = nil
        worktreePatch = .idle
        guard page == .worktree, let repository else {
            worktree = .idle
            return
        }

        worktree = .loading
        worktreeTask = Task {
            do {
                let changes = try await git.worktreeChanges(in: repository)
                let tree = await Task.detached(priority: .userInitiated) {
                    WorktreeTree(changes: changes)
                }.value
                try Task.checkCancellation()
                worktree = .loaded(tree)
            } catch {
                guard !Task.isCancelled else { return }
                worktree = .failed(error.localizedDescription)
            }
        }
    }

    func worktreeVersions(at path: Data) -> [WorktreeFile] {
        guard case .loaded(let tree) = worktree else { return [] }
        return tree.versions(at: path)
    }

    func selectWorktreePath(_ path: Data) {
        guard worktreeFile?.change.path != path else { return }
        let versions = worktreeVersions(at: path)
        if let file = versions.first(where: { $0.section == .unstaged }) ?? versions.first {
            selectWorktreeFile(file)
        }
    }

    func selectWorktreeVersion(_ section: WorktreeSection) {
        guard let file = worktreeFile, file.section != section,
              let version = worktreeVersions(at: file.change.path).first(where: { $0.section == section }) else { return }
        selectWorktreeFile(version)
    }

    func selectWorktreeFile(_ file: WorktreeFile) {
        guard page == .worktree, let repository else { return }
        patchTask?.cancel()
        worktreeFile = file
        worktreePatch = .loading
        patchTask = Task {
            do {
                let patch = try await git.worktreePatch(in: repository, section: file.section, change: file.change)
                try Task.checkCancellation()
                worktreePatch = .loaded(patch)
            } catch {
                guard !Task.isCancelled else { return }
                worktreePatch = .failed(error.localizedDescription)
            }
        }
    }

    func openCommitDiff(_ file: FileChange) {
        guard page == .commits, let selectedCommit, case .loaded(let nodes) = changes else { return }
        commitDiff = CommitDiffSelection(commit: selectedCommit, nodes: nodes, file: file)
        reloadCommitPatch()
    }

    func selectCommitDiffFile(_ file: FileChange) {
        guard let current = commitDiff, current.file != file else { return }
        commitDiff?.file = file
        reloadCommitPatch()
    }

    func reloadCommitPatch() {
        guard let repository, let selection = commitDiff else { return }
        commitPatchTask?.cancel()
        commitPatch = .loading
        commitPatchTask = Task {
            do {
                let patch = try await git.commitPatch(in: repository, commitID: selection.commit.id,
                                                      change: selection.file)
                try Task.checkCancellation()
                commitPatch = .loaded(patch)
            } catch {
                guard !Task.isCancelled else { return }
                commitPatch = .failed(error.localizedDescription)
            }
        }
    }

    func closeCommitDiff() {
        guard commitDiff != nil else { return }
        commitPatchTask?.cancel()
        commitPatchTask = nil
        commitDiff = nil
        commitPatch = .idle
    }

    private func reloadHistory(preserving commitID: String?) {
        historyTask?.cancel()
        pageTask?.cancel()
        changesTask?.cancel()
        head = nil
        selectedCommit = nil
        changes = .idle
        hasMore = false
        loadingMore = false
        pageError = nil

        guard let repository else {
            history = .idle
            return
        }

        history = .loading
        historyTask = Task {
            do {
                let head = try await git.head(in: repository)
                try Task.checkCancellation()
                self.head = head
                guard let headID = head.commitID else {
                    history = .loaded(CommitGraph())
                    return
                }

                let page = try await git.history(in: repository, headID: headID,
                                                 upstreamID: head.upstream?.commitID, offset: 0)
                try Task.checkCancellation()
                var graph = CommitGraph(localHeadID: headID, remoteHeadID: head.upstream?.commitID)
                graph.append(page.commits)
                history = .loaded(graph)
                hasMore = page.hasMore
                let selected = page.commits.first { $0.id == commitID }
                    ?? page.commits.first { $0.id == headID }
                    ?? page.commits.first
                if let commit = selected {
                    selectCommit(commit)
                }
            } catch {
                guard !Task.isCancelled else { return }
                history = .failed(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        guard let repository, let head, let headID = head.commitID, case .loaded(let graph) = history,
              hasMore, !loadingMore else { return }

        loadingMore = true
        pageError = nil
        pageTask = Task {
            defer {
                if !Task.isCancelled { loadingMore = false }
            }
            do {
                let page = try await git.history(in: repository, headID: headID,
                                                 upstreamID: head.upstream?.commitID, offset: graph.rows.count)
                try Task.checkCancellation()
                var updated = graph
                updated.append(page.commits)
                history = .loaded(updated)
                hasMore = page.hasMore
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.localizedDescription
            }
        }
    }

    func selectCommit(_ commit: Commit) {
        guard let repository else { return }
        changesTask?.cancel()
        selectedCommit = commit
        changes = .loading
        changesTask = Task {
            do {
                let files = try await git.changes(in: repository, commitID: commit.id)
                try Task.checkCancellation()
                let nodes = await Task.detached(priority: .userInitiated) {
                    FileNode.tree(from: files)
                }.value
                try Task.checkCancellation()
                changes = .loaded(nodes)
            } catch {
                guard !Task.isCancelled else { return }
                changes = .failed(error.localizedDescription)
            }
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(repositories), forKey: Self.repositoriesKey)
        defaults.set(repository?.id, forKey: Self.selectionKey)
        defaults.set(recentRepositoryIDs, forKey: Self.recentRepositoriesKey)
    }
}
