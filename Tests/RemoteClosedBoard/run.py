#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from PIL import Image, ImageChops


def main():
    parser = argparse.ArgumentParser(description="Exercise a closed remote board through an isolated development viewer.")
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--viewer-home", type=Path, required=True)
    parser.add_argument("--host-socket", required=True)
    parser.add_argument("--host-home", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, EASL_DEV_HOME=str(args.viewer_home), EASL_DEV_REMOTE_HOME=args.host_home)
    observations = {}
    failures = []

    def call(method, params, socket_path=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(20)
            connection.connect(socket_path or args.host_socket)
            connection.sendall((json.dumps({"id": "probe", "method": method, "params": params}) + "\n").encode())
            with connection.makefile() as stream:
                for line in stream:
                    reply = json.loads(line)
                    if reply.get("id") == "probe":
                        if not reply.get("ok"):
                            raise RuntimeError(reply.get("error"))
                        return reply["result"]
        raise RuntimeError(f"{method} closed without a reply")

    def input_event(*arguments):
        subprocess.run([str(args.checkout / "scripts/dev.sh"), "input", *map(str, arguments)],
                       cwd=args.checkout, env=environment, check=True, capture_output=True, text=True)

    def state():
        log = args.viewer_home / "app.log"
        offset = log.stat().st_size
        input_event("state")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with log.open() as stream:
                stream.seek(offset)
                for line in stream:
                    if "DevInput.state " in line:
                        return json.loads(line.split("DevInput.state ", 1)[1])
            time.sleep(0.05)
        raise RuntimeError("The development viewer did not report its window state")

    def remote_state():
        return next(window for window in state() if window["board"] == board)

    def expect(name, condition, detail):
        observations[name] = detail
        print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)
        if not condition:
            failures.append(name)

    def capture(name, window):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(window), str(args.out / name)], check=True)

    board = call("board.open", {"root": args.root, "select": False})["board"]
    existing = call("board.get", {"board": board})["objects"]
    assert existing == [], "Use a new, empty scratch board root"
    markdown = "# Closed board inspection\n\nCopy this closed-board text.\n\n" + "\n\n".join(f"Retained paragraph {n}." for n in range(1, 31))
    note = call("object.create", {"board": board, "type": "note", "props": {"markdown": markdown},
                                  "frame": {"x": 0, "y": 0, "w": 560, "h": 360}})["object"]
    input_event("remote", args.host, board, args.host_home)
    deadline = time.monotonic() + 30
    while True:
        try:
            opened = remote_state()
            break
        except (StopIteration, RuntimeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)
    input_event("shortcut", "0", "--mods", "cmd")
    time.sleep(0.5)
    call("object.create", {"board": board, "type": "question",
                           "props": {"question": "Hidden closed-board question", "asker": {"name": "closed-board regression"},
                                     "options": [{"id": "a", "label": "Keep unanswered"}], "keep": True},
                           "frame": {"x": 5000, "y": 5000, "w": 300, "h": 200}})
    call("board.close", {"board": board})
    deadline = time.monotonic() + 10
    while not remote_state()["closed"]:
        if time.monotonic() >= deadline:
            raise RuntimeError("The viewer did not observe host close")
        time.sleep(0.1)
    before = remote_state()
    capture("closed-before.png", before["window"])
    rect = before["viewport"]["rect"]
    zoom = before["viewport"]["zoom"]
    x = int((note["frame"]["x"] - rect["x"] + 80) * zoom)
    y = int((note["frame"]["y"] - rect["y"] + 100) * zoom)
    input_event("click", x, y)
    input_event("shortcut", "a", "--mods", "cmd")
    input_event("shortcut", "c", "--mods", "cmd")
    selected = remote_state()
    expected_text = "\n".join(["Closed board inspection", "Copy this closed-board text."] + [f"Retained paragraph {n}." for n in range(1, 31)])
    expected_hash = hashlib.sha256(expected_text.encode()).hexdigest()
    expect("closed note selects text to copy", selected["selectedTextHashes"] == [expected_hash], selected["selectedTextHashes"])
    if selected["selectedTextHashes"] == [expected_hash]:
        copied = subprocess.check_output(["pbpaste"])
        expect("closed note copies its selected text", hashlib.sha256(copied).hexdigest() == expected_hash, {"matchesFixture": hashlib.sha256(copied).hexdigest() == expected_hash})
    input_event("scroll", x, y, 0, -80)
    input_event("scroll", 900, 400, -160, 0)
    input_event("drag", 900, 400, 1040, 450, "--middle")
    time.sleep(0.5)
    panned = remote_state()
    expect("closed board pans", panned["viewport"]["rect"] != before["viewport"]["rect"],
           {"before": before["viewport"], "after": panned["viewport"]})
    capture("closed-panned.png", panned["window"])
    input_event("shortcut", "-", "--mods", "cmd")
    time.sleep(0.4)
    zoomed = remote_state()
    expect("closed board zooms", zoomed["viewport"]["zoom"] < panned["viewport"]["zoom"], zoomed["viewport"])
    capture("closed-panned-zoomed.png", zoomed["window"])
    with Image.open(args.out / "closed-panned.png") as panned_image, Image.open(args.out / "closed-panned-zoomed.png") as zoomed_image:
        crop = (0, 300, panned_image.width, panned_image.height - 150)
        difference = ImageChops.difference(panned_image.convert("RGB").crop(crop), zoomed_image.convert("RGB").crop(crop)).getbbox()
    expect("closed board visibly zooms", difference is not None, {"pixelDifference": difference})
    input_event("shortcut", "n", "--mods", "cmd")
    input_event("key", "delete")
    input_event("text", "THIS EDIT MUST BE REFUSED")
    after_edit = remote_state()
    expect("closed board refuses edits", after_edit["objects"] == before["objects"], after_edit["objects"])
    tour_root = args.viewer_home.parent / "easl-followups-tour"
    tour_root.mkdir(exist_ok=True)
    local = call("board.open", {"root": str(tour_root), "select": True}, str(args.viewer_home / "easl.sock"))["board"]
    time.sleep(0.4)
    hidden_before = remote_state()
    input_event("shortcut", "j", "--mods", "cmd")
    input_event("mainmenu", "View/Go to Next Needs-You")
    time.sleep(0.4)
    hidden_after = remote_state()
    expect("needs-you skips the hidden closed tab",
           hidden_after["viewport"] == hidden_before["viewport"] and hidden_after["responder"] == hidden_before["responder"] and not hidden_after["selected"],
           {"before": hidden_before, "after": hidden_after, "local": local})
    call("board.open", {"root": args.root, "select": False})
    deadline = time.monotonic() + 10
    while remote_state()["closed"]:
        if time.monotonic() >= deadline:
            raise RuntimeError("The viewer did not observe host reopen")
        time.sleep(0.1)
    retained = call("object.get", {"id": note["id"]})["object"]
    expect("host retained the note", retained["props"]["markdown"] == markdown and retained["frame"] == note["frame"], retained)
    args.out.joinpath("observations.json").write_text(json.dumps(observations, indent=2) + "\n")
    if failures:
        raise SystemExit("Failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
