#!/usr/bin/env swift

import Foundation

struct DiagnosticEvent: Decodable {
    let code: String
    let metadata: [String: String]
}

struct Measurement: Encodable {
    let sampleCount: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maximumMilliseconds: Double?
    let targetMilliseconds: Double?
    let sampleStatus: String
}

struct PerformanceSummary: Encodable {
    let schemaVersion: Int
    let generatedAt: String
    let source: String
    let minimumRecommendedSamples: Int
    let overlayReady: Measurement
    let snapTargetsReady: Measurement
    let dragUpdateMaximum: Measurement
    let privacy: String
}

let recommendedSamples = 100

func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(Double(sorted.count) * fraction)))
    return sorted[min(rank - 1, sorted.count - 1)]
}

func measurement(_ values: [Double], target: Double? = nil) -> Measurement {
    Measurement(
        sampleCount: values.count,
        p50Milliseconds: percentile(values, 0.50),
        p95Milliseconds: percentile(values, 0.95),
        maximumMilliseconds: values.max(),
        targetMilliseconds: target,
        sampleStatus: values.count >= recommendedSamples ? "sufficient" : "insufficient"
    )
}

func metric(
    from event: DiagnosticEvent,
    code: String,
    key: String
) -> Double? {
    guard event.code == code,
          let rawValue = event.metadata[key],
          let value = Double(rawValue),
          value >= 0,
          value.isFinite else {
        return nil
    }
    return value
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("Usage: summarize-capture-performance.swift <output.json>\n".utf8)
    )
    exit(64)
}

let applicationSupport = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
)[0]
let diagnosticsURL = applicationSupport
    .appendingPathComponent("Lens/diagnostics/events.jsonl")
let outputURL = URL(fileURLWithPath: arguments[1])

let data = (try? Data(contentsOf: diagnosticsURL)) ?? Data()
let decoder = JSONDecoder()
let events = data.split(separator: 0x0A).compactMap { line in
    try? decoder.decode(DiagnosticEvent.self, from: Data(line))
}

let overlayValues = events.compactMap {
    metric(
        from: $0,
        code: "capture.region_overlay_ready",
        key: "durationMilliseconds"
    )
}
let snapValues = events.compactMap {
    metric(
        from: $0,
        code: "capture.region_snap_targets_ready",
        key: "durationMilliseconds"
    )
}
let dragValues = events.compactMap {
    metric(
        from: $0,
        code: "capture.region_drag_performance",
        key: "maximumMilliseconds"
    )
}

let summary = PerformanceSummary(
    schemaVersion: 1,
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    source: "local-private-diagnostics",
    minimumRecommendedSamples: recommendedSamples,
    overlayReady: measurement(overlayValues, target: 150),
    snapTargetsReady: measurement(snapValues),
    dragUpdateMaximum: measurement(dragValues, target: 16.67),
    privacy: "Aggregated allowlisted durations only; no media, paths, titles, text, or coordinates."
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var output = try encoder.encode(summary)
output.append(0x0A)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try output.write(to: outputURL, options: .atomic)
print(outputURL.path)
