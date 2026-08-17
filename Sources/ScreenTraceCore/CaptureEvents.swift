import Foundation

public struct TracePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum PointerEventKind: String, Codable, Sendable {
    case moved
    case dragged
    case scroll
}

/// A privacy-safe description of the system cursor that was visible while
/// recording. Custom third-party cursor artwork intentionally falls back to
/// `unknown`; no application pixels or accessibility text are stored.
public enum PointerCursorShape: String, Codable, CaseIterable, Hashable, Sendable {
    case arrow
    case pointingHand
    case iBeam
    case verticalIBeam
    case crosshair
    case openHand
    case closedHand
    case horizontalResize
    case verticalResize
    case operationNotAllowed
    case dragCopy
    case dragLink
    case contextualMenu
    case disappearingItem
    case unknown
}

public struct PointerEvent: Codable, Equatable, Sendable {
    public let time: Double
    public let kind: PointerEventKind
    public let location: TracePoint
    public let normalizedLocation: TracePoint?
    public let displayID: UInt32?
    public let scrollDelta: TracePoint?
    public let cursorShape: PointerCursorShape?

    public init(
        time: Double,
        kind: PointerEventKind,
        location: TracePoint,
        normalizedLocation: TracePoint? = nil,
        displayID: UInt32?,
        scrollDelta: TracePoint? = nil,
        cursorShape: PointerCursorShape? = nil
    ) {
        self.time = time
        self.kind = kind
        self.location = location
        self.normalizedLocation = normalizedLocation
        self.displayID = displayID
        self.scrollDelta = scrollDelta
        self.cursorShape = cursorShape
    }
}

public enum PointerButton: String, Codable, Sendable {
    case left
    case right
    case middle
    case other
}

public enum ClickPhase: String, Codable, Sendable {
    case down
    case up
}

public struct ClickEvent: Codable, Equatable, Sendable {
    public let time: Double
    public let button: PointerButton
    public let phase: ClickPhase
    public let location: TracePoint
    public let normalizedLocation: TracePoint?
    public let displayID: UInt32?
    public let clickCount: Int
    public let cursorShape: PointerCursorShape?

    public init(
        time: Double,
        button: PointerButton,
        phase: ClickPhase,
        location: TracePoint,
        normalizedLocation: TracePoint? = nil,
        displayID: UInt32? = nil,
        clickCount: Int,
        cursorShape: PointerCursorShape? = nil
    ) {
        self.time = time
        self.button = button
        self.phase = phase
        self.location = location
        self.normalizedLocation = normalizedLocation
        self.displayID = displayID
        self.clickCount = clickCount
        self.cursorShape = cursorShape
    }
}

public enum KeyboardModifier: String, Codable, CaseIterable, Sendable {
    case command
    case control
    case option
    case shift
    case function
    case capsLock
}

/// A privacy-reduced keyboard interaction. Plain text input is never represented by this type;
/// platform recorders should only emit shortcuts and non-text navigation/control keys.
public struct KeyboardEvent: Codable, Equatable, Sendable {
    public let time: Double
    public let keyCode: Int
    public let label: String?
    public let modifiers: [KeyboardModifier]
    public let isRepeat: Bool

    public init(
        time: Double,
        keyCode: Int,
        label: String? = nil,
        modifiers: [KeyboardModifier] = [],
        isRepeat: Bool = false
    ) {
        self.time = max(time.isFinite ? time : 0, 0)
        self.keyCode = max(keyCode, 0)
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modifiers = KeyboardModifier.allCases.filter(modifiers.contains)
        self.isRepeat = isRepeat
    }
}

/// Records application focus changes without window titles or document names.
public struct WindowEvent: Codable, Equatable, Sendable {
    public let time: Double
    public let applicationName: String?
    public let bundleIdentifier: String?

