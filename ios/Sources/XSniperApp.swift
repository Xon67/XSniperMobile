import SwiftUI
import WebKit

@main
struct XSniperApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

struct RootView: View {
    @AppStorage("serverURL") private var saved = ""
    @State private var input = ""
    @State private var failed = false
    @State private var reload = 0
    private let bg = Color(red: 0.11, green: 0.11, blue: 0.125)
    private let brand = Color(red: 0.608, green: 0.361, blue: 1.0)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            if let url = URL(string: saved), !saved.isEmpty {
                WebView(url: url, failed: $failed, reload: reload).ignoresSafeArea(edges: .bottom)
                if failed { problem }
            } else {
                setup
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true            // keep the screen awake
            if !saved.isEmpty { SnipeListener.shared.start(link: saved) }
        }
        .onChange(of: saved) { link in
            if link.isEmpty { SnipeListener.shared.stop() } else { SnipeListener.shared.start(link: link) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            SnipeListener.shared.ensure()
        }
    }

    var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("XSniper").font(.system(size: 34, weight: .bold)).foregroundColor(brand)
            Text("On your PC open XSniper, go to Settings, Phone web server, press Copy link, then paste it here.")
                .foregroundColor(.gray)
            TextField("http://192.168.1.5:8765/?t=...", text: $input)
                .textInputAutocapitalization(.never).autocorrectionDisabled(true).keyboardType(.URL)
                .padding(14).background(Color.black.opacity(0.4)).cornerRadius(4)
            Button {
                var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty && !s.lowercased().hasPrefix("http") { s = "http://" + s }
                if URL(string: s) != nil { saved = s; failed = false }
            } label: {
                Text("Connect").bold().frame(maxWidth: .infinity, minHeight: 54)
                    .background(brand.opacity(0.3)).foregroundColor(.white).cornerRadius(4)
            }
        }.padding(24)
    }

    var problem: some View {
        VStack(spacing: 12) {
            Text("Can't reach your PC").font(.headline)
            Text("Check the PC is on, the webserver is launched and this phone is on the same WiFi.")
                .font(.footnote).multilineTextAlignment(.center).foregroundColor(.gray)
            HStack {
                Button("Retry") { failed = false; reload += 1 }
                Button("Change server") { saved = ""; input = ""; failed = false }
            }.buttonStyle(.bordered)
        }
        .padding(22).background(.ultraThinMaterial).cornerRadius(10).padding(24)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var failed: Bool
    let reload: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.bounces = false
        w.load(URLRequest(url: url))
        context.coordinator.lastReload = reload
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            w.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastReload = 0
        init(_ p: WebView) { parent = p }

        // Join links (roblox.com) leave the app and open the real Roblox app.
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = a.request.url, let host = u.host, host != parent.url.host,
               a.targetFrame?.isMainFrame != false {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { parent.failed = false }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { parent.failed = true }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { parent.failed = true }
    }
}
