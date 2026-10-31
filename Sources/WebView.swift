import SwiftUI
import WebKit

/// Embedded browser for deposit pages, so choosing an opportunity never kicks the
/// user out to Safari — the app itself is the whole experience.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the target actually changed, so we don't interrupt the
        // user mid-navigation on unrelated SwiftUI updates.
        if webView.url != url, webView.isLoading == false {
            let current = webView.url?.absoluteString ?? ""
            if current != url.absoluteString {
                webView.load(URLRequest(url: url))
            }
        }
    }
}

/// A sheet that shows a deposit page with a title bar and a "done" affordance.
struct DepositSheet: View {
    let opportunity: YieldOpportunity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deposit into \(opportunity.displayName)")
                        .font(.headline)
                    Text(opportunity.depositURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)

            Divider()

            WebView(url: opportunity.depositURL)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}