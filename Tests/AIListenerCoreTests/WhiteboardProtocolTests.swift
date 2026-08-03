import Foundation
import Testing
@testable import AIListenerCore

struct WhiteboardProtocolTests {
    @Test func testWhiteboardSanitizerStripsDangerousTags() {
        let maliciousInput = "<script>alert('xss')</script>Hello <iframe src='evil.com'></iframe> javascript:void(0) onload=bad()"
        let clean = WhiteboardSanitizer.sanitizeText(maliciousInput)

        #expect(!clean.contains("<script>"))
        #expect(!clean.contains("</script>"))
        #expect(!clean.contains("javascript:"))
        #expect(!clean.contains("onload="))
        #expect(!clean.contains("<iframe"))
    }

    @Test func testNodeAndActionEncodingDecoding() throws {
        let node = WhiteboardNode(
            id: "node_123",
            type: .card,
            label: "测试任务卡片",
            x: 100,
            y: 200,
            width: 180,
            height: 90,
            backgroundColor: "#ffffff",
            strokeColor: "#000000",
            metadata: ["key": "value"]
        )

        let action = WhiteboardAction(
            kind: .addCard,
            node: node
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(action)
        let decoded = try decoder.decode(WhiteboardAction.self, from: data)

        #expect(decoded.kind == .addCard)
        #expect(decoded.node?.id == "node_123")
        #expect(decoded.node?.type == .card)
        #expect(decoded.node?.label == "测试任务卡片")
        #expect(decoded.node?.metadata?["key"] == "value")
    }

    @Test func testSanitizeActionAppliesToNodeAndConnection() {
        let dirtyNode = WhiteboardNode(
            id: "dirty_1",
            type: .rectangle,
            label: "<script>hack()</script>正常节点",
            x: 0,
            y: 0,
            metadata: ["bad": "javascript:alert(1)"]
        )
        let action = WhiteboardAction(kind: .addNode, node: dirtyNode)
        let cleanAction = WhiteboardSanitizer.sanitizeAction(action)

        #expect(cleanAction.node?.label.contains("script") == false)
        #expect(cleanAction.node?.metadata?["bad"]?.contains("javascript:") == false)
    }
}
