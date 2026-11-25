import AppKit

@MainActor
enum MaterialTreeIcons {
    private static let resources = Bundle.main.resourceURL?.appendingPathComponent("MaterialIconTheme")
    private static let manifest: Manifest? = {
        guard let url = resources?.appendingPathComponent("dist/material-icons.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()
    private static let images = NSCache<NSString, NSImage>()

    static func image(for id: FileNode.ID, expanded: Bool, light: Bool) -> NSImage? {
        guard let manifest, let resources else { return nil }
        let name = iconName(for: id, expanded: expanded, light: light)
        guard let asset = name.flatMap({ manifest.iconDefinitions[$0]?.iconPath }) else { return nil }

        let key = asset as NSString
        if let cached = images.object(forKey: key) { return cached }
        let url = resources.appendingPathComponent("dist").appendingPathComponent(asset).standardizedFileURL
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    static func iconName(for id: FileNode.ID, expanded: Bool, light: Bool) -> String? {
        guard let manifest else { return nil }
        let path = String(decoding: id.path, as: UTF8.self).lowercased()
        if id.isDirectory {
            let names = expanded ? manifest.base.folderNamesExpanded : manifest.base.folderNames
            let variants = expanded ? manifest.light.folderNamesExpanded : manifest.light.folderNames
            return match(path, separator: "/", names: names, variants: light ? variants : [:])
                ?? (expanded ? manifest.folderExpanded : manifest.folder)
        }

        if let named = match(path, separator: "/", names: manifest.base.fileNames,
                             variants: light ? manifest.light.fileNames : [:]) {
            return named
        }
        let filename = path.split(separator: "/").last ?? ""
        guard let dot = filename.firstIndex(of: ".") else { return manifest.file }
        return match(String(filename[filename.index(after: dot)...]), separator: ".",
                     names: manifest.base.fileExtensions, variants: light ? manifest.light.fileExtensions : [:])
            ?? manifest.file
    }

    private static func match(_ value: String, separator: Character,
                              names: [String: String], variants: [String: String]) -> String? {
        var suffix = value[...]
        while !suffix.isEmpty {
            let key = String(suffix)
            if let icon = variants[key] ?? names[key] { return icon }
            guard let next = suffix.firstIndex(of: separator) else { break }
            suffix = suffix[suffix.index(after: next)...]
        }
        return nil
    }

    private struct Manifest: Decodable {
        struct Definition: Decodable {
            let iconPath: String
        }

        let iconDefinitions: [String: Definition]
        let file: String
        let folder: String
        let folderExpanded: String
        let base: Associations
        let light: Associations

        private enum CodingKeys: String, CodingKey {
            case iconDefinitions, file, folder, folderExpanded, light
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            iconDefinitions = try fields.decode([String: Definition].self, forKey: .iconDefinitions)
            file = try fields.decode(String.self, forKey: .file)
            folder = try fields.decode(String.self, forKey: .folder)
            folderExpanded = try fields.decode(String.self, forKey: .folderExpanded)
            base = try Associations(from: decoder)
            light = try fields.decode(Associations.self, forKey: .light)
        }
    }

    private struct Associations: Decodable {
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]

        private enum CodingKeys: String, CodingKey {
            case fileNames, fileExtensions, folderNames, folderNamesExpanded
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            func normalized(_ field: CodingKeys) throws -> [String: String] {
                let names = try fields.decode([String: String].self, forKey: field)
                return names.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
            }
            fileNames = try normalized(.fileNames)
            fileExtensions = try normalized(.fileExtensions)
            folderNames = try normalized(.folderNames)
            folderNamesExpanded = try normalized(.folderNamesExpanded)
        }
    }
}
