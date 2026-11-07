import CryptoKit
import Foundation
import Vision

// A clip filmed on the phone is posed by Vision once, and its poses kept on disk, in a folder of the app's own
// (its Caches), so the clip reopens after a relaunch without running Vision again. Nothing goes into or beside
// the clip. A recorded live set doesn't need this: its poses are in the movie.
//
// Which file a clip is, is the file system's to say, through Foundation's resource values: the volume's UUID,
// the file's identifier on it, and its generation identifier, which changes whenever the file's data does and
// lasts across restarts (NSURL.h). So the same file is found again, also after a move on its volume, and a
// changed file, or another file at the same path, is posed again. A volume that can't say which file it is has
// its clips posed every time.

extension Poses {
    /// How ``detect(in:trim:progress:)`` poses a clip, for ``PoseCache``. Raise the number whenever it would find
    /// other poses in the same clip (the joints it keeps, how it turns and times them, which person it takes), so
    /// the poses kept from before go unused rather than wrong. Vision's revision of the request is in it too, so
    /// a macOS whose Vision poses another way starts afresh.
    public static let posing = "1 \(DetectHumanBodyPoseRequest().revision)"
}

/// Clips' poses kept on disk, one file each in `folder`, written and read as `golden/` holds them. The folder
/// holds at most `limit` bytes: keeping a clip's poses removes the ones used longest ago beyond that.
public struct PoseCache: Sendable {
    public let folder: URL
    public let limit: Int
    /// How the poses were found: kept under it, and found again only by it.
    public let posing: String

    /// 200 MB holds the poses of sixteen 2-minute clips at 60 fps (12 MB each), or about 250 clips like the
    /// test clips.
    public init(folder: URL, limit: Int = 200_000_000, posing: String = Poses.posing) {
        (self.folder, self.limit, self.posing) = (folder, limit, posing)
    }

    /// Where the poses of the clip at `clip` are kept, named for which file it is, as it is now, and how it was
    /// posed. Nil for a clip on a volume that can't say which file it is.
    public func entry(for clip: URL) throws -> URL? {
        var clip = clip
        // The URL may hold its values from before the file changed.
        clip.removeAllCachedResourceValues()
        let values = try clip.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey, .generationIdentifierKey])
        guard let volume = values.volumeUUIDString, let file = values.fileIdentifier,
              let generation = values.generationIdentifier else { return nil }
        // The generation identifier is opaque: its secure coding is the one way to its bytes that NSURL.h promises.
        let archived = try NSKeyedArchiver.archivedData(withRootObject: generation, requiringSecureCoding: true)
        var hash = SHA256()
        hash.update(data: Data("\(posing)\n\(volume)\n\(file)\n".utf8))
        hash.update(data: archived)
        let name = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return folder.appending(component: "\(name).json")
    }

    /// The poses kept at `entry`, or nil if there are none. Marked as used now, so they're the last to go.
    public func poses(at entry: URL) throws -> Poses? {
        guard FileManager.default.fileExists(atPath: entry.path(percentEncoded: false)) else { return nil }
        var entry = entry
        var used = URLResourceValues()
        used.contentModificationDate = .now
        try entry.setResourceValues(used)
        return try Poses(contentsOf: entry)
    }

    /// Keeps `poses` at `entry`, then removes the poses used longest ago until the folder is within the limit.
    public func keep(_ poses: Poses, at entry: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try poses.write(to: entry)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            .map { (url: $0, values: try $0.resourceValues(forKeys: keys)) }
            .sorted { ($0.values.contentModificationDate ?? .distantPast) > ($1.values.contentModificationDate ?? .distantPast) }
        var size = 0
        for entry in entries {
            size += entry.values.fileSize ?? 0
            if size > limit { try FileManager.default.removeItem(at: entry.url) }
        }
    }
}
