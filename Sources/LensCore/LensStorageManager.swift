import CryptoKit
import Foundation

/// The storage classes used by the storage panel and migration report. The
/// distinction is deliberately based on paths inside a Lens package so a
/// cleanup pass cannot mistake a user file for a generated cache.
public enum LensStorageCategory: String, Codable, Equatable, Sendable {
    case source
    case rendered
    case derived
    case rebuildable
    case temporary
    case index
    case other
}

public struct LensStorageItem: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let category: LensStorageCategory
    public let packageRelativePath: String?

    public init(
        relativePath: String,
        byteCount: Int64,
        category: LensStorageCategory,
        packageRelativePath: String? = nil
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.category = category
        self.packageRelativePath = packageRelativePath
    }
}

public struct LensStorageInventory: Codable, Equatable, Sendable {
    public let rootPath: String
    public let packageCount: Int
    public let fileCount: Int
    public let items: [LensStorageItem]
    public let bytesByCategory: [LensStorageCategory: Int64]

    public init(
        rootPath: String,
        packageCount: Int,
        fileCount: Int,
        items: [LensStorageItem],
        bytesByCategory: [LensStorageCategory: Int64]
    ) {
        self.rootPath = rootPath
        self.packageCount = packageCount
        self.fileCount = fileCount
        self.items = items
        self.bytesByCategory = bytesByCategory
    }

    public var totalBytes: Int64 {
        bytesByCategory.values.reduce(0, +)
    }

    public var temporaryItems: [LensStorageItem] {
        items.filter { $0.category == .temporary }
    }
}

public struct LensStorageMigrationPlan: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let packageCount: Int
    public let fileCount: Int
    public let totalBytes: Int64

    public init(
        sourcePath: String,
        destinationPath: String,
        packageCount: Int,
        fileCount: Int,
        totalBytes: Int64
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.packageCount = packageCount
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public enum LensStorageMigrationPhase: String, Codable, Equatable, Sendable {
    case copying
    case verifying
    case publishing
    case completed
}

public struct LensStorageMigrationProgress: Codable, Equatable, Sendable {
    public let phase: LensStorageMigrationPhase
    public let completedChildren: Int
    public let totalChildren: Int

    public init(
        phase: LensStorageMigrationPhase,
        completedChildren: Int,
        totalChildren: Int
    ) {
        self.phase = phase
        self.completedChildren = completedChildren
        self.totalChildren = totalChildren
    }

    public var fraction: Double {
        switch phase {
        case .copying:
            guard totalChildren > 0 else { return 0 }
            return min(max(Double(completedChildren) / Double(totalChildren), 0), 1) * 0.75
        case .verifying:
            return 0.82
        case .publishing:
            return 0.95
        case .completed:
            return 1
        }
    }
}

public struct LensStorageMigrationReceipt: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let packageCount: Int
    public let verifiedFileCount: Int
    public let copiedBytes: Int64
    public let completedAt: Date

    public init(
        sourcePath: String,
        destinationPath: String,
        packageCount: Int,
        verifiedFileCount: Int,
        copiedBytes: Int64,
        completedAt: Date = Date()
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.packageCount = packageCount
        self.verifiedFileCount = verifiedFileCount
        self.copiedBytes = copiedBytes
        self.completedAt = completedAt
    }
}

/// A migration journal is kept beside the managed root while a copy is in
/// progress. It makes a power loss or a forced quit recoverable without
/// guessing whether the destination is complete.
public struct LensStoragePendingMigration: Codable, Equatable, Sendable {
    public let plan: LensStorageMigrationPlan
    public let stagingPath: String
    public let phase: String
    public let updatedAt: Date

