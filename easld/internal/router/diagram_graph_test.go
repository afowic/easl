package router

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func graphNode(id, label string, extra map[string]any) map[string]any {
	node := map[string]any{"id": id, "label": label}
	for key, value := range extra {
		node[key] = value
	}
	return node
}

// reasoningGraphProps is a small knowledge graph: a premise, the two steps drawn from it, and
// their conclusion, each with what practice has shown and where it came from.
func reasoningGraphProps() map[string]any {
	return map[string]any{"kind": "graph", "title": "Why the cache lies", "graph": map[string]any{
		"nodes": []any{
			graphNode("cold", "Tests fail on a cold start", map[string]any{
				"detail": "The first read after launch returns an empty cache.", "status": "weak",
				"sources": []any{map[string]any{"session": "sess-1"}},
			}),
			graphNode("stale", "The cache keeps a stale stamp", map[string]any{
				"detail": "**Root cause**: the stamp is written before the read.", "status": "taught",
				"sources": []any{map[string]any{"message": "m-9"}},
			}),
			graphNode("fix", "Write the stamp after the read", map[string]any{
				"status": "practiced", "sources": []any{map[string]any{"tile": "obj_term"}},
			}),
			graphNode("verify", "Cold-start tests pass", map[string]any{"status": "retained"}),
		},
		"edges": []any{
			map[string]any{"from": "cold", "to": "stale", "label": "observed by"},
			map[string]any{"from": "stale", "to": "fix", "label": "fixed by"},
			map[string]any{"from": "fix", "to": "verify", "label": "verified by"},
		},
	}}
}

func createGraph(f *fixture, props map[string]any) string {
	f.t.Helper()
	return idOf(f.result("object.create", map[string]any{"type": "diagram", "props": props,
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 760.0, "h": 480.0}}))
}

func storedGraph(f *fixture, id string) map[string]any {
	f.t.Helper()
	graph, ok := propsOf(diagramObject(f, id))["graph"].(map[string]any)
	if !ok {
		f.t.Fatalf("%s has no props.graph", id)
	}
	return graph
}

func graphNodesByID(f *fixture, graph map[string]any) map[string]map[string]any {
	f.t.Helper()
	nodes := map[string]map[string]any{}
	list, ok := graph["nodes"].([]any)
	if !ok {
		f.t.Fatalf("graph.nodes is %T", graph["nodes"])
	}
	for _, value := range list {
		node := value.(map[string]any)
		nodes[node["id"].(string)] = node
	}
	return nodes
}

func TestCallerGraphsGetReasoningLevelsAndKeepDetailSourcesAndStatus(t *testing.T) {
	f := newFixture(t)
	id := createGraph(f, reasoningGraphProps())
	graph := storedGraph(f, id)
	if aim := graph["aim"].(map[string]any); aim["kind"] != "graph" {
		t.Fatalf("aim = %v, want kind graph", aim)
	}
	nodes := graphNodesByID(f, graph)
	for node, want := range map[string]struct {
		name   string
		level  float64
		status string
	}{"cold": {"Tests fail on a cold start", 0, "weak"}, "stale": {"The cache keeps a stale stamp", 1, "taught"},
		"fix": {"Write the stamp after the read", 2, "practiced"}, "verify": {"Cold-start tests pass", 3, "retained"}} {
		got := nodes[node]
		if got["name"] != want.name || got["level"] != want.level || got["status"] != want.status {
			t.Errorf("%s = %v, want %+v", node, got, want)
		}
	}
	if nodes["stale"]["detail"] != "**Root cause**: the stamp is written before the read." {
		t.Errorf("stale detail = %v", nodes["stale"]["detail"])
	}
	if want := []any{map[string]any{"session": "sess-1"}}; !reflect.DeepEqual(nodes["cold"]["sources"], want) {
		t.Errorf("cold sources = %v, want %v", nodes["cold"]["sources"], want)
	}
	edges := graph["edges"].([]any)
	first := edges[0].(map[string]any)
	if first["from"] != "cold" || first["to"] != "stale" || first["label"] != "observed by" {
		t.Errorf("first edge = %v", first)
	}
	if lines, ok := first["lines"].([]any); !ok || len(lines) != 0 {
		t.Errorf("a graph edge has no call lines: %v", first["lines"])
	}

	// The caller's graph is not the language server's to compute: reload answers with it and
	// changes nothing.
	before := propsOf(diagramObject(f, id))
	reload := f.result("object.reload", map[string]any{"id": id})
	if reload["loaded"] != true || reload["nodes"] != 4.0 || reload["edges"] != 3.0 {
		t.Errorf("reload = %v", reload)
	}
	if after := propsOf(diagramObject(f, id)); !reflect.DeepEqual(before, after) {
		t.Errorf("reload changed the graph:\nbefore %v\nafter %v", before, after)
	}
}

