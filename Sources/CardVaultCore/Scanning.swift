import Foundation
import UniformTypeIdentifiers

public struct MediaClassifier: Sendable {
    private static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "gpr", "iiq", "kdc", "mef",
        "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "srw"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mts", "m2ts", "mpg", "mpeg",
        "360", "insv", "mxf", "braw", "r3d"
    ]
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe", "insp"]
    private static let heifExtensions: Set<String> = ["heif", "heic", "hif"]
    private static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a", "aac", "flac"]
    /// Files a camera writes beside a shot and cannot regenerate from it: edit
    /// lists, per-clip metadata, and the proxies action cameras record next to
    /// the full-resolution clip (GoPro `.lrv`/`.thm`).
    private static let sidecarExtensions: Set<String> = ["xmp", "thm", "lrv", "xml", "aae"]

    public init() {}

    public func classify(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) { return .raw }
        if Self.sidecarExtensions.contains(ext) { return .sidecar }
        if Self.jpegExtensions.contains(ext) { return .jpeg }
        if Self.heifExtensions.contains(ext) { return .heif }
        if ext == "tif" || ext == "tiff" { return .tiff }
        if ext == "png" { return .png }
        if Self.videoExtensions.contains(ext) { return .video }
        if Self.audioExtensions.contains(ext) { return .audio }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heif }
            if type.conforms(to: .tiff) { return .tiff }
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .rawImage) { return .raw }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }
}

/// What the card actually holds, by category. Reported instead of a stills-only
/// statistic so a video card, a JPEG-only card, and a mixed card each describe
/// themselves. Only categories present on the card appear.
public struct MediaComposition: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let category: MediaCategory
        public let fileCount: Int
        public let byteCount: Int64
        public var id: MediaCategory { category }
    }

    public let groups: [Group]

    public init(files: [SourceFile]) {
        var counts: [MediaCategory: (Int, Int64)] = [:]
        for file in files {
            let existing = counts[file.mediaKind.category] ?? (0, 0)
            counts[file.mediaKind.category] = (existing.0 + 1, existing.1 + file.byteCount)
        }
        groups = MediaCategory.allCases.compactMap { category in
            guard let tally = counts[category] else { return nil }
            return Group(category: category, fileCount: tally.0, byteCount: tally.1)
        }
    }

    public func fileCount(of category: MediaCategory) -> Int {
        groups.first { $0.category == category }?.fileCount ?? 0
    }
}

public struct ScanResult: Sendable {
    public var files: [SourceFile]
    public var excludedFiles: [SourceFile]
    /// Kept because a card where every frame exists twice is worth flagging
    /// before a transfer, but it is one detail about one workflow, not the
    /// summary: it is reported only when the card actually holds such pairs.
    public var rawJPEGPairCount: Int
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    public var composition: MediaComposition { MediaComposition(files: files) }
}

public enum SourceScanError: Error, Equatable, Sendable, LocalizedError {
    case sourceUnavailable

    public var errorDescription: String? {
        "The source is unavailable or unreadable."
    }
}

public struct SourceScanner: Sendable {
    private let classifier: MediaClassifier
    public init(classifier: MediaClassifier = MediaClassifier()) { self.classifier = classifier }

    public func scan(root: URL, mode: TransferMode) throws -> ScanResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: root.path) else {
            throw SourceScanError.sourceUnavailable
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw SourceScanError.sourceUnavailable }

        let canonicalRoot = root.resolvingSymlinksInPath()
        var included: [SourceFile] = []
        var excluded: [SourceFile] = []
        var stems: [String: Set<MediaKind>] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let canonicalURL = url.resolvingSymlinksInPath()
            let rootComponents = canonicalRoot.pathComponents
            let urlComponents = canonicalURL.pathComponents
            guard urlComponents.starts(with: rootComponents) else { continue }
            let relative = urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let kind = classifier.classify(url)
            let file = SourceFile(relativePath: relative, byteCount: Int64(values.fileSize ?? 0),
                                  creationDate: values.creationDate, modificationDate: values.contentModificationDate,
                                  mediaKind: kind)
            if mode == .mediaOnly && !kind.isRecognizedMedia { excluded.append(file) }
            else { included.append(file) }
            let directory = (relative as NSString).deletingLastPathComponent
            let stem = (url.deletingPathExtension().lastPathComponent).lowercased()
            stems[directory + "/" + stem, default: []].insert(kind)
        }
        if enumerationError != nil { throw SourceScanError.sourceUnavailable }
        let pairs = stems.values.count { $0.contains(.raw) && ($0.contains(.jpeg) || $0.contains(.heif)) }
        return ScanResult(files: included.sorted { $0.relativePath < $1.relativePath },
                          excludedFiles: excluded.sorted { $0.relativePath < $1.relativePath },
                          rawJPEGPairCount: pairs)
    }
}
