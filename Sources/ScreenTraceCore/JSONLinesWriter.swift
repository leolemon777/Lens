import Foundation

public actor JSONLinesWriter<Event: Encodable & Sendable> {
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle?.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(_ event: Event) throws {
        guard let fileHandle else { return }
        var data = try encoder.encode(event)
        data.append(0x0A)
        try fileHandle.write(contentsOf: data)
    }

    public func synchronize() throws {
        try fileHandle?.synchronize()
    }

    public func close() throws {
        guard let fileHandle else { return }
        try fileHandle.synchronize()
        try fileHandle.close()
        self.fileHandle = nil
    }
}
