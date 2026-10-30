import Foundation
import simd

/// A first guess at where the device is clipped, from the gravity direction alone.
/// Heuristic. Tune the thresholds once a real puck has been worn in each spot; the
/// accelerometer axes of the XIAO differ from the phone's.
enum WearPosition: String {
    case uprightOnChest = "Upright on chest"
    case lyingFlat = "Lying flat"
    case sideways = "Sideways (sleeve?)"
    case unknown = "Unknown"

    static func guess(gravity g: SIMD3<Double>) -> WearPosition {
        let len = simd_length(g)
        guard len > 0.5 else { return .unknown }
        let n = g / len
        if abs(n.z) > 0.8 { return .lyingFlat }
        if abs(n.y) > 0.7 { return .uprightOnChest }
        if abs(n.x) > 0.7 { return .sideways }
        return .unknown
    }

    var sensesBreath: Bool {
        switch self {
        case .uprightOnChest, .lyingFlat: return true
        case .sideways, .unknown: return false
        }
    }
}
