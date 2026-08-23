import Foundation
import UniformTypeIdentifiers

public struct MediaClassifier: Sendable {
    private static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq", "kdc", "mef",
        "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "srw"
    ]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mpg", "mpeg"]
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe"]
    private static let heifExtensions: Set<String> = ["heif", "heic", "hif"]

    public init() {}

    public func classify(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) { return .raw }
        if ext == "xmp" { return .sidecar }
        if Self.jpegExtensions.contains(ext) { return .jpeg }
        if Self.heifExtensions.contains(ext) { return .heif }
        if ext == "tif" || ext == "tiff" { return .tiff }
        if ext == "png" { return .png }
        if Self.videoExtensions.contains(ext) { return .video }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heif }
            if type.conforms(to: .tiff) { return .tiff }
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .rawImage) { return .raw }
        }
        return .other
    }
}

public struct ScanResult: Sendable {
    public var files: [SourceFile]
    public var excludedFiles: [SourceFile]
    public var rawJPEGPairCount: Int
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

public struct SourceScanner: Sendable {
    private let classifier: MediaClassifier
    public init(classifier: MediaClassifier = MediaClassifier()) { self.classifier = classifier }

    public func scan(root: URL, mode: TransferMode) throws -> ScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ScanResult(files: [], excludedFiles: [], rawJPEGPairCount: 0) }

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
        let pairs = stems.values.count { $0.contains(.raw) && ($0.contains(.jpeg) || $0.contains(.heif)) }
        return ScanResult(files: included.sorted { $0.relativePath < $1.relativePath },
                          excludedFiles: excluded.sorted { $0.relativePath < $1.relativePath },
                          rawJPEGPairCount: pairs)
    }
}