    public init(
        time: Double,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.time = max(time.isFinite ? time : 0, 0)
        self.applicationName = applicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct AutoEditPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.2"

    public struct ClickPulse: Codable, Equatable, Sendable {
        public let time: Double
        public let position: TracePoint
        public let button: PointerButton
        public let duration: Double

        public init(
            time: Double,
            position: TracePoint,
            button: PointerButton,
            duration: Double = 0.55
        ) {
            self.time = time
            self.position = position
            self.button = button
            self.duration = max(duration, 0.05)
        }
    }

    public struct Interaction: Codable, Equatable, Sendable {
        public enum ClickEffect: String, Codable, CaseIterable, Hashable, Sendable {
            case ripple
            case pulse
            case spotlight
        }

        public var showsClickPulse: Bool
        public var clickEffect: ClickEffect
        public var clickEffectStrength: Double
        public var clickPulseScale: Double
        public var clickPulseColorHex: String
        /// Nil preserves each legacy pulse's authored duration.
        public var clickPulseDuration: Double?
        public var clickPulses: [ClickPulse]

        public init(
            showsClickPulse: Bool = true,
            clickEffect: ClickEffect = .ripple,
            clickEffectStrength: Double = 1,
            clickPulseScale: Double = 1.25,
            clickPulseColorHex: String = "#FF684D",
            clickPulseDuration: Double? = 0.62,
            clickPulses: [ClickPulse] = []
        ) {
            self.showsClickPulse = showsClickPulse
            self.clickEffect = clickEffect
            self.clickEffectStrength = min(max(
                clickEffectStrength.isFinite ? clickEffectStrength : 1,
                0.1
            ), 1)
            self.clickPulseScale = min(max(
                clickPulseScale.isFinite ? clickPulseScale : 1,
                0.5
            ), 3)
            self.clickPulseColorHex = Self.normalizedHex(clickPulseColorHex)
            self.clickPulseDuration = clickPulseDuration.map {
                min(max($0.isFinite ? $0 : 0.55, 0.15), 1.5)
            }
            self.clickPulses = clickPulses
        }

        private enum CodingKeys: String, CodingKey {
            case showsClickPulse
            case clickEffect
            case clickEffectStrength
            case clickPulseScale
            case clickPulseColorHex
            case clickPulseDuration
            case clickPulses
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                showsClickPulse: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .showsClickPulse
                ) ?? true,
                clickEffect: try container.decodeIfPresent(
                    ClickEffect.self,
                    forKey: .clickEffect
                ) ?? .ripple,
                clickEffectStrength: try container.decodeIfPresent(
                    Double.self,
                    forKey: .clickEffectStrength
                ) ?? 1,
                clickPulseScale: try container.decodeIfPresent(
                    Double.self,
                    forKey: .clickPulseScale
                ) ?? 1,
                clickPulseColorHex: try container.decodeIfPresent(
                    String.self,
                    forKey: .clickPulseColorHex
                ) ?? "#00D9FF",
                clickPulseDuration: try container.decodeIfPresent(
                    Double.self,
                    forKey: .clickPulseDuration
                ),
                clickPulses: try container.decodeIfPresent(
                    [ClickPulse].self,
                    forKey: .clickPulses
                ) ?? []
            )
        }

