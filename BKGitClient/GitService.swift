import Foundation

struct Repository: Codable, Hashable, Identifiable, Sendable {
    let path: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct Commit: Identifiable, Equatable, Sendable {
    let id: String
    let shortID: String
    let author: String
    let authoredAt: Date
    let subject: String
    let parentIDs: [String]
}

struct Head: Equatable, Sendable {
    struct Upstream: Equatable, Sendable {
        let name: String
        let commitID: String?
    }

    let branch: String?
    let commitID: String?
    let upstream: Upstream?

    init(branch: String?, commitID: String?, upstream: Upstream? = nil) {
        self.branch = branch
        self.commitID = commitID
        self.upstream = upstream
    }
}

struct CommitPage: Sendable {
    let commits: [Commit]
    let hasMore: Bool
}

enum WorktreeSection: String, CaseIterable, Identifiable, Sendable {
    case staged, unstaged, untracked, conflicted

    var id: Self { self }
}

struct FilePatch: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Sendable {
            case context, addition, removal, hunk, metadata
        }

        let text: String
        let kind: Kind
    }

    let lines: [Line]
    let inlineDiff: InlineDiff?
    let truncated: Bool
    var document: DiffDocument?

    init(output: Data, truncated: Bool) {
        var text = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
        if text.last?.isEmpty == true { text.removeLast() }
        var hunkColumns = 0
        lines = text.map { line in
            let kind: Line.Kind
            if line.hasPrefix("diff --") {
                hunkColumns = 0
                kind = .metadata
            } else if line.hasPrefix("@@") {
                hunkColumns = line.prefix { $0 == "@" }.count - 1
                kind = .hunk
            } else if hunkColumns == 0 || line.hasPrefix("\\") {
                kind = .metadata
            } else {
                let prefix = line.prefix(hunkColumns)
                kind = prefix.contains("+") ? .addition : (prefix.contains("-") ? .removal : .context)
            }
            return Line(text: line, kind: kind)
        }
        inlineDiff = InlineDiff(lines: lines)
        self.truncated = truncated
    }
}

struct DiffDocument: Equatable, Sendable {
    let id = UUID()
    let path: String
    let original: String
    let modified: String

    init?(path: String, fullPatch: Data) {
        // A full-context diff for one file has a single hunk covering both versions from line 1.
        var lines = fullPatch.split(separator: 10, omittingEmptySubsequences: false)[...]
        guard lines.last?.isEmpty == true else { return nil }
        lines.removeLast()
        let prefix = Data("@@ ".utf8)
        let filePrefix = Data("diff --git ".utf8)
        guard let headerIndex = lines.firstIndex(where: { $0.starts(with: prefix) }),
              lines[..<headerIndex].filter({ $0.starts(with: filePrefix) }).count == 1 else { return nil }
        let header = String(decoding: lines[headerIndex], as: UTF8.self).split(separator: " ", maxSplits: 4)
        guard header.count >= 4, header[3] == "@@",
              let oldCount = Self.lineCount(header[1], sign: "-"),
              let newCount = Self.lineCount(header[2], sign: "+") else { return nil }

        var old = Data()
        var new = Data()
        var oldLines = 0
        var newLines = 0
        var previous: UInt8?
        for line in lines[lines.index(after: headerIndex)...] {
            guard let marker = line.first else { return nil }
            switch marker {
            case 32, 43, 45:
                if marker != 43 {
                    old.append(contentsOf: line.dropFirst())
                    old.append(10)
                    oldLines += 1
                }
                if marker != 45 {
                    new.append(contentsOf: line.dropFirst())
                    new.append(10)
                    newLines += 1
                }
                previous = marker
            case 92:
                guard let marker = previous, line.elementsEqual("\\ No newline at end of file".utf8) else { return nil }
                if marker != 43 { old.removeLast() }
                if marker != 45 { new.removeLast() }
                previous = nil
            default:
                return nil
            }
        }
        guard oldLines == oldCount, newLines == newCount,
              let original = Self.editorText(old), let modified = Self.editorText(new),
              !original.utf8.elementsEqual(modified.utf8) else { return nil }
        self.path = path
        self.original = original
        self.modified = modified
    }

