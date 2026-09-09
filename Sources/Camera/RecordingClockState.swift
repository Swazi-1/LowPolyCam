import Combine
import Foundation

final class RecordingClockState: ObservableObject {
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private var startUptime: TimeInterval?
    private var timer: Timer?
    private let uptimeProvider: () -> TimeInterval

    init(uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptimeProvider = uptimeProvider
    }

    deinit {
        timer?.invalidate()
    }

    func startIfNeeded() {
        if startUptime == nil {
            startUptime = uptimeProvider()
            if elapsedSeconds != 0 { elapsedSeconds = 0 }
        }

        update()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAndReset() {
        timer?.invalidate()
        timer = nil
        startUptime = nil
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
    }

    func update() {
        guard let startUptime else { return }
        let elapsed = floor(max(0, uptimeProvider() - startUptime))
        if elapsed != elapsedSeconds { elapsedSeconds = elapsed }
    }
}
