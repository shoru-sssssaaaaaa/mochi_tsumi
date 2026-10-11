import SwiftUI
import WebKit
import UIKit

/// アプリに同梱した web/index.html（ゲーム本体）を、画面いっぱいに表示する。
/// ネットには一切つながない。
struct GameView: UIViewRepresentable {
    func makeCoordinator() -> GameBridge { GameBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let bridge = context.coordinator

        let contents = WKUserContentController()
        bridge.installSaveScript(into: contents)
        contents.add(bridge, name: "save")    // JS → アプリ：進みぐあいを保存
        contents.add(bridge, name: "haptic")  // JS → アプリ：ぶるっとふるえる
        contents.add(bridge, name: "score")   // JS → アプリ：Game Center にスコアを送る
        contents.add(bridge, name: "leaderboard") // JS → アプリ：ランキング画面を開く

        let config = WKWebViewConfiguration()
        config.userContentController = contents
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        let bg = UIColor(named: "LaunchBackground") ?? .systemRed
        web.isOpaque = false
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.navigationDelegate = bridge
        bridge.webView = web

        bridge.loadGame()
        bridge.prepareHaptics()
        bridge.gameCenter.authenticate()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class GameBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let saveKey = "mochitto-save"
    weak var webView: WKWebView?
    let gameCenter = GameCenter()

    private let lightTap = UIImpactFeedbackGenerator(style: .light)
    private let softTap = UIImpactFeedbackGenerator(style: .soft)
    private let notice = UINotificationFeedbackGenerator()

    /// 同梱の web/index.html を読みこむ（ピンチ拡大は HTML 側の user-scalable=no で止めている）
    func loadGame() {
        guard let web = webView,
              let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else { return }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    override init() {
        super.init()
        gameCenter.onChange = { [weak self] _ in self?.notifyGameCenter() }
    }

    /// Game Center が使えるかどうかを、ページに知らせる
    func notifyGameCenter() {
        webView?.evaluateJavaScript("window.mochiGC&&mochiGC(\(gameCenter.isReady))")
    }

    /// 振動をすぐ出せるように準備しておく
    func prepareHaptics() {
        lightTap.prepare()
        softTap.prepare()
        notice.prepare()
    }

    /// 保存しておいた進みぐあいを、ページのスクリプトより先に window.__MOCHI_SAVE__ に入れる
    func installSaveScript(into contents: WKUserContentController) {
        let saved = UserDefaults.standard.string(forKey: Self.saveKey) ?? "{}"
        let literal = (try? JSONSerialization.data(withJSONObject: saved, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"{}\""
        contents.removeAllUserScripts()
        contents.addUserScript(WKUserScript(source: "window.__MOCHI_SAVE__ = \(literal);",
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "save":
            if let json = message.body as? String, json.utf8.count < 10_000 {
                UserDefaults.standard.set(json, forKey: Self.saveKey)
            }
        case "haptic":
            switch message.body as? String {
            case "light": lightTap.impactOccurred()
            case "soft": softTap.impactOccurred()
            case "success": notice.notificationOccurred(.success)
            case "warning": notice.notificationOccurred(.warning)
            default: break
            }
            prepareHaptics()
        case "score":
            if let body = message.body as? [String: Any],
               let board = body["board"] as? String,
               let value = body["value"] as? Int {
                gameCenter.submit(board: board, value: value)
            }
        case "leaderboard":
            gameCenter.showLeaderboards()
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notifyGameCenter()
    }

    // メモリ不足などでページが落ちたら、最新のセーブで読み直す
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        installSaveScript(into: webView.configuration.userContentController)
        loadGame()
    }
}
