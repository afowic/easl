import Foundation

/// What a diagram tile draws, computed from the code (`type: diagram`, `props.kind`). Each kind
/// has its own builder that fills a `DiagramGraph`; the tile, layout, freshness, mentions, and
/// arrow ends are shared.
public enum DiagramKind: String, CaseIterable, Codable, Sendable {
    /// The callers and callees of one function (LSP call hierarchy).
    case calls
    /// A caller-supplied knowledge or reasoning graph: premises, conclusions and the links
    /// between them, laid out one column per reasoning depth. Never computed from code.
    case graph
}

/// Which side of the root a call graph grows: its callers, its callees, or both.
public enum CallDirection: String, CaseIterable, Codable, Sendable {
    case incoming, outgoing, both

    var includesIncoming: Bool { self != .outgoing }
    var includesOutgoing: Bool { self != .incoming }
}

/// A diagram tile's props (schema `DiagramProps`).
public struct DiagramSpec: Equatable, Sendable {
    public static let defaultDepth = 2
    public static let maxDepth = 4
    /// The most nodes a caller-supplied graph may have. Calls graphs stop at
    /// `CallGraphBuilder.maxNodes`; a knowledge graph is authored on purpose, so it may be much
    /// larger while the layered layout and render stay bounded.
    public static let maxGraphNodes = 500
    public static let maxGraphEdges = 2000
    public static let maxGraphIDBytes = 256
    public static let maxGraphNodeLabelBytes = 512
    public static let maxGraphEdgeLabelBytes = 256
    public static let maxGraphDetailBytes = 8192
    public static let maxGraphSources = 8
    public static let maxGraphSourceFieldBytes = 256

    public var kind: DiagramKind
    /// The file declaring the root symbol: board-relative or absolute; nil to find `symbol`'s file.
    public var path: String?
    /// The root symbol, `Type.member` or a bare name (a function's parameter labels optional).
    public var symbol: String?
    /// 1-based line of the root's declaration (or inside its body) when there is no `symbol`.
    public var line: Int?
    public var direction: CallDirection
    /// Levels each side of the root shows unasked.
    public var depth: Int
    /// Nodes (`DiagramNode.id`) opened one more level than `depth` shows.
    public var expanded: [String]

    public init(kind: DiagramKind = .calls, path: String? = nil, symbol: String? = nil, line: Int? = nil, direction: CallDirection = .incoming,
                depth: Int = defaultDepth, expanded: [String] = []) {
        self.kind = kind
        self.path = path
        self.symbol = symbol
        self.line = line
        self.direction = direction
        self.depth = depth
        self.expanded = expanded
    }

