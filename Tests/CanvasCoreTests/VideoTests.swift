import Foundation
import Testing
import CanvasCore

extension ApiRouterTests {
    @Test func videoPropsPersistAndRejectInvalidUpdates() async throws {
        let client = try connect()
        let props: JSONValue = .object(["path": "clip.mp4", "poster": "poster.png", "loop": true, "muted": false, "autoplay": false, "startTime": 1.25, "title": "Demo", "key": "demo"])
        let created = try await call(client, "object.create", ["board": .string(board.id), "type": "video", "props": props])
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        #expect(created["result"]?["warnings"] == nil)
        let patches: [JSONValue] = [
            .object(["startTime": -1]), .object(["startTime": "2"]), .object(["startTime": true]),
            .object(["loop": "true"]), .object(["muted": 1]), .object(["autoplay": "false"]),
            .object(["poster": 2]), .object(["title": false]), .object(["path": .null])
        ]
        for patch in patches {
            let reply = try await call(client, "object.update", ["id": .string(id), "props": patch])
            #expect(reply["error"]?["code"] == "invalid_params")
        }
        _ = try await call(client, "object.update", ["id": .string(id), "props": .object(["startTime": 2.5, "title": "Edited"])])
        let store = BoardStore(directory: dir.appendingPathComponent("video-store"))
        try store.saveChecked(board)
        let restored = store.load(root: board.root)
        let object = try restored.object(id)
        #expect(object.type == .video)
        #expect(object.props == props.merging(.object(["startTime": 2.5, "title": "Edited"])))
    }
}
