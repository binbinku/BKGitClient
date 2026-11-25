import Foundation
import XCTest
@testable import BKGitClient

final class GitServiceTests: XCTestCase {
    private let git = GitService()

    func testWorktreeDiffSeparatesStagesAndDoesNotWriteToRepository() async throws {
        let fixture = try GitFixture()
        let tracked = "tracked [literal].txt"
        let renamed = "nested/renamed\n雪.txt"
        let untracked = "nested/ new file\t.txt"
        try fixture.write(tracked, "base\n")
        try fixture.write("old.txt", "rename me\n")
        try fixture.write(".gitignore", "ignored.txt\n")
        try fixture.write(".gitattributes", "tracked* filter=bk-test diff=bk-test\n")
        _ = try fixture.commit("Base")

        try fixture.write(tracked, "staged\n")
        try fixture.git("--literal-pathspecs", "add", "--", tracked)
        try fixture.write(tracked, "unstaged\n")
        try fixture.write(untracked, "new file\n")
        try fixture.write("ignored.txt", "ignored\n")
        try fixture.git("mv", "--", "old.txt", renamed)

        try fixture.git("config", "filter.bk-test.clean", "touch .git/filter-ran; cat")
        try fixture.git("config", "filter.bk-test.required", "true")
        try fixture.git("config", "diff.bk-test.command", "touch .git/diff-ran")
        try fixture.git("config", "diff.bk-test.textconv", "touch .git/textconv-ran")
        let before = try fixture.snapshot()

        let groups = try await git.worktreeChanges(in: fixture.repository)
        XCTAssertEqual(groups[.staged]?.count, 2)
        XCTAssertEqual(groups[.unstaged]?.map(\.path), [Data(tracked.utf8)])
        XCTAssertEqual(groups[.untracked]?.map(\.path), [Data(untracked.utf8)])
        XCTAssertEqual(groups[.staged]?.first { $0.kind == .renamed },
                       FileChange(kind: .renamed, path: Data(renamed.utf8), previousPath: Data("old.txt".utf8)))

        let staged = try XCTUnwrap(groups[.staged]?.first { $0.path == Data(tracked.utf8) })
        let stagedPatch = try await git.worktreePatch(in: fixture.repository, section: .staged, change: staged)
        XCTAssertTrue(stagedPatch.lines.contains(.init(text: "-base", kind: .removal)))
        XCTAssertTrue(stagedPatch.lines.contains(.init(text: "+staged", kind: .addition)))
        XCTAssertFalse(stagedPatch.lines.contains { $0.text == "+unstaged" })
        XCTAssertEqual(stagedPatch.document?.original, "base\n")
        XCTAssertEqual(stagedPatch.document?.modified, "staged\n")

        let edited = try XCTUnwrap(groups[.unstaged]?.first)
        let editedPatch = try await git.worktreePatch(in: fixture.repository, section: .unstaged, change: edited)
        XCTAssertTrue(editedPatch.lines.contains(.init(text: "-staged", kind: .removal)))
        XCTAssertTrue(editedPatch.lines.contains(.init(text: "+unstaged", kind: .addition)))
        XCTAssertEqual(editedPatch.document?.original, "staged\n")
        XCTAssertEqual(editedPatch.document?.modified, "unstaged\n")

        let renamedFile = try XCTUnwrap(groups[.staged]?.first { $0.kind == .renamed })
        let renamePatch = try await git.worktreePatch(in: fixture.repository, section: .staged, change: renamedFile)
        XCTAssertTrue(renamePatch.lines.contains { $0.text == "rename from old.txt" })
        XCTAssertTrue(renamePatch.lines.contains { $0.text.hasPrefix("rename to ") })
        XCTAssertNil(renamePatch.document)

        let newFile = try XCTUnwrap(groups[.untracked]?.first)
        let newPatch = try await git.worktreePatch(in: fixture.repository, section: .untracked, change: newFile)
        XCTAssertTrue(newPatch.lines.contains(.init(text: "+new file", kind: .addition)))
        XCTAssertEqual(newPatch.document?.original, "")
        XCTAssertEqual(newPatch.document?.modified, "new file\n")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testWorktreeDiffBeforeFirstCommitAndBinaryPreview() async throws {
        let fixture = try GitFixture()
        try fixture.write("staged.txt", "first\n")
        try fixture.git("add", "staged.txt")
        try Data([0, 1, 2]).write(to: fixture.url.appendingPathComponent("binary.dat"))
        let before = try fixture.snapshot()

        let groups = try await git.worktreeChanges(in: fixture.repository)
        let staged = try XCTUnwrap(groups[.staged]?.first)
        let binary = try XCTUnwrap(groups[.untracked]?.first)
        let stagedPatch = try await git.worktreePatch(in: fixture.repository, section: .staged, change: staged)
        let binaryPatch = try await git.worktreePatch(in: fixture.repository, section: .untracked, change: binary)
        XCTAssertTrue(stagedPatch.lines.contains(.init(text: "+first", kind: .addition)))
        XCTAssertEqual(stagedPatch.document?.original, "")
        XCTAssertEqual(stagedPatch.document?.modified, "first\n")
        XCTAssertTrue(binaryPatch.lines.contains { $0.text.hasPrefix("Binary files ") })
        let added = try XCTUnwrap(stagedPatch.inlineDiff?.rows.compactMap { row -> InlineDiff.CodeLine? in
            if case .code(let line) = row { return line }
            return nil
        }.first)
        XCTAssertNil(added.oldNumber)
        XCTAssertEqual(added.newNumber, 1)
        XCTAssertNil(binaryPatch.inlineDiff)
        XCTAssertNil(binaryPatch.document)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testInlineDiffTracksBothLineNumbersAndHighlightsOnlyTheEditedText() async throws {
        let fixture = try GitFixture()
        var lines = ["let name = \"猫\""] + (2...25).map { "line \($0)" }
        let original = lines.joined(separator: "\n")
        try fixture.write("example.swift", original)
        _ = try fixture.commit("Original")
        lines[0] = "let name = \"狗\""
        lines.insert("new line", at: 20)
        lines[25] = "last line"
        try fixture.write("example.swift", lines.joined(separator: "\n"))
        let before = try fixture.snapshot()

        let changes = try await git.worktreeChanges(in: fixture.repository)
        let file = try XCTUnwrap(changes[.unstaged]?.first)
        let patch = try await git.worktreePatch(in: fixture.repository, section: .unstaged, change: file)
        XCTAssertEqual(patch.document?.original, original)
        XCTAssertEqual(patch.document?.modified, lines.joined(separator: "\n"))
        let diff = try XCTUnwrap(patch.inlineDiff)
        XCTAssertEqual(diff.rows.filter { if case .hunk = $0 { return true }; return false }.count, 2)
        let code = diff.rows.compactMap { row -> InlineDiff.CodeLine? in
            if case .code(let line) = row { return line }
            return nil
        }
        let old = try XCTUnwrap(code.first { $0.oldNumber == 1 })
        let new = try XCTUnwrap(code.first { $0.newNumber == 1 })
        XCTAssertNil(old.newNumber)
        XCTAssertNil(new.oldNumber)
        XCTAssertEqual(String(old.text[try XCTUnwrap(old.emphasis)]), "猫")
        XCTAssertEqual(String(new.text[try XCTUnwrap(new.emphasis)]), "狗")
        let shifted = try XCTUnwrap(code.first { $0.text == "line 21" })
        XCTAssertEqual(shifted.oldNumber, 21)
        XCTAssertEqual(shifted.newNumber, 22)
        XCTAssertEqual(code.last?.newNumber, 26)
        XCTAssertTrue(diff.rows.contains(.note("\\ No newline at end of file")))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCommitDiffUsesHistoricalContentAndMatchesAnExactRename() async throws {
        let fixture = try GitFixture()
        let filename = "tracked [literal].txt"
        try fixture.write(filename, "original\n")
        try fixture.write("node", "rename me\n")
        let first = try fixture.commit("Initial")
        try FileManager.default.moveItem(at: fixture.url.appendingPathComponent("node"),
                                         to: fixture.url.appendingPathComponent("moved"))
        try fixture.write("node/another", "unrelated addition\n")
        try FileManager.default.moveItem(at: fixture.url.appendingPathComponent("moved"),
                                         to: fixture.url.appendingPathComponent("node/雪"))
        try fixture.write(filename, "committed\n")
        let second = try fixture.commit("Update")
        try fixture.write(filename, "working tree\n")
        let before = try fixture.snapshot()

        let rootChanges = try await git.changes(in: fixture.repository, commitID: first)
        let root = try XCTUnwrap(rootChanges.first { $0.path == Data(filename.utf8) })
        let rootPatch = try await git.commitPatch(in: fixture.repository, commitID: first, change: root)
        XCTAssertTrue(rootPatch.lines.contains(.init(text: "+original", kind: .addition)))
        XCTAssertNotNil(rootPatch.inlineDiff)
        XCTAssertEqual(rootPatch.document?.original, "")
        XCTAssertEqual(rootPatch.document?.modified, "original\n")

        let changes = try await git.changes(in: fixture.repository, commitID: second)
        let edit = try XCTUnwrap(changes.first { $0.path == Data(filename.utf8) })
        let editPatch = try await git.commitPatch(in: fixture.repository, commitID: second, change: edit)
        XCTAssertTrue(editPatch.lines.contains(.init(text: "-original", kind: .removal)))
        XCTAssertTrue(editPatch.lines.contains(.init(text: "+committed", kind: .addition)))
        XCTAssertFalse(editPatch.lines.contains { $0.text.contains("working tree") })
        XCTAssertEqual(editPatch.document?.original, "original\n")
        XCTAssertEqual(editPatch.document?.modified, "committed\n")

        let rename = try XCTUnwrap(changes.first { $0.kind == .renamed })
        let renamePatch = try await git.commitPatch(in: fixture.repository, commitID: second, change: rename)
        XCTAssertTrue(renamePatch.lines.contains { $0.text == "rename from node" })
        XCTAssertFalse(renamePatch.lines.contains { $0.text.contains("another") })
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testWorktreeDiscoveryAndEmptyHead() async throws {
        let fixture = try GitFixture()
        let nested = fixture.url.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let repository = try await git.repository(at: nested)
        XCTAssertEqual(repository, fixture.repository)
        let head = try await git.head(in: repository)
        XCTAssertEqual(head, Head(branch: "main", commitID: nil))

        _ = try fixture.commit("Initial")
        let worktree = fixture.url.appendingPathComponent("linked")
        try fixture.git("worktree", "add", "-b", "linked", worktree.path)
        let linked = try await git.repository(at: worktree)
        XCTAssertNotEqual(linked, repository)
        let linkedHead = try await git.head(in: linked)
        XCTAssertEqual(linkedHead.branch, "linked")
    }

    func testRootAndOrdinaryCommitKeepSpecialPathsAndRepositoryIntact() async throws {
        let fixture = try GitFixture()
        let original = "first/old name\t雪\n.txt"
        let renamed = "second/new name\t雪\n.txt"
        try fixture.write(original, "keep this content")
        try fixture.write("modified", "old")
        try fixture.write("removed", "delete this")
        try fixture.write("type", "ordinary file")
        let root = try fixture.commit("Initial")

        try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent("second"),
                                                withIntermediateDirectories: false)
        try fixture.git("mv", original, renamed)
        try fixture.write("modified", "different")
        try fixture.write("z-added", "new file")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("removed"))
        let type = fixture.url.appendingPathComponent("type")
        try FileManager.default.removeItem(at: type)
        try FileManager.default.createSymbolicLink(atPath: type.path, withDestinationPath: "modified")
        let ordinary = try fixture.commit("Update")
        let empty = try fixture.commit("Empty")
        let before = try fixture.snapshot()

        let repository = try await git.repository(at: fixture.url)
        let head = try await git.head(in: repository)
        let history = try await git.history(in: repository, headID: try XCTUnwrap(head.commitID), offset: 0)
        XCTAssertEqual(history.commits.map(\.id), [empty, ordinary, root])
        XCTAssertEqual(history.commits.map(\.subject), ["Empty", "Update", "Initial"])
        XCTAssertEqual(history.commits.first?.author, "Fixture Author")
        XCTAssertFalse(history.hasMore)

        let additions = try await git.changes(in: repository, commitID: root)
        XCTAssertEqual(Set(additions.map(\.path)), Set([original, "modified", "removed", "type"].map {
            Data($0.utf8)
        }))
        XCTAssertTrue(additions.allSatisfy { $0.kind == .added })
        let updates = try await git.changes(in: repository, commitID: ordinary)
        XCTAssertEqual(Set(updates.map(\.kind)), [.renamed, .modified, .deleted, .typeChanged, .added])
        XCTAssertEqual(updates.first { $0.kind == .renamed },
                       FileChange(kind: .renamed, path: Data(renamed.utf8), previousPath: Data(original.utf8)))

        let tree = FileNode.tree(from: updates)
        XCTAssertEqual(tree.first?.name, "second")
        XCTAssertEqual(tree.first?.children.first?.name, "new name\\t雪\\n.txt")
        XCTAssertEqual(tree.first?.children.first?.id.path, Data(renamed.utf8))
        let noChanges = try await git.changes(in: repository, commitID: empty)
        XCTAssertTrue(noChanges.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testMergeUsesFirstParentAndDetachedHeadStillHasHistory() async throws {
        let fixture = try GitFixture()
        _ = try fixture.commit("Base")
        try fixture.git("switch", "-c", "feature")
        try fixture.write("feature.txt", "feature")
        let feature = try fixture.commit("Feature")
        try fixture.git("switch", "main")
        try fixture.write("main.txt", "main")
        let main = try fixture.commit("Main")
        try fixture.git("merge", "--no-ff", "-m", "Merge", "feature")
        let merge = try fixture.git("rev-parse", "HEAD")
        try fixture.git("switch", "--detach", merge)

        let head = try await git.head(in: fixture.repository)
        XCTAssertEqual(head, Head(branch: nil, commitID: merge))
        let history = try await git.history(in: fixture.repository, headID: merge, offset: 0)
        XCTAssertEqual(history.commits.first?.id, merge)
        XCTAssertEqual(history.commits.first?.parentIDs, [main, feature])
        XCTAssertTrue(history.commits.contains { $0.id == feature })
        XCTAssertTrue(history.commits.contains { $0.id == main })
        let changes = try await git.changes(in: fixture.repository, commitID: merge)
        XCTAssertEqual(changes, [FileChange(kind: .added, path: Data("feature.txt".utf8), previousPath: nil)])
        let patch = try await git.commitPatch(in: fixture.repository, commitID: merge, change: try XCTUnwrap(changes.first))
        XCTAssertTrue(patch.lines.contains(.init(text: "+feature", kind: .addition)))
        XCTAssertFalse(patch.lines.contains { $0.text.contains("main.txt") })
    }

    func testShallowBoundaryDoesNotAppearAsRoot() async throws {
        let origin = try GitFixture()
        try origin.write("base", "base")
        _ = try origin.commit("Base")
        try origin.write("tip", "tip")
        let tip = try origin.commit("Tip")
        let clone = try GitFixture(initialize: false)
        try clone.git("clone", "--depth=1", origin.url.absoluteString, ".")

        let head = try await git.head(in: clone.repository)
        XCTAssertEqual(head.commitID, tip)
        XCTAssertEqual(head.upstream?.commitID, tip)
        let page = try await git.history(in: clone.repository, headID: tip, offset: 0)
        XCTAssertEqual(page.commits.first?.parentIDs, [])
        do {
            _ = try await git.changes(in: clone.repository, commitID: tip)
            XCTFail("A missing first parent must be reported")
        } catch let error as GitFailure {
            XCTAssertEqual(error, .missingParent)
        }
    }

    func testPartialCloneDoesNotFetchMissingObjects() async throws {
        let origin = try GitFixture()
        try origin.git("config", "uploadpack.allowFilter", "true")
        try origin.write("file.txt", "content")
        let tip = try origin.commit("Root")
        let clone = try GitFixture(initialize: false)
        try clone.git("clone", "--filter=tree:0", "--no-checkout", origin.url.absoluteString, ".")
        let before = try clone.snapshot()

        let history = try await git.history(in: clone.repository, headID: tip, offset: 0)
        XCTAssertEqual(history.commits.map(\.id), [tip])
        do {
            _ = try await git.changes(in: clone.repository, commitID: tip)
            XCTFail("The missing tree must not be fetched")
        } catch let error as GitFailure {
            guard case .command = error else { throw error }
        }
        XCTAssertEqual(try clone.snapshot(), before)
    }

    func testPaginationRemainsAnchoredAfterNewCommit() async throws {
        let fixture = try GitFixture()
        var expected: [String] = []
        for number in 1...53 {
            expected.append(try fixture.commit("Commit \(number)"))
        }
        let anchor = try XCTUnwrap(expected.last)
        try fixture.git("switch", "-c", "remote-fixture", try XCTUnwrap(expected.first))
        let remote = try fixture.commit("Remote tip")
        try fixture.git("switch", "main")
        let ordered = try fixture.git("log", "--topo-order", "--format=%H", anchor, remote, "--")
            .components(separatedBy: .newlines)
        let first = try await git.history(in: fixture.repository, headID: anchor, upstreamID: remote, offset: 0)
        XCTAssertEqual(first.commits.count, 50)
        XCTAssertTrue(first.hasMore)

        _ = try fixture.commit("Added outside the browser")
        try fixture.git("switch", "remote-fixture")
        _ = try fixture.commit("Remote added outside the browser")
        let next = try await git.history(in: fixture.repository, headID: anchor, upstreamID: remote,
                                         offset: first.commits.count)
        XCTAssertFalse(next.hasMore)
        XCTAssertEqual((first.commits + next.commits).map(\.id), ordered)
    }

    func testFetchUpdatesOnlyTheConfiguredUpstreamReference() async throws {
        let remote = try GitFixture()
        try remote.git("branch", "-m", "release")
        try remote.write("tracked.txt", "base\n")
        let base = try remote.commit("Base")

        let local = try GitFixture(initialize: false)
        try local.git("clone", "--origin", "team", "--branch", "release", remote.url.path, ".")
        try local.git("branch", "-m", "main")
        try local.git("branch", "untouched", base)
        try local.git("config", "--add", "remote.team.fetch", "+refs/heads/release:refs/heads/untouched")
        try local.git("config", "fetch.pruneTags", "true")
        try local.write("tracked.txt", "staged\n")
        try local.git("add", "tracked.txt")
        try local.write("tracked.txt", "working copy\n")
        try local.write("untracked.txt", "untracked\n")

        try remote.write("remote.txt", "new remote file\n")
        let remoteTip = try remote.commit("Remote update")
        try remote.git("tag", "remote-tag")
        try remote.git("branch", "unrelated")

        let protectedFiles = Set(["HEAD", "index", "config", "FETCH_HEAD"])
        func worktreeAndIndex() throws -> [String: GitFixture.SnapshotEntry] {
            try local.snapshot().filter { path, _ in
                guard let metadata = path.range(of: "/.git/") else { return true }
                return protectedFiles.contains(String(path[metadata.upperBound...]))
            }
        }
        let before = try worktreeAndIndex()

        try await git.fetchUpstream(in: local.repository)

        let head = try await git.head(in: local.repository)
        XCTAssertEqual(head, Head(branch: "main", commitID: base,
                                  upstream: Head.Upstream(name: "team/release", commitID: remoteTip)))
        let page = try await git.history(in: local.repository, headID: base, upstreamID: remoteTip, offset: 0)
        XCTAssertEqual(page.commits.map(\.id), [remoteTip, base])
        XCTAssertEqual(try local.git("rev-parse", "refs/heads/untouched"), base)
        XCTAssertEqual(try local.git("for-each-ref", "--format=%(refname)", "refs/tags", "refs/remotes/team/unrelated"), "")
        XCTAssertEqual(try worktreeAndIndex(), before)
    }

    func testGitHubRepositoryURLPrefersUpstreamAndConvertsCloneURLs() async throws {
        let fixture = try GitFixture()
        _ = try fixture.commit("Base")
        try fixture.git("remote", "add", "origin", "https://user:placeholder@github.com/Owner/Fork.git")
        try fixture.git("remote", "add", "team", "git@github.com:Team/Shared.git")
        try fixture.git("config", "branch.main.remote", "team")
        try fixture.git("config", "branch.main.merge", "refs/heads/main")

        let upstream = try await git.githubRepositoryURL(in: fixture.repository)
        XCTAssertEqual(upstream?.absoluteString, "https://github.com/Team/Shared")

        try fixture.git("remote", "set-url", "team", "ssh://git@ssh.github.com:443/Team/Shared.git")
        let ssh = try await git.githubRepositoryURL(in: fixture.repository)
        XCTAssertEqual(ssh, upstream)

        try fixture.git("remote", "set-url", "team", "https://github.com.example.invalid/Team/Shared.git")
        let fallback = try await git.githubRepositoryURL(in: fixture.repository)
        XCTAssertEqual(fallback?.absoluteString, "https://github.com/Owner/Fork")

        try fixture.git("remote", "set-url", "origin", "https://github.com/Owner/%2E%2E")
        let unsupported = try await git.githubRepositoryURL(in: fixture.repository)
        XCTAssertNil(unsupported)
    }

    func testHistoryCombinesCurrentBranchAndItsConfiguredRemote() async throws {
        let fixture = try GitFixture()
        let base = try fixture.commit("Common base")
        try fixture.git("remote", "add", "team", fixture.url.path)
        try fixture.git("config", "branch.main.remote", "team")
        try fixture.git("config", "branch.main.merge", "refs/heads/release")
        let trackingRef = "refs/remotes/team/release"

        let missing = try await git.head(in: fixture.repository)
        XCTAssertEqual(missing.upstream, Head.Upstream(name: "team/release", commitID: nil))
        try fixture.git("update-ref", trackingRef, base)
        let synced = try await git.head(in: fixture.repository)
        XCTAssertEqual(synced.upstream?.commitID, synced.commitID)
        let syncedPage = try await git.history(in: fixture.repository, headID: base, upstreamID: base, offset: 0)
        XCTAssertEqual(syncedPage.commits.map(\.id), [base])

        let localBase = try fixture.commit("Local ahead")
        let ahead = try await git.head(in: fixture.repository)
        XCTAssertEqual(ahead, Head(branch: "main", commitID: localBase,
                                   upstream: Head.Upstream(name: "team/release", commitID: base)))
        let aheadPage = try await git.history(in: fixture.repository, headID: localBase,
                                             upstreamID: ahead.upstream?.commitID, offset: 0)
        XCTAssertEqual(aheadPage.commits.map(\.id), [localBase, base])

        try fixture.git("switch", "-c", "remote-fixture")
        try fixture.write("only-remote.txt", "remote contents")
        let remote = try fixture.commit("Remote ahead")
        try fixture.git("switch", "main")
        try fixture.git("update-ref", trackingRef, remote)
        let behind = try await git.head(in: fixture.repository)
        let behindPage = try await git.history(in: fixture.repository, headID: localBase,
                                              upstreamID: behind.upstream?.commitID, offset: 0)
        XCTAssertEqual(behindPage.commits.map(\.id), [remote, localBase, base])

        let local = try fixture.commit("Local divergence")
        let before = try fixture.snapshot()
        let diverged = try await git.head(in: fixture.repository)
        XCTAssertEqual(diverged.commitID, local)
        XCTAssertEqual(diverged.upstream, Head.Upstream(name: "team/release", commitID: remote))
        let page = try await git.history(in: fixture.repository, headID: local,
                                        upstreamID: diverged.upstream?.commitID, offset: 0)
        XCTAssertEqual(page.commits.count, 4)
        XCTAssertEqual(Set(page.commits.prefix(2).map(\.id)), [local, remote])
        XCTAssertEqual(page.commits.suffix(2).map(\.id), [localBase, base])
        let changes = try await git.changes(in: fixture.repository, commitID: remote)
        XCTAssertEqual(changes.map(\.path), [Data("only-remote.txt".utf8)])
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testGraphCarriesLanesAcrossPageAndJoinsSharedParent() {
        func commit(_ id: String, parents: [String]) -> Commit {
            Commit(id: id, shortID: id, author: "", authoredAt: Date(timeIntervalSince1970: 0),
                   subject: id, parentIDs: parents)
        }

        var graph = CommitGraph(localHeadID: "merge", remoteHeadID: "side")
        graph.append([
            commit("merge", parents: ["main", "side"]),
            commit("main", parents: ["base"])
        ])
        XCTAssertEqual(graph.rows[0].parents.map(\.toLane), [0, 1])
        XCTAssertEqual(graph.rows[0].color, .localHead)
        XCTAssertEqual(graph.rows[1].color, .localHead)
        XCTAssertEqual(graph.rows[1].passing.map(\.toLane), [1])

        graph.append([commit("side", parents: ["base"]), commit("base", parents: [])])
        XCTAssertEqual(graph.laneCount, 2)
        XCTAssertNotNil(graph.rows[2].incomingColor)
        XCTAssertEqual(graph.rows[2].color, .remoteHead)
        XCTAssertEqual(graph.rows[2].lane, 1)
        XCTAssertEqual(graph.rows[2].parents.map(\.toLane), [0])
        XCTAssertEqual(graph.rows[2].parents.map(\.color), [.remoteHead])
        XCTAssertEqual(graph.rows[2].passing.map(\.toLane), [0])
        XCTAssertEqual(graph.rows[3].incomingColor, .localHead)
        XCTAssertTrue(graph.rows[3].parents.isEmpty)
    }

    func testFileAndDirectoryWithSamePathHaveDifferentIDs() {
        let tree = FileNode.tree(from: [
            FileChange(kind: .deleted, path: Data("node".utf8), previousPath: nil),
            FileChange(kind: .added, path: Data("node/child".utf8), previousPath: nil)
        ])
        XCTAssertEqual(tree.map(\.name), ["node", "node"])
        XCTAssertEqual(tree.map(\.id.isDirectory), [true, false])
        XCTAssertNotEqual(tree.first?.id, tree.last?.id)
    }
}

final class GitFixture {
    let url: URL
    var repository: Repository { Repository(path: url.path) }

    init(initialize: Bool = true) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BKGitClient-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if initialize { try git("-c", "init.templateDir=", "init", "--initial-branch=main") }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relativePath: String, _ content: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    func commit(_ subject: String) throws -> String {
        try git("add", "-A")
        try git("commit", "--allow-empty", "-m", subject)
        return try git("rev-parse", "HEAD")
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.currentDirectoryURL = url
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=Fixture Author", "-c", "user.email=fixture@example.test",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"
        ] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitFailure.command(output) }
        return output.trimmingCharacters(in: .newlines)
    }

    struct SnapshotEntry: Equatable {
        let data: Data
        let modificationDate: Date?
    }

    func snapshot() throws -> [String: SnapshotEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)))
        var snapshot: [String: SnapshotEntry] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            let data: Data
            if values.isSymbolicLink == true {
                data = try Data(FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)
            } else if values.isRegularFile == true {
                data = try Data(contentsOf: file)
            } else {
                continue
            }
            snapshot[file.path] = SnapshotEntry(data: data, modificationDate: values.contentModificationDate)
        }
        return snapshot
    }
}
