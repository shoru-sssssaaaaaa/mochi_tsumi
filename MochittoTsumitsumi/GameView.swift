import SwiftUI
import WebKit
import UIKit
import StoreKit

/// アプリに同梱した web/index.html（ゲーム本体）を、画面いっぱいに表示する。
/// 通信は Game Center と、1日1回のアップデート確認（AppUpdate）だけ。
struct GameView: UIViewRepresentable {
    func makeCoordinator() -> GameBridge { GameBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let bridge = context.coordinator

        let contents = WKUserContentController()
        bridge.installBootScript(into: contents)
        contents.add(bridge, name: "save")    // JS → アプリ：進みぐあいを保存
        contents.add(bridge, name: "haptic")  // JS → アプリ：ぶるっとふるえる
        contents.add(bridge, name: "score")   // JS → アプリ：Game Center にスコアを送る
        contents.add(bridge, name: "ranking") // JS → アプリ：ランキングを読みこんで mochiRank() で返す
        contents.add(bridge, name: "leaderboard") // JS → アプリ：Game Center のランキング画面を開く
        contents.add(bridge, name: "review")  // JS → アプリ：App Store のレビューをおねがいする
        contents.add(bridge, name: "tilt")    // JS → アプリ：かたむきを mochiTilt() で送りはじめる／やめる
        contents.add(bridge, name: "update")  // JS → アプリ：App Store のページを開く

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
        bridge.appUpdate.check { [weak bridge] _ in bridge?.notifyUpdate() }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class GameBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let saveKey = "mochitto-save"
    weak var webView: WKWebView?
    let gameCenter = GameCenter()
    let tilt = Tilt()
    let appUpdate = AppUpdate()

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
        tilt.onChange = { [weak self] x in
            self?.webView?.evaluateJavaScript("window.mochiTilt&&mochiTilt(\(String(format: "%.4f", x)))")
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tilt.pause() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tilt.resume() }
        }
    }

    /// Game Center が使えるかどうかを、ページに知らせる
    func notifyGameCenter() {
        webView?.evaluateJavaScript("window.mochiGC&&mochiGC(\(gameCenter.isReady))")
    }

    /// App Store に新しいバージョンがあれば、ページに知らせる（ホームで いちどだけ おしらせが出る）
    func notifyUpdate() {
        guard let version = appUpdate.available else { return }
        webView?.evaluateJavaScript("window.mochiUpdate&&mochiUpdate(\(Self.jsString(version)))")
    }

    /// 振動をすぐ出せるように準備しておく
    func prepareHaptics() {
        lightTap.prepare()
        softTap.prepare()
        notice.prepare()
    }

    /// ページのスクリプトより先に、保存しておいた進みぐあい（window.__MOCHI_SAVE__）と
    /// iOS がこのアプリに選んだ言語（window.__MOCHI_LANG__、"ja" か "en"）と、バージョン（window.__MOCHI_VER__）を入れる
    func installBootScript(into contents: WKUserContentController) {
        let saved = UserDefaults.standard.string(forKey: Self.saveKey) ?? "{}"
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        contents.removeAllUserScripts()
        contents.addUserScript(WKUserScript(source: "window.__MOCHI_SAVE__ = \(Self.jsString(saved)); window.__MOCHI_LANG__ = \(Self.jsString(lang)); window.__MOCHI_VER__ = \(Self.jsString(version));",
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: true))
    }

    private static func jsString(_ value: String) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
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
        case "ranking":
            guard let board = message.body as? String else { break }
            Task {
                let result = await gameCenter.loadRanking(board: board)
                guard let data = try? JSONSerialization.data(withJSONObject: result),
                      let json = String(data: data, encoding: .utf8) else { return }
                _ = try? await webView?.evaluateJavaScript("window.mochiRank&&mochiRank(\(json))")
            }
        case "leaderboard":
            gameCenter.showLeaderboards()
        case "review":
            // 実際に出すかどうか（1年に3回まで）は iOS が決める。TestFlight では出ない
            if let scene = webView?.window?.windowScene { AppStore.requestReview(in: scene) }
        case "tilt":
            tilt.set(message.body as? Bool ?? false)
        case "update":
            UIApplication.shared.open(AppUpdate.storeURL)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notifyGameCenter()
        notifyUpdate()
    }

    // メモリ不足などでページが落ちたら、最新のセーブで読み直す
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tilt.set(false)
        installBootScript(into: webView.configuration.userContentController)
        loadGame()
    }
}
