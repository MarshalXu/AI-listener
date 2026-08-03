import SwiftUI
import WebKit
import AIListenerCore

public struct WhiteboardWebView: NSViewRepresentable {
    public let nodes: [WhiteboardNode]
    public let connections: [WhiteboardConnection]
    public var onUserEditedNode: ((WhiteboardNode) -> Void)?

    public init(
        nodes: [WhiteboardNode],
        connections: [WhiteboardConnection],
        onUserEditedNode: ((WhiteboardNode) -> Void)? = nil
    ) {
        self.nodes = nodes
        self.connections = connections
        self.onUserEditedNode = onUserEditedNode
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "whiteboardBridge")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView

        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    background-color: #fafafa;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    overflow: auto;
                    user-select: none;
                }
                #canvas {
                    position: relative;
                    width: 2000px;
                    height: 2000px;
                    background-size: 20px 20px;
                    background-image: radial-gradient(circle, #e0e0e0 1px, transparent 1px);
                }
                .wb-node {
                    position: absolute;
                    border: 2px solid #333;
                    border-radius: 8px;
                    padding: 8px 12px;
                    box-shadow: 2px 2px 6px rgba(0,0,0,0.1);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    text-align: center;
                    font-size: 13px;
                    font-weight: 500;
                    cursor: move;
                    box-sizing: border-box;
                    background-color: white;
                    color: #333;
                    transition: transform 0.1s ease;
                }
                .wb-node.flowStep {
                    border-radius: 4px;
                    border-left: 6px solid #1E88E5;
                }
                .wb-node.timelineEvent {
                    border-radius: 16px;
                    border-left: 6px solid #FB8C00;
                }
                .wb-node.card {
                    border-radius: 6px;
                    border-top: 6px solid #43A047;
                }
                .wb-node.ellipse {
                    border-radius: 50%;
                }
                .wb-node.diamond {
                    transform: rotate(45deg);
                }
                .wb-node.diamond > span {
                    transform: rotate(-45deg);
                }
                svg.connections {
                    position: absolute;
                    top: 0;
                    left: 0;
                    width: 2000px;
                    height: 2000px;
                    pointer-events: none;
                }
            </style>
        </head>
        <body>
            <div id="canvas">
                <svg class="connections" id="svg-connections"></svg>
            </div>
            <script>
                const canvas = document.getElementById('canvas');
                const svg = document.getElementById('svg-connections');

                let nodesData = [];
                let connectionsData = [];

                window.renderData = function(nodesJson, connectionsJson) {
                    nodesData = JSON.parse(nodesJson);
                    connectionsData = JSON.parse(connectionsJson);
                    draw();
                };

                function draw() {
                    // Clear existing node elements
                    const existingNodes = canvas.querySelectorAll('.wb-node');
                    existingNodes.forEach(n => n.remove());
                    svg.innerHTML = '';

                    // Draw nodes
                    nodesData.forEach(node => {
                        const el = document.createElement('div');
                        el.className = 'wb-node ' + (node.type || 'rectangle');
                        el.style.left = node.x + 'px';
                        el.style.top = node.y + 'px';
                        el.style.width = (node.width || 160) + 'px';
                        el.style.height = (node.height || 80) + 'px';
                        if (node.backgroundColor) el.style.backgroundColor = node.backgroundColor;
                        if (node.strokeColor) el.style.borderColor = node.strokeColor;

                        const span = document.createElement('span');
                        span.textContent = node.label || '';
                        el.appendChild(span);

                        // Simple Dragging
                        let isDragging = false;
                        let startX, startY, origX, origY;

                        el.addEventListener('mousedown', (e) => {
                            isDragging = true;
                            startX = e.clientX;
                            startY = e.clientY;
                            origX = node.x;
                            origY = node.y;
                            e.stopPropagation();
                        });

                        document.addEventListener('mousemove', (e) => {
                            if (!isDragging) return;
                            const dx = e.clientX - startX;
                            const dy = e.clientY - startY;
                            node.x = origX + dx;
                            node.y = origY + dy;
                            el.style.left = node.x + 'px';
                            el.style.top = node.y + 'px';
                        });

                        document.addEventListener('mouseup', () => {
                            if (isDragging) {
                                isDragging = false;
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.whiteboardBridge) {
                                    window.webkit.messageHandlers.whiteboardBridge.postMessage({
                                        event: 'userEditedNode',
                                        node: node
                                    });
                                }
                            }
                        });

                        canvas.appendChild(el);
                    });
                }
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(htmlString, baseURL: nil)
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        let encoder = JSONEncoder()
        guard let nodesData = try? encoder.encode(nodes),
              let connsData = try? encoder.encode(connections),
              let nodesJson = String(data: nodesData, encoding: .utf8),
              let connsJson = String(data: connsData, encoding: .utf8) else {
            return
        }

        let js = "if (window.renderData) { window.renderData(\(jsQuote(nodesJson)), \(jsQuote(connsJson))); }"
        nsView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsQuote(_ str: String) -> String {
        guard let data = try? JSONEncoder().encode(str),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return jsonStr
    }

    public class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: WhiteboardWebView
        weak var webView: WKWebView?

        init(parent: WhiteboardWebView) {
            self.parent = parent
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "whiteboardBridge",
                  let body = message.body as? [String: Any],
                  let event = body["event"] as? String else {
                return
            }

            if event == "userEditedNode",
               let nodeDict = body["node"] as? [String: Any],
               let nodeData = try? JSONSerialization.data(withJSONObject: nodeDict),
               let node = try? JSONDecoder().decode(WhiteboardNode.self, from: nodeData) {
                parent.onUserEditedNode?(node)
            }
        }
    }
}
