@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import LensCore
import UniformTypeIdentifiers

enum StepDocumentExportError: LocalizedError {
    case noSteps
    case frameUnavailable(Double)
    case destinationConflict
    case unsafeDestination(URL)
    case recoveryRequired(original: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .noSteps:
            "这段录制里没有可用的点击事件，无法生成步骤文档。"
        case let .frameUnavailable(time):
            String(format: "无法提取第 %.1f 秒的画面，请重试。", time)
        case .destinationConflict:
            "步骤文档导出目标发生冲突，请选择新的文件名后重试。"
        case let .unsafeDestination(url):
            "步骤文档导出拒绝覆盖现有文件夹或符号链接：\(url.path)"
        case let .recoveryRequired(original, recovery):
            "步骤文档导出未完成：\(original)。原文件尚未确认恢复，请保留暂存目录并联系支持（\(recovery)）。"
        }
    }
}

/// Writes a generated step document (Markdown + one frame per step) into a
/// user-chosen location. Pure delivery: the plan itself comes from
/// `StepDocumentPlanner` in the core.
@MainActor
struct StepDocumentExporter {
    typealias FrameWriter = @MainActor (Double, URL) async throws -> Void

    let document: StepDocument
    private let frameWriter: FrameWriter

    init(document: StepDocument, videoURL: URL) {
        self.document = document
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.frameWriter = { time, imageURL in
            let frame = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            )
            let destination = CGImageDestinationCreateWithURL(
                imageURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
            guard let destination else {
                throw StepDocumentExportError.frameUnavailable(time)
            }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw StepDocumentExportError.frameUnavailable(time)
            }
        }
    }

    init(document: StepDocument, frameWriter: @escaping FrameWriter) {
        self.document = document
        self.frameWriter = frameWriter
    }

    func write(to markdownURL: URL) async throws {
        guard !document.steps.isEmpty else { throw StepDocumentExportError.noSteps }
        let directory = markdownURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let stagingDirectory = directory.appendingPathComponent(
            ".lens-step-export-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupDirectory = stagingDirectory.appendingPathComponent(
            ".backup",
            isDirectory: true
        )
        var removeStagingWhenFinished = true
        defer {
            if removeStagingWhenFinished {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )

        let markdownStem = markdownURL.deletingPathExtension().lastPathComponent
        let assetsDirectoryName = "\(markdownStem).assets"
        let assetsDirectory = directory.appendingPathComponent(
            assetsDirectoryName,
            isDirectory: true
        )
        let stagedAssetsDirectory = stagingDirectory.appendingPathComponent(
            assetsDirectoryName,
            isDirectory: true
        )
        try validateExistingTarget(markdownURL, allowRegularFile: true)
        try validateAssetsDirectory(assetsDirectory)
        try FileManager.default.createDirectory(
            at: stagedAssetsDirectory,
            withIntermediateDirectories: true
        )
        try makeAssetsManifest(at: stagedAssetsDirectory, imageNames: document.steps.map {
            imageName(for: $0)
        })

        var entries: [(staged: URL, target: URL)] = []
        var targetPaths = Set<String>()
        var imageNames = Set<String>()
        for step in document.steps {
            let imageName = imageName(for: step)
            guard imageNames.insert(imageName).inserted,
                  imageName == URL(fileURLWithPath: imageName).lastPathComponent else {
                throw StepDocumentExportError.destinationConflict
            }
        }
        guard targetPaths.insert(assetsDirectory.standardizedFileURL.path).inserted else {
            throw StepDocumentExportError.destinationConflict
        }
        entries.append((staged: stagedAssetsDirectory, target: assetsDirectory))

        let stagedMarkdownURL = stagingDirectory.appendingPathComponent(
            markdownURL.lastPathComponent
        )
        guard targetPaths.insert(markdownURL.standardizedFileURL.path).inserted else {
            throw StepDocumentExportError.destinationConflict
        }
        for step in document.steps {
            let stagedImageURL = stagedAssetsDirectory.appendingPathComponent(
                imageName(for: step)
            )
            try await frameWriter(step.time, stagedImageURL)
            guard FileManager.default.fileExists(atPath: stagedImageURL.path) else {
                throw StepDocumentExportError.frameUnavailable(step.time)
            }
        }
        try document.markdown(imageDirectory: assetsDirectoryName).write(
            to: stagedMarkdownURL,
            atomically: true,
            encoding: .utf8
        )
        entries.append((staged: stagedMarkdownURL, target: markdownURL))

        var backups: [(original: URL, backup: URL)] = []
        var installedTargets: [URL] = []
        do {
            for entry in entries where FileManager.default.fileExists(atPath: entry.target.path) {
                try FileManager.default.createDirectory(
                    at: backupDirectory,
                    withIntermediateDirectories: true
                )
                let backupURL = backupDirectory.appendingPathComponent(
                    "\(backups.count)-\(entry.target.lastPathComponent)"
                )
                try FileManager.default.moveItem(at: entry.target, to: backupURL)
                backups.append((original: entry.target, backup: backupURL))
            }
            for entry in entries {
                try FileManager.default.moveItem(at: entry.staged, to: entry.target)
                installedTargets.append(entry.target)
            }
        } catch {
            var recoveryError: Error?
            for target in installedTargets {
                do {
                    try FileManager.default.removeItem(at: target)
                } catch {
                    recoveryError = recoveryError ?? error
                }
            }
            for backup in backups.reversed() {
                do {
                    if FileManager.default.fileExists(atPath: backup.original.path) {
                        try FileManager.default.removeItem(at: backup.original)
                    }
                    try FileManager.default.moveItem(at: backup.backup, to: backup.original)
                } catch {
                    recoveryError = recoveryError ?? error
                }
            }
            if let recoveryError {
                removeStagingWhenFinished = false
                throw StepDocumentExportError.recoveryRequired(
                    original: error.localizedDescription,
                    recovery: recoveryError.localizedDescription
                )
            }
            throw error
        }
    }

    private func imageName(for step: StepDocument.Step) -> String {
        String(format: "step-%02d.png", step.index)
    }

    private func validateExistingTarget(
        _ url: URL,
        allowRegularFile: Bool
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true,
              (allowRegularFile && values.isRegularFile == true) else {
            throw StepDocumentExportError.unsafeDestination(url)
        }
    }

    private func validateAssetsDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw StepDocumentExportError.unsafeDestination(url)
        }
        let manifest = url.appendingPathComponent(Self.assetsManifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw StepDocumentExportError.unsafeDestination(url)
        }
        let existingManifest: AssetsManifest
        do {
            existingManifest = try JSONDecoder().decode(
                AssetsManifest.self,
                from: Data(contentsOf: manifest)
            )
        } catch {
            throw StepDocumentExportError.unsafeDestination(url)
        }
        let allowedNames = Set(existingManifest.imageNames + [Self.assetsManifestName])
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard children.allSatisfy({
            allowedNames.contains($0.lastPathComponent)
        }) else {
            throw StepDocumentExportError.unsafeDestination(url)
        }
    }

    private func makeAssetsManifest(at directory: URL, imageNames: [String]) throws {
        let manifest = AssetsManifest(imageNames: imageNames)
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: directory.appendingPathComponent(Self.assetsManifestName),
            options: .atomic
        )
    }

    private struct AssetsManifest: Codable {
        let schemaVersion: Int
        let imageNames: [String]

        init(imageNames: [String]) {
            schemaVersion = 1
            self.imageNames = imageNames
        }
    }

    private static let assetsManifestName = ".lens-step-export.json"
}