func TestInvalidGraphsAreRefusedWithTheRuleTheyBreak(t *testing.T) {
	f := newFixture(t)
	cases := []struct {
		name  string
		props map[string]any
		rule  string
	}{
		{"duplicate id", map[string]any{"kind": "graph", "graph": map[string]any{"nodes": []any{
			graphNode("a", "A", nil), graphNode("a", "B", nil),
		}}}, `duplicate node id "a"`},
		{"endpoint", map[string]any{"kind": "graph", "graph": map[string]any{
			"nodes": []any{graphNode("a", "A", nil)},
			"edges": []any{map[string]any{"from": "a", "to": "ghost"}},
		}}, `edges[0].to "ghost" is not a node`},
		{"empty label", map[string]any{"kind": "graph", "graph": map[string]any{"nodes": []any{
			graphNode("a", "  ", nil),
		}}}, "nodes[0].label must not be empty"},
		{"cycle", map[string]any{"kind": "graph", "graph": map[string]any{
			"nodes": []any{graphNode("a", "A", nil), graphNode("b", "B", nil)},
			"edges": []any{map[string]any{"from": "a", "to": "b"}, map[string]any{"from": "b", "to": "a"}},
		}}, `cycle through node "a"`},
		{"status", map[string]any{"kind": "graph", "graph": map[string]any{"nodes": []any{
			graphNode("a", "A", map[string]any{"status": "known"}),
		}}}, "status must be one of taught, practiced, retained, weak"},
		{"source", map[string]any{"kind": "graph", "graph": map[string]any{"nodes": []any{
			graphNode("a", "A", map[string]any{"sources": []any{map[string]any{"author": "me"}}}),
		}}}, "sources[0] needs a session, message, board, or tile"},
	}
	for _, entry := range cases {
		message := f.refused("object.create", map[string]any{"type": "diagram", "props": entry.props,
			"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 760.0, "h": 480.0}})
		if !strings.Contains(message, entry.rule) {
			t.Errorf("%s: refusal %q does not name %q", entry.name, message, entry.rule)
		}
	}

	// An update keeps the same rules: a graph that would break one is refused whole.
	id := createGraph(f, reasoningGraphProps())
	broken := reasoningGraphProps()
	broken["graph"] = map[string]any{"nodes": []any{graphNode("a", "", nil)}}
	message := f.refused("object.update", map[string]any{"id": id, "props": broken})
	if !strings.Contains(message, "label must not be empty") {
		t.Errorf("update refusal = %q", message)
	}
	if graph := storedGraph(f, id); len(graphNodesByID(f, graph)) != 4 {
		t.Errorf("a refused update stored %v", graph)
	}
}

func TestAnExplicitlyLevelledCycleIsAccepted(t *testing.T) {
	f := newFixture(t)
	props := map[string]any{"kind": "graph", "graph": map[string]any{
		"nodes": []any{
			graphNode("a", "A", map[string]any{"level": 0.0}),
			graphNode("b", "B", map[string]any{"level": 1.0}),
		},
		"edges": []any{map[string]any{"from": "a", "to": "b"}, map[string]any{"from": "b", "to": "a"}},
	}}
	nodes := graphNodesByID(f, storedGraph(f, createGraph(f, props)))
	if nodes["a"]["level"] != 0.0 || nodes["b"]["level"] != 1.0 {
		t.Errorf("explicit levels = %v, %v", nodes["a"]["level"], nodes["b"]["level"])
	}
}

func TestTheGraphNodeCapIsFiveHundred(t *testing.T) {
	f := newFixture(t)
	many := func(count int) map[string]any {
		nodes := make([]any, 0, count)
		for i := range count {
			nodes = append(nodes, graphNode(fmt.Sprintf("n%d", i), fmt.Sprintf("Node %d", i), nil))
		}
		return map[string]any{"kind": "graph", "graph": map[string]any{"nodes": nodes, "edges": []any{}}}
	}
	if nodes := graphNodesByID(f, storedGraph(f, createGraph(f, many(500)))); len(nodes) != 500 {
		t.Fatalf("500 nodes stored as %d", len(nodes))
	}
	message := f.refused("object.create", map[string]any{"type": "diagram", "props": many(501),
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 760.0, "h": 480.0}})
	if !strings.Contains(message, "501 nodes: at most 500") {
		t.Errorf("cap refusal = %q", message)
	}
}

func TestPracticeStatusFeedsBackThroughObjectUpdate(t *testing.T) {
	f := newFixture(t)
	id := createGraph(f, reasoningGraphProps())
	stronger := reasoningGraphProps()
	stronger["graph"].(map[string]any)["nodes"] = []any{
		graphNode("cold", "Tests fail on a cold start", map[string]any{
			"detail": "The first read after launch returns an empty cache.", "status": "retained",
			"sources": []any{map[string]any{"session": "sess-1"}},
		}),
		graphNode("stale", "The cache keeps a stale stamp", map[string]any{
			"detail": "**Root cause**: the stamp is written before the read.", "status": "taught",
			"sources": []any{map[string]any{"message": "m-9"}},
		}),
		graphNode("fix", "Write the stamp after the read", map[string]any{
			"status": "practiced", "sources": []any{map[string]any{"tile": "obj_term"}},
		}),
		graphNode("verify", "Cold-start tests pass", map[string]any{"status": "retained"}),
	}
	f.result("object.update", map[string]any{"id": id, "props": stronger})
	nodes := graphNodesByID(f, storedGraph(f, id))
	if nodes["cold"]["status"] != "retained" {
		t.Errorf("cold status = %v, want retained", nodes["cold"]["status"])
	}
	if nodes["cold"]["level"] != 0.0 || nodes["verify"]["level"] != 3.0 {
		t.Errorf("an update keeps the reasoning levels: %v, %v", nodes["cold"]["level"], nodes["verify"]["level"])
	}
	if nodes["cold"]["detail"] != "The first read after launch returns an empty cache." {
		t.Errorf("an update keeps the detail: %v", nodes["cold"]["detail"])
	}
}
