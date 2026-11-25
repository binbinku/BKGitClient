import XCTest
@testable import BKGitClient

@MainActor
final class MaterialTreeIconTests: XCTestCase {
    func testFileNamesSuffixesAndFallbackUseBundledIcons() {
        assertIcon("examples/DOCKERFILE", "docker")
        assertIcon("README.md", "readme")
        assertIcon("Sources/main.SWIFT", "swift")
        assertIcon("src/model.d.ts", "typescript-def")
        assertIcon("src/example.test.ts", "test-ts")
        assertIcon("instructions.md", "instructions")
        assertIcon("unrecognized.bk-unknown", "file")
    }

    func testFolderPathsExpansionAndLightVariants() {
        assertIcon("subproject/.github/workflows", "folder-gh-workflows", directory: true)
        assertIcon("subproject/.github/workflows", "folder-gh-workflows-open", directory: true, expanded: true)
        assertIcon("UnrecognizedDirectory", "folder-open", directory: true, expanded: true)
        assertIcon("project.toml", "toml_light", light: true)
        assertIcon("main.swift", "swift", light: true)
    }

    private func assertIcon(
        _ path: String, _ name: String, directory: Bool = false, expanded: Bool = false, light: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let id = FileNode.ID(path: Data(path.utf8), isDirectory: directory)
        XCTAssertEqual(MaterialTreeIcons.iconName(for: id, expanded: expanded, light: light), name,
                       file: file, line: line)
        XCTAssertNotNil(MaterialTreeIcons.image(for: id, expanded: expanded, light: light), file: file, line: line)
    }
}
