import Foundation

/// What became of one date on one destination copy.
///
/// A date is metadata, not content. Every state here is reported and none of
/// them is a failure of the transfer: the bytes are the product, and a copy
/// whose SHA-256 matches the source is a good copy whether or not its dates
/// could be written.
public enum TimestampState: String, Codable, Sendable {
    /// Not attempted yet, or attempted and worth attempting again on resume.
    case pending
    /// Written and read back within the destination's granularity.
    case applied
    /// The source never had this date, so there is nothing to carry over.
    case unrecorded
    /// The destination file system does not store this date at all. Measured
    /// once per destination — NFS reports a zero birth time for every file, and
    /// probing per file would turn one fact about the mount into one notice per
    /// file.
    case unsupported
    /// The write was refused, or the value read back afterwards disagreed.
    case failed
}

/// The fate of both dates on one destination copy, recorded in the manifest so
/// a metadata shortfall stays auditable long after the transfer.
public struct TimestampOutcome: Codable, Hashable, Sendable {
    public var creationDate: TimestampState
    public var modificationDate: TimestampState
    public var error: String?

    public init(creationDate: TimestampState = .pending,
                modificationDate: TimestampState = .pending,
                error: String? = nil) {
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.error = error
    }

    /// Modification time is the date every other tool sorts by, so it is the one
    /// a shortfall is reported about. A creation date the file system refuses to
    /// store is expected, not a shortfall.
    public var hasFailure: Bool { creationDate == .failed || modificationDate == .failed }

    /// A resumed transfer reapplies anything still pending, and retries anything
    /// that failed: the drive that refused the write may be healthy now.
    public var needsApplication: Bool {
        [creationDate, modificationDate].contains { $0 == .pending || $0 == .failed }
    }
}

public enum TimestampTolerance {
    /// FAT-family volumes truncate modification times to a two-second grid.
    /// Comparing a read-back exactly would report a shortfall for every single
    /// file on such a destination, which says nothing the user can act on.
    /// Measured precision is better than this on exFAT than on FAT32, but the
    /// extra slack costs only the ability to notice a sub-second discrepancy
    /// that no FAT-family tool would preserve anyway.
    public static let fatGranularity: TimeInterval = 2

    /// Everything else stores sub-second times exactly. The slack left here is
    /// for floating-point rounding through `Date`, not for the file system.
    public static let exact: TimeInterval = 0.000_01

    /// The FAT family is exactly the set of formats Windows reads natively, so
    /// this asks `VolumeFormat` rather than matching the name a second time.
    public static func forFileSystem(_ name: String) -> TimeInterval {
        VolumeFormat(fileSystemDescription: name).isWindowsNative ? fatGranularity : exact
    }
}
