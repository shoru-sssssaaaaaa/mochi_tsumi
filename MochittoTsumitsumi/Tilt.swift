import CoreMotion

/// iPhone の かたむき（画面の左右方向にかかる重力。-1〜1、右が下がるとプラス）を知らせる。
/// ゲーム中だけ動かし、アプリが うしろに回っているあいだは止める。
@MainActor
final class Tilt {
    var onChange: ((Double) -> Void)?
    private let motion = CMMotionManager()
    private var wanted = false
    private var last = 0.0

    func set(_ on: Bool) {
        wanted = on
        on ? start() : motion.stopDeviceMotionUpdates()
    }

    func pause() { motion.stopDeviceMotionUpdates() }
    func resume() { if wanted { start() } }

    private func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        last = .greatestFiniteMagnitude
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let x = data?.gravity.x, abs(x - self.last) > 0.002 else { return }
            self.last = x
            self.onChange?(x)
        }
    }
}
