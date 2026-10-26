package board

import (
	"math"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/question"
	"github.com/twaldin/easl/easld/internal/store"
)

func TestQuestionBoardLoadNormalizesStoredAnswers(t *testing.T) {
	for _, value := range []float64{1e100, math.NaN(), -1, math.Inf(1), math.Inf(-1), 0.8} {
		for _, pick := range []string{"a", "b", ""} {
			for _, key := range []string{"a", ""} {
				answer := map[string]any{"confidence": value, "correct": pick != "a", "note": "Stored answer"}
				if pick != "" {
					answer["option"] = pick
				}
				props := askProps(map[string]any{"status": "answered", "answer": answer, "askConfidence": true, "keep": true})
				if key != "" {
					props["correct"] = key
				}
				snapshot := &store.Snapshot{ID: "brd_question", Root: "/tmp", Objects: []model.Object{{ID: "obj_question", Type: model.Question, Props: props}}}
				loaded := FromSnapshot(snapshot).Objects()["obj_question"]
				stored := loaded.Props["answer"].(map[string]any)
				if value == 0.8 {
					if stored["confidence"] != 0.8 {
						t.Fatalf("valid confidence lost: %v", stored)
					}
				} else if _, exists := stored["confidence"]; exists {
					t.Fatalf("invalid confidence survived: %v", stored)
				}
				if pick == "" || key == "" {
					if _, exists := stored["correct"]; exists {
						t.Fatalf("correctness without pick and key: %v", stored)
					}
				} else if stored["correct"] != (pick == key) {
					t.Fatalf("forged correctness survived: %v", stored)
				}
				for _, spec := range []question.Spec{question.Read(props), question.Read(loaded.Props)} {
					if value == 0.8 {
						if spec.Answer.Confidence == nil || *spec.Answer.Confidence != 0.8 {
							t.Fatal("valid direct confidence lost")
						}
					} else if spec.Answer.Confidence != nil {
						t.Fatal("unsafe direct confidence")
					}
					if pick == "" || key == "" {
						if spec.Answer.Correct != nil {
							t.Fatal("direct correctness without pick and key")
						}
					} else if spec.Answer.Correct == nil || *spec.Answer.Correct != (pick == key) {
						t.Fatal("forged direct correctness")
					}
				}
			}
		}
	}
}
