import Foundation

/// Second-order IIR filter, transposed direct form II.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    /// Butterworth low-pass (Q = 1/sqrt 2).
    static func lowPass(cutoffHz: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - cosw) / 2 / a0,
                      b1: (1 - cosw) / a0,
                      b2: (1 - cosw) / 2 / a0,
                      a1: -2 * cosw / a0,
                      a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// Fixed-capacity ring buffer that hands back its contents oldest first.
struct Ring<Element> {
    private var storage: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { storage.count }
    var isFull: Bool { storage.count == capacity }

    mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    var elements: [Element] {
        if storage.count < capacity { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    var last: Element? {
        if storage.isEmpty { return nil }
        if storage.count < capacity { return storage[storage.count - 1] }
        return storage[(head + capacity - 1) % capacity]
    }

    mutating func removeAll() { storage.removeAll(keepingCapacity: true); head = 0 }
}
