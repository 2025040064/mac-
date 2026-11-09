import Foundation

public struct Sample: Identifiable, Equatable {
    public let id: Int
    public let time: Double
    public let values: [Float]
}

public struct ChannelStats {
    public init() {}
    public private(set) var count = 0
    public private(set) var latest: Float?
    public private(set) var min: Float?
    public private(set) var max: Float?
    private var sum: Double = 0
    public var mean: Double? { count == 0 ? nil : sum / Double(count) }

    mutating func add(_ value: Float) {
        count += 1
        latest = value
        min = Swift.min(min ?? value, value)
        max = Swift.max(max ?? value, value)
        sum += Double(value)
    }
}

public struct SampleStore {
    public let interval: Double
    public private(set) var count = 0
    public private(set) var statistics = Array(repeating: ChannelStats(), count: 8)
    private var ring: [Sample?]
    public var lastTime: Double { Double(max(0, count - 1)) * interval }
    public var firstTime: Double { Double(max(0, count - ring.count)) * interval }

    public init(interval: Double, capacity: Int = 120_000) {
        self.interval = interval.isFinite && interval > 0 ? interval : 0.01
        ring = Array(repeating: nil, count: max(1, capacity))
    }

    @discardableResult
    public mutating func append(_ values: [Float]) -> Sample {
        let sample = Sample(id: count, time: Double(count) * interval, values: Array(values.prefix(8)))
        for (index, value) in sample.values.enumerated() where value.isFinite {
            statistics[index].add(value)
        }
        ring[count % ring.count] = sample
        count += 1
        return sample
    }

    public func nearest(to time: Double) -> Sample? {
        guard count > 0, time.isFinite, (firstTime...lastTime).contains(time) else { return nil }
        return ring[Int((time / interval).rounded()) % ring.count]
    }

    public func envelope(in range: ClosedRange<Double>, channel: Int, buckets: Int = 350) -> [Sample] {
        guard count > 0, (0..<8).contains(channel), range.upperBound >= firstTime,
              range.lowerBound <= lastTime else { return [] }
        let start = max(count - ring.count, max(0, Int((max(firstTime, range.lowerBound) / interval).rounded(.down))))
        let end = min(count - 1, Int((min(lastTime, range.upperBound) / interval).rounded(.up)))
        guard start <= end else { return [] }
        let width = max(1, (end - start + max(1, buckets)) / max(1, buckets))
        var output = [Sample]()
        for lower in stride(from: start, through: end, by: width) {
            var low: Sample?
            var high: Sample?
            for index in lower...min(end, lower + width - 1) {
                guard let sample = ring[index % ring.count], sample.values.indices.contains(channel) else { continue }
                let value = sample.values[channel]
                if low.map({ value < $0.values[channel] }) ?? true { low = sample }
                if high.map({ value >= $0.values[channel] }) ?? true { high = sample }
            }
            if let low, let high {
                output.append(low.id <= high.id ? low : high)
                if low.id != high.id { output.append(low.id < high.id ? high : low) }
            }
        }
        return output
    }
}
