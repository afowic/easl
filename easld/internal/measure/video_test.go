package measure

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func videoBox(kind string, body []byte) []byte {
	box := make([]byte, 8+len(body))
	binary.BigEndian.PutUint32(box, uint32(len(box)))
	copy(box[4:], kind)
	copy(box[8:], body)
	return box
}

func videoMetadata(rotated bool) []byte {
	tkhd := make([]byte, 84)
	tkhd[3] = 3
	binary.BigEndian.PutUint32(tkhd[40:], 1<<16)
	binary.BigEndian.PutUint32(tkhd[56:], 1<<16)
	binary.BigEndian.PutUint32(tkhd[72:], 1<<30)
	binary.BigEndian.PutUint32(tkhd[76:], 1920<<16)
	binary.BigEndian.PutUint32(tkhd[80:], 1080<<16)
	if rotated {
		binary.BigEndian.PutUint32(tkhd[40:], 0)
		binary.BigEndian.PutUint32(tkhd[44:], 1<<16)
		binary.BigEndian.PutUint32(tkhd[52:], 0xffff0000)
		binary.BigEndian.PutUint32(tkhd[56:], 0)
	}
	hdlr := make([]byte, 12)
	copy(hdlr[8:], "vide")
	track := append(videoBox("tkhd", tkhd), videoBox("mdia", videoBox("hdlr", hdlr))...)
	return videoBox("moov", videoBox("trak", track))
}

func TestVideoMeasureUsesContainerDisplayDimensions(t *testing.T) {
	for _, rotated := range []bool{false, true} {
		root := t.TempDir()
		path := filepath.Join(root, "clip.mp4")
		if err := os.WriteFile(path, videoMetadata(rotated), 0600); err != nil {
			t.Fatal(err)
		}
		w, h, approximate, err := Size("video", map[string]any{"path": "clip.mp4"}, nil, root, nil)
		wantW, wantH := 960.0, 566.0
		if rotated {
			wantW, wantH = 960, 1733
		}
		if err != nil || w != wantW || h != wantH || approximate {
			t.Fatalf("rotated %v: %v x %v approximate %v, %v", rotated, w, h, approximate, err)
		}
	}
}

func TestVideoMeasureRefusesOutsideAndDoesNotInventDimensions(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	path := filepath.Join(outside, "clip.mp4")
	if err := os.WriteFile(path, videoMetadata(false), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(root, "escape.mp4")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{path, "escape.mp4"} {
		_, _, err := VideoNaturalSize(name, root)
		if failure, ok := err.(*Failure); !ok || failure.Code != "invalid_params" {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "bad.mp4"), []byte("not a movie"), 0600); err != nil {
		t.Fatal(err)
	}
	_, _, err := VideoNaturalSize("bad.mp4", root)
	if failure, ok := err.(*Failure); !ok || failure.Code != "unavailable" {
		t.Fatal(err)
	}
}

func TestVideoMeasureFindsMetadataAfterLargeMediaPayload(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "end.mp4")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	const payloadEnd = 64 << 20
	header := make([]byte, 8)
	binary.BigEndian.PutUint32(header, payloadEnd)
	copy(header[4:], "mdat")
	if _, err := file.Write(header); err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteAt(videoMetadata(false), payloadEnd); err != nil {
		t.Fatal(err)
	}
	w, h, err := VideoNaturalSize("end.mp4", root)
	if err != nil || w != 1920 || h != 1080 {
		t.Fatalf("%v x %v: %v", w, h, err)
	}
}
