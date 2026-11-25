import Foundation
import XCTest
@testable import BKGitClient

@MainActor
final class BrowserModelTests: XCTestCase {
    func testBrowserFrameUsesTheSelectedDisplaysOriginAndSize() {
        let display = CGRect(x: -1440, y: 240, width: 1440, height: 1080)
        let frame = BKGitClientApp.centeredFrame(in: display)

        XCTAssertEqual(frame.size, CGSize(width: 1152, height: 900))
        XCTAssertEqual(frame.midX, display.midX)
        XCTAssertEqual(frame.midY, display.midY)
    }

    func testProjectsSelectionRefreshAndMovedRepository() async throws {
        let first = try GitFixture()
        try first.write("nested/one.txt", "first")
        let original = try first.commit("First project")
        let second = try GitFixture()
        let other = try second.commit("Second project")

        let suite = "BKGitClient-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = BrowserModel(defaults: defaults)
        await model.addRepository(at: first.url.appendingPathComponent("nested"))
        try await waitUntil { model.selectedCommit?.id == original }
        await model.addRepository(at: first.url)
        XCTAssertEqual(model.repositories, [first.repository])

        await model.addRepository(at: second.url)
        try await waitUntil { model.selectedCommit?.id == other }
        model.selectRepository(first.repository)
        model.selectRepository(second.repository)
        model.selectRepository(first.repository)
        try await waitUntil { model.selectedCommit?.id == original }
        XCTAssertEqual(model.repositories, [first.repository, second.repository])

        let newTip = try first.commit("New tip")
        model.refresh()
        try await waitUntil {
            guard case .loaded(let graph) = model.history else { return false }
            return graph.rows.first?.id == newTip && model.selectedCommit?.id == original
        }

        let restored = BrowserModel(defaults: defaults)
        XCTAssertEqual(restored.repositories, model.repositories)
        XCTAssertEqual(restored.repository, first.repository)
        restored.refresh()
        try await waitUntil { restored.selectedCommit?.id == newTip }

        let moved = first.url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: first.url, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        restored.refresh()
        try await waitUntil {
            if case .failed = restored.history { return true }
            return false
        }
        XCTAssertTrue(restored.repositories.contains(first.repository))
        restored.removeCurrentRepository()
        try await waitUntil { restored.selectedCommit?.id == other }
        XCTAssertEqual(restored.repositories, [second.repository])
        let afterRemoval = BrowserModel(defaults: defaults)
        XCTAssertEqual(afterRemoval.repository, second.repository)
    }

    func testQuickPickerUsesRecentProjectsAndPreservesExistingPreferences() throws {
        let first = try GitFixture()
        let second = try GitFixture()
        let third = try GitFixture()
        let added = [first.repository, second.repository, third.repository]
        let suite = "BKGitClient-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(added), forKey: "repositories")
        defaults.set(second.repository.id, forKey: "selectedRepository")

        let model = BrowserModel(defaults: defaults)
        XCTAssertEqual(model.repositoriesByRecency, [second.repository, first.repository, third.repository])
        model.selectRepository(third.repository)
        model.selectRepository(first.repository)
        model.selectRepository(third.repository)

        let restored = BrowserModel(defaults: defaults)
        XCTAssertEqual(restored.repositories, added)
        XCTAssertEqual(restored.repositoriesByRecency, [third.repository, first.repository, second.repository])

        restored.removeCurrentRepository()
        XCTAssertEqual(BrowserModel(defaults: defaults).repositoriesByRecency, [first.repository, second.repository])
    }

    func testWorktreeShowsOneTreeAndSwitchesDiffVersionsForOneFile() async throws {
        let fixture = try GitFixture()
        try fixture.write("src/existing.txt", "original\n")
        _ = try fixture.commit("Base")
        try fixture.write("src/existing.txt", "staged\n")
        try fixture.git("add", "--", "src/existing.txt")
        try fixture.write("src/existing.txt", "unstaged\n")
        try fixture.write("src/new.txt", "untracked\n")
        let before = try fixture.snapshot()

        let suite = "BKGitClient-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(defaults: defaults)
        model.selectRepository(fixture.repository)
        model.selectPage(.worktree)
        try await waitUntil {
            if case .loaded = model.worktree { return true }
            return false
        }
        guard case .loaded(let tree) = model.worktree else { return XCTFail("Missing worktree") }
        XCTAssertEqual(tree.nodes.map(\.name), ["src"])
        XCTAssertEqual(tree.nodes.first?.children.map(\.name), ["existing.txt", "new.txt"])

        let existing = Data("src/existing.txt".utf8)
        let new = Data("src/new.txt".utf8)
        XCTAssertEqual(tree.versions(at: existing).map(\.section), [.staged, .unstaged])
        XCTAssertEqual(tree.versions(at: new).map(\.section), [.untracked])

        model.selectWorktreePath(existing)
        try await waitUntil {
            guard case .loaded(let patch) = model.worktreePatch else { return false }
            return patch.lines.contains { $0.text == "+unstaged" }
        }
        model.selectWorktreeVersion(.staged)
        try await waitUntil {
            guard case .loaded(let patch) = model.worktreePatch else { return false }
            return patch.lines.contains { $0.text == "+staged" }
        }
        model.selectWorktreePath(new)
        try await waitUntil {
            guard case .loaded(let patch) = model.worktreePatch else { return false }
            return patch.lines.contains { $0.text == "+untracked" }
        }
        XCTAssertEqual(model.worktreeFile?.section, .untracked)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testProjectFilesReadTextWithoutFollowingLinksOrExposingGitMetadata() throws {
        let fixture = try GitFixture()
        let outside = try GitFixture(initialize: false)
        try fixture.write("Sources/example.swift", "let message = \"你好\"\n")
        try fixture.write(".gitignore", "ignored.txt\n")
        try fixture.write("ignored.txt", "local project file\n")
        try outside.write("external.txt", "outside the project\n")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.url.appendingPathComponent("external").path, withDestinationPath: outside.url.path
        )
        try Data([0, 1, 2]).write(to: fixture.url.appendingPathComponent("binary.dat"))
        let utf16 = Data([0xff, 0xfe]) + Data("UTF-16 内容\n".utf16.flatMap { [$0 & 0xff, $0 >> 8].map(UInt8.init) })
        try utf16.write(to: fixture.url.appendingPathComponent("utf16.txt"))
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: fixture.url.appendingPathComponent("large.txt"))
        let before = try fixture.snapshot()