    private static func lineCount(_ range: Substring, sign: Character) -> Int? {
        guard range.first == sign else { return nil }
        let fields = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = fields.first.flatMap({ Int($0) }), fields.count <= 2,
              let count = fields.count == 1 ? 1 : Int(fields[1]),
              count >= 0, start == (count == 0 ? 0 : 1) else { return nil }
        return count
    }

    private static func editorText(_ bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8), !text.unicodeScalars.contains(where: {
            $0.value < 32 && ![9, 10, 12, 13].contains($0.value)
        }) else { return nil }
        // Monaco uses one line-ending style per model.
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

enum GitFailure: LocalizedError, Equatable {
    case notAWorktree
    case unavailable
    case invalidOutput
    case missingParent
    case missingUpstream
    case invalidTrackingReference
    case command(String)

    var errorDescription: String? {
        switch self {
        case .notAWorktree: "请选择 Git 工作树或其中的目录。"
        case .unavailable: "无法访问此仓库。若目录已移动，请移除此项目并重新添加。"
        case .invalidOutput: "无法解析 Git 返回的数据。"
        case .missingParent: "本地缺少此提交的第一父提交，无法计算文件改动。"
        case .missingUpstream: "当前分支没有配置远程上游。"
        case .invalidTrackingReference: "上游的抓取配置没有指向远程跟踪分支。"
        case .command(let message): message
        }
    }
}

struct GitService: Sendable {
    static let pageSize = 50
    private static let patchLimit = 512 * 1024
    private static let patchOptions = [
        "--patch", "--no-color", "--no-relative", "--no-ext-diff", "--no-textconv",
        "--no-indent-heuristic", "--unified=3", "--find-renames", "--submodule=short",
        "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= "
    ]

    func repository(at directory: URL) async throws -> Repository {
        let inside = try await run(["rev-parse", "--is-inside-work-tree"], in: directory)
        guard inside.status == 0, inside.line == "true" else {
            if inside.status != 0 && !inside.error.contains("not a git repository") {
                try inside.check()
            }
            throw GitFailure.notAWorktree
        }

        let root = try await run(["rev-parse", "--show-toplevel"], in: directory)
        try root.check()
        guard root.line.hasPrefix("/") else { throw GitFailure.invalidOutput }
        let canonical = URL(fileURLWithPath: root.line, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return Repository(path: canonical.path)
    }

    func head(in repository: Repository) async throws -> Head {
        try await checkRepository(repository)

        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"], in: repository.url)
        if symbolic.status != 1 { try symbolic.check() }
        let branch = symbolic.status == 0
            ? String(symbolic.line.dropFirst(symbolic.line.hasPrefix("refs/heads/") ? 11 : 0))
            : nil
        let resolved = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: repository.url)
        if resolved.status == 1, branch != nil {
            let ref = try await run(["show-ref", "--verify", "--quiet", symbolic.line], in: repository.url)
            if ref.status == 1 { return Head(branch: branch, commitID: nil) }
        }
        try resolved.check()
        let upstream = branch == nil ? nil : try await upstream(for: symbolic.line, in: repository)
        return Head(branch: branch, commitID: resolved.line, upstream: upstream)
    }

    func fetchUpstream(in repository: Repository) async throws {
        try await checkRepository(repository)
        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"], in: repository.url)
        if symbolic.status != 1 { try symbolic.check() }
        guard symbolic.status == 0,
              let upstream = try await upstreamConfiguration(for: symbolic.line, in: repository) else {
            throw GitFailure.missingUpstream
        }
        guard upstream.remoteReference.hasPrefix("refs/heads/"),
              upstream.trackingReference.hasPrefix("refs/remotes/") else {
            throw GitFailure.invalidTrackingReference
        }
        for reference in [upstream.remoteReference, upstream.trackingReference] {
            let valid = try await run(["check-ref-format", reference], in: repository.url)
            guard valid.status == 0 else { throw GitFailure.invalidTrackingReference }
        }

        // The explicit refspec and empty refmap keep configured mirror or additional mappings out of this fetch.
        let result = try await run([
            "fetch", "--refmap=", "--no-tags", "--no-prune", "--no-prune-tags", "--no-recurse-submodules",
            "--no-auto-maintenance", "--no-write-fetch-head", "--no-write-commit-graph",
            "--", upstream.remote, "+\(upstream.remoteReference):\(upstream.trackingReference)"
        ], in: repository.url, allowRemoteTransport: true)
        try result.check()
    }

