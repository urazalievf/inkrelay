import InkRelayCore
import SwiftUI
import WebKit

/// Signs in to Viwoods Cloud inside InkRelay: the user logs in on Viwoods' own page (captcha and all),
/// and InkRelay keeps the access token the page stores, so nobody copies tokens out of developer tools.
struct ViwoodsSignInView: View {
    @ObservedObject var model: BarModel
    let onDone: () -> Void
    @State private var state = "Sign in with your Viwoods account."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(state).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            Divider()
            ViwoodsWebView { token in
                state = "Checking…"
                Task { @MainActor in
                    if let error = model.saveViwoodsToken(token) {
                        state = error
                    } else {
                        onDone()
                    }
                }
            }
        }
        .frame(width: 480, height: 640)
    }
}

/// The portal's login page. Once the page has stored an access token, `onToken` gets it once.
private struct ViwoodsWebView: NSViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.load(URLRequest(url: URL(string: "https://cloud.viwoods.com/login")!))
        context.coordinator.watch(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let onToken: (String) -> Void
        private var timer: Timer?
        private var delivered = false

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func watch(_ view: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] _ in
                guard let self, let view, !self.delivered else { return }
                view.evaluateJavaScript("window.localStorage.getItem('Access-Token')") { value, _ in
                    guard let token = value as? String, token.count > 20, !self.delivered else { return }
                    self.delivered = true
                    self.stop()
                    self.onToken(token)
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }
}
