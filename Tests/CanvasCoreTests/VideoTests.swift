import Foundation
import Testing
import CanvasCore

extension ApiRouterTests {
    @Test func videoPropsPersistAndRejectInvalidUpdates() async throws {
        let client = try connect()
        let props: JSONValue = .object(["path": "clip.mp4", "poster": "poster.png", "loop": .bool(true), "muted": .bool(false), "autoplay": .bool(false), "startTime": .number(1.25), "title": "Demo", "key": "demo"])
        let created = try await call(client, "object.create", ["board": .string(board.id), "type": "video", "props": props])
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let patches: [JSONValue] = [
            .object(["startTime": -1]), .object(["startTime": "2"]), .object(["startTime": .bool(true)]),
            .object(["loop": "true"]), .object(["muted": 1]), .object(["autoplay": "false"]),
            .object(["poster": 2]), .object(["title": .bool(false)]), .object(["path": .null])
        ]
        for patch in patches {
            let reply = try await call(client, "object.update", ["id": .string(id), "props": patch])
            #expect(reply["error"]?["code"] == "invalid_params")
        }
        _ = try await call(client, "object.update", ["id": .string(id), "props": .object(["startTime": .number(2.5), "title": "Edited"])])
        let store = BoardStore(directory: dir.appendingPathComponent("video-store"))
        try store.saveChecked(board)
        let restored = store.load(root: board.root)
        let object = try restored.object(id)
        #expect(object.type == .video)
        #expect(object.props == .object(["path": "clip.mp4", "poster": "poster.png", "loop": .bool(true), "muted": .bool(false), "autoplay": .bool(false), "startTime": .number(2.5), "title": "Edited", "key": "demo"]))
    }
}
