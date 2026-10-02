import Foundation

/// Thread-safe rolling speed meter.
final class SpeedMeter {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var lastSampleTime: Date = Date()
    private var lastSampleBytes: Int64 = 0
    private(set) var speedBps: Int64 = 0

    func add(_ n: Int64) {
        lock.lock()
        bytes += n
        lock.unlock()
    }

    func sample() {
        lock.lock()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed > 0 {
            let delta = bytes - lastSampleBytes
            speedBps = Int64(Double(delta) / elapsed)
            lastSampleBytes = bytes
            lastSampleTime = now
        }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        bytes = 0
        lastSampleBytes = 0
        speedBps = 0
        lastSampleTime = Date()
        lock.unlock()
    }
}
