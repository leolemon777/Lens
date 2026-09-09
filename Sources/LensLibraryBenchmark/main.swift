import Foundation
import LensCore

private struct BenchmarkResult: Codable {
    let sampleCount: Int
    let corruptPackages: Int
    let coldLibraryEntriesMilliseconds: Double
    let warmLibraryEntriesMilliseconds: Double
    let searchP95Milliseconds: Double
    let entryCount: Int
    let searchMatchCount: Int
}

private struct BenchmarkReport: Codable {
    let generatedAt: Date
    let machine: String
    let results: [BenchmarkResult]
}

@main
struct LensLibraryBenchmark {
    private static let sampleCounts = [100, 1_000, 5_000]

    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let outputURL = arguments.first.map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Build/Quality/library-benchmark.json")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryBenchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var results: [BenchmarkResult] = []
        for count in sampleCounts {
            let sampleRoot = root.appendingPathComponent("sample-\(count)", isDirectory: true)
            try makeFixture(count: count, root: sampleRoot)
            let store = LensProjectStore(rootDirectory: sampleRoot)

            let coldStart = DispatchTime.now().uptimeNanoseconds
            let coldEntries = store.libraryEntries()
            let coldMilliseconds = milliseconds(since: coldStart)

            let warmStart = DispatchTime.now().uptimeNanoseconds
            let warmEntries = store.libraryEntries()
            let warmMilliseconds = milliseconds(since: warmStart)

            _ = LensLibrarySearch.filter(warmEntries, query: "roadmap", filter: .all)
            var searchDurations: [Double] = []
            var matchCount = 0
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                let matches = LensLibrarySearch.filter(
                    warmEntries,
                    query: "roadmap",
                    filter: .all
                )
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
                    / 1_000_000
                searchDurations.append(elapsed)
                matchCount = matches.count
            }
            searchDurations.sort()
            let p95 = searchDurations[min(
                searchDurations.count - 1,
                Int(Double(searchDurations.count) * 0.95)
            )]
            results.append(BenchmarkResult(
                sampleCount: count,
                corruptPackages: 1,
                coldLibraryEntriesMilliseconds: coldMilliseconds,
                warmLibraryEntriesMilliseconds: warmMilliseconds,
                searchP95Milliseconds: p95,
                entryCount: coldEntries.count,
                searchMatchCount: matchCount
            ))
        }

        let report = BenchmarkReport(
            generatedAt: Date(),
            machine: ProcessInfo.processInfo.hostName,
            results: results
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        for result in results {
            print(String(format: "L17 sample=%d cold=%.3fms warm=%.3fms searchP95=%.3fms entries=%d matches=%d",
                         result.sampleCount,
                         result.coldLibraryEntriesMilliseconds,
                         result.warmLibraryEntriesMilliseconds,
                         result.searchP95Milliseconds,
                         result.entryCount,
                         result.searchMatchCount))
        }
        print("L17 benchmark report: \(outputURL.path)")
    }

    private static func makeFixture(count: Int, root: URL) throws {
        let fileManager = FileManager.default
        let day = root.appendingPathComponent("2026-09-05", isDirectory: true)
        try fileManager.createDirectory(at: day, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let ocr = OCRDocument(
            engine: "benchmark",
            recognitionLanguages: ["zh-Hans", "en-US"],
            blocks: [OCRTextBlock(
                text: "roadmap checklist",
                confidence: 1,
                normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 0.2)
            )]
        )
        let insights = LensInsightsDocument(
            engine: "benchmark",
            suggestedTitle: "Roadmap",
            summary: "fixed scale benchmark",
            tags: ["benchmark", "roadmap"]
        )
        let ocrData = try encoder.encode(ocr)
        let insightsData = try encoder.encode(insights)

        for index in 0..<count {
            let id = UUID()
            let package = day.appendingPathComponent("\(id.uuidString).lens", isDirectory: true)
            let isScreenshot = index.isMultiple(of: 2)
            let asset = isScreenshot
                ? LensAsset(role: .screenshot, relativePath: "raw/screenshot.png")
                : LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")
            let manifest = LensManifest(
                id: id,
                kind: isScreenshot ? .screenshot : .recording,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                title: index.isMultiple(of: 17) ? "Roadmap \(index)" : "资料 \(index)",
                dimensions: LensDimensions(width: 1_920, height: 1_080),
                assets: [asset]
            )
            let analysis = package.appendingPathComponent("analysis", isDirectory: true)
            try fileManager.createDirectory(at: analysis, withIntermediateDirectories: true)
            try encoder.encode(manifest).write(
                to: package.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try ocrData.write(to: analysis.appendingPathComponent("ocr.json"), options: .atomic)
            try insightsData.write(
                to: analysis.appendingPathComponent("insights.json"),
                options: .atomic
            )
        }

        let corrupt = day.appendingPathComponent("corrupt.lens", isDirectory: true)
        try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: corrupt.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