    public init(
        plan: LensStorageMigrationPlan,
        stagingPath: String,
        phase: String,
        updatedAt: Date = Date()
    ) {
        self.plan = plan
        self.stagingPath = stagingPath
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

public struct LensStorageCleanupReport: Codable, Equatable, Sendable {
    public let removedItems: [LensStorageItem]
    public let skippedItems: [LensStorageItem]

    public init(
        removedItems: [LensStorageItem],
        skippedItems: [LensStorageItem]
    ) {
        self.removedItems = removedItems
        self.skippedItems = skippedItems
    }

    public var removedBytes: Int64 {
        removedItems.reduce(0) { $0 + $1.byteCount }
    }
}

public enum LensStorageManagerError: LocalizedError, Equatable {
    case rootMissing
    case rootIsNotDirectory
    case destinationAlreadyExists
    case destinationInsideManagedRoot
    case sourceInsideDestination
    case migrationAlreadyInProgress
    case verificationFailed
    case symbolicLinkNotAllowed
    case inventoryReadFailed
    case migrationJournalCorrupted
    case migrationJournalIncomplete
    case protectedTemporaryFile
    case simulatedInterruption

    public var errorDescription: String? {
        switch self {
        case .rootMissing:
            return "Lens 存储目录不存在。"
        case .rootIsNotDirectory:
            return "Lens 存储路径不是目录。"
        case .destinationAlreadyExists:
            return "目标目录已存在，为避免覆盖未执行迁移。"
        case .destinationInsideManagedRoot:
            return "目标目录不能位于当前 Lens 目录内部。"
        case .sourceInsideDestination:
            return "目标目录不能包含当前 Lens 目录。"
        case .migrationAlreadyInProgress:
            return "已有一次未完成的 Lens 存储迁移；请继续原目标或清理迁移暂存目录。"
        case .verificationFailed:
            return "迁移后的文件校验未通过，原目录保持不变。"
        case .symbolicLinkNotAllowed:
            return "Lens 存储目录包含符号链接；为避免迁移到目录外的内容，迁移已停止。"
        case .inventoryReadFailed:
            return "Lens 存储目录未能完整读取；为避免漏算文件，操作已停止。"
        case .migrationJournalCorrupted:
            return "Lens 存储迁移记录无法读取；为避免覆盖数据，操作已停止。"
        case .migrationJournalIncomplete:
            return "Lens 存储迁移记录对应的暂存和目标目录均不存在；为避免覆盖记录，操作已停止。"
        case .protectedTemporaryFile:
            return "临时文件仍被当前任务保护，未删除。"
        case .simulatedInterruption:
            return "迁移在测试注入点中断；原目录保持不变。"
        }
    }
}

/// Provides an auditable storage inventory, a copy-and-verify migration, and
/// a narrow temporary-file cleanup. It never removes a Lens package or the
/// source tree as part of migration.
public struct LensStorageManager: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func inventory() throws -> LensStorageInventory {
        try ensureManagedRoot()
        var items: [LensStorageItem] = []
        var packages = Set<String>()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw LensStorageManagerError.inventoryReadFailed
        }

        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw LensStorageManagerError.inventoryReadFailed
            }
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = relativePath(of: url, to: rootDirectory)
            let classification = classify(relativePath: relativePath)
            if let packagePath = classification.packagePath {
                packages.insert(packagePath)
            }
            let bytes = Int64(values.fileSize ?? 0)
            items.append(LensStorageItem(
                relativePath: relativePath,
                byteCount: bytes,
                category: classification.category,
                packageRelativePath: classification.packagePath
            ))
        }
        guard !enumerationFailed else {
            throw LensStorageManagerError.inventoryReadFailed
        }

        items.sort { $0.relativePath < $1.relativePath }
        let totals = Dictionary(grouping: items, by: \.category).mapValues { values in
            values.reduce(Int64(0)) { $0 + $1.byteCount }
        }
        return LensStorageInventory(
            rootPath: rootDirectory.path,
            packageCount: packages.count,
            fileCount: items.count,
            items: items,
            bytesByCategory: totals
        )
    }

    public func migrationPlan(to destination: URL) throws -> LensStorageMigrationPlan {
        try ensureManagedRoot()
        let destination = destination.standardizedFileURL
        try validateMigrationDestination(destination)
        try rejectSymbolicLinks(in: rootDirectory)
        let current = try inventory()
        return LensStorageMigrationPlan(
            sourcePath: rootDirectory.path,
            destinationPath: destination.path,
            packageCount: current.packageCount,
            fileCount: current.fileCount,
            totalBytes: current.totalBytes
        )
    }

    /// Returns a migration whose staging tree still exists. The source is
    /// intentionally left untouched until `migrate(to:)` verifies every file.
    public func pendingMigration() throws -> LensStoragePendingMigration? {
        guard let journal = try loadMigrationJournal(),
              journal.plan.sourcePath == rootDirectory.path else {
            return nil
        }
        let stagingExists = FileManager.default.fileExists(atPath: journal.stagingPath)
        let destinationExists = FileManager.default.fileExists(
            atPath: journal.plan.destinationPath
        )
        guard stagingExists || destinationExists else {
            throw LensStorageManagerError.migrationJournalIncomplete
        }
        guard stagingExists else {
            // A published destination is recovered by the explicit
            // publish-window verifier. It is not a resumable copy yet.
            return nil
        }
        return journal
    }

    /// Repairs the narrow crash window after the staging directory has been
    /// published but before the journal could be removed. `moveItem` is the
    /// final publish step; when the staging path is gone and the destination
    /// exists, compare both trees before treating the migration as complete.
    /// A mismatch keeps the journal in place so the caller can present a
    /// recoverable verification failure instead of silently switching roots.
    public func recoverPublishedMigrationIfNeeded() throws -> LensStorageMigrationReceipt? {
        guard let journal = try loadMigrationJournal(),
              journal.plan.sourcePath == rootDirectory.path else {
            return nil
        }
        let staging = URL(fileURLWithPath: journal.stagingPath, isDirectory: true)
        let destination = URL(
            fileURLWithPath: journal.plan.destinationPath,
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: staging.path),
              FileManager.default.fileExists(atPath: destination.path) else {
            return nil
        }

        try rejectSymbolicLinks(in: rootDirectory)
        try rejectSymbolicLinks(in: destination)
        let sourceFiles = try fileDigests(in: rootDirectory)
        let destinationFiles = try fileDigests(in: destination)
        guard sourceFiles == destinationFiles else {
            throw LensStorageManagerError.verificationFailed
        }

        try FileManager.default.removeItem(at: migrationJournalURL)
        return LensStorageMigrationReceipt(
            sourcePath: rootDirectory.path,
            destinationPath: destination.path,
            packageCount: journal.plan.packageCount,
            verifiedFileCount: destinationFiles.count,
            copiedBytes: journal.plan.totalBytes
        )
    }

    /// Copies the complete managed root to a new directory, hashes every
    /// regular file in both trees, and only then publishes the destination.
    /// The source remains available for rollback or manual comparison.
    public func migrate(
        to destination: URL,
        interruptionAfterCopiedChildren: Int? = nil,
        progress: ((LensStorageMigrationProgress) -> Void)? = nil
    ) throws -> LensStorageMigrationReceipt {
        try Task.checkCancellation()
        let requestedDestination = destination.standardizedFileURL
        if let recovered = try recoverPublishedMigrationIfNeeded() {
            if recovered.destinationPath == requestedDestination.path {
                progress?(
                    LensStorageMigrationProgress(
                        phase: .completed,
                        completedChildren: recovered.verifiedFileCount,
                        totalChildren: recovered.verifiedFileCount
                    )
                )
                return recovered
            }
        }
        let pending = try pendingMigration()
        if let pending,
           pending.plan.destinationPath != requestedDestination.path {
            throw LensStorageManagerError.migrationAlreadyInProgress
        }
        let plan: LensStorageMigrationPlan
        if let pending,
           pending.plan.destinationPath == requestedDestination.path {
            plan = pending.plan
        } else {
            plan = try migrationPlan(to: requestedDestination)
        }
        // Recheck on resume as well: a link could have appeared after the
        // journal was written, and copying it would make the destination
        // depend on a path outside the managed root.
        try rejectSymbolicLinks(in: rootDirectory)
        let destination = URL(fileURLWithPath: plan.destinationPath, isDirectory: true)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = pending.map {
            URL(fileURLWithPath: $0.stagingPath, isDirectory: true)
        } ?? parent.appendingPathComponent(
            ".\(destination.lastPathComponent).lens-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeMigrationJournal(
                LensStoragePendingMigration(
                    plan: plan,
                    stagingPath: staging.path,
                    phase: "copying"
                )
            )
            let children = try FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            progress?(
                LensStorageMigrationProgress(
                    phase: .copying,
                    completedChildren: 0,
                    totalChildren: children.count
                )
            )
            for (index, child) in children.enumerated() {
                try Task.checkCancellation()
                let stagedChild = staging.appendingPathComponent(child.lastPathComponent)
                if FileManager.default.fileExists(atPath: stagedChild.path) {
                    try FileManager.default.removeItem(at: stagedChild)
                }
                try FileManager.default.copyItem(
                    at: child,
                    to: stagedChild
                )
                progress?(
                    LensStorageMigrationProgress(
                        phase: .copying,
                        completedChildren: index + 1,
                        totalChildren: children.count
                    )
                )
                if let interruptionAfterCopiedChildren,
                   interruptionAfterCopiedChildren >= 0,
                   index + 1 >= interruptionAfterCopiedChildren {
                    throw LensStorageManagerError.simulatedInterruption
                }
            }

            try Task.checkCancellation()
            progress?(
                LensStorageMigrationProgress(
                    phase: .verifying,
                    completedChildren: children.count,
                    totalChildren: children.count
                )
            )
            let sourceFiles = try fileDigests(in: rootDirectory)
            try Task.checkCancellation()
            let stagedFiles = try fileDigests(in: staging)
            try writeMigrationJournal(
                LensStoragePendingMigration(
                    plan: plan,
                    stagingPath: staging.path,
                    phase: "verifying"
                )
            )
            guard sourceFiles == stagedFiles else {
                throw LensStorageManagerError.verificationFailed
            }
            try Task.checkCancellation()
            progress?(
                LensStorageMigrationProgress(
                    phase: .publishing,
                    completedChildren: children.count,
                    totalChildren: children.count
                )
            )
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: migrationJournalURL)
            progress?(
                LensStorageMigrationProgress(
                    phase: .completed,
                    completedChildren: children.count,
                    totalChildren: children.count
                )
            )
            return LensStorageMigrationReceipt(
                sourcePath: rootDirectory.path,
                destinationPath: destination.path,
                packageCount: plan.packageCount,
                verifiedFileCount: stagedFiles.count,
                copiedBytes: plan.totalBytes
            )
        } catch {
            // Keep the journal and staging tree. A later launch can resume
            // from the same destination after the transient failure clears.
            throw error
        }
    }

    /// Deletes only generated encoder/intermediate files. A caller can pass
    /// active package paths while a render is running; those candidates are
    /// reported as skipped and remain intact.
    public func cleanupTemporaryFiles(
        protecting protectedPackages: Set<URL> = []
    ) throws -> LensStorageCleanupReport {
        let current = try inventory()
        let protected = Set(protectedPackages.map { $0.standardizedFileURL.path })
        var removed: [LensStorageItem] = []
        var skipped: [LensStorageItem] = []
        for item in current.temporaryItems {
            guard let packagePath = item.packageRelativePath else {
                skipped.append(item)
                continue
            }
            let packageURL = rootDirectory.appendingPathComponent(packagePath, isDirectory: true)
            if protected.contains(packageURL.standardizedFileURL.path) {
                skipped.append(item)
                continue
            }
            let url = rootDirectory.appendingPathComponent(item.relativePath)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(item)
            } catch {
                skipped.append(item)
            }
        }
        return LensStorageCleanupReport(removedItems: removed, skippedItems: skipped)
    }

    private func ensureManagedRoot() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: rootDirectory.path,
            isDirectory: &isDirectory
        ) else {
            throw LensStorageManagerError.rootMissing
        }
        guard isDirectory.boolValue else {
            throw LensStorageManagerError.rootIsNotDirectory
        }
    }

    private var migrationJournalURL: URL {
        rootDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(rootDirectory.lastPathComponent).lens-migration.json"
        )
    }

    private func loadMigrationJournal() throws -> LensStoragePendingMigration? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard FileManager.default.fileExists(atPath: migrationJournalURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: migrationJournalURL)
            return try decoder.decode(LensStoragePendingMigration.self, from: data)
        } catch {
            throw LensStorageManagerError.migrationJournalCorrupted
        }
    }

    private func writeMigrationJournal(_ journal: LensStoragePendingMigration) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: migrationJournalURL, options: .atomic)
    }

    private func validateMigrationDestination(_ destination: URL) throws {
        let sourcePath = rootDirectory.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath else {
            throw LensStorageManagerError.destinationInsideManagedRoot
        }
        if destinationPath.hasPrefix(sourcePath + "/") {
            throw LensStorageManagerError.destinationInsideManagedRoot
        }
        if sourcePath.hasPrefix(destinationPath + "/") {
            throw LensStorageManagerError.sourceInsideDestination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LensStorageManagerError.destinationAlreadyExists
        }
    }

    private func fileDigests(in directory: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw LensStorageManagerError.inventoryReadFailed }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relative = relativePath(of: url, to: directory)
            result[relative] = try digest(of: url)
        }
        guard !enumerationFailed else {
            throw LensStorageManagerError.inventoryReadFailed
        }
        return result
    }

    private func rejectSymbolicLinks(in directory: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw LensStorageManagerError.inventoryReadFailed }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw LensStorageManagerError.symbolicLinkNotAllowed
            }
        }
        guard !enumerationFailed else {
            throw LensStorageManagerError.inventoryReadFailed
        }
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func relativePath(of url: URL, to root: URL) -> String {
        let prefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
    }

    private func classify(relativePath: String) -> (
        category: LensStorageCategory,
        packagePath: String?
    ) {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let packageIndex = components.firstIndex(where: { $0.hasSuffix(".lens") }) else {
            return components.first == ".index"
                ? (.index, nil)
                : (.other, nil)
        }
        let packagePath = components[...packageIndex].joined(separator: "/")
        let inside = Array(components.dropFirst(packageIndex + 1))
        guard let first = inside.first else { return (.other, packagePath) }
        if first == "raw" { return (.source, packagePath) }
        if first == "previews" {
            let name = inside.dropFirst().first ?? ""
            if Self.temporaryPrefixes.contains(where: { name.hasPrefix($0) }) {
                return (.temporary, packagePath)
            }
            if name == "narration-draft.caf" { return (.rebuildable, packagePath) }
            if name == "auto.mp4" || name == "annotated.png" {
                return (.rendered, packagePath)
            }
            return (.derived, packagePath)
        }
        if first == "events" || first == "analysis" || first == "edits" || first == "diagnostics" {
            return (.derived, packagePath)
        }
        if first == "manifest.json" { return (.derived, packagePath) }
        return (.other, packagePath)
    }

    private static let temporaryPrefixes = [
        ".auto-",
        ".audio-mix-",
        ".auto-mixed-",
        ".timeline-transitions-",
        ".screen-effects-",
        ".system-transitions-",
        ".conditioned-microphone-",
        ".microphone-transitions-",
        ".g3-mixed-"
    ]
}
