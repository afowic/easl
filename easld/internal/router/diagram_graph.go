package router

import (
	"math"
	"strconv"
	"strings"
	"time"
)

// diagramGraphMaxNodes is DiagramSpec.maxGraphNodes: calls graphs stop at
// CallGraphBuilder.maxNodes, while a caller-supplied knowledge graph may be much larger.
const diagramGraphMaxNodes = 500
const diagramGraphMaxEdges = 2000
const diagramGraphMaxIDBytes = 256
const diagramGraphMaxNodeLabelBytes = 512
const diagramGraphMaxEdgeLabelBytes = 256
const diagramGraphMaxDetailBytes = 8192
const diagramGraphMaxSources = 8
const diagramGraphMaxSourceFieldBytes = 256

type diagramGraphNodeInput struct {
	id      string
	label   string
	detail  *string
	level   *int
	sources []any
	status  string
}

type diagramGraphEdgeInput struct {
	from, to, label string
}

func diagramKindOf(props map[string]any) string {
	if kind, ok := props["kind"].(string); ok && kind != "" {
		return kind
	}
	return "calls"
}

func graphOf(props map[string]any) (map[string]any, string) {
	input, ok := props["knowledge"].(map[string]any)
	if !ok {
		return nil, "a graph diagram needs props.knowledge.nodes and props.knowledge.edges"
	}
	nodeValues, ok := input["nodes"].([]any)
	if !ok {
		return nil, "a graph diagram needs props.knowledge.nodes"
	}
	if len(nodeValues) == 0 {
		return nil, "props.knowledge.nodes needs at least one node"
	}
	if len(nodeValues) > diagramGraphMaxNodes {
		return nil, "props.knowledge.nodes has " + itoa(len(nodeValues)) + " nodes: at most " + itoa(diagramGraphMaxNodes)
	}
	var nodes []diagramGraphNodeInput
	ids := map[string]bool{}
	for i, value := range nodeValues {
		path := "props.knowledge.nodes[" + itoa(i) + "]"
		raw, ok := value.(map[string]any)
		if !ok {
			return nil, path + " must be an object"
		}
		id, ok := raw["id"].(string)
		if !ok || id == "" {
			return nil, path + ".id must be a non-empty string"
		}
		if len(id) > diagramGraphMaxIDBytes {
			return nil, path + ".id exceeds " + itoa(diagramGraphMaxIDBytes) + " UTF-8 bytes"
		}
		if ids[id] {
			return nil, "duplicate node id \"" + id + "\""
		}
		ids[id] = true
		label := ""
		if v, present := raw["label"]; present && v != nil {
			s, ok := v.(string)
			if !ok {
				return nil, path + ".label must be text"
			}
			label = s
		}
		if label == "" {
			if v, present := raw["name"]; present && v != nil {
				s, ok := v.(string)
				if !ok {
					return nil, path + ".label must be text"
				}
				label = s
			}
		}
		if len(label) > diagramGraphMaxNodeLabelBytes {
			return nil, path + ".label exceeds " + itoa(diagramGraphMaxNodeLabelBytes) + " UTF-8 bytes"
		}
		if strings.TrimSpace(label) == "" {
			return nil, path + ".label must not be empty"
		}
		var detail *string
		if v, present := raw["detail"]; present && v != nil {
			s, ok := v.(string)
			if !ok {
				return nil, path + ".detail must be text"
			}
			if len(s) > diagramGraphMaxDetailBytes {
				return nil, path + ".detail exceeds " + itoa(diagramGraphMaxDetailBytes) + " UTF-8 bytes"
			}
			if s != "" {
				detail = &s
			}
		}
		var level *int
		if v, present := raw["level"]; present && v != nil {
			raw, valid := v.(float64)
			if !valid || math.IsNaN(raw) || math.IsInf(raw, 0) || raw < 0 || raw != math.Trunc(raw) || raw >= math.Ldexp(1, strconv.IntSize-1) {
				return nil, path + ".level must be a non-negative integer"
			}
			n := int(raw)
			level = &n
		}
		var sources []any
		if v, present := raw["sources"]; present && v != nil {
			list, ok := v.([]any)
			if !ok {
				return nil, path + ".sources must be an array"
			}
			if len(list) > diagramGraphMaxSources {
				return nil, path + ".sources has " + itoa(len(list)) + " entries: at most " + itoa(diagramGraphMaxSources)
			}
			for j, entry := range list {
				sourcePath := path + ".sources[" + itoa(j) + "]"
				object, ok := entry.(map[string]any)
				if !ok {
					return nil, sourcePath + " must be an object"
				}
				source := map[string]any{}
				for _, key := range []string{"session", "message", "board", "tile"} {
					field, present := object[key]
					if !present || field == nil {
						continue
					}
					text, ok := field.(string)
					if !ok || text == "" {
						return nil, sourcePath + "." + key + " must be a non-empty string"
					}
					if len(text) > diagramGraphMaxSourceFieldBytes {
						return nil, sourcePath + "." + key + " exceeds " + itoa(diagramGraphMaxSourceFieldBytes) + " UTF-8 bytes"
					}
					source[key] = text
				}
				if len(source) == 0 {
					return nil, sourcePath + " needs a session, message, board, or tile"
				}
				sources = append(sources, source)
			}
		}
		status := ""
		if v, present := raw["status"]; present && v != nil {
			s, ok := v.(string)
			if !ok || !diagramStatuses[s] {
				return nil, path + ".status must be one of taught, practiced, retained, weak"
			}
			status = s
		}
		nodes = append(nodes, diagramGraphNodeInput{id: id, label: label, detail: detail, level: level, sources: sources, status: status})
	}

	var edges []diagramGraphEdgeInput
	endpoints := map[[2]string]bool{}
	if v, present := input["edges"]; present && v != nil {
		list, ok := v.([]any)
		if !ok {
			return nil, "props.knowledge.edges must be an array"
		}
		if len(list) > diagramGraphMaxEdges {
			return nil, "props.knowledge.edges has " + itoa(len(list)) + " edges: at most " + itoa(diagramGraphMaxEdges)
		}
		for i, value := range list {
			path := "props.knowledge.edges[" + itoa(i) + "]"
			raw, ok := value.(map[string]any)
			if !ok {
				return nil, path + " must be an object"
			}
			from, ok := raw["from"].(string)
			if !ok || from == "" {
				return nil, path + ".from must be a node id"
			}
			to, ok := raw["to"].(string)
			if !ok || to == "" {
				return nil, path + ".to must be a node id"
			}
			if !ids[from] {
				return nil, path + ".from \"" + from + "\" is not a node"
			}
			if !ids[to] {
				return nil, path + ".to \"" + to + "\" is not a node"
			}
			pair := [2]string{from, to}
			if endpoints[pair] {
				return nil, path + " duplicates directed edge \"" + from + "\" -> \"" + to + "\""
			}
			endpoints[pair] = true
			label := ""
			if v, present := raw["label"]; present && v != nil {
				s, ok := v.(string)
				if !ok {
					return nil, path + ".label must be text"
				}
				if len(s) > diagramGraphMaxEdgeLabelBytes {
					return nil, path + ".label exceeds " + itoa(diagramGraphMaxEdgeLabelBytes) + " UTF-8 bytes"
				}
				label = s
			}
			edges = append(edges, diagramGraphEdgeInput{from: from, to: to, label: label})
		}
	}

	levels := map[string]int{}
	explicit := true
	for _, node := range nodes {
		if node.level == nil {
			explicit = false
			break
		}
	}
	if explicit {
		for _, node := range nodes {
			levels[node.id] = *node.level
		}
	} else {
		adjacency := map[string][]string{}
		for _, edge := range edges {
			adjacency[edge.from] = append(adjacency[edge.from], edge.to)
		}
		state := map[string]int{}
		var cycle func(string) string
		cycle = func(id string) string {
			state[id] = 1
			for _, next := range adjacency[id] {
				if state[next] == 1 {
					return next
				}
				if state[next] == 0 {
					if found := cycle(next); found != "" {
						return found
					}
				}
			}
			state[id] = 2
			return ""
		}
		for _, node := range nodes {
			if state[node.id] == 0 {
				if found := cycle(node.id); found != "" {
					return nil, "graph has a cycle through node \"" + found + "\": give every node a level or break the cycle"
				}
			}
		}
		indegree := map[string]int{}
		for _, node := range nodes {
			indegree[node.id] = 0
		}
		for _, edge := range edges {
			indegree[edge.to]++
		}
		var queue []string
		for _, node := range nodes {
			if indegree[node.id] == 0 {
				queue = append(queue, node.id)
			}
		}
		var order []string
		for head := 0; head < len(queue); {
			id := queue[head]
			head++
			order = append(order, id)
			for _, next := range adjacency[id] {
				indegree[next]--
				if indegree[next] == 0 {
					queue = append(queue, next)
				}
			}
		}
		byID := map[string]diagramGraphNodeInput{}
		for _, node := range nodes {
			byID[node.id] = node
		}
		predecessors := map[string][]string{}
		for _, edge := range edges {
			predecessors[edge.to] = append(predecessors[edge.to], edge.from)
		}
		for _, id := range order {
			if given := byID[id].level; given != nil {
				levels[id] = *given
				continue
			}
			deepest := -1
			for _, from := range predecessors[id] {
				if level, ok := levels[from]; ok {
					if level == int(^uint(0)>>1) {
						return nil, "graph reasoning depth exceeds the supported integer range"
					}
					deepest = max(deepest, level+1)
				}
			}
			if deepest < 0 {
				deepest = 0
			}
			levels[id] = deepest
		}
	}

	outNodes := make([]any, 0, len(nodes))
	for _, node := range nodes {
		out := map[string]any{"id": node.id, "name": node.label, "level": float64(levels[node.id])}
		if node.detail != nil {
			out["detail"] = *node.detail
		}
		if node.sources != nil {
			out["sources"] = node.sources
		}
		if node.status != "" {
			out["status"] = node.status
		}
		outNodes = append(outNodes, out)
	}
	outEdges := make([]any, 0, len(edges))
	for _, edge := range edges {
		out := map[string]any{"from": edge.from, "to": edge.to, "lines": []any{}}
		if edge.label != "" {
			out["label"] = edge.label
		}
		outEdges = append(outEdges, out)
	}
	graph := map[string]any{
		"aim":        map[string]any{"kind": "graph", "direction": "incoming"},
		"nodes":      outNodes,
		"edges":      outEdges,
		"computedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	return graph, ""
}

var diagramStatuses = map[string]bool{"taught": true, "practiced": true, "retained": true, "weak": true}

func cloneProps(props map[string]any) map[string]any {
	out := make(map[string]any, len(props))
	for key, value := range props {
		out[key] = value
	}
	return out
}
