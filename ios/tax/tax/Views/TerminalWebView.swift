import SwiftUI
@preconcurrency import WebKit

struct TerminalWebView: UIViewRepresentable {
    let pipeline: TerminalRenderPipeline

    func makeCoordinator() -> Coordinator { Coordinator(pipeline: pipeline) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "terminalInput")
        configuration.userContentController.add(context.coordinator, name: "terminalResize")
        configuration.userContentController.add(context.coordinator, name: "terminalAck")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.keyboardDismissMode = .interactive
        context.coordinator.webView = view
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalResize")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalAck")
        uiView.navigationDelegate = nil
        coordinator.pipeline?.surface = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, TerminalRendererSurface {
        weak var webView: WKWebView?
        weak var pipeline: TerminalRenderPipeline?
        private var snapshotGeneration = 0
        private var pendingAckGeneration = 0
        private var pendingCompletion: (@MainActor () -> Void)?
        private var isReady = false

        init(pipeline: TerminalRenderPipeline) {
            self.pipeline = pipeline
        }

        func apply(update: TerminalRenderUpdate, completion: (@MainActor () -> Void)?) {
            guard webView != nil else {
                completion?()
                return
            }
            if update.resetsTerminal {
                snapshotGeneration += 1
                pendingAckGeneration = snapshotGeneration
                pendingCompletion = completion
            }
            let reset = update.resetsTerminal ? "true" : "false"
            webView?.evaluateJavaScript("window.taxTerminal.push('\(update.data.base64EncodedString())', \(reset))")
        }

        func requestFocus() {
            webView?.evaluateJavaScript("document.getElementById('terminal').focus()")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            pipeline?.surface = self
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "terminalInput",
               let bytes = message.body as? [UInt8] {
                pipeline?.rendererDidReceiveInput(Data(bytes))
            } else if message.name == "terminalResize",
                      let body = message.body as? [String: Int],
                      let columns = body["columns"],
                      let rows = body["rows"] {
                let viewport = TerminalRendererViewport(columns: columns, rows: rows)
                if !isReady {
                    isReady = true
                    pipeline?.rendererDidBecomeReady(viewport: viewport)
                } else {
                    pipeline?.rendererViewportDidChange(viewport)
                }
            } else if message.name == "terminalAck" {
                if pendingAckGeneration == snapshotGeneration {
                    let completion = pendingCompletion
                    pendingCompletion = nil
                    completion?()
                }
            }
        }
    }

    private static let html = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <link rel="stylesheet" href="xterm.css">
    <style>
      html,body,#terminal{width:100%;height:100%;margin:0;background:#101114;overflow:hidden}
      .xterm{height:100%;padding:2px 0}.xterm-viewport{touch-action:none!important;overscroll-behavior:none!important}
    </style></head><body><div id="terminal"></div><script src="xterm.js"></script><script>
    const terminal = new Terminal({
      cursorBlink:true, convertEol:false, scrollback:5000, smoothScrollDuration:0,
      fontFamily:'SFMono-Regular,Menlo,monospace', fontSize:13,
      theme:{background:'#101114'}
    });
    const element = document.getElementById('terminal');
    terminal.open(element);
    terminal.onData(value => webkit.messageHandlers.terminalInput.postMessage(
      Array.from(new TextEncoder().encode(value))
    ));

    window.taxTerminal={push:(value,reset)=>{
      const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
      if (reset) terminal.reset();
      terminal.write(bytes, () => {
        if (reset) webkit.messageHandlers.terminalAck.postMessage(null);
      });
    }};

    let resizeTimer, lastColumns=0, lastRows=0;
    function reportSize(){
      clearTimeout(resizeTimer);
      resizeTimer=setTimeout(()=>{
        const cell=terminal._core?._renderService?.dimensions?.css?.cell;
        if(!cell?.width||!cell?.height) return;
        const columns=Math.max(2,Math.floor(element.clientWidth/cell.width));
        const rows=Math.max(1,Math.floor(element.clientHeight/cell.height));
        if(columns===lastColumns&&rows===lastRows) return;
        lastColumns=columns; lastRows=rows;
        webkit.messageHandlers.terminalResize.postMessage({columns,rows});
      },180);
    }
    new ResizeObserver(reportSize).observe(element);
    setTimeout(reportSize,100);

    let touchStartY=0, touchLastY=0, touchTravel=0, touchRemainder=0;
    element.addEventListener('touchstart',event=>{
      if(event.touches.length!==1) return;
      touchStartY=touchLastY=event.touches[0].clientY; touchTravel=0; touchRemainder=0;
    },{passive:true});
    element.addEventListener('touchmove',event=>{
      if(event.touches.length!==1) return;
      const current=event.touches[0].clientY;
      const delta=touchLastY-current;
      touchLastY=current; touchTravel+=Math.abs(delta); touchRemainder+=delta;
      const cellHeight=terminal._core?._renderService?.dimensions?.css?.cell?.height||16;
      const lines=Math.trunc(touchRemainder/cellHeight);
      if(lines!==0){ terminal.scrollLines(lines); touchRemainder-=lines*cellHeight; }
      event.preventDefault();
    },{passive:false});
    element.addEventListener('touchend',()=>{ if(touchTravel<8) terminal.focus(); },{passive:true});
    </script></body></html>
    """
}
