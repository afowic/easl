import Foundation
import Testing
@testable import CanvasCore

struct SurfaceProtocolTests {
    @Test func progressIsASeparatePrivateRequest() throws {
        #expect(try SurfaceRequest(method: "surface.progress", params: .object([
            "stream": "str_refresh", "frame": 7, "offset": 16384,
        ])) == .progress(stream: "str_refresh", frame: 7, offset: 16384))
        #expect(try SurfaceRequest(method: "surface.ack", params: .object([
            "stream": "str_refresh", "frame": 0,
        ])) == .ack(stream: "str_refresh", frame: 0))
        #expect(try SurfaceRequest(method: "surface.progress", params: .object([
            "stream": "str_refresh", "frame": 7, "offset": 573440,
        ])) == .progress(stream: "str_refresh", frame: 7, offset: 573440))
    }

    @Test func malformedProgressIsRejectedAtTheBoundary() {
        let valid: [String: JSONValue] = ["stream": "str_refresh", "frame": 7, "offset": 0]
        let invalid: [(String, JSONValue?)] = [
            ("stream", "obj_wrong"), ("stream", nil), ("frame", 0), ("frame", -1),
            ("frame", 1.5), ("frame", nil), ("offset", -16384), ("offset", 1),
            ("offset", 589824), ("offset", 0.5), ("offset", "0"), ("offset", nil),
        ]
        for (key, value) in invalid {
            var params = valid
            params[key] = value
            #expect(throws: ApiRouter.Failure.self) {
                try SurfaceRequest(method: "surface.progress", params: .object(params))
            }
        }
    }

    @Test func removedRegionFormatIsNotNegotiated() throws {
        #expect(SurfaceFormat(rawValue: "patch") == nil)
        #expect(throws: ApiRouter.Failure.self) {
            try SurfaceRequest(method: "surface.stream", params: .object(["id": "obj_page", "format": "patch"]))
        }
        #expect(try SurfaceRequest(method: "surface.stream", params: .object(["id": "obj_page", "format": "h264"])) ==
            .stream(tile: "obj_page", scale: 1, format: .h264))
    }

    @Test func normalFramesKeepTheirWireShapeAndFragmentsAddOnlyTransportMetadata() throws {
        var frame = SurfaceEvent.Frame(stream: "str_refresh", seq: 7, input: 3,
            size: CGSize(width: 2, height: 2), scale: 1, format: .h264,
            data: Data([1, 2, 3]), width: 2, height: 2, back: false, forward: false, loading: false)
        let normal: JSONValue = .object([
            "stream": "str_refresh", "seq": 7, "input": 3, "size": .object(["w": 2, "h": 2]),
            "scale": 1, "format": "h264", "data": "AQID", "width": 2, "height": 2,
            "back": false, "forward": false, "loading": false,
        ])
        #expect(frame.json == normal)
        frame.refresh = true
        var transmission = try SurfaceRefreshTransmission(frame: frame)
        let fragment = try #require(transmission.start().first)
        #expect(fragment.json == normal.merging(.object(["refresh": true, "offset": 0, "total": 3])))
        var assembly = SurfaceRefreshAssembly()
        #expect(try assembly.append(frame: fragment)?.json == normal.merging(.object(["refresh": true])))
    }
}
