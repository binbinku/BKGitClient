import Foundation

enum ChangeKind: Equatable, Sendable {
    case added, modified, deleted, renamed, typeChanged, copied, conflicted, other

    init(code: UInt8) {
        switch code {
        case 65: self = .added
        case 77: self = .modified
        case 68: self = .deleted
        case 82: self = .renamed
        case 84: self = .typeChanged
        case 67: self = .copied
        default: self = .other
        }
    }
}

struct FileChange: Equatable, Sendable {
    let kind: ChangeKind
    let path: Data
    let previousPath: Data?
}

struct WorktreeFile: Equatable, Sendable {
    let section: WorktreeSection
    let change: FileChange
}

struct WorktreeTree: Sendable {
    let nodes: [FileNode]
    private let filesByPath: [Data: [WorktreeFile]]

    init(changes: [WorktreeSection: [FileChange]]) {
        var filesByPath: [Data: [WorktreeFile]] = [:]
        for section in WorktreeSection.allCases {
            for change in changes[section] ?? [] {
                filesByPath[change.path, default: []].append(WorktreeFile(section: section, change: change))
            }
        }
        self.filesByPath = filesByPath
        nodes = FileNode.tree(from: filesByPath.values.compactMap { $0.first?.change })
    }

    func versions(at path: Data) -> [WorktreeFile] {
        filesByPath[path] ?? []
    }
}

struct FileNode: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let path: Data
        let isDirectory: Bool
    }

    let id: ID
    let name: String
    let children: [FileNode]
    let change: FileChange?

    static func displayPath(_ path: Data) -> String {
        String(decoding: path, as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func tree(from changes: [FileChange]) -> [FileNode] {
        let root = Directory(path: Data())
        for change in changes {
            var directory = root
            let components = change.path.split(separator: 47)
            guard let name = components.last else { continue }
            for component in components.dropLast() {
                if let existing = directory.subdirectories[component] {
                    directory = existing
                } else {
                    var path = directory.path
                    if !path.isEmpty { path.append(47) }
                    path.append(component)
                    let child = Directory(path: path)
                    directory.subdirectories[component] = child
                    directory = child
                }
            }
            directory.files.append(FileNode(
                id: ID(path: change.path, isDirectory: false),
                name: displayPath(name), children: [], change: change
            ))
        }
        return root.nodes
    }

    private final class Directory {
        let path: Data
        var subdirectories: [Data: Directory] = [:]
        var files: [FileNode] = []

        init(path: Data) { self.path = path }

        var nodes: [FileNode] {
            let directories = subdirectories.map { name, directory in
                FileNode(id: ID(path: directory.path, isDirectory: true),
                         name: displayPath(name), children: directory.nodes, change: nil)
            }
            return directories.sorted(by: Self.byName) + files.sorted(by: Self.byName)
        }

        private static func byName(_ first: FileNode, _ second: FileNode) -> Bool {
            let comparison = first.name.localizedStandardCompare(second.name)
            if comparison == .orderedSame { return first.id.path.lexicographicallyPrecedes(second.id.path) }
            return comparison == .orderedAscending
        }
    }
}
