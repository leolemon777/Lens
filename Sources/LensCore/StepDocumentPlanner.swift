import Foundation

/// A generated how-to document: one numbered step per meaningful click,
/// carrying the source timestamp so the exporter can grab a frame per step.
public struct StepDocument: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let index: Int
        public let time: Double
        public let title: String
        public let detail: String?

        public init(index: Int, time: Double, title: String, detail: String? = nil) {
            self.index = index
            self.time = max(time.isFinite ? time : 0, 0)
            self.title = title
            self.detail = detail
        }
    }

    public let steps: [Step]
    public let durationSeconds: Double

    public init(steps: [Step], durationSeconds: Double) {
        self.steps = steps
        self.durationSeconds = max(durationSeconds.isFinite ? durationSeconds : 0, 0)
    }

    public var markdown: String {
        var lines: [String] = [
            "# 操作步骤",
            "",
            "共 \(steps.count) 步 · 录制时长 \(Self.timestamp(durationSeconds))。",
            ""
        ]
        for step in steps {
            lines.append("\(step.index). **[\(Self.timestamp(step.time))] \(step.title)**")
            if let detail = step.detail, !detail.isEmpty {
                lines.append("   - \(detail)（截图：step-\(String(format: "%02d", step.index)).png）")
            } else {
                lines.append("   - 截图：step-\(String(format: "%02d", step.index)).png")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Groups the recorded click track into documentation steps. Bursts of clicks
/// (double clicks, retry spam) merge into one step; the app that owned the
/// focus at that moment becomes the step's context.
public struct StepDocumentPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Clicks closer than this join the previous step.
        public var mergeWindowSeconds: Double
        public var maximumSteps: Int

        public init(
            mergeWindowSeconds: Double = 1.2,
            maximumSteps: Int = 60
        ) {
            self.mergeWindowSeconds = max(mergeWindowSeconds, 0.2)
            self.maximumSteps = max(maximumSteps, 1)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func document(
        clicks: [ClickEvent],
        windows: [WindowEvent],
        durationSeconds: Double
    ) -> StepDocument {
        let duration = durationSeconds.isFinite ? max(durationSeconds, 0) : 0
        let sortedWindows = windows
            .filter { $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        var anchors: [ClickEvent] = []
        for click in clicks {
            guard click.phase == .down,
                  click.normalizedLocation != nil,
                  click.time >= 0,
                  click.time <= duration else { continue }
            if let last = anchors.last,
               click.time - last.time < configuration.mergeWindowSeconds {
                // A burst keeps its first click: double clicks and retries
                // describe one user intention.
                continue
            }
            anchors.append(click)
            if anchors.count >= configuration.maximumSteps { break }
        }
        let steps = anchors.enumerated().map { index, click in
            StepDocument.Step(
                index: index + 1,
                time: click.time,
                title: title(for: click, windows: sortedWindows),
                detail: detail(for: click)
            )
        }
        return StepDocument(steps: steps, durationSeconds: duration)
    }

    private func title(for click: ClickEvent, windows: [WindowEvent]) -> String {
        let application = windows
            .last { $0.time <= click.time + 0.05 }?
            .applicationName
        let verb: String
        switch click.button {
        case .right: verb = "右键点击"
        default: verb = click.clickCount >= 2 ? "双击" : "点击"
        }
        guard let application, !application.isEmpty else { return verb }
        return "在 \(application) 中\(verb)"
    }

    private func detail(for click: ClickEvent) -> String? {
        guard let position = click.normalizedLocation else { return nil }
        return "画面\(Self.regionName(for: position))"
    }

    /// Nine-region grid naming, the granularity that reads naturally in docs.
    static func regionName(for position: LensPoint) -> String {
        let horizontal: String
        switch position.x {
        case ..<0.34: horizontal = "左"
        case 0.34..<0.66: horizontal = "中"
        default: horizontal = "右"
        }
        let vertical: String
        switch position.y {
        case ..<0.34: vertical = "上"
        case 0.34..<0.66: vertical = "部"
        default: vertical = "下"
        }
        if horizontal == "中" && vertical == "部" { return "中部" }
        return horizontal + vertical
    }
}
