import Darwin
import Foundation

/// Measures the space a bundle takes on disk, the way `du` does: allocated blocks,
/// symbolic links not followed, and hard-linked files recorded so totals count them once.
public enum DiskUsageCalculator {
    public static func usage(of url: URL) -> DiskUsage {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .zero }

        if info.st_mode & S_IFMT != S_IFDIR {
            return DiskUsage(
                allocated: Int64(info.st_blocks) * 512,
                fileCount: 1,
                hardLinks: hardLink(for: info).map { [$0] } ?? []
            )
        }

        guard let rootPath = strdup(url.path) else { return .zero }
        defer { free(rootPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .zero }
        defer { fts_close(stream) }

        var allocated: Int64 = 0
        var fileCount = 0
        var hardLinks: [HardLink] = []

        while let entry = fts_read(stream) {
            let kind = Int32(entry.pointee.fts_info)
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            switch kind {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                allocated += Int64(stat.st_blocks) * 512
                fileCount += 1
                if kind == FTS_F, let link = hardLink(for: stat) {
                    hardLinks.append(link)
                }
            case FTS_D:
                allocated += Int64(stat.st_blocks) * 512
            default:
                break
            }
        }
        return DiskUsage(allocated: allocated, fileCount: fileCount, hardLinks: hardLinks)
    }

    private static func hardLink(for info: stat) -> HardLink? {
        guard info.st_nlink > 1, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return HardLink(device: info.st_dev, inode: info.st_ino, bytes: Int64(info.st_blocks) * 512, linkCount: Int(info.st_nlink))
    }

    /// Total bytes of several bundles, counting each hard-linked file once.
    public static func combinedBytes<S: Sequence>(of usages: S) -> Int64 where S.Element == DiskUsage {
        var total: Int64 = 0
        var seen = Set<HardLink.Key>()
        for usage in usages {
            total += usage.exclusiveBytes
            for link in usage.hardLinks where seen.insert(link.key).inserted {
                total += link.bytes
            }
        }
        return total
    }

    /// Bytes that removing these bundles would actually free. A hard-linked file only frees
    /// space once every one of its links is removed.
    public static func reclaimableBytes<S: Sequence>(of usages: S) -> Int64 where S.Element == DiskUsage {
        var total: Int64 = 0
        var linkHits: [HardLink.Key: (bytes: Int64, needed: Int, hits: Int)] = [:]
        for usage in usages {
            total += usage.exclusiveBytes
            for link in usage.hardLinks {
                linkHits[link.key, default: (link.bytes, link.linkCount, 0)].hits += 1
            }
        }
        for entry in linkHits.values where entry.hits >= entry.needed {
            total += entry.bytes
        }
        return total
    }
}
