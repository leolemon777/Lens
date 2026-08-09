import Foundation

public enum TraceEventReader {
    public static func read<Event: Decodable & Sendable>(
        _ type: Event.Type,
        from url: URL
    ) throws -> [Event] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(Event.self, from: Data(line))
        }
    }
}
