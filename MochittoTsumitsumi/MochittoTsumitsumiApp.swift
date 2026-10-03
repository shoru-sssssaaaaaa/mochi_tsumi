import SwiftUI
import AVFoundation

@main
struct MochittoTsumitsumiApp: App {
    init() {
        // ほかのアプリで流している音楽を止めない。消音スイッチがONなら音を出さない。
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            GameView()
                .ignoresSafeArea()          // 画面いっぱいに表示（すき間はHTML側でよける）
                .background(Color("LaunchBackground").ignoresSafeArea())
                .persistentSystemOverlays(.hidden) // ホームバーを目立たなくする
        }
    }
}