    func githubRepositoryURL(in repository: Repository) async throws -> URL? {
        try await checkRepository(repository)
        let listed = try await run(["remote"], in: repository.url)
        try listed.check()
        let remotes = listed.line.split(separator: "\n").map(String.init)
        guard !remotes.isEmpty else { return nil }

        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"], in: repository.url)
        if symbolic.status != 1 { try symbolic.check() }
        let upstream = symbolic.status == 0 ? try await upstreamConfiguration(for: symbolic.line, in: repository) : nil
        var orderedRemotes = remotes
        for preferred in ["origin", upstream?.remote].compactMap({ $0 }) {
            if let index = orderedRemotes.firstIndex(of: preferred) {
                orderedRemotes.remove(at: index)
                orderedRemotes.insert(preferred, at: 0)
            }
        }

        for remote in orderedRemotes {
            let urls = try await run(["remote", "get-url", "--all", "--", remote], in: repository.url)
            guard urls.status == 0 else { continue }
            for url in urls.line.split(separator: "\n") {
                if let page = Self.githubWebURL(from: String(url)) { return page }
            }
        }
        return nil
    }

    private static func githubWebURL(from remote: String) -> URL? {
        let path: String
        if remote.contains("://") {
            guard let components = URLComponents(string: remote),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git"].contains(scheme),
                  let host = components.host?.lowercased(),
                  host == "github.com" || (scheme == "ssh" && host == "ssh.github.com") else { return nil }
            path = components.path
        } else {
            // Git also accepts the SCP-style spelling git@github.com:owner/repository.git.
            let address = remote.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard address.count == 2,
                  address[0].split(separator: "@", omittingEmptySubsequences: false).last?.lowercased() == "github.com"
            else { return nil }
            path = String(address[1])
        }

        let segments = path.split(separator: "/")
        guard segments.count == 2 else { return nil }
        let owner = segments[0]
        let name = segments[1].hasSuffix(".git") ? segments[1].dropLast(4) : segments[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [owner, name].allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".." && segment.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return URL(string: "https://github.com/\(owner)/\(name)")
    }

    private func checkRepository(_ repository: Repository) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw GitFailure.unavailable }

        do {
            guard try await self.repository(at: repository.url) == repository else {
                throw GitFailure.unavailable
            }
        } catch GitFailure.notAWorktree {
            throw GitFailure.unavailable
        }
    }

    private struct UpstreamConfiguration {
        let name: String
        let trackingReference: String
        let remote: String
        let remoteReference: String
    }

    private func upstreamConfiguration(for localRef: String, in repository: Repository) async throws -> UpstreamConfiguration? {
        let result = try await run([
            "for-each-ref", "--count=1",
            "--format=%(refname)%00%(upstream)%00%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)",
            "--", localRef
        ], in: repository.url)
        try result.check()
        let fields = result.line.components(separatedBy: "\0")
        guard fields.count == 5, fields[0] == localRef,
              !fields[1].isEmpty, !fields[3].isEmpty, fields[3] != "." else { return nil }
        return UpstreamConfiguration(name: fields[2].isEmpty ? fields[1] : fields[2],
                                     trackingReference: fields[1], remote: fields[3], remoteReference: fields[4])
    }

    private func upstream(for localRef: String, in repository: Repository) async throws -> Head.Upstream? {
        guard let upstream = try await upstreamConfiguration(for: localRef, in: repository) else { return nil }
        let resolved = try await run(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(upstream.trackingReference)^{commit}"],
            in: repository.url
        )
        if resolved.status == 1 { return Head.Upstream(name: upstream.name, commitID: nil) }
        try resolved.check()
        return Head.Upstream(name: upstream.name, commitID: resolved.line)
    }

