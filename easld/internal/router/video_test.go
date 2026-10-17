package router

import (
	"reflect"
	"testing"
)

func TestVideoPropsSurviveUpdatesAndBoardReopen(t *testing.T) {
	f := newFixture(t)
	props := map[string]any{"path": "clip.mp4", "poster": "poster.png", "loop": true, "muted": false, "autoplay": false, "startTime": 1.25, "title": "Demo", "key": "demo"}
	created := f.result("object.create", map[string]any{"type": "video", "props": props})
	id := idOf(created)
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"startTime": 2.5, "title": "Edited"}})
	props["startTime"], props["title"] = 2.5, "Edited"
	f.result("board.close", map[string]any{"board": f.board.ID()})
	f.result("board.open", map[string]any{"root": f.board.Root()})
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if got["type"] != "video" || !reflect.DeepEqual(got["props"], props) {
		t.Fatalf("reopened video: %#v", got)
	}
}

func TestVideoRejectsInvalidPropsWithoutChangingTheObject(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", map[string]any{"type": "video", "props": map[string]any{"path": "clip.mp4"}}))
	for _, patch := range []map[string]any{
		{"startTime": -1.0}, {"startTime": "2"}, {"startTime": true}, {"loop": "true"}, {"muted": 1.0}, {"autoplay": "false"}, {"poster": 2.0}, {"title": false}, {"path": nil},
	} {
		code, _ := errorOf(f.call("object.update", map[string]any{"id": id, "props": patch}))
		if code != "invalid_params" {
			t.Fatalf("%#v: %s", patch, code)
		}
		creating := map[string]any{"path": "clip.mp4"}
		for key, value := range patch {
			creating[key] = value
		}
		code, _ = errorOf(f.call("object.create", map[string]any{"type": "video", "props": creating}))
		if code != "invalid_params" {
			t.Fatalf("create %#v: %s", patch, code)
		}
	}
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if !reflect.DeepEqual(got["props"], map[string]any{"path": "clip.mp4"}) {
		t.Fatal(got)
	}
}
