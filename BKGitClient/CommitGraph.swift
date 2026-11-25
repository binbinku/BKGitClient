struct CommitGraph {
    enum LaneColor: Equatable {
        case localHead
        case remoteHead
        case branch(Int)
    }

    struct Connection: Equatable {
        let fromLane: Int
        let toLane: Int
        let color: LaneColor
    }

    struct Row: Identifiable {
        let commit: Commit
        let lane: Int
        let color: LaneColor
        let incomingColor: LaneColor?
        let passing: [Connection]
        let parents: [Connection]

        var id: String { commit.id }
    }

    private struct Lane {
        let id: String
        let color: LaneColor
    }

    private(set) var rows: [Row] = []
    private(set) var laneCount = 1
    private var pending: [Lane] = []
    private var nextColor = 0
    private let localHeadID: String?
    private let remoteHeadID: String?

    init(localHeadID: String? = nil, remoteHeadID: String? = nil) {
        self.localHeadID = localHeadID
        self.remoteHeadID = remoteHeadID
    }

    mutating func append(_ commits: [Commit]) {
        for commit in commits {
            let laneIndex = pending.firstIndex { $0.id == commit.id } ?? pending.count
            let hasIncoming = laneIndex < pending.count
            let incomingColor = hasIncoming ? pending[laneIndex].color : nil
            let color = headColor(for: commit.id) ?? incomingColor ?? allocateColor()
            var outgoing = pending
            if hasIncoming { outgoing.remove(at: laneIndex) }

            // Replace the current lane with its first new parent, then add lanes for other parents.
            // A parent already in flight keeps its lane so separate paths can converge on it.
            var insertion = laneIndex
            for (index, parent) in commit.parentIDs.enumerated() where !outgoing.contains(where: { $0.id == parent }) {
                let parentColor = index == 0 ? color : allocateColor()
                outgoing.insert(Lane(id: parent, color: parentColor), at: insertion)
                insertion += 1
            }

            let destinations = Dictionary(uniqueKeysWithValues: outgoing.enumerated().map { ($1.id, $0) })
            let passing = pending.enumerated().compactMap { index, lane -> Connection? in
                guard index != laneIndex, let target = destinations[lane.id] else { return nil }
                return Connection(fromLane: index, toLane: target, color: lane.color)
            }
            let parents = commit.parentIDs.enumerated().compactMap { index, id -> Connection? in
                guard let target = destinations[id] else { return nil }
                let edgeColor = index == 0 ? color : outgoing[target].color
                return Connection(fromLane: laneIndex, toLane: target, color: edgeColor)
            }

            rows.append(Row(commit: commit, lane: laneIndex, color: color, incomingColor: incomingColor,
                            passing: passing, parents: parents))
            laneCount = max(laneCount, laneIndex + 1, outgoing.count)
            pending = outgoing
        }
    }

    private func headColor(for id: String) -> LaneColor? {
        if id == localHeadID { return .localHead }
        if id == remoteHeadID { return .remoteHead }
        return nil
    }

    private mutating func allocateColor() -> LaneColor {
        defer { nextColor += 1 }
        return .branch(nextColor)
    }
}
