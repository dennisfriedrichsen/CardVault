import CryptoKit
import Foundation

public enum FileSystemOperation: String, Sendable { case read, write, createDirectory, remove, move, attributes }
public enum FileSystemError: Error, Equatable, Sendable {
    case injected(FileSystemOperation, String)
    case unexpectedEndOfFile(String)
    case existingConflict(String)
    case sourceChanged(String)
}

public actor FaultInjector {
    public struct Rule: Sendable {
        public let operation: FileSystemOperation
        public let pathContains: String?
        public var remainingPasses: Int
        public init(_ operation: FileSystemOperation, pathContains: String? = nil, after passes: Int = 0) {
            self.operation = operation
            self.pathContains = pathContains
            self.remainingPasses = passes
        }
    }
    private var rules: [Rule]
    public init(rules: [Rule] = []) { self.rules = rules }

    public func check(_ operation: FileSystemOperation, url: URL) throws {
        guard let index = rules.firstIndex(where: {
            $0.operation == operation && ($0.pathContains.map { url.path.contains($0) } ?? true)
        }) else { return }
        if rules[index].remainingPasses > 0 {
            rules[index].remainingPasses -= 1
            return
        }
        rules.remove(at: index)
        throw FileSystemError.injected(operation, url.lastPathComponent)
    }
}

public actor LocalFileSystem {
    /// Reports incremental processed bytes while a read or write is in flight.
    /// Handlers are expected to aggregate cheaply; they must never do UI work.
    public typealias ByteHandler = @Sendable (Int64) async -> Void

    private let injector: FaultInjector?
    private let chunkBytes: Int
    private let fileManager = FileManager()

    public init(injector: FaultInjector? = nil, chunkBytes: Int = TransferTuning.default.chunkBytes) {
        self.injector = injector
        self.chunkBytes = max(4096, chunkBytes)
    }

    /// Creates an independent file system actor that shares this one's fault
    /// injector and chunk size. Bounded-concurrency work needs separate actors
    /// because a single `LocalFileSystem` serialises every operation.
    public func makePeer() -> LocalFileSystem {
        LocalFileSystem(injector: injector, chunkBytes: chunkBytes)
    }

    public func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    public func createDirectory(_ url: URL) async throws {
        try await injector?.check(.createDirectory, url: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func removeIncompleteFile(_ url: URL) async throws {
        try await injector?.check(.remove, url: url)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func fileSize(_ url: URL) async throws -> Int64 {
        try await injector?.check(.attributes, url: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    public func checksum(_ url: URL, expectedSize: Int64? = nil,
                         onBytes: ByteHandler? = nil) async throws -> String {
        try await injector?.check(.read, url: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytesRead: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
            bytesRead += Int64(data.count)
            hash.update(data: data)
            await onBytes?(Int64(data.count))
        }
        if let expectedSize, bytesRead != expectedSize {
            throw FileSystemError.sourceChanged(url.lastPathComponent)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func copyExclusive(from source: URL, to destination: URL, expectedSize: Int64,
                              onBytes: ByteHandler? = nil) async throws {
        try await injector?.check(.read, url: source)
        try await injector?.check(.write, url: destination)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileSystemError.existingConflict(destination.path)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: chunkBytes), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                await onBytes?(Int64(data.count))
            }
            try output.synchronize()
            guard copied == expectedSize else { throw FileSystemError.sourceChanged(source.lastPathComponent) }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    public func move(_ source: URL, to destination: URL) async throws {
        try await injector?.check(.move, url: source)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileSystemError.existingConflict(destination.path)
        }
        try fileManager.moveItem(at: source, to: destination)
    }
}
