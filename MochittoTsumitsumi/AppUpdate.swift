import UIKit

/// App Store に新しいバージョンが出ているかを、1日1回だけ確かめる（アプリで ただひとつの通信）。
/// 送るのはアプリのIDと国だけ。オフラインや失敗のときは何もしない。
@MainActor
final class AppUpdate {
    static let appID = "6818688922"
    static let storeURL = URL(string: "itms-apps://apps.apple.com/app/id\(appID)")!
    private static let checkedKey = "update-checked-at"
    private static let latestKey = "update-latest"

    /// 前に見つけたバージョンが、いま入っているものより新しければ返す
    var available: String? {
        guard let latest = UserDefaults.standard.string(forKey: Self.latestKey),
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              latest.compare(current, options: .numeric) == .orderedDescending else { return nil }
        return latest
    }

    func check(onFound: @escaping (String) -> Void) {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.checkedKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: Self.appID)]
        if let region = Locale.current.region?.identifier {
            url.queryItems?.append(URLQueryItem(name: "country", value: region))
        }
        let request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return }
            defaults.set(Date(), forKey: Self.checkedKey)
            // この iPhone の iOS では入れられない新しい版は、知らせない
            if let app = results.first, let version = app["version"] as? String,
               UIDevice.current.systemVersion.compare(app["minimumOsVersion"] as? String ?? "0", options: .numeric) != .orderedAscending {
                defaults.set(version, forKey: Self.latestKey)
            } else {
                defaults.removeObject(forKey: Self.latestKey)
            }
            if let version = available { onFound(version) }
        }
    }
}
