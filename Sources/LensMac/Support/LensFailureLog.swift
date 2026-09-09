import Foundation
import LensCore
import os

/// Shared store/load failure log so business-path `try?` does not go silent.
enum LensFailureLog {
    private static let logger = Logger(subsystem: "app.lens", category: "store")

    static func safeErrorMetadata(_ error: Error) -> [String: String] {
        DiagnosticEvent.errorMetadata(error)
    }

    static func record(_ code: String, error: Error) {
        let metadata = safeErrorMetadata(error)
        logger.error(
            "\(code, privacy: .public) domain=\(metadata["errorDomain", default: "unknown"], privacy: .public) code=\(metadata["errorCode", default: "unknown"], privacy: .public)"
        )
    }

    static func optional<T>(_ code: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            record(code, error: error)
            return nil
        }
    }

    static func ignoringFailure(_ code: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            record(code, error: error)
        }
    }
}
