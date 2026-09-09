import AVFoundation

/// Timestamp gaps in the last saved clip, not a live preview/encoder drop counter.
enum ClipFrameDiagnostics {
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.frameDiagnostics", qos: .utility)
    private static let batchSize = 512

    static func inspect(_ url: URL, completion: @escaping (Int?) -> Void) {
        queue.async {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .video).first else {
                    completion(nil)
                    return
                }

                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    completion(nil)
                    return
                }
                reader.add(output)
                guard reader.startReading() else {
                    completion(nil)
                    return
                }

                var expectedCadence = track.nominalFrameRate > 0 ? 1.0 / Double(track.nominalFrameRate) : 0
                var batch: [Double] = []
                batch.reserveCapacity(batchSize)
                var previousTime: Double?
                var gapCount = 0
                var validIntervals = 0

                func consumeBatch() {
                    guard !batch.isEmpty else { return }
                    batch.sort()
                    if expectedCadence <= 0, batch.count > 2 {
                        let intervals = zip(batch.dropFirst(), batch).map { $0.0 - $0.1 }.filter { $0 > 0 }
                        if !intervals.isEmpty {
                            let sorted = intervals.sorted()
                            expectedCadence = sorted[sorted.count / 2]
                        }
                    }

                    for time in batch {
                        if let previousTime {
                            let interval = time - previousTime
                            if interval > 0, expectedCadence > 0 {
                                validIntervals += 1
                                if interval > expectedCadence * 1.5 {
                                    gapCount += max(0, Int((interval / expectedCadence).rounded()) - 1)
                                }
                            }
                        }
                        previousTime = time
                    }
                    batch.removeAll(keepingCapacity: true)
                }

                while let time = autoreleasepool(invoking: { () -> Double? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                }) {
                    if time.isFinite {
                        batch.append(time)
                        if batch.count >= batchSize { consumeBatch() }
                    }
                }
                consumeBatch()

                guard reader.status == .completed, validIntervals > 1 else {
                    completion(nil)
                    return
                }
                completion(gapCount)
            } catch {
                completion(nil)
            }
        }
    }
}
