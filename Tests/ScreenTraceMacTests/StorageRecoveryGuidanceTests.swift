import Foundation
import XCTest
@testable import ScreenTraceMac

final class StorageRecoveryGuidanceTests: XCTestCase {
    func testReadOnlyAndPermissionErrorsExplainHowToRecoverWithoutDeletingProjects() {
        for code in [
            CocoaError.Code.fileWriteNoPermission,
            .fileWriteVolumeReadOnly,
            .fileReadNoPermission
        ] {
            let detail = StorageRecoveryGuidance.detail(for: NSError(
                domain: NSCocoaErrorDomain,
                code: code.rawValue
            ))
            XCTAssertTrue(detail.contains("不会删除已有项目"))
            XCTAssertTrue(detail.contains("可写磁盘"))
        }
    }

    func testDiskFullAndMissingProjectErrorsProvideSpecificNextSteps() {
        let diskFull = StorageRecoveryGuidance.detail(for: NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue
        ))
        XCTAssertTrue(diskFull.contains("原始媒体和分片"))
        XCTAssertTrue(diskFull.contains("释放空间"))

        let missing = StorageRecoveryGuidance.detail(for: NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileNoSuchFile.rawValue
        ))
        XCTAssertTrue(missing.contains("整个 .screentrace 项目包"))
        XCTAssertTrue(missing.contains("备份"))
    }

    func testUnrelatedErrorsKeepTheirOriginalDescription() {
        let error = NSError(
            domain: "app.screentrace.tests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "synthetic failure"]
        )
        XCTAssertEqual(StorageRecoveryGuidance.detail(for: error), "synthetic failure")
    }
}
