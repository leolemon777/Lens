import Foundation
import os

/// Shared failure log so LensCore store/load `try?` does not go silent.
enum LensCoreLog {
    private static let logger = Logger(subsystem: "app.lens", category: "core")

    static func record(_ code: String, error: Error) {
        logger.error("\(code, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
