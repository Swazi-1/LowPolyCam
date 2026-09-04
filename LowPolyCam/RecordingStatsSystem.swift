//
//  RecordingStatsSystem.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import Foundation
import Observation
import CoreMedia
import QuartzCore // CACurrentMediaTime()

/// 📊 Reusable recording stats system — live FPS, dropped-frame rate,
/// measured bitrate, and duration for the active take.
///
/// This is intentionally a standalone, additive module: it does not touch
/// AVAssetWriter, the writerLock, or any of CameraRecorder's existing
/// recording-path state. It is fed from the outside (append succeeded /
/// frame dropped / file grew by N bytes) and only computes/publishes
/// numbers — so it cannot destabilize the capture pipeline.
///
/// iOS 27 / Swift 6.4: snapshot is a Sendable value type; the tracker is
/// isolation-safe and published through CameraRecorder's @Observable state.
struct RecordingStatsSnapshot: Sendable, Equatable {
    /// Frames actually appended to the writer since recording started.
    var framesAppended: Int = 0
    /// Frames dropped/discarded since recording started (mirrors
    /// CameraRecorder.droppedFrames, kept here too so this system is
    /// self-contained and reusable outside CameraRecorder if needed).
    var framesDropped: Int = 0
    /// Target frame rate from the active EncodePlan, for comparison.
    var targetFPS: Double = 0
    /// Measured average FPS = framesAppended / elapsed wall time.
    var measuredFPS: Double = 0
    /// Bytes written to the current output file, last time we sampled it.
    var bytesWritten: Int64 = 0
    /// Rolling instantaneous bitrate estimate (bits per second), computed
    /// from the byte delta between the last two samples.
    var currentBitrateBps: Double = 0
    /// Average bitrate (bits per second) across the whole take so far,
    /// from total bytesWritten / elapsed.
    var averageBitrateBps: Double = 0
    /// Wall-clock seconds since this stats session started.
    var elapsedSeconds: TimeInterval = 0

    var dropRatePercent: Double {
        let total = framesAppended + framesDropped
        guard total > 0 else { return 0 }
        return (Double(framesDropped) / Double(total)) * 100.0
    }

    var measuredFPSLabel: String {
        guard measuredFPS > 0 else { return "-- fps" }
        return String(format: "%.1f fps", measuredFPS)
    }

    var currentBitrateLabel: String {
        Self.formatBitrate(currentBitrateBps)
    }

    var averageBitrateLabel: String {
        Self.formatBitrate(averageBitrateBps)
    }

    static func formatBitrate(_ bps: Double) -> String {
        guard bps > 0 else { return "-- Mbps" }
        let mbps = bps / 1_000_000.0
        if mbps >= 10 {
            return String(format: "%.0f Mbps", mbps)
        } else if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f Kbps", bps / 1000.0)
        }
    }
}

/// Owns the math for one recording take. CameraRecorder (or any other
/// caller) drives this with small, cheap calls; RecordingStatsTracker
/// never touches the camera session, the writer, or any lock the capture
/// path depends on.
///
/// Not @Observable on purpose — CameraRecorder publishes `snapshot`
/// through its own tracked properties so this tracker stays reusable
/// outside SwiftUI (tests, CLI diagnostics).
final class RecordingStatsTracker {

    private(set) var snapshot = RecordingStatsSnapshot()

    private var startHostTime: CFTimeInterval = 0
    private var lastByteSampleHostTime: CFTimeInterval = 0
    private var lastByteSampleBytes: Int64 = 0
    /// Bytes from segments that already finished and rotated out, folded
    /// into every subsequent average-bitrate calculation so a long,
    /// fragmented take doesn't look like its bitrate reset to zero at
    /// each segment boundary.
    private var carriedOverBytes: Int64 = 0

    /// Minimum spacing between bitrate samples so a burst of calls (e.g.
    /// several frames landing in the same runloop tick) doesn't make the
    /// instantaneous-rate math divide by a near-zero time delta.
    private static let minSampleInterval: CFTimeInterval = 0.2

    /// Call once when a fresh take begins (mirrors CameraRecorder's
    /// elapsed = 0 / droppedFrames = 0 reset in startRecording()).
    func reset(targetFPS: Double) {
        snapshot = RecordingStatsSnapshot()
        snapshot.targetFPS = targetFPS
        let now = CACurrentMediaTime()
        startHostTime = now
        lastByteSampleHostTime = now
        lastByteSampleBytes = 0
        carriedOverBytes = 0
    }

    /// Call each time a video sample buffer is successfully appended to
    /// the AVAssetWriter (the same success path CameraRecorder already
    /// tracks via lastVideoPTS).
    func recordAppendedFrame() {
        snapshot.framesAppended += 1
    }

    /// Call each time a frame is dropped/discarded (same events that
    /// already call CameraRecorder.countDroppedFrame()).
    func recordDroppedFrame(count: Int = 1) {
        snapshot.framesDropped += count
    }

    /// Call periodically (e.g. from the existing 0.25s elapsed-push tick)
    /// with the current output file's byte size, to refresh FPS/bitrate.
    /// currentFileBytes should be the size of the segment/file currently
    /// being written; pass the same number you'd get from
    /// `url.resourceValues(forKeys: [.fileSizeKey])`.
    func sample(currentFileBytes: Int64) {
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - startHostTime)
        snapshot.elapsedSeconds = elapsed

        let totalBytes = carriedOverBytes + currentFileBytes
        if elapsed > 0 {
            snapshot.measuredFPS = Double(snapshot.framesAppended) / elapsed
            snapshot.averageBitrateBps = (Double(totalBytes) * 8.0) / elapsed
        }

        let dt = now - lastByteSampleHostTime
        if dt >= Self.minSampleInterval {
            let byteDelta = max(0, currentFileBytes - lastByteSampleBytes)
            // AVAssetWriter only flushes bytes to disk at each movie-fragment
            // boundary (4s in this app — see VideoRecordingSystem.fragmentSeconds),
            // so most 0.25s sample ticks see byteDelta == 0 even though the
            // encoder is running fine. Only overwrite currentBitrateBps when
            // we actually observed new bytes on disk; otherwise keep showing
            // the last real reading instead of flashing to "--" every tick.
            if byteDelta > 0 {
                snapshot.currentBitrateBps = (Double(byteDelta) * 8.0) / dt
            }
            lastByteSampleHostTime = now
            lastByteSampleBytes = currentFileBytes
        }

        snapshot.bytesWritten = totalBytes
    }

    /// Cumulative bytes across earlier finished segments in a multi-segment
    /// take (fragmented long recordings). Call when a segment finalizes and
    /// rotates to a new file, so averageBitrateBps stays accurate across
    /// the whole take rather than resetting per-segment. Optional — only
    /// needed if the caller wants cross-segment accuracy.
    func carryOverSegmentBytes(_ bytes: Int64) {
        carriedOverBytes += bytes
        lastByteSampleBytes = 0
    }
}
