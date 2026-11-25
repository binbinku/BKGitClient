import Combine
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProjectFile: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case directory, file, symbolicLink
    }

    let path: String
    let name: String
    let kind: Kind

    var id: String { path }
    var isMarkdown: Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return fileExtension == "md" || fileExtension == "markdown"
    }
}

struct ProjectDocument: Sendable {
    let id = UUID()
    let repository: Repository
    let file: ProjectFile
    let text: String
}

struct MarkdownImage: Sendable {
    let data: Data
    let mimeType: String

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

enum ProjectFileError: LocalizedError, Equatable {
    case invalidPath, symbolicLink, unsupportedFile, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPath: "无法访问此项目路径。"
        case .symbolicLink: "符号链接不在文件预览范围内。"
        case .unsupportedFile: "此文件不是可预览的 UTF-8 或 UTF-16 文本。"
        case .tooLarge: "文件超过 2 MiB，无法预览。"
        }
    }
}

enum ProjectFiles {
    private static let maximumSize = 2 * 1024 * 1024

    static func list(in repository: Repository, path: String = "") throws -> [ProjectFile] {
        let descriptor = try openPath(path, in: repository, directory: true)
        guard let directory = fdopendir(descriptor) else {
            let error = fileError()
            Darwin.close(descriptor)
            throw error
        }
        defer { closedir(directory) }

        var files: [ProjectFile] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw fileError() }
                break
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
            }
            guard let name, allowedComponent(name) else { continue }

            let kind: ProjectFile.Kind
            switch Int32(entry.pointee.d_type) {
            case DT_DIR: kind = .directory
            case DT_REG: kind = .file
            case DT_LNK: kind = .symbolicLink
            case DT_UNKNOWN:
                var metadata = stat()
                guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR: kind = .directory
                case S_IFREG: kind = .file
                case S_IFLNK: kind = .symbolicLink
                default: continue
                }
            default: continue
            }
            files.append(ProjectFile(path: path.isEmpty ? name : "\(path)/\(name)", name: name, kind: kind))
        }
        return files.sorted { left, right in
            if (left.kind == .directory) != (right.kind == .directory) { return left.kind == .directory }
            let order = left.name.localizedStandardCompare(right.name)
            if order == .orderedSame { return left.name.utf8.lexicographicallyPrecedes(right.name.utf8) }
            return order == .orderedAscending
        }
    }

    static func scan(in repository: Repository, expanding directories: Set<String>?) -> [String: LoadState<[ProjectFile]>] {
        var pending = [""]
        var folders: [String: LoadState<[ProjectFile]>] = [:]
        while !Task.isCancelled, let path = pending.popLast() {
            do {
                let entries = try list(in: repository, path: path)
                folders[path] = .loaded(entries)
                pending.append(contentsOf: entries.lazy.filter {
                    $0.kind == .directory && (directories?.contains($0.path) ?? true)
                }.map(\.path))
            } catch {
                folders[path] = .failed(error.localizedDescription)
            }
        }
        return folders
    }

    static func read(_ file: ProjectFile, in repository: Repository) throws -> ProjectDocument {
        guard file.kind != .symbolicLink else { throw ProjectFileError.symbolicLink }
        guard file.kind == .file else { throw ProjectFileError.unsupportedFile }
        let data = try readBytes(at: file.path, in: repository, limit: maximumSize)
        let text: String?
        if data.starts(with: [0xff, 0xfe]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xfe, 0xff]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: {
            $0.value < 32 && ![9, 10, 12, 13].contains($0.value)
        }) else { throw ProjectFileError.unsupportedFile }
        return ProjectDocument(repository: repository, file: file, text: text)
    }

    static func markdownImage(_ reference: String, relativeTo document: ProjectDocument) throws -> MarkdownImage {
        guard let url = URLComponents(string: reference), url.scheme == nil, url.host == nil,
              let relative = url.percentEncodedPath.removingPercentEncoding,
              !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else {
            throw ProjectFileError.invalidPath
        }

        var parts = document.file.path.split(separator: "/").dropLast().map(String.init)
        for component in relative.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard parts.popLast() != nil else { throw ProjectFileError.invalidPath }
            default:
                let name = String(component)
                guard allowedComponent(name) else { throw ProjectFileError.invalidPath }
                parts.append(name)
            }
        }
        let data = try readBytes(at: parts.joined(separator: "/"), in: document.repository, limit: 8 * 1024 * 1024)
        // Only pass validated bitmap data to WebKit. It never gets an address on disk.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let mimeType = UTType(type as String)?.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 40_000_000 else {
            throw ProjectFileError.unsupportedFile
        }
        return MarkdownImage(data: data, mimeType: mimeType)
    }

    private static func readBytes(at path: String, in repository: Repository, limit: Int) throws -> Data {
        let descriptor = try openPath(path, in: repository, directory: false)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw fileError() }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ProjectFileError.unsupportedFile }
        guard metadata.st_size <= limit else { throw ProjectFileError.tooLarge }

        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { throw ProjectFileError.tooLarge }
        }
        return data
    }

    private static func openPath(_ path: String, in repository: Repository, directory: Bool) throws -> Int32 {
        let components = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false)
        guard (directory || !components.isEmpty), components.allSatisfy({ allowedComponent(String($0)) }) else {
            throw ProjectFileError.invalidPath
        }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open(repository.path, flags | O_DIRECTORY)
        guard descriptor >= 0 else { throw fileError() }
        for (index, component) in components.enumerated() {
            let mustBeDirectory = directory || index < components.count - 1
            // Open each component relative to an already-open directory and never follow symbolic links.
            let next = openat(descriptor, String(component), flags | (mustBeDirectory ? O_DIRECTORY : O_NONBLOCK))
            if next < 0 {
                let error = fileError()
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func allowedComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.lowercased() != ".git" && !name.utf8.contains(0)
    }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@MainActor
final class ProjectFilesModel: ObservableObject {
    @Published private(set) var folders: [String: LoadState<[ProjectFile]>] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var expandingAll = false
    @Published private(set) var selected: ProjectFile?
    @Published private(set) var document: LoadState<ProjectDocument> = .idle

    private var repository: Repository?
    private var folderTasks: [String: Task<Void, Never>] = [:]
    private var scanTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?

    func open(_ repository: Repository?) {
        guard repository != self.repository else { return }
        cancelScan()
        folderTasks.values.forEach { $0.cancel() }
        folderTasks.removeAll()
        documentTask?.cancel()
        self.repository = repository
        folders = [:]
        expanded = []
        selected = nil
        document = .idle
        if repository != nil { loadFolder("") }
    }

    func refresh() {
        guard repository != nil else { return }
        if expanded.isEmpty {
            cancelScan()
            loadFolder("")
        } else {
            scan(expanding: expanded)
        }
        if let selected { loadFile(selected) }
    }

    func toggle(_ directory: ProjectFile) {
        cancelScan()
        if expanded.contains(directory.path) {
            expanded.remove(directory.path)
        } else {
            expanded.insert(directory.path)
            if folders[directory.path] == nil { loadFolder(directory.path) }
        }
    }

    func expandAll() {
        guard !expandingAll else { return }
        scan(expanding: nil)
    }

    func collapseAll() {
        cancelScan()
        expanded.removeAll()
    }

    func cancelScan() {
        guard let scanTask else { return }
        scanTask.cancel()
        self.scanTask = nil
        expandingAll = false
    }

    private func scan(expanding directories: Set<String>?) {
        guard let repository else { return }
        cancelScan()
        expandingAll = directories == nil
        let reader = Task.detached(priority: .utility) {
            ProjectFiles.scan(in: repository, expanding: directories)
        }
        scanTask = Task {
            let result = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
            guard !Task.isCancelled else { return }
            folderTasks.values.forEach { $0.cancel() }
            folderTasks.removeAll()
            folders = result
            expanded = Set(result.keys.filter { !$0.isEmpty })
            expandingAll = false
            scanTask = nil
        }
    }

    func loadFolder(_ path: String) {
        guard let repository else { return }
        folderTasks[path]?.cancel()
        folders[path] = .loading
        folderTasks[path] = Task {
            defer { if !Task.isCancelled { folderTasks[path] = nil } }
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try ProjectFiles.list(in: repository, path: path)
                }.value
                try Task.checkCancellation()
                folders[path] = .loaded(files)
            } catch {
                guard !Task.isCancelled else { return }
                folders[path] = .failed(error.localizedDescription)
            }
        }
    }

    func select(_ file: ProjectFile) {
        guard selected != file else { return }
        loadFile(file)
    }

    func retryFile() {
        if let selected { loadFile(selected) }
    }

    private func loadFile(_ file: ProjectFile) {
        guard let repository else { return }
        documentTask?.cancel()
        selected = file
        document = .loading
        documentTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectFiles.read(file, in: repository)
                }.value
                try Task.checkCancellation()
                document = .loaded(result)
            } catch {
                guard !Task.isCancelled else { return }
                document = .failed(error.localizedDescription)
            }
        }
    }
}
