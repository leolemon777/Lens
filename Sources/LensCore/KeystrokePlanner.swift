import Foundation

/// Converts the privacy-sanitized keyboard event track into on-screen
/// keystroke capsules. Input events only ever contain shortcuts and
/// non-text control keys (see `PointerEventRecorder.sanitizedKeyboardEvent`),
/// so plain typing cannot leak into a finished video through this path.
public struct KeystrokePlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var holdSeconds: Double
        public var maximumCount: Int

        public init(
            holdSeconds: Double = 1.15,
            maximumCount: Int = 300
        ) {
            self.holdSeconds = min(max(holdSeconds, 0.3), 3)
            self.maximumCount = max(maximumCount, 1)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func displays(
        events: [KeyboardEvent],
        durationSeconds: Double
    ) -> [AutoEditPlan.KeystrokeDisplay] {
        let duration = durationSeconds.isFinite ? max(durationSeconds, 0) : 0
        var result: [AutoEditPlan.KeystrokeDisplay] = []
        for event in events {
            guard event.isRepeat == false,
                  event.label?.isEmpty == false,
                  event.time >= 0,
                  event.time <= duration,
                  result.count < configuration.maximumCount else { continue }
            guard let text = Self.displayText(for: event) else { continue }
            result.append(AutoEditPlan.KeystrokeDisplay(
                time: event.time,
                text: text,
                holdSeconds: configuration.holdSeconds
            ))
        }
        return result.sorted { $0.time < $1.time }
    }

    /// "⌘⇧P"-style label; modifier symbols follow the system order used by
    /// the recorder's `KeyboardModifier.allCases`.
    static func displayText(for event: KeyboardEvent) -> String? {
        guard let label = event.label?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !label.isEmpty else { return nil }
        let symbols = event.modifiers.compactMap(Self.symbol(for:))
        return symbols.joined() + label
    }

    private static func symbol(for modifier: KeyboardModifier) -> String? {
        switch modifier {
        case .command: "⌘"
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .function, .capsLock: nil
        }
    }
}
