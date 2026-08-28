import SwiftUI
@preconcurrency import WebKit

protocol TerminalRenderer: AnyObject {
    func render(_ update: TerminalRenderUpdate)
    func clear()
}

struct TerminalWebView: UIViewRepresentable {
    let update: TerminalRenderUpdate
    let onInput: @MainActor (String) -> Void
    let onResize: @MainActor (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput, onResize: onResize) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "terminalInput")
        configuration.userContentController.add(context.coordinator, name: "terminalResize")
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

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.render(update)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalResize")
        uiView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, TerminalRenderer {
        weak var webView: WKWebView?
        private var lastSequence: UInt64 = 0
        private var isReady = false
        private var pendingReset = false
        private var pendingData = Data()
        private let onInput: @MainActor (String) -> Void
        private let onResize: @MainActor (Int, Int) -> Void

        init(onInput: @escaping @MainActor (String) -> Void, onResize: @escaping @MainActor (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func render(_ update: TerminalRenderUpdate) {
            guard update.sequence > lastSequence else { return }
            lastSequence = update.sequence
            if !isReady {
                if update.resetsTerminal {
                    pendingReset = true
                    pendingData = update.data
                } else {
                    pendingData.append(update.data)
                }
                return
            }
            evaluate(update)
        }

        func clear() {
            pendingReset = true
            pendingData.removeAll(keepingCapacity: true)
            guard isReady else { return }
            evaluate(TerminalRenderUpdate(sequence: lastSequence, resetsTerminal: true, data: Data()))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isReady = true
            if pendingReset || !pendingData.isEmpty {
                evaluate(TerminalRenderUpdate(sequence: lastSequence, resetsTerminal: pendingReset, data: pendingData))
                pendingReset = false
                pendingData.removeAll(keepingCapacity: true)
            }
        }

        private func evaluate(_ update: TerminalRenderUpdate) {
            let reset = update.resetsTerminal ? "true" : "false"
            webView?.evaluateJavaScript("window.taxTerminal.push('\(update.data.base64EncodedString())', \(reset))")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "terminalInput",
               let bytes = message.body as? [UInt8],
               let text = String(bytes: bytes, encoding: .utf8) {
                onInput(text)
            } else if message.name == "terminalResize",
                      let body = message.body as? [String: Int],
                      let columns = body["columns"],
                      let rows = body["rows"] {
                onResize(columns, rows)
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

    let renderQueue = [], writing = false;
    const bytes = value => Uint8Array.from(atob(value), character => character.charCodeAt(0));
    function flushRenderQueue(){
      if(writing || renderQueue.length===0) return;
      writing=true;
      let resetIndex=-1;
      for(let index=0; index<renderQueue.length; index++) if(renderQueue[index].reset) resetIndex=index;
      if(resetIndex>=0){ terminal.reset(); renderQueue=renderQueue.slice(resetIndex); }
      const items=renderQueue.splice(0);
      const size=items.reduce((total,item)=>total+item.data.length,0);
      const combined=new Uint8Array(size); let offset=0;
      for(const item of items){ combined.set(item.data,offset); offset+=item.data.length; }
      if(combined.length===0){ writing=false; flushRenderQueue(); return; }
      terminal.write(combined,()=>{ writing=false; requestAnimationFrame(flushRenderQueue); });
    }
    window.taxTerminal={push:(value,reset)=>{
      renderQueue.push({data:bytes(value),reset});
      requestAnimationFrame(flushRenderQueue);
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