        let root = try ProjectFiles.list(in: fixture.repository)
        XCTAssertEqual(root.first?.name, "Sources")
        XCTAssertFalse(root.contains { $0.name == ".git" })
        XCTAssertTrue(root.contains { $0.name == ".gitignore" })
        XCTAssertTrue(root.contains { $0.name == "ignored.txt" })
        let child = try XCTUnwrap(try ProjectFiles.list(in: fixture.repository, path: "Sources").first)
        XCTAssertEqual(child.path, "Sources/example.swift")
        XCTAssertEqual(try ProjectFiles.read(child, in: fixture.repository).text, "let message = \"你好\"\n")
        let unicode = try XCTUnwrap(root.first { $0.name == "utf16.txt" })
        XCTAssertEqual(try ProjectFiles.read(unicode, in: fixture.repository).text, "UTF-16 内容\n")

        let binary = try XCTUnwrap(root.first { $0.name == "binary.dat" })
        let large = try XCTUnwrap(root.first { $0.name == "large.txt" })
        XCTAssertThrowsError(try ProjectFiles.read(binary, in: fixture.repository)) {
            XCTAssertEqual($0 as? ProjectFileError, .unsupportedFile)
        }
        XCTAssertThrowsError(try ProjectFiles.read(large, in: fixture.repository)) {
            XCTAssertEqual($0 as? ProjectFileError, .tooLarge)
        }
        XCTAssertThrowsError(try ProjectFiles.list(in: fixture.repository, path: "external"))
        XCTAssertThrowsError(try ProjectFiles.list(in: fixture.repository, path: ".git"))
        XCTAssertThrowsError(try ProjectFiles.read(
            ProjectFile(path: "external/external.txt", name: "external.txt", kind: .file), in: fixture.repository
        ))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testMarkdownImageReadsOnlyValidatedProjectFiles() throws {
        let fixture = try GitFixture()
        let outside = try GitFixture(initialize: false)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQTp0BAAHPASH9HA8SAAAAAElFTkSuQmCC"
        ))
        try fixture.write("docs/guide/Readme.MARKDOWN", "# Preview")
        try fixture.write("docs/fake.png", "plain text")
        try png.write(to: fixture.url.appendingPathComponent("docs/截图 1.png"))
        try png.write(to: outside.url.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(
            atPath: fixture.url.appendingPathComponent("docs/link.png").path,
            withDestinationPath: outside.url.appendingPathComponent("image.png").path
        )
        try png.write(to: fixture.url.appendingPathComponent(".git/image.png"))
        let before = try fixture.snapshot()
        let file = ProjectFile(path: "docs/guide/Readme.MARKDOWN", name: "Readme.MARKDOWN", kind: .file)
        XCTAssertTrue(file.isMarkdown)
        let document = try ProjectFiles.read(file, in: fixture.repository)
        let image = try ProjectFiles.markdownImage("../%E6%88%AA%E5%9B%BE%201.png", relativeTo: document)
        XCTAssertEqual(image.data, png)
        XCTAssertEqual(image.mimeType, "image/png")
        for reference in [
            "https://example.test/image.png", "//example.test/image.png", "file:///tmp/image.png",
            "/docs/截图%201.png", "../../../image.png", "../../%2e%2e/image.png",
            "../../.git/image.png", "../../%2eGiT/image.png", "../link.png", "../fake.png"
        ] {
            XCTAssertThrowsError(try ProjectFiles.markdownImage(reference, relativeTo: document), reference)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testProjectTreeExpandsNestedFoldersWithoutFollowingLinks() async throws {
        let fixture = try GitFixture()
        let outside = try GitFixture(initialize: false)
        try fixture.write("Sources/Deep/file.txt", "inside\n")
        try outside.write("hidden/secret.txt", "outside\n")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.url.appendingPathComponent("link").path, withDestinationPath: outside.url.path
        )
        let before = try fixture.snapshot()
        let model = ProjectFilesModel()
        model.open(fixture.repository)
        try await waitUntil {
            if case .loaded = model.folders[""] { return true }
            return false
        }
        model.expandAll()
        try await waitUntil { !model.expandingAll && model.expanded == ["Sources", "Sources/Deep"] }
        guard case .loaded(let children) = model.folders["Sources/Deep"] else {
            return XCTFail("Nested directory was not loaded")
        }
        XCTAssertEqual(children.map(\.name), ["file.txt"])
        XCTAssertNil(model.folders["link"])
        XCTAssertNil(model.folders[".git"])

        model.expandAll()
        model.collapseAll()
        model.refresh()
        try await waitUntil {
            if case .loaded = model.folders[""] { return true }
            return false
        }
        XCTAssertFalse(model.expandingAll)
        XCTAssertTrue(model.expanded.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else {
                throw GitFailure.command("Timed out waiting for the browser state")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
