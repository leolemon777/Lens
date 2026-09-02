import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
    func setCursorEnabled(_ enabled: Bool) {
        mutate { $0.cursor.isEnabled = enabled }
    }

    func setCursorAppearance(_ appearance: AutoEditPlan.Cursor.Appearance) {
        mutate { $0.cursor.appearance = appearance }
    }

    func setCursorAccentColorHex(_ value: String) {
        mutate { plan in
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "# ")
            ).uppercased()
            plan.cursor.accentColorHex = if trimmed.count == 6,
                                            UInt32(trimmed, radix: 16) != nil {
                "#\(trimmed)"
            } else {
                "#5BD6FF"
            }
        }
    }

    func setCursorMotionEffect(_ effect: AutoEditPlan.Cursor.MotionEffect) {
        mutate { $0.cursor.motionEffect = effect }
    }

    func setCursorMotionEffectStrength(_ value: Double) {
        mutate { plan in
            plan.cursor.motionEffectStrength = min(max(
                value.isFinite ? value : 0.42,
                0.1
            ), 1)
        }
    }

    func setCursorScale(_ value: Double) {
        mutate { $0.cursor.scale = min(max(value, 0.5), 3) }
    }

    func setCursorSmoothingWindowMilliseconds(_ value: Double) {
        mutate { plan in
            let milliseconds = min(max(value.isFinite ? value : 0, 0), 160)
            plan.cursor.smoothingWindowMilliseconds = milliseconds
            plan.cursor.smoothing = min(milliseconds / 80, 1)
        }
    }

    func setCursorHidesWhenIdle(_ enabled: Bool) {
        mutate { $0.cursor.hidesWhenIdle = enabled }
    }

    func setClickPulseEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.showsClickPulse = enabled
        }
    }

    func setClickEffect(_ effect: AutoEditPlan.Interaction.ClickEffect) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickEffect = effect
        }
    }

    func setClickEffectStrength(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickEffectStrength = min(max(
                value.isFinite ? value : 1,
                0.1
            ), 1)
        }
    }

    func setClickPulseScale(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickPulseScale = min(max(
                value.isFinite ? value : 1.25,
                0.5
            ), 3)
        }
    }

    func setClickPulseDuration(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickPulseDuration = min(max(
                value.isFinite ? value : 0.62,
                0.15
            ), 1.5)
        }
    }

    func setClickPulseColorHex(_ value: String) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            let normalized = AutoEditPlan.Interaction(
                clickPulseColorHex: value
            ).clickPulseColorHex
            plan.interaction?.clickPulseColorHex = normalized
        }
    }
    func setCanvasEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.isEnabled = enabled
        }
    }

    func setCanvasMargin(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.margin = min(max(value, 0), 0.25)
        }
    }

    func setCanvasCornerRadius(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.cornerRadius = min(max(value, 0), 0.2)
        }
    }

    func setCanvasShadowOpacity(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.shadowOpacity = min(max(
                value.isFinite ? value : 0.24,
                0
            ), 1)
        }
    }

    func setCanvasPreset(topHex: String, bottomHex: String) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.backgroundTopHex = topHex
            plan.canvas?.backgroundBottomHex = bottomHex
        }
    }
}
