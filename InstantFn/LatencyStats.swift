import Foundation

/// Small fixed-size record of switch latencies (milliseconds). Main thread only.
///
/// - select:  Fn release seen by the event tap → `TISSelectInputSource` returned.
/// - confirm: Fn release seen by the event tap → system broadcast
///            "selected input source changed" arrived back at InstantFn.
///
/// Not measured: the time between the physical key release and the event reaching the
/// tap (HID + WindowServer), which InstantFn cannot observe reliably.
@MainActor
final class LatencyStats {
    private let capacity = 200
    private(set) var select: [Double] = []
    private(set) var confirm: [Double] = []

    func recordSelect(ns: UInt64) { append(&select, Double(ns) / 1e6) }
    func recordConfirm(ns: UInt64) { append(&confirm, Double(ns) / 1e6) }

    private func append(_ a: inout [Double], _ v: Double) {
        if a.count == capacity { a.removeFirst() }
        a.append(v)
    }

    static func summary(_ samples: [Double]) -> String {
        guard let last = samples.last else { return "no samples yet" }
        let s = samples.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return String(format: "last %.1f · median %.1f · p95 %.1f · max %.1f ms (n=%d)",
                      last, pct(0.5), pct(0.95), s.last!, s.count)
    }
}
