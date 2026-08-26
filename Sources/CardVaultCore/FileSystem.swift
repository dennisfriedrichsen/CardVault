import CryptoKit
import Foundation

public enum FileSystemOperation: String, Sendable { case read, write, createDirectory, remove, move, attributes }

/// Why an injected fault stopped an operation. Each kind names a failure the
/// hardware really produces, so a test reproduces a situation rather than a
/// generic error.
public enum FaultKind: String, Sendable, Equatable {
    case generic
    /// The volume went away mid-operation: a card pulled, a cable knocked out.
    case disconnected
    /// The file, or the directory holding it, stopped being readable or writable.
    case permissionDenied
    /// The destination ran out of space.
    case deviceFull
}

public enum FileSystemError: Error, Equatable, Sendable {
    case injected(FileSystemOperation, String)
    case disconnected(FileSystemOperation, String)
    case permissionDenied(FileSystemOperation, String)
    case destinationFull(String)
    /// The read ended before the file did, with nothing reported about why.
    case shortRead(String, bytesRead: Int64)
    /// Fewer bytes reached the destination than the source held.
    case shortWrite(String, bytesWritten: Int64)
    case unexpectedEndOfFile(String)
    case existingConflict(String)
    case sourceChanged(String)
}

extension FaultKind {
    func error(operation: FileSystemOperation, url: URL) -> FileSystemError {
        switch self {
        case .generic: .injected(operation, url.lastPathComponent)
        case .disconnected: .disconnected(operation, url.lastPathComponent)
        case .permissionDenied: .permissionDenied(operation, url.lastPathComponent)
        case .deviceFull: .destinationFull(url.lastPathComponent)
        }
    }
}

/// A fault that lets an operation start and then stops it partway.
public struct InjectedFault: Sendable {
    /// Bytes the operation may move before it stops.
    public let byteLimit: Int64
    /// What to raise once the limit is reached. Nil stops silently, the way a
    /// short read or a short write does.
    public let kind: FaultKind?
}

public actor FaultInjector {
    /// What a matched rule does. Every effect is deterministic: no timing, no
    /// randomness, and no dependence on the speed of the drive underneath.
    public enum Effect: Sendable {
        /// Raise before a single byte moves.
        case fail(FaultKind)
        /// Let `afterBytes` bytes through, then stop. A nil kind is a silently
        /// short read or write; a kind is a device that says why it stopped.
        case stop(afterBytes: Int64, reporting: FaultKind?)
        /// Run at the operation boundary and let the operation proceed. Used to
        /// change a file underneath the transfer, to open a sleep/wake gap, or
        /// to let a test cancel at a known point.
        case interpose(@Sendable () async -> Void)
    }

    public struct Rule: Sendable {
        public let operation: FileSystemOperation
        public let pathContains: String?
        public var remainingPasses: Int
        public let effect: Effect
        /// A repeating rule is a condition rather than an event: a volume that
        /// is gone stays gone for every operation that follows.
        public let repeats: Bool

        public init(_ operation: FileSystemOperation, pathContains: String? = nil, after passes: Int = 0,
                    effect: Effect = .fail(.generic), repeats: Bool = false) {
            self.operation = operation
            self.pathContains = pathContains
            self.remainingPasses = passes
            self.effect = effect
            self.repeats = repeats
        }
    }

    private var rules: [Rule]
    public init(rules: [Rule] = []) { self.rules = rules }

    /// Returns a byte budget when the matched rule stops the operation partway,
    /// and nil when the operation may run to completion.
    @discardableResult
    public func check(_ operation: FileSystemOperation, url: URL) async throws -> InjectedFault? {
        guard let index = rules.firstIndex(where: {
            $0.operation == operation && ($0.pathContains.map { url.path.contains($0) } ?? true)
        }) else { return nil }
        if rules[index].remainingPasses > 0 {
            rules[index].remainingPasses -= 1
            return nil
        }
        let rule = rules[index]
        if !rule.repeats { rules.remove(at: index) }
        switch rule.effect {
        case .fail(let kind):
            throw kind.error(operation: operation, url: url)
        case .stop(let bytes, let kind):
            return InjectedFault(byteLimit: bytes, kind: kind)
        case .interpose(let body):
            await body()
            return nil
        }
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
        let fault = try await injector?.check(.read, url: url) ?? nil
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytesRead: Int64 = 0
        var stoppedShort = false
        while true {
            try Task.checkCancellation()
            var limit = chunkBytes
            if let fault {
                let remaining = fault.byteLimit - bytesRead
                guard remaining > 0 else { stoppedShort = true; break }
                limit = min(limit, Int(remaining))
            }
            guard let data = try handle.read(upToCount: limit), !data.isEmpty else { break }
            bytesRead += Int64(data.count)
            hash.update(data: data)
            await onBytes?(Int64(data.count))
        }
        // A digest over part of a file is worse than no digest at all, so a
        // truncated read never returns one.
        if stoppedShort {
            throw fault?.kind?.error(operation: .read, url: url)
                ?? FileSystemError.shortRead(url.lastPathComponent, bytesRead: bytesRead)
        }
        if let expectedSize, bytesRead != expectedSize {
            throw FileSystemError.sourceChanged(url.lastPathComponent)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func copyExclusive(from source: URL, to destination: URL, expectedSize: Int64,
                              onBytes: ByteHandler? = nil) async throws {
        let readFault = try await injector?.check(.read, url: source) ?? nil
        let writeFault = try await injector?.check(.write, url: destination) ?? nil
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
            var shortWrite = false
            var shortRead = false
            while true {
                try Task.checkCancellation()
                var limit = chunkBytes
                if let writeFault {
                    let remaining = writeFault.byteLimit - copied
                    guard remaining > 0 else { shortWrite = true; break }
                    limit = min(limit, Int(remaining))
                }
                if let readFault {
                    let remaining = readFault.byteLimit - copied
                    guard remaining > 0 else { shortRead = true; break }
                    limit = min(limit, Int(remaining))
                }
                guard let data = try input.read(upToCount: limit), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                await onBytes?(Int64(data.count))
            }
            try output.synchronize()
            if shortWrite {
                throw writeFault?.kind?.error(operation: .write, url: destination)
                    ?? FileSystemError.shortWrite(destination.lastPathComponent, bytesWritten: copied)
            }
            if shortRead {
                throw readFault?.kind?.error(operation: .read, url: source)
                    ?? FileSystemError.shortRead(source.lastPathComponent, bytesRead: copied)
            }
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