    func history(in repository: Repository, headID: String, upstreamID: String? = nil,
                 offset: Int) async throws -> CommitPage {
        var tips = [headID]
        if let upstreamID, upstreamID != headID { tips.append(upstreamID) }
        let result = try await run([
            "log", "--topo-order", "--no-patch", "--no-notes", "--no-decorate", "--no-show-signature",
            "--no-color", "--encoding=UTF-8", "-z", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P",
            "--max-count=\(Self.pageSize + 1)", "--skip=\(offset)"
        ] + tips + ["--"], in: repository.url)
        try result.check()
        let fields = try Self.fields(in: result.output)
        let width = 6
        guard fields.count.isMultiple(of: width) else { throw GitFailure.invalidOutput }

        let dateFormat = Date.ISO8601FormatStyle(timeSeparator: .colon, timeZoneSeparator: .colon)
        let commits = try stride(from: 0, to: fields.count, by: width).map { index in
            guard let date = try? dateFormat.parse(String(decoding: fields[index + 3], as: UTF8.self)) else {
                throw GitFailure.invalidOutput
            }
            return Commit(
                id: String(decoding: fields[index], as: UTF8.self),
                shortID: String(decoding: fields[index + 1], as: UTF8.self),
                author: String(decoding: fields[index + 2], as: UTF8.self),
                authoredAt: date,
                subject: String(decoding: fields[index + 4], as: UTF8.self),
                parentIDs: String(decoding: fields[index + 5], as: UTF8.self).split(separator: " ").map(String.init)
            )
        }
        return CommitPage(commits: Array(commits.prefix(Self.pageSize)), hasMore: commits.count > Self.pageSize)
    }

    func changes(in repository: Repository, commitID: String) async throws -> [FileChange] {
        let comparison = try await commitComparison(in: repository, commitID: commitID)
        let arguments = [
            "diff-tree", "-r", "--no-commit-id", "--name-status", "-z", "--find-renames",
            "--no-color", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none"
        ] + comparison + ["--"]
        let result = try await run(arguments, in: repository.url)
        try result.check()
        return try Self.parseChanges(result.output)
    }

    func commitPatch(in repository: Repository, commitID: String, change: FileChange) async throws -> FilePatch {
        let comparison = try await commitComparison(in: repository, commitID: commitID)
        let paths = try Self.diffPaths(for: change)
        let arguments = ["diff-tree", "-r", "--no-commit-id", "--ignore-submodules=none"]
            + Self.patchOptions + comparison + ["--"] + Self.pathspecs(for: paths)
        return try await filePatch(arguments, path: paths[0], in: repository)
    }

    private func commitComparison(in repository: Repository, commitID: String) async throws -> [String] {
        // Read the actual commit headers so a shallow boundary is distinguishable from a root commit.
        let commit = try await run(["cat-file", "commit", commitID], in: repository.url)
        try commit.check()
        let parentPrefix = Data("parent ".utf8)
        let firstParent = commit.output.split(separator: 10, omittingEmptySubsequences: false)
            .prefix { !$0.isEmpty }
            .first { $0.starts(with: parentPrefix) }
            .map { String(decoding: $0.dropFirst(parentPrefix.count), as: UTF8.self) }

        if let firstParent {
            let parent = try await run(["cat-file", "-e", "\(firstParent)^{commit}"], in: repository.url)
            if parent.status == 1 || parent.status == 128 { throw GitFailure.missingParent }
            try parent.check()
            return [firstParent, commitID]
        }
        return ["--root", commitID]
    }

    func worktreeChanges(in repository: Repository) async throws -> [WorktreeSection: [FileChange]] {
        guard try await self.repository(at: repository.url) == repository else { throw GitFailure.unavailable }
        let options = try await worktreeOptions(in: repository)
        let result = try await run([
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames",
            "--ignore-submodules=dirty"
        ], in: repository.url, options: options)
        try result.check()
        return try Self.parseWorktreeChanges(result.output)
    }

