//
// DiskBudgetPlanner.swift — Disk Space Preflight & Budget Verification for Gate G1 S05
//
// Calculates required staging, snapshot, copy-on-write reserves, and system headroom.
// Supports fault injection for simulating ENOSPC without filling real SSD.
//

import Darwin
import Foundation

public struct DiskBudgetReport: Sendable, Equatable {
    public let fileSize: Int64
    public let acquisitionMethod: AcquisitionMethod
    public let stagingBytes: Int64
    public let snapshotBytes: Int64
    public let cowReserveBytes: Int64
    public let systemReserveBytes: Int64
    public let totalRequiredBytes: Int64
    public let availableBytes: Int64
    public let isAdequate: Bool

    public init(
        fileSize: Int64,
        acquisitionMethod: AcquisitionMethod,
        stagingBytes: Int64,
        snapshotBytes: Int64,
        cowReserveBytes: Int64,
        systemReserveBytes: Int64,
        totalRequiredBytes: Int64,
        availableBytes: Int64,
        isAdequate: Bool
    ) {
        self.fileSize = fileSize
        self.acquisitionMethod = acquisitionMethod
        self.stagingBytes = stagingBytes
        self.snapshotBytes = snapshotBytes
        self.cowReserveBytes = cowReserveBytes
        self.systemReserveBytes = systemReserveBytes
        self.totalRequiredBytes = totalRequiredBytes
        self.availableBytes = availableBytes
        self.isAdequate = isAdequate
    }
}

public struct DiskBudgetPlanner: Sendable {
    /// Minimum headroom reserved for OS, SQLite WAL, and background system tasks (500 MB)
    public static let defaultSystemReserveBytes: Int64 = 500 * 1024 * 1024

    /// Minimum COW headroom for APFS clone (10 MB or 10% of source size)
    public static let minCOWReserveBytes: Int64 = 10 * 1024 * 1024

    public init() {}

    /// Query actual available bytes on the filesystem hosting the given URL
    public static func queryAvailableBytes(at url: URL) -> Int64 {
        let path = url.standardizedFileURL.path
        var vfs = statvfs()
        if statvfs(path, &vfs) == 0 {
            return Int64(vfs.f_bavail) * Int64(vfs.f_frsize)
        }

        // Fallback to URL resource values
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
        } catch {
            // Ignore error
        }
        return 0
    }

    /// Calculate required space and verify against available capacity
    public static func planBudget(
        fileSize: Int64,
        method: AcquisitionMethod,
        destinationURL: URL,
        systemReserve: Int64 = defaultSystemReserveBytes,
        simulatedAvailableBytes: Int64? = nil
    ) throws -> DiskBudgetReport {
        let stagingBytes: Int64
        let snapshotBytes: Int64
        let cowReserveBytes: Int64

        switch method {
        case .fullCopy:
            stagingBytes = fileSize
            snapshotBytes = fileSize
            cowReserveBytes = 0
        case .apfsClone:
            stagingBytes = 1 * 1024 * 1024 // 1 MB staging metadata
            snapshotBytes = 0              // Shared blocks initially
            cowReserveBytes = max(minCOWReserveBytes, Int64(Double(fileSize) * 0.10))
        }

        let totalRequired = stagingBytes + snapshotBytes + cowReserveBytes + systemReserve
        let available = simulatedAvailableBytes ?? queryAvailableBytes(at: destinationURL)
        let isAdequate = available >= totalRequired

        let report = DiskBudgetReport(
            fileSize: fileSize,
            acquisitionMethod: method,
            stagingBytes: stagingBytes,
            snapshotBytes: snapshotBytes,
            cowReserveBytes: cowReserveBytes,
            systemReserveBytes: systemReserve,
            totalRequiredBytes: totalRequired,
            availableBytes: available,
            isAdequate: isAdequate
        )

        if !isAdequate {
            throw SourceImportError.insufficientDiskSpace(
                requiredBytes: totalRequired,
                availableBytes: available,
                reserveBytes: systemReserve
            )
        }

        return report
    }
}
