import GameKit
import UIKit

/// Game Center のサインイン・スコア送信・ランキング画面。
/// サインインしていないときは何もしない（ゲームはそのまま遊べる）。
@MainActor
final class GameCenter {
    /// JS から届く名前 → App Store Connect で作ったリーダーボードID
    static let leaderboards = [
        "stage": "com.shotasakaguchi.mochittotsumitsumi.max_stage",
        "free": "com.shotasakaguchi.mochittotsumitsumi.free_best",
    ]

    var onChange: ((Bool) -> Void)?
    var isReady: Bool { GKLocalPlayer.local.isAuthenticated }

    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, _ in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    self.present(viewController)
                } else {
                    self.onChange?(self.isReady)
                }
            }
        }
    }

    func submit(board: String, value: Int) {
        guard isReady, value > 0, let id = Self.leaderboards[board] else { return }
        GKLeaderboard.submitScore(value, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [id]) { _ in }
    }

    /// ゲーム内のランキング画面用に、上位とじぶんの順位を読みこむ（JS にそのまま渡せる形）
    func loadRanking(board: String) async -> [String: Any] {
        var result: [String: Any] = ["board": board, "ok": false]
        guard isReady, let id = Self.leaderboards[board] else { return result }
        do {
            guard let leaderboard = try await GKLeaderboard.loadLeaderboards(IDs: [id]).first else { return result }
            let (me, top, total) = try await leaderboard.loadEntries(
                for: .global, timeScope: .allTime, range: NSRange(location: 1, length: Self.rankingSize))
            let myID = GKLocalPlayer.local.gamePlayerID
            func row(_ e: GKLeaderboard.Entry) -> [String: Any] {
                ["rank": e.rank, "name": e.player.displayName, "value": e.score, "me": e.player.gamePlayerID == myID]
            }
            result["ok"] = true
            result["total"] = total
            result["top"] = top.map(row)
            if let me { result["me"] = row(me) }
        } catch {}
        return result
    }

    private static let rankingSize = 20

    /// GKGameCenterViewController は iOS 26 で非推奨。自前で present すると、
    /// 表示に失敗したとき透明な画面が残って操作できなくなるので、表示と終了は GameKit にまかせる。
    func showLeaderboards() {
        guard isReady else { return }
        GKAccessPoint.shared.trigger(state: .leaderboards) {}
    }

    private func present(_ vc: UIViewController) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard var top = window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        top.present(vc, animated: true)
    }
}