    func worktreePatch(in repository: Repository, section: WorktreeSection,
                       change: FileChange) async throws -> FilePatch {
        guard try await self.repository(at: repository.url) == repository else { throw GitFailure.unavailable }
        let paths = try Self.diffPaths(for: change)
        var arguments = ["diff", "--ignore-submodules=dirty"] + Self.patchOptions
        switch section {
        case .staged:
            arguments.append("--cached")
        case .conflicted:
            arguments.append("--cc")
        case .unstaged:
            break
        case .untracked:
            let path = repository.url.appendingPathComponent(paths[0]).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeSymbolicLink else {
                throw GitFailure.command("此项目没有可显示的文件 Diff。")
            }
            arguments += ["--no-index", "--", "/dev/null", "./\(paths[0])"]
        }
        if section != .untracked {
            arguments += ["--"] + Self.pathspecs(for: paths)
        }
        let options = try await worktreeOptions(in: repository)
        return try await filePatch(arguments, path: paths[0], in: repository, options: options,
                                   noIndex: section == .untracked)
    }

    private func filePatch(_ arguments: [String], path: String, in repository: Repository,
                           options: [String] = [], noIndex: Bool = false) async throws -> FilePatch {
        let result = try await run(arguments, in: repository.url, options: options, outputLimit: Self.patchLimit)
        if !noIndex || result.status != 1 || result.output.isEmpty { try result.check() }
        var patch = FilePatch(output: result.output, truncated: result.outputTruncated)
        guard patch.inlineDiff != nil, !patch.truncated, !arguments.contains("--cc") else { return patch }

        // Use Git's own comparison for the full snapshots, including index contents and path attributes.
        let fullArguments = arguments.map { $0 == "--unified=3" ? "--unified=\(Self.patchLimit)" : $0 }
        if let full = try? await run(fullArguments, in: repository.url, options: options, outputLimit: Self.patchLimit),
           !full.outputTruncated, full.status == 0 || (noIndex && full.status == 1) {
            patch.document = DiffDocument(path: path, fullPatch: full.output)
        }
        return patch
    }