    /// Lenient: what `validate` would reject reads as the default.
    public init(_ props: JSONValue) {
        func nonEmpty(_ key: String) -> String? { props[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(kind: props["kind"]?.string.flatMap(DiagramKind.init) ?? .calls, path: nonEmpty("path"), symbol: nonEmpty("symbol"),
                  line: props["line"]?.int.flatMap { $0 >= 1 ? $0 : nil },
                  direction: props["direction"]?.string.flatMap(CallDirection.init) ?? .incoming,
                  depth: min(max(props["depth"]?.int ?? Self.defaultDepth, 1), Self.maxDepth),
                  expanded: props["expanded"]?.array?.compactMap(\.string) ?? [])
    }

    /// The graph's subject: a graph computed for another aim is not this tile's past (no stale
    /// nodes carry over from it). Depth and expansions only change how much of it shows.
    public var aim: DiagramAim { DiagramAim(kind: kind, path: path, symbol: symbol, line: line, direction: direction) }

    /// The tile's title without `props.title`: `Callers of SocketServer.start`, naming the
    /// root as the props do (or as the graph resolved it).
    public static func title(_ props: JSONValue) -> String {
        if let title = props["title"]?.string, !title.isEmpty { return title }
        let spec = DiagramSpec(props)
        if spec.kind == .graph { return "Graph" }
        let graph = DiagramGraph(props["graph"])
        let root = spec.symbol ?? graph?.root.flatMap { graph?.node($0)?.qualifiedName } ?? spec.path.map { "\(PathLabel.short($0)):\(spec.line ?? 1)" } ?? "?"
        switch spec.direction {
        case .incoming: return "Callers of \(root)"
        case .outgoing: return "Calls from \(root)"
        case .both: return "Calls around \(root)"
        }
    }

    private struct GraphNodeInput {
        var id: String
        var label: String
        var detail: String?
        var level: Int?
        var sources: [DiagramSource]?
        var status: DiagramNodeStatus?
    }

    private struct GraphEdgeInput {
        var from: String
        var to: String
        var label: String?
    }

    private struct GraphEdgeEndpoints: Hashable {
        var from: String
        var to: String
    }

    /// A `kind: "graph"` diagram's graph as `object.create`/`update` will store it: the caller's
    /// nodes and edges with reasoning levels computed where omitted (longest path from a source
    /// node; premises 0). Failure names the rule broken.
    public static func graph(_ props: JSONValue) -> (graph: DiagramGraph?, problem: String?) {
        guard let input = props["graph"], input.object != nil else {
            return (nil, "a graph diagram needs props.graph.nodes and props.graph.edges")
        }
        guard let nodeValues = input["nodes"]?.array else {
            return (nil, "a graph diagram needs props.graph.nodes")
        }
        guard !nodeValues.isEmpty else { return (nil, "props.graph.nodes needs at least one node") }
        guard nodeValues.count <= maxGraphNodes else {
            return (nil, "props.graph.nodes has \(nodeValues.count) nodes: at most \(maxGraphNodes)")
        }
        var nodes: [GraphNodeInput] = []
        var ids: Set<String> = []
        for (index, value) in nodeValues.enumerated() {
            let path = "props.graph.nodes[\(index)]"
            guard let raw = value.object else { return (nil, "\(path) must be an object") }
            guard let id = raw["id"]?.string, !id.isEmpty else { return (nil, "\(path).id must be a non-empty string") }
            guard id.utf8.count <= maxGraphIDBytes else { return (nil, "\(path).id exceeds \(maxGraphIDBytes) UTF-8 bytes") }
            guard ids.insert(id).inserted else { return (nil, "duplicate node id \"\(id)\"") }
            let label = raw["label"]?.string ?? raw["name"]?.string ?? ""
            guard label.utf8.count <= maxGraphNodeLabelBytes else { return (nil, "\(path).label exceeds \(maxGraphNodeLabelBytes) UTF-8 bytes") }
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (nil, "\(path).label must not be empty")
            }
            var detail: String?
            if let value = raw["detail"], value != .null {
                guard let text = value.string else { return (nil, "\(path).detail must be text") }
                guard text.utf8.count <= maxGraphDetailBytes else { return (nil, "\(path).detail exceeds \(maxGraphDetailBytes) UTF-8 bytes") }
                detail = text.isEmpty ? nil : text
            }
            var level: Int?
            if let value = raw["level"], value != .null {
                guard let number = value.int, number >= 0 else { return (nil, "\(path).level must be a non-negative integer") }
                level = number
            }
            var sources: [DiagramSource]?
            if let value = raw["sources"], value != .null {
                guard let list = value.array else { return (nil, "\(path).sources must be an array") }
                guard list.count <= maxGraphSources else { return (nil, "\(path).sources has \(list.count) entries: at most \(maxGraphSources)") }
                var parsed: [DiagramSource] = []
                for (sourceIndex, entry) in list.enumerated() {
                    let sourcePath = "\(path).sources[\(sourceIndex)]"
                    guard let object = entry.object else { return (nil, "\(sourcePath) must be an object") }
                    var fields: [String: String] = [:]
                    for key in ["session", "message", "board", "tile"] {
                        guard let field = object[key], field != .null else { continue }
                        guard let text = field.string, !text.isEmpty else { return (nil, "\(sourcePath).\(key) must be a non-empty string") }
                        guard text.utf8.count <= maxGraphSourceFieldBytes else { return (nil, "\(sourcePath).\(key) exceeds \(maxGraphSourceFieldBytes) UTF-8 bytes") }
                        fields[key] = text
                    }
                    guard !fields.isEmpty else { return (nil, "\(sourcePath) needs a session, message, board, or tile") }
                    parsed.append(DiagramSource(session: fields["session"], message: fields["message"], board: fields["board"], tile: fields["tile"]))
                }
                sources = parsed.isEmpty ? nil : parsed
            }
            var status: DiagramNodeStatus?
            if let value = raw["status"], value != .null {
                guard let text = value.string, let parsed = DiagramNodeStatus(rawValue: text) else {
                    return (nil, "\(path).status must be one of \(DiagramNodeStatus.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                status = parsed
            }
            nodes.append(GraphNodeInput(id: id, label: label, detail: detail, level: level, sources: sources, status: status))
        }
        var edges: [GraphEdgeInput] = []
        var endpoints: Set<GraphEdgeEndpoints> = []
        if let value = input["edges"], value != .null {
            guard let list = value.array else { return (nil, "props.graph.edges must be an array") }
            guard list.count <= maxGraphEdges else { return (nil, "props.graph.edges has \(list.count) edges: at most \(maxGraphEdges)") }
            for (index, entry) in list.enumerated() {
                let path = "props.graph.edges[\(index)]"
                guard let raw = entry.object else { return (nil, "\(path) must be an object") }
                guard let from = raw["from"]?.string, !from.isEmpty else { return (nil, "\(path).from must be a node id") }
                guard let to = raw["to"]?.string, !to.isEmpty else { return (nil, "\(path).to must be a node id") }
                guard ids.contains(from) else { return (nil, "\(path).from \"\(from)\" is not a node") }
                guard ids.contains(to) else { return (nil, "\(path).to \"\(to)\" is not a node") }
                guard endpoints.insert(GraphEdgeEndpoints(from: from, to: to)).inserted else {
                    return (nil, "\(path) duplicates directed edge \"\(from)\" -> \"\(to)\"")
                }
                var label: String?
                if let value = raw["label"], value != .null {
                    guard let text = value.string else { return (nil, "\(path).label must be text") }
                    guard text.utf8.count <= maxGraphEdgeLabelBytes else { return (nil, "\(path).label exceeds \(maxGraphEdgeLabelBytes) UTF-8 bytes") }
                    label = text.isEmpty ? nil : text
                }
                edges.append(GraphEdgeInput(from: from, to: to, label: label))
            }
        }

        var levels: [String: Int] = [:]
        let explicit = nodes.allSatisfy { $0.level != nil }
        if explicit {
            for node in nodes { levels[node.id] = node.level }
        } else {
            var adjacency: [String: [String]] = [:]
            for edge in edges { adjacency[edge.from, default: []].append(edge.to) }
            var state: [String: Int] = [:]
            func cycle(from id: String) -> String? {
                state[id] = 1
                for next in adjacency[id] ?? [] {
                    if state[next] == 1 { return next }
                    if state[next] == nil, let found = cycle(from: next) { return found }
                }
                state[id] = 2
                return nil
            }
            for node in nodes where state[node.id] == nil {
                if let found = cycle(from: node.id) {
                    return (nil, "graph has a cycle through node \"\(found)\": give every node a level or break the cycle")
                }
            }
            var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
            for edge in edges { indegree[edge.to, default: 0] += 1 }
            var queue = nodes.map(\.id).filter { indegree[$0] == 0 }
            var order: [String] = []
            var head = 0
            while head < queue.count {
                let id = queue[head]
                head += 1
                order.append(id)
                for next in adjacency[id] ?? [] {
                    indegree[next, default: 0] -= 1
                    if indegree[next] == 0 { queue.append(next) }
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            var predecessors: [String: [String]] = [:]
            for edge in edges { predecessors[edge.to, default: []].append(edge.from) }
            for id in order {
                if let given = byID[id]?.level {
                    levels[id] = given
                } else {
                    levels[id] = (predecessors[id] ?? []).compactMap { levels[$0].map { $0 + 1 } }.max() ?? 0
                }
            }
        }
        let graphNodes = nodes.map { node in
            DiagramNode(id: node.id, name: node.label, level: levels[node.id] ?? node.level ?? 0,
                        detail: node.detail, sources: node.sources, status: node.status)
        }
        let graphEdges = edges.map { DiagramEdge(from: $0.from, to: $0.to, lines: [], label: $0.label) }
        return (DiagramGraph(aim: DiagramAim(kind: .graph, path: nil, symbol: nil, line: nil, direction: .incoming),
                              nodes: graphNodes, edges: graphEdges), nil)
    }

    /// Why a diagram's props (as they will be after a create or update) can't be drawn: nil when
    /// they can.
    public static func problem(_ props: JSONValue) -> String? {
        if let kind = props["kind"], kind.string.flatMap(DiagramKind.init) == nil {
            return "diagram kind must be one of \(DiagramKind.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if let direction = props["direction"], direction.string.flatMap(CallDirection.init) == nil {
            return "direction must be one of \(CallDirection.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if let depth = props["depth"], !(depth.int.map { (1...maxDepth).contains($0) } ?? false) {
            return "depth must be an integer from 1 to \(maxDepth)"
        }
        if let line = props["line"], !(line.int.map { $0 >= 1 } ?? false) { return "line is 1-based: an integer of at least 1" }
        if let expanded = props["expanded"], expanded.array?.allSatisfy({ $0.string != nil }) != true { return "expanded is an array of node ids" }
        let spec = DiagramSpec(props)
        if spec.kind == .graph {
            if let reason = graph(props).problem { return reason }
            return nil
        }
        if spec.symbol == nil, spec.path == nil { return "a calls diagram needs props.symbol (e.g. \"SocketServer.start\"), or props.path with a line or symbol" }
        if spec.symbol == nil, spec.line == nil { return "a calls diagram needs props.symbol or props.line to name its root function in \(spec.path ?? "the file")" }
        return nil
    }
}

/// What a diagram is of (`DiagramSpec.aim`), recorded with the graph computed for it.
public struct DiagramAim: Codable, Equatable, Sendable {
    public var kind: DiagramKind
    public var path: String?
    public var symbol: String?
    public var line: Int?
    public var direction: CallDirection
}
