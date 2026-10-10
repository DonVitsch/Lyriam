import Foundation

enum SystemLevelSteps {
    static func next(_ current: Double, up: Bool, fine: Bool) -> Double {
        let count = fine ? 64.0 : 16.0
        let position = min(1, max(0, current)) * count
        let step = up ? floor(position + 0.0001) + 1 : ceil(position - 0.0001) - 1
        return min(1, max(0, step / count))
    }

    static func isBeyondLimit(_ current: Double, up: Bool) -> Bool {
        up ? current >= 0.9999 : current <= 0.0001
    }
}

/// Some built-in panels report the backlight range used by DisplayServices,
/// rather than the full sixteen-position keyboard slider. Recognize that
/// curve from a settled native key notch (e.g. 0.9175, 0.835, 0.7525).
/// Slider edits remain continuous; only keyboard commands snap to a notch.
struct SystemBrightnessScale {
    private(set) var range = 1.0

    mutating func recognizeNativeNotch(_ raw: Double) {
        guard range == 1, raw > 0.02, raw < 0.999 else { return }
        let ordinary = raw * 16
        let extended = ((raw + 0.32) / 1.32) * 16
        if abs(ordinary - ordinary.rounded()) > 0.005,
           abs(extended - extended.rounded()) < 0.003 {
            range = 1.32
        }
    }

    func sliderValue(for raw: Double) -> Double {
        min(1, max(0, (raw + range - 1) / range))
    }

    func hardwareValue(for slider: Double) -> Double {
        min(1, max(0, slider * range - (range - 1)))
    }
}
