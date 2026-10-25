package store

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestQuestionSnapshotAnswersAreNormalized(t *testing.T) {
	for _, value := range []float64{1e100, -1, 0.8} {
		s := &Snapshot{ID: "brd_question", Root: "/tmp", Objects: []model.Object{{
			ID: "obj_question", Type: model.Question, CreatedBy: model.Actor{Kind: "user"},
			Props: map[string]any{
				"question": "Which?", "options": []any{map[string]any{"id": "a", "label": "A"}, map[string]any{"id": "b", "label": "B"}},
				"status": "answered", "askConfidence": true, "correct": "a",
				"answer": map[string]any{"option": "b", "confidence": value, "correct": true},
			},
		}}}
		data, err := json.Marshal(s.JSON())
		if err != nil {
			t.Fatal(err)
		}
		loaded, err := DecodeSnapshot(data)
		if err != nil {
			t.Fatal(err)
		}
		answer := loaded.Objects[0].Props["answer"].(map[string]any)
		if answer["correct"] != false {
			t.Fatalf("forged correctness survived: %v", answer)
		}
		if value == 0.8 {
			if answer["confidence"] != 0.8 {
				t.Fatalf("valid confidence lost: %v", answer)
			}
		} else if _, exists := answer["confidence"]; exists {
			t.Fatalf("invalid confidence survived: %v", answer)
		}
		if value == 0.8 {
			invalid := strings.Replace(string(data), `"confidence":0.8`, `"confidence":NaN`, 1)
			if _, err := DecodeSnapshot([]byte(invalid)); err == nil {
				t.Fatal("non-JSON NaN accepted")
			}
		}
	}
}
