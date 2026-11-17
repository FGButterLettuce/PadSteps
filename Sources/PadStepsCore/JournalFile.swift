import Foundation

public enum JournalFileError: LocalizedError {
    case unreadable
    public var errorDescription: String? { "The saved journal is unreadable or newer than this app. It was preserved; writing is paused to protect existing records." }
}

/// Failed decoding is never equivalent to an empty journal. Every save goes
/// through the same guard, including startup migrations and settings changes.
public final class JournalFile<Value: Codable> {
    public private(set) var initialValue: Value
    public private(set) var readable: Bool
    private let url: URL
    private let options: Data.WritingOptions
    private let validate: (Value) -> Bool
    public init(url: URL, fresh: Value, options: Data.WritingOptions = [.atomic], validate: @escaping (Value) -> Bool = { _ in true }) {
        self.url = url; self.options = options.union(.atomic)
        self.validate = validate
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Value.self, from: data), validate(decoded) {
                initialValue = decoded; readable = true
            } else { initialValue = fresh; readable = false }
        } else { initialValue = fresh; readable = true }
    }
    public func reloadIfAvailable() -> Value? {
        guard !readable, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data), validate(decoded) else { return nil }
        initialValue = decoded; readable = true
        return decoded
    }
    public func save(_ value: Value) throws {
        guard readable else { throw JournalFileError.unreadable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: options)
    }
}