    private static func diffPaths(for change: FileChange) throws -> [String] {
        try [change.path, change.previousPath].compactMap { $0 }.map { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw GitFailure.command("无法预览此文件名编码的 Diff。")
            }
            return path
        }
    }

    private static func pathspecs(for paths: [String]) -> [String] {
        paths.map { path in
            let escaped = path.reduce(into: "") { pattern, character in
                if "\\[]*?".contains(character) { pattern.append("\\") }
                pattern.append(character)
            }
            // Force full glob matching. A plain literal also matches descendants of this path.
            let pattern = escaped.hasPrefix("\\") ? escaped : "\\" + escaped
            return ":(glob)\(pattern)"
        }
    }

    private func worktreeOptions(in repository: Repository) async throws -> [String] {
        // Status and worktree diff may invoke clean/process filters unless their drivers are disabled.
        let result = try await run([
            "config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"
        ], in: repository.url)
        if result.status == 1 && result.error.isEmpty { return [] }
        try result.check()
        let drivers = Set(try Self.fields(in: result.output).compactMap { field -> String? in
            let key = String(decoding: field, as: UTF8.self)
            guard let lastDot = key.lastIndex(of: ".") else { return nil }
            return String(key[..<lastDot])
        })
        return drivers.sorted().flatMap { driver in
            ["-c", "\(driver).clean=", "-c", "\(driver).process=", "-c", "\(driver).required=false"]
        }
    }

    private static func parseWorktreeChanges(_ output: Data) throws -> [WorktreeSection: [FileChange]] {
        var records = try fields(in: output)[...]
        var changes: [WorktreeSection: [FileChange]] = [:]
        while let record = records.popFirst() {
            let kind = record.first
            let width: Int
            switch kind {
            case 49: width = 8  // ordinary tracked entry
            case 50: width = 9  // rename or copy
            case 117: width = 10  // unmerged entry
            case 63: width = 1  // untracked entry
            default: throw GitFailure.invalidOutput
            }
            let parts = record.split(separator: 32, maxSplits: width, omittingEmptySubsequences: false)
            guard parts.count == width + 1, let path = parts.last, !path.isEmpty else {
                throw GitFailure.invalidOutput
            }
            if kind == 63 || kind == 117 {
                let section: WorktreeSection = kind == 63 ? .untracked : .conflicted
                changes[section, default: []].append(FileChange(
                    kind: kind == 63 ? .added : .conflicted, path: path, previousPath: nil
                ))
                continue
            }

            let previous = kind == 50 ? records.popFirst() : nil
            if kind == 50 && previous == nil { throw GitFailure.invalidOutput }
            let codes = parts[1]
            guard codes.count == 2 else { throw GitFailure.invalidOutput }
            for (section, code) in zip([WorktreeSection.staged, .unstaged], codes) where code != 46 {
                let change = ChangeKind(code: code)
                changes[section, default: []].append(FileChange(
                    kind: change, path: path, previousPath: change == .renamed || change == .copied ? previous : nil
                ))
            }
        }
        return changes
    }

    private static func parseChanges(_ output: Data) throws -> [FileChange] {
        let fields = try fields(in: output)
        var changes: [FileChange] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            guard let code = status.first, index + 1 < fields.count else { throw GitFailure.invalidOutput }
            let kind = ChangeKind(code: code)
            if kind == .renamed || kind == .copied {
                guard index + 2 < fields.count else { throw GitFailure.invalidOutput }
                changes.append(FileChange(kind: kind, path: fields[index + 2], previousPath: fields[index + 1]))
                index += 3
            } else {
                changes.append(FileChange(kind: kind, path: fields[index + 1], previousPath: nil))
                index += 2
            }
        }
        return changes
    }

    private static func fields(in output: Data) throws -> [Data] {
        guard !output.isEmpty else { return [] }
        guard output.last == 0 else { throw GitFailure.invalidOutput }
        return output.dropLast().split(separator: 0, omittingEmptySubsequences: false)
    }

    private func run(_ arguments: [String], in directory: URL, options: [String] = [],
                     outputLimit: Int? = nil, allowRemoteTransport: Bool = false) async throws -> GitResult {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = [
            "--no-pager", "--no-optional-locks", "--no-replace-objects",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "diff.autoRefreshIndex=false",
            "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-c", "submodule.recurse=false"
        ] + options + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_ALLOW_PROTOCOL"] = allowRemoteTransport ? "file:git:http:https:ssh" : ""
        process.environment = environment

        let exit = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exit.continuation.yield(process.terminationStatus)
            exit.continuation.finish()
        }
        try process.run()
        async let output = Self.drain(stdout.fileHandleForReading, limit: outputLimit)
        async let errors = Self.drain(stderr.fileHandleForReading)
        var statuses = exit.stream.makeAsyncIterator()
        guard let status = await statuses.next() else { throw CancellationError() }
        let data = try await output
        return try await GitResult(status: status, output: data.data, errorOutput: errors.data,
                                   outputTruncated: data.truncated)
    }

    private static func drain(_ handle: FileHandle, limit: Int? = nil) async throws -> (data: Data, truncated: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    guard let limit else { return (try handle.readToEnd() ?? Data(), false) }
                    var data = Data()
                    var truncated = false
                    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        let remaining = limit - data.count
                        if chunk.count > remaining { truncated = true }
                        data.append(chunk.prefix(remaining))
                    }
                    return (data, truncated)
                })
            }
        }
    }
}

private struct GitResult {
    let status: Int32
    let output: Data
    let errorOutput: Data
    let outputTruncated: Bool

    var line: String {
        String(decoding: output.last == 10 ? output.dropLast() : output, as: UTF8.self)
    }

    var error: String {
        String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() throws {
        guard status == 0 else {
            throw GitFailure.command(error.isEmpty ? "Git 命令失败（退出状态 \(status)）。" : error)
        }
    }
}
