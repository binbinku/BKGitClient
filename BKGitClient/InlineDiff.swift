import Foundation

struct InlineDiff: Equatable, Sendable {
    struct CodeLine: Equatable, Sendable {
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
        let kind: FilePatch.Line.Kind
        var emphasis: Range<String.Index>?
    }

    enum Row: Equatable, Sendable {
        case hunk(String)
        case code(CodeLine)
        case note(String)
    }

    let rows: [Row]
    let lineNumberDigits: Int

    init?(lines: [FilePatch.Line]) {
        var rows: [Row] = []
        var oldNumber = 0
        var newNumber = 0
        var maximumNumber = 0
        var sawHunk = false
        var removals: [Int] = []
        var additions: [Int] = []

        func finishChange() {
            for (oldIndex, newIndex) in zip(removals, additions) {
                guard case .code(var old) = rows[oldIndex], case .code(var new) = rows[newIndex] else { continue }
                (old.emphasis, new.emphasis) = Self.changedRanges(old.text, new.text)
                rows[oldIndex] = .code(old)
                rows[newIndex] = .code(new)
            }
            removals.removeAll(keepingCapacity: true)
            additions.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.kind {
            case .hunk:
                finishChange()
                // Combined merge diffs have more than one old line number. Keep Git's original view for those.
                guard let numbers = Self.hunkStarts(line.text) else { return nil }
                (oldNumber, newNumber) = numbers
                sawHunk = true
                rows.append(.hunk(line.text))
            case .context, .addition, .removal:
                let text = line.text.dropFirst()
                let content = String(text.last == "\r" ? text.dropLast() : text)
                let old = line.kind == .addition ? nil : oldNumber
                let new = line.kind == .removal ? nil : newNumber
                if old != nil { oldNumber += 1 }
                if new != nil { newNumber += 1 }
                maximumNumber = max(maximumNumber, old ?? 0, new ?? 0)
                switch line.kind {
                case .context: finishChange()
                case .addition: additions.append(rows.count)
                case .removal: removals.append(rows.count)
                default: break
                }
                rows.append(.code(CodeLine(oldNumber: old, newNumber: new, text: content, kind: line.kind)))
            case .metadata:
                if line.text.hasPrefix("diff --") { finishChange() }
                if !["diff --", "index ", "--- ", "+++ "].contains(where: line.text.hasPrefix) {
                    rows.append(.note(line.text))
                }
            }
        }
        finishChange()
        guard sawHunk else { return nil }
        self.rows = rows
        lineNumberDigits = String(maximumNumber).count
    }

    private static func hunkStarts(_ header: String) -> (Int, Int)? {
        let fields = header.split(separator: " ", maxSplits: 4)
        guard fields.count >= 4, fields[0] == "@@", fields[3] == "@@",
              fields[1].first == "-", fields[2].first == "+",
              let old = Int(fields[1].dropFirst().prefix { $0 != "," }),
              let new = Int(fields[2].dropFirst().prefix { $0 != "," }) else { return nil }
        return (old, new)
    }

    private static func changedRanges(_ old: String, _ new: String) -> (Range<String.Index>?, Range<String.Index>?) {
        var oldStart = old.startIndex
        var newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex, old[oldStart] == new[newStart] {
            old.formIndex(after: &oldStart)
            new.formIndex(after: &newStart)
        }

        var oldEnd = old.endIndex
        var newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let oldLast = old.index(before: oldEnd)
            let newLast = new.index(before: newEnd)
            guard old[oldLast] == new[newLast] else { break }
            oldEnd = oldLast
            newEnd = newLast
        }
        // The line background already marks a whole-line replacement.
        if oldStart == old.startIndex, newStart == new.startIndex, oldEnd == old.endIndex, newEnd == new.endIndex {
            return (nil, nil)
        }
        return (oldStart < oldEnd ? oldStart..<oldEnd : nil, newStart < newEnd ? newStart..<newEnd : nil)
    }
}
