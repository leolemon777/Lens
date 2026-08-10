import Foundation

enum StorageRecoveryGuidance {
    static func detail(for error: Error) -> String {
        let cocoaError = error as NSError
        guard cocoaError.domain == NSCocoaErrorDomain else {
            return error.localizedDescription
        }

        switch CocoaError.Code(rawValue: cocoaError.code) {
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileReadNoPermission:
            return "目标位置不可写。屏迹不会删除已有项目；请把 .screentrace 项目包复制到可写磁盘，或恢复文件夹写入权限后重试。"
        case .fileWriteOutOfSpace:
            return "项目磁盘空间不足。已经写入的原始媒体和分片会继续保留；请释放空间后重试。"
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return "项目文件不完整或已被移动。请从备份恢复整个 .screentrace 项目包，再重新打开。"
        default:
            return error.localizedDescription
        }
    }
}
