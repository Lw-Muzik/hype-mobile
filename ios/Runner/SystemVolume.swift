import Foundation

/// Converts the system output volume (linear 0...1) to dB for the engine's
/// "Smooth equalizer/tone gains" feature.
enum SystemVolume {
    static let floorDb: Float = -96

    static func db(fromOutputVolume v: Float) -> Float {
        if !(v > 0) { return floorDb }
        return max(floorDb, min(0, 20 * log10(v)))
    }
}
