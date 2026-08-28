import SwiftUI
@preconcurrency import WebKit

protocol TerminalRenderer: AnyObject {
    func restore(snapshot: Data)
    func write(data: Data)
    func clear()
}

struct TerminalWebView: UIViewRepresentable {
    let data: Data
    let onInput: @MainActor (String) -> Void
    let onResize: @MainActor (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput, onResize: onResize) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "terminalInput")
        configuration.userContentController.add(context.coordinator, name: "terminalResize")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        context.coordinator.webView = view
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastData != data else { return }
        let previous = context.coordinator.lastData
        context.coordinator.lastData = data
        let addition: Data
        let method: String
        if data.starts(with: previous) {
            addition = data.dropFirst(previous.count)
            method = "write"
        } else {
            addition = data
            method = "reset"
        }
        guard !addition.isEmpty else { return }
        if method == "write" { context.coordinator.write(data: addition) }
        else { context.coordinator.restore(snapshot: addition) }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalResize")
        uiView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, TerminalRenderer {
        weak var webView: WKWebView?
        var lastData = Data()
        private var isReady = false
        private let onInput: @MainActor (String) -> Void
        private let onResize: @MainActor (Int, Int) -> Void

        init(onInput: @escaping @MainActor (String) -> Void, onResize: @escaping @MainActor (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func restore(snapshot: Data) { evaluate(method: "reset", data: snapshot) }
        func write(data: Data) { evaluate(method: "write", data: data) }
        func clear() {
            guard isReady else { return }
            webView?.evaluateJavaScript("window.taxTerminal.reset('')")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isReady = true
            if !lastData.isEmpty { restore(snapshot: lastData) }
        }

        private func evaluate(method: String, data: Data) {
            guard isReady else { return }
            webView?.evaluateJavaScript("window.taxTerminal.\(method)('\(data.base64EncodedString())')")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "terminalInput", let bytes = message.body as? [UInt8], let text = String(bytes: bytes, encoding: .utf8) {
                onInput(text)
            } else if message.name == "terminalResize", let body = message.body as? [String: Int], let columns = body["columns"], let rows = body["rows"] {
                onResize(columns, rows)
            }
        }
    }

    private static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <link rel="stylesheet" href="xterm.css"><style>html,body,#terminal{width:100%;height:100%;margin:0;background:#101114;overflow:hidden}</style></head>
    <body><div id="terminal"></div><script src="xterm.js"></script><script>
    const terminal = new Terminal({cursorBlink:true,convertEol:false,scrollback:5000,fontFamily:'SFMono-Regular,Menlo,monospace',fontSize:13,theme:{background:'#101114'}});
    terminal.open(document.getElementById('terminal'));
    const decode = value => new TextDecoder().decode(Uint8Array.from(atob(value), c => c.charCodeAt(0)));
    terminal.onData(value => webkit.messageHandlers.terminalInput.postMessage(Array.from(new TextEncoder().encode(value))));
    function reportSize(){const d=terminal._core?._renderService?.dimensions?.css?.cell;if(!d?.width||!d?.height)return;const e=document.getElementById('terminal');webkit.messageHandlers.terminalResize.postMessage({columns:Math.max(2,Math.floor(e.clientWidth/d.width)),rows:Math.max(1,Math.floor(e.clientHeight/d.height))});}
    new ResizeObserver(reportSize).observe(document.getElementById('terminal'));
    window.taxTerminal={write:value=>terminal.write(decode(value)),reset:value=>{terminal.reset();terminal.write(decode(value));}};
    setTimeout(reportSize,100);
    </script></body></html>
    """
}
