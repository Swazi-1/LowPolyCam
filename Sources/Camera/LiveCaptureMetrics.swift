import AVFoundation
import Foundation

/// Measures the capture callback stream. These drops are not encoder drops.
final class LiveCaptureMetrics: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "com.swazi.lowpolycam.liveMetrics", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var first: Double?
    private var latest: Double?
    private var intervals = 0
    private var dropped = 0

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setRunning(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        running = value
        first = nil
        latest = nil
        intervals = 0
        dropped = 0
    }

    func read() -> (fps: Double?, drops: Int) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = (latest ?? 0) - (first ?? 0)
        let fps = elapsed > 0 && intervals > 0 ? Double(intervals) / elapsed : nil
        // Keep a rolling measurement window; drop count remains per clip.
        first = latest
        intervals = 0
        return (fps, dropped)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        if first == nil { first = timestamp } else { intervals += 1 }
        latest = timestamp
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        defer { lock.unlock() }
        if running { dropped += 1 }
    }
}
