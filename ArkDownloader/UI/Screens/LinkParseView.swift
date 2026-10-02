import SwiftUI
import WebKit

/// Embeds the CloudDrive parse page (https://clouds.arkdream.top/c?embed=1).
/// The page can push download tasks to this app via the local RPC bridge.
struct LinkParseView: View {
    @ObservedObject var vm: MainViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                ArkColors.bg.ignoresSafeArea()
                WebView(url: AppSettings.ensureParsePageEmbedParams(vm.settings.parsePageUrl))
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
    }
}

struct WebView: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        if let u = URL(string: url) {
            webView.load(URLRequest(url: u))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