        private static func normalizedHex(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "# ")
            ).uppercased()
            guard trimmed.count == 6, UInt32(trimmed, radix: 16) != nil else {
                return "#00D9FF"
            }
            return "#\(trimmed)"
        }
    }

    public struct Canvas: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        public var margin: Double
        public var cornerRadius: Double
        public var shadowOpacity: Double
        public var backgroundTopHex: String
        public var backgroundBottomHex: String

        public init(
            isEnabled: Bool = true,
            margin: Double = 0.055,
            cornerRadius: Double = 0.026,
            shadowOpacity: Double = 0.28,
            backgroundTopHex: String = "#D9D6CF",
            backgroundBottomHex: String = "#9EA9A7"
        ) {
            self.isEnabled = isEnabled
            self.margin = min(max(margin, 0), 0.25)
            self.cornerRadius = min(max(cornerRadius, 0), 0.2)
            self.shadowOpacity = min(max(shadowOpacity, 0), 1)
            self.backgroundTopHex = backgroundTopHex
            self.backgroundBottomHex = backgroundBottomHex
        }
    }

    public struct CursorKeyframe: Codable, Equatable, Sendable {
        public let time: Double
        public let position: TracePoint
        /// Preserves whether the pointer was freely moving or actively dragging.
        /// Legacy plans omit this field and continue to render normally.
        public let kind: PointerEventKind?

        public init(
            time: Double,
            position: TracePoint,
            kind: PointerEventKind? = nil
        ) {
            self.time = time
            self.position = position
            self.kind = kind
        }
    }

    public struct CursorShapeKeyframe: Codable, Equatable, Sendable {
        public let time: Double
        public let shape: PointerCursorShape

        public init(time: Double, shape: PointerCursorShape) {
            self.time = max(time.isFinite ? time : 0, 0)
            self.shape = shape
        }
    }

    public struct CameraKeyframe: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case baseline
            case clickFocus
            case pointerFollow
            case clickHold
            case returnToOverview
            case manualAnchor
            case manualFocus
            case manualHold
            case manualReturn
        }

        public let time: Double
        public let scale: Double
        public let center: TracePoint
        public let easing: String
        public let reason: Reason

        public init(
            time: Double,
            scale: Double,
            center: TracePoint,
            easing: String,
            reason: Reason
        ) {
            self.time = time
            self.scale = scale
            self.center = center
            self.easing = easing
            self.reason = reason
        }
    }

    public struct Cursor: Codable, Equatable, Sendable {
        public enum Appearance: String, Codable, CaseIterable, Hashable, Sendable {
            /// Replays standard system shapes captured during recording.
            case recorded
            /// Preserves the legacy fixed macOS arrow.
            case macOS
            case highContrast
            case minimalDot
        }

        public enum MotionEffect: String, Codable, CaseIterable, Hashable, Sendable {
            case none
            case halo
            case trail
            case spotlight
        }

        /// Nil in legacy projects means enabled.
        public var isEnabled: Bool?
        public var appearance: Appearance
        public var accentColorHex: String
        public var motionEffect: MotionEffect
        public var motionEffectStrength: Double
        public var smoothing: Double
        /// Nil preserves the legacy normalized smoothing renderer.
        public var smoothingWindowMilliseconds: Double?
        public var scale: Double
        public var hidesWhenIdle: Bool
        public var keyframes: [CursorKeyframe]
        public var shapeKeyframes: [CursorShapeKeyframe]

        public init(
            isEnabled: Bool? = true,
            appearance: Appearance = .recorded,
            accentColorHex: String = "#5BD6FF",
            motionEffect: MotionEffect = .halo,
            motionEffectStrength: Double = 0.42,
            smoothing: Double,
            smoothingWindowMilliseconds: Double? = nil,
            scale: Double,
            hidesWhenIdle: Bool,
            keyframes: [CursorKeyframe] = [],
            shapeKeyframes: [CursorShapeKeyframe] = []
        ) {
            self.isEnabled = isEnabled
            self.appearance = appearance
            self.accentColorHex = Self.normalizedHex(accentColorHex)
            self.motionEffect = motionEffect
            self.motionEffectStrength = min(max(
                motionEffectStrength.isFinite ? motionEffectStrength : 0.42,
                0.1
            ), 1)
            self.smoothing = smoothing
            self.smoothingWindowMilliseconds = smoothingWindowMilliseconds.map {
                min(max($0.isFinite ? $0 : 0, 0), 160)
            }
            self.scale = scale
            self.hidesWhenIdle = hidesWhenIdle
            self.keyframes = keyframes
            self.shapeKeyframes = shapeKeyframes
        }

        public var resolvedSmoothingWindowMilliseconds: Double {
            smoothingWindowMilliseconds
                ?? min(max(smoothing.isFinite ? smoothing : 0.72, 0), 1) * 80
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled
            case appearance
            case accentColorHex
            case motionEffect
            case motionEffectStrength
            case smoothing
            case smoothingWindowMilliseconds
            case scale
            case hidesWhenIdle
            case keyframes
            case shapeKeyframes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled),
                appearance: try container.decodeIfPresent(
                    Appearance.self,
                    forKey: .appearance
                ) ?? .macOS,
                accentColorHex: try container.decodeIfPresent(
                    String.self,
                    forKey: .accentColorHex
                ) ?? "#5BD6FF",
                motionEffect: try container.decodeIfPresent(
                    MotionEffect.self,
                    forKey: .motionEffect
                ) ?? .none,
                motionEffectStrength: try container.decodeIfPresent(
                    Double.self,
                    forKey: .motionEffectStrength
                ) ?? 0.42,
                smoothing: try container.decodeIfPresent(Double.self, forKey: .smoothing)
                    ?? 0.72,
                smoothingWindowMilliseconds: try container.decodeIfPresent(
                    Double.self,
                    forKey: .smoothingWindowMilliseconds
                ),
                scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.15,
                hidesWhenIdle: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .hidesWhenIdle
                ) ?? true,
                keyframes: try container.decodeIfPresent(
                    [CursorKeyframe].self,
                    forKey: .keyframes
                ) ?? [],
                shapeKeyframes: try container.decodeIfPresent(
                    [CursorShapeKeyframe].self,
                    forKey: .shapeKeyframes
                ) ?? []
            )
        }

        private static func normalizedHex(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "# ")
            ).uppercased()
            guard trimmed.count == 6, UInt32(trimmed, radix: 16) != nil else {
                return "#5BD6FF"
            }
            return "#\(trimmed)"
        }
    }

    public struct Camera: Codable, Equatable, Sendable {
        public enum GenerationStrength: String, Codable, CaseIterable, Sendable {
            case restrained
            case balanced
            case active
        }

        public var mode: String
        /// Legacy normalized intensity. Nil `zoomScale` plans still use it so
        /// existing projects render exactly as before.
        public var zoomIntensity: Double
        public var followPointer: Bool
        public var clickToZoom: Bool
        /// Absolute authored zoom for newly generated automatic keyframes.
        /// Nil identifies a legacy plan whose keyframes still need intensity scaling.
        public var zoomScale: Double?
        public var generationStrength: GenerationStrength
        /// Speed-driven blur applied only to the transformed screen content.
        /// Zero is a strict bypass and preserves legacy project pixels.
        public var motionBlurStrength: Double
        public var keyframes: [CameraKeyframe]

        public init(
            mode: String,
            zoomIntensity: Double,
            followPointer: Bool,
            clickToZoom: Bool = true,
            zoomScale: Double? = nil,
            generationStrength: GenerationStrength = .balanced,
            motionBlurStrength: Double = 0,
            keyframes: [CameraKeyframe] = []
        ) {
            self.mode = mode
            self.zoomIntensity = zoomIntensity
            self.followPointer = followPointer
            self.clickToZoom = clickToZoom
            self.zoomScale = zoomScale.map { min(max($0.isFinite ? $0 : 1.58, 1), 3) }
            self.generationStrength = generationStrength
            self.motionBlurStrength = min(max(
                motionBlurStrength.isFinite ? motionBlurStrength : 0,
                0
            ), 1)
            self.keyframes = keyframes
        }

        public var resolvedZoomScale: Double {
            zoomScale ?? min(max(1 + 0.58 * (zoomIntensity / 0.42), 1), 3)
        }

        private enum CodingKeys: String, CodingKey {
            case mode
            case zoomIntensity
            case followPointer
            case clickToZoom
            case zoomScale
            case generationStrength
            case motionBlurStrength
            case keyframes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                mode: try container.decodeIfPresent(String.self, forKey: .mode)
                    ?? "event-driven",
                zoomIntensity: try container.decodeIfPresent(Double.self, forKey: .zoomIntensity)
                    ?? 0.42,
                followPointer: try container.decodeIfPresent(Bool.self, forKey: .followPointer)
                    ?? true,
                clickToZoom: try container.decodeIfPresent(Bool.self, forKey: .clickToZoom)
                    ?? true,
                zoomScale: try container.decodeIfPresent(Double.self, forKey: .zoomScale),
                generationStrength: try container.decodeIfPresent(
                    GenerationStrength.self,
                    forKey: .generationStrength
                ) ?? .balanced,
                motionBlurStrength: try container.decodeIfPresent(
                    Double.self,
                    forKey: .motionBlurStrength
                ) ?? 0,
                keyframes: try container.decodeIfPresent(
                    [CameraKeyframe].self,
                    forKey: .keyframes
                ) ?? []
            )
        }
    }

    public struct PresenterCameraKeyframe: Codable, Equatable, Sendable {
        public let sourceTimeSeconds: Double
        /// Output-normalized center using a top-left origin.
        public let center: TracePoint
        /// Width as a fraction of the output canvas.
        public let size: Double
        public let easing: String

        public init(
            sourceTimeSeconds: Double,
            center: TracePoint,
            size: Double,
            easing: String = "spring-gentle"
        ) {
            self.sourceTimeSeconds = max(
                sourceTimeSeconds.isFinite ? sourceTimeSeconds : 0,
                0
            )
            self.center = TracePoint(
                x: min(max(center.x.isFinite ? center.x : 0.5, 0), 1),
                y: min(max(center.y.isFinite ? center.y : 0.5, 0), 1)
            )
            self.size = min(max(size.isFinite ? size : 0.19, 0.08), 0.45)
            self.easing = easing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public struct PresenterCamera: Codable, Equatable, Sendable {
        public enum Shape: String, Codable, Sendable {
            case circle
            case roundedRectangle
        }

        public enum Anchor: String, Codable, Sendable {
            case topLeading
            case topTrailing
            case bottomLeading
            case bottomTrailing
        }

        public var isEnabled: Bool
        public var shape: Shape
        public var anchor: Anchor
        /// Width as a fraction of the output canvas.
        public var size: Double
        public var margin: Double
        public var cornerRadius: Double
        public var isMirrored: Bool
        public var shadowOpacity: Double
        /// Nil follows `anchor`; otherwise this is the output-normalized center
        /// using the same top-left origin as pointer and camera focus events.
        public var position: TracePoint?
        public var automaticallyAvoidsContent: Bool
        /// Source-time edits survive cuts, reordering and playback-rate changes.
        public var keyframes: [PresenterCameraKeyframe]

        public init(
            isEnabled: Bool = false,
            shape: Shape = .circle,
            anchor: Anchor = .bottomTrailing,
            size: Double = 0.19,
            margin: Double = 0.035,
            cornerRadius: Double = 0.08,
            isMirrored: Bool = true,
            shadowOpacity: Double = 0.30,
            position: TracePoint? = nil,
            automaticallyAvoidsContent: Bool = true,
            keyframes: [PresenterCameraKeyframe] = []
        ) {
            self.isEnabled = isEnabled
            self.shape = shape
            self.anchor = anchor
            self.size = min(max(size, 0.08), 0.45)
            self.margin = min(max(margin, 0), 0.20)
            self.cornerRadius = min(max(cornerRadius, 0), 0.5)
            self.isMirrored = isMirrored
            self.shadowOpacity = min(max(shadowOpacity, 0), 1)
            self.position = position.map {
                TracePoint(
                    x: min(max($0.x.isFinite ? $0.x : 0.5, 0), 1),
                    y: min(max($0.y.isFinite ? $0.y : 0.5, 0), 1)
                )
            }
            self.automaticallyAvoidsContent = automaticallyAvoidsContent
            self.keyframes = keyframes.sorted {
                $0.sourceTimeSeconds < $1.sourceTimeSeconds
            }
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled
            case shape
            case anchor
            case size
            case margin
            case cornerRadius
            case isMirrored
            case shadowOpacity
            case position
            case automaticallyAvoidsContent
            case keyframes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                shape: try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .circle,
                anchor: try container.decodeIfPresent(Anchor.self, forKey: .anchor)
                    ?? .bottomTrailing,
                size: try container.decodeIfPresent(Double.self, forKey: .size) ?? 0.19,
                margin: try container.decodeIfPresent(Double.self, forKey: .margin) ?? 0.035,
                cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius)
                    ?? 0.08,
                isMirrored: try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? true,
                shadowOpacity: try container.decodeIfPresent(
                    Double.self,
                    forKey: .shadowOpacity
                ) ?? 0.30,
                position: try container.decodeIfPresent(TracePoint.self, forKey: .position),
                automaticallyAvoidsContent: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .automaticallyAvoidsContent
                ) ?? true,
                keyframes: try container.decodeIfPresent(
                    [PresenterCameraKeyframe].self,
                    forKey: .keyframes
                ) ?? []
            )
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        public var systemVolume: Double
        public var microphoneVolume: Double
        public var reducesMicrophoneNoise: Bool
        public var noiseReductionAmount: Double
        public var normalizesLoudness: Bool
        public var targetLoudnessLUFS: Double
        public var ducksSystemUnderNarration: Bool
        public var duckedSystemVolume: Double
        public var narrationThresholdDecibels: Double
        public var duckAttackSeconds: Double
        public var duckReleaseSeconds: Double

        public init(
            isEnabled: Bool = true,
            systemVolume: Double = 1,
            microphoneVolume: Double = 1,
            reducesMicrophoneNoise: Bool = true,
            noiseReductionAmount: Double = 0.55,
            normalizesLoudness: Bool = true,
            targetLoudnessLUFS: Double = -16,
            ducksSystemUnderNarration: Bool = true,
            duckedSystemVolume: Double = 0.32,
            narrationThresholdDecibels: Double = -42,
            duckAttackSeconds: Double = 0.12,
            duckReleaseSeconds: Double = 0.36
        ) {
            self.isEnabled = isEnabled
            self.systemVolume = min(max(systemVolume, 0), 2)
            self.microphoneVolume = min(max(microphoneVolume, 0), 2)
            self.reducesMicrophoneNoise = reducesMicrophoneNoise
            self.noiseReductionAmount = min(max(
                noiseReductionAmount.isFinite ? noiseReductionAmount : 0.55,
                0
            ), 1)
            self.normalizesLoudness = normalizesLoudness
            self.targetLoudnessLUFS = min(max(
                targetLoudnessLUFS.isFinite ? targetLoudnessLUFS : -16,
                -24
            ), -10)
            self.ducksSystemUnderNarration = ducksSystemUnderNarration
            self.duckedSystemVolume = min(max(duckedSystemVolume, 0), 1)
            self.narrationThresholdDecibels = min(max(narrationThresholdDecibels, -80), 0)
            self.duckAttackSeconds = min(max(duckAttackSeconds, 0), 2)
            self.duckReleaseSeconds = min(max(duckReleaseSeconds, 0), 3)
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled
            case systemVolume
            case microphoneVolume
            case reducesMicrophoneNoise
            case noiseReductionAmount
            case normalizesLoudness
            case targetLoudnessLUFS
            case ducksSystemUnderNarration
            case duckedSystemVolume
            case narrationThresholdDecibels
            case duckAttackSeconds
            case duckReleaseSeconds
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
                systemVolume: try container.decodeIfPresent(
                    Double.self,
                    forKey: .systemVolume
                ) ?? 1,
                microphoneVolume: try container.decodeIfPresent(
                    Double.self,
                    forKey: .microphoneVolume
                ) ?? 1,
                // Missing values identify a pre-0.6 project. Preserve its sound
                // instead of silently applying a newly introduced processor.
                reducesMicrophoneNoise: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .reducesMicrophoneNoise
                ) ?? false,
                noiseReductionAmount: try container.decodeIfPresent(
                    Double.self,
                    forKey: .noiseReductionAmount
                ) ?? 0.55,
                normalizesLoudness: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .normalizesLoudness
                ) ?? false,
                targetLoudnessLUFS: try container.decodeIfPresent(
                    Double.self,
                    forKey: .targetLoudnessLUFS
                ) ?? -16,
                ducksSystemUnderNarration: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .ducksSystemUnderNarration
                ) ?? true,
                duckedSystemVolume: try container.decodeIfPresent(
                    Double.self,
                    forKey: .duckedSystemVolume
                ) ?? 0.32,
                narrationThresholdDecibels: try container.decodeIfPresent(
                    Double.self,
                    forKey: .narrationThresholdDecibels
                ) ?? -42,
                duckAttackSeconds: try container.decodeIfPresent(
                    Double.self,
                    forKey: .duckAttackSeconds
                ) ?? 0.12,
                duckReleaseSeconds: try container.decodeIfPresent(
                    Double.self,
                    forKey: .duckReleaseSeconds
                ) ?? 0.36
            )
        }
    }

    public struct Captions: Codable, Equatable, Sendable {
        public enum Style: String, Codable, CaseIterable, Sendable {
            case glass
            case clean
            case highContrast
        }

        public enum Position: String, Codable, CaseIterable, Sendable {
            case top
            case center
            case bottom
        }

        public var isEnabled: Bool
        public var style: Style
        public var position: Position
        public var fontScale: Double
        public var maxCharactersPerCue: Int
        public var verticalMargin: Double
        /// Nil keeps following the latest transcript. Once edited, this stores a
        /// non-destructive source-time caption copy in the edit plan.
        public var customCues: [CaptionSourceCue]?

        public init(
            isEnabled: Bool = false,
            style: Style = .glass,
            position: Position = .bottom,
            fontScale: Double = 1,
            maxCharactersPerCue: Int = 28,
            verticalMargin: Double = 0.065,
            customCues: [CaptionSourceCue]? = nil
        ) {
            self.isEnabled = isEnabled
            self.style = style
            self.position = position
            self.fontScale = min(max(fontScale.isFinite ? fontScale : 1, 0.7), 1.6)
            self.maxCharactersPerCue = min(max(maxCharactersPerCue, 8), 64)
            self.verticalMargin = min(max(
                verticalMargin.isFinite ? verticalMargin : 0.065,
                0
            ), 0.3)
            self.customCues = customCues
        }
    }

    /// Reproducible delivery intent. The platform renderer decides the concrete
    /// codec while preserving this small, portable set of quality tiers.
    public struct Export: Codable, Equatable, Sendable {
        public enum Preset: String, Codable, CaseIterable, Sendable {
            case source
            case balanced
            case compact
        }

        public var preset: Preset

        public init(preset: Preset = .balanced) {
            self.preset = preset
        }
    }

    public var schemaVersion: String
    public var preset: String
    public var cursor: Cursor
    public var camera: Camera
    public var presenterCamera: PresenterCamera?
    public var audio: Audio?
    public var canvas: Canvas?
    public var interaction: Interaction?
    public var timeline: VideoEditTimeline?
    public var captions: Captions?
    public var videoAnnotations: [VideoAnnotation]?
    public var export: Export?

    public init(
        schemaVersion: String = AutoEditPlan.currentSchemaVersion,
        preset: String = "natural",
        cursor: Cursor = Cursor(
            smoothing: 0.72,
            smoothingWindowMilliseconds: 48,
            scale: 1.15,
            hidesWhenIdle: false
        ),
        camera: Camera = Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.60,
            generationStrength: .balanced,
            motionBlurStrength: 0.12
        ),
        presenterCamera: PresenterCamera? = PresenterCamera(),
        audio: Audio? = Audio(),
        canvas: Canvas? = Canvas(),
        interaction: Interaction? = Interaction(),
        timeline: VideoEditTimeline? = nil,
        captions: Captions? = Captions(),
        videoAnnotations: [VideoAnnotation]? = [],
        export: Export? = Export()
    ) {
        self.schemaVersion = schemaVersion
        self.preset = preset
        self.cursor = cursor
        self.camera = camera
        self.presenterCamera = presenterCamera
        self.audio = audio
        self.canvas = canvas
        self.interaction = interaction
        self.timeline = timeline
        self.captions = captions
        self.videoAnnotations = videoAnnotations
        self.export = export
    }
}
