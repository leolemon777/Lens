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
}

public struct PointerEvent: Codable, Equatable, Sendable {
    public let time: Double
    public let kind: PointerEventKind
    public let location: TracePoint
    public let normalizedLocation: TracePoint?
    public let displayID: UInt32?

    public init(
        time: Double,
        kind: PointerEventKind,
        location: TracePoint,
        normalizedLocation: TracePoint? = nil,
        displayID: UInt32?
    ) {
        self.time = time
        self.kind = kind
        self.location = location
        self.normalizedLocation = normalizedLocation
        self.displayID = displayID
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

    public init(
        time: Double,
        button: PointerButton,
        phase: ClickPhase,
        location: TracePoint,
        normalizedLocation: TracePoint? = nil,
        displayID: UInt32? = nil,
        clickCount: Int
    ) {
        self.time = time
        self.button = button
        self.phase = phase
        self.location = location
        self.normalizedLocation = normalizedLocation
        self.displayID = displayID
        self.clickCount = clickCount
    }
}

public struct AutoEditPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.5"

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
        public var showsClickPulse: Bool
        public var clickPulses: [ClickPulse]

        public init(showsClickPulse: Bool = true, clickPulses: [ClickPulse] = []) {
            self.showsClickPulse = showsClickPulse
            self.clickPulses = clickPulses
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

        public init(time: Double, position: TracePoint) {
            self.time = time
            self.position = position
        }
    }

    public struct CameraKeyframe: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case baseline
            case clickFocus
            case clickHold
            case returnToOverview
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
        /// Nil in legacy projects means enabled.
        public var isEnabled: Bool?
        public var smoothing: Double
        public var scale: Double
        public var hidesWhenIdle: Bool
        public var keyframes: [CursorKeyframe]

        public init(
            isEnabled: Bool? = true,
            smoothing: Double,
            scale: Double,
            hidesWhenIdle: Bool,
            keyframes: [CursorKeyframe] = []
        ) {
            self.isEnabled = isEnabled
            self.smoothing = smoothing
            self.scale = scale
            self.hidesWhenIdle = hidesWhenIdle
            self.keyframes = keyframes
        }
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var mode: String
        public var zoomIntensity: Double
        public var followPointer: Bool
        public var keyframes: [CameraKeyframe]

        public init(
            mode: String,
            zoomIntensity: Double,
            followPointer: Bool,
            keyframes: [CameraKeyframe] = []
        ) {
            self.mode = mode
            self.zoomIntensity = zoomIntensity
            self.followPointer = followPointer
            self.keyframes = keyframes
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
        public var ducksSystemUnderNarration: Bool
        public var duckedSystemVolume: Double
        public var narrationThresholdDecibels: Double
        public var duckAttackSeconds: Double
        public var duckReleaseSeconds: Double

        public init(
            isEnabled: Bool = true,
            systemVolume: Double = 1,
            microphoneVolume: Double = 1,
            ducksSystemUnderNarration: Bool = true,
            duckedSystemVolume: Double = 0.32,
            narrationThresholdDecibels: Double = -42,
            duckAttackSeconds: Double = 0.12,
            duckReleaseSeconds: Double = 0.36
        ) {
            self.isEnabled = isEnabled
            self.systemVolume = min(max(systemVolume, 0), 2)
            self.microphoneVolume = min(max(microphoneVolume, 0), 2)
            self.ducksSystemUnderNarration = ducksSystemUnderNarration
            self.duckedSystemVolume = min(max(duckedSystemVolume, 0), 1)
            self.narrationThresholdDecibels = min(max(narrationThresholdDecibels, -80), 0)
            self.duckAttackSeconds = min(max(duckAttackSeconds, 0), 2)
            self.duckReleaseSeconds = min(max(duckReleaseSeconds, 0), 3)
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

    public init(
        schemaVersion: String = AutoEditPlan.currentSchemaVersion,
        preset: String = "natural",
        cursor: Cursor = Cursor(smoothing: 0.72, scale: 1.15, hidesWhenIdle: true),
        camera: Camera = Camera(mode: "event-driven", zoomIntensity: 0.42, followPointer: true),
        presenterCamera: PresenterCamera? = PresenterCamera(),
        audio: Audio? = Audio(),
        canvas: Canvas? = Canvas(),
        interaction: Interaction? = Interaction(),
        timeline: VideoEditTimeline? = nil,
        captions: Captions? = Captions()
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
    }
}
