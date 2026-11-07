import Foundation
import Testing
@testable import PushUpsEngine

/// A folder of the test's own, with a clip in it and the cache's folder beside. The clip can be any bytes: the
/// cache only asks the file system which file it is.
private struct Scratch {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "PoseCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var clips: URL { folder.appending(component: "clips", directoryHint: .isDirectory) }
    var cache: PoseCache { PoseCache(folder: folder.appending(component: "cache", directoryHint: .isDirectory)) }

    init() throws {
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    }

    func clip(_ name: String, bytes: String = "a clip") throws -> URL {
        let url = clips.appending(component: name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func remove() throws {
        try FileManager.default.removeItem(at: folder)
    }
}

/// A clip's worth of real poses: half-reps', 8 s at 60 fps.
private func halfReps() throws -> Poses {
    try Poses(contentsOf: golden("half-reps", "poses-vision.json"))
}

/// A clip's poses come back as they were kept, and nothing is written into or beside the clip.
@Test func keptPosesComeBack() throws {
    let scratch = try Scratch()
    defer { #expect(throws: Never.self) { try scratch.remove() } }
    let clip = try scratch.clip("set.mov")
    let poses = try halfReps()
    let entry = try #require(try scratch.cache.entry(for: clip))
    #expect(try scratch.cache.poses(at: entry) == nil)

    try scratch.cache.keep(poses, at: entry)
    #expect(try scratch.cache.entry(for: clip) == entry)
    let kept = try #require(try scratch.cache.poses(at: entry))
    #expect(kept.frames == poses.frames)
    #expect((kept.source, kept.width, kept.height) == (poses.source, poses.width, poses.height))
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.clips.path(percentEncoded: false)) == ["set.mov"])
}

/// A clip changed in place, even one put back to its old size and modification date, or another file at the same
/// path, is posed again. A clip moved on its volume is the same file, and found again.
@Test func onlyTheSameUnchangedFileIsFoundAgain() throws {
    let scratch = try Scratch()
    defer { #expect(throws: Never.self) { try scratch.remove() } }
    var clip = try scratch.clip("set.mov", bytes: "frames")
    let entry = try #require(try scratch.cache.entry(for: clip))
    try scratch.cache.keep(try halfReps(), at: entry)

    let moved = scratch.clips.appending(component: "moved.mov")
    try FileManager.default.moveItem(at: clip, to: moved)
    #expect(try scratch.cache.entry(for: moved) == entry)
    try FileManager.default.moveItem(at: moved, to: clip)
    #expect(try scratch.cache.entry(for: clip) == entry)

    // Same size, same modification date, other bytes.
    let modified = try #require(try clip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let handle = try FileHandle(forWritingTo: clip)
    try handle.write(contentsOf: Data("FRAMES".utf8))
    try handle.close()
    var dated = URLResourceValues()
    dated.contentModificationDate = modified
    try clip.setResourceValues(dated)
    let changed = try #require(try scratch.cache.entry(for: clip))
    #expect(changed != entry)
    #expect(try scratch.cache.poses(at: changed) == nil)

    // Another file in its place, with the same bytes.
    try scratch.cache.keep(try halfReps(), at: changed)
    try Data("FRAMES".utf8).write(to: clip, options: .atomic)
    let replaced = try #require(try scratch.cache.entry(for: clip))
    #expect(![entry, changed].contains(replaced))
    #expect(try scratch.cache.poses(at: replaced) == nil)
}

/// Poses kept from another way of posing clips go unused.
@Test func anotherWayOfPosingStartsAfresh() throws {
    let scratch = try Scratch()
    defer { #expect(throws: Never.self) { try scratch.remove() } }
    let clip = try scratch.clip("set.mov")
    let before = PoseCache(folder: scratch.cache.folder, posing: "0 revision1")
    try before.keep(try halfReps(), at: try #require(try before.entry(for: clip)))

    let entry = try #require(try scratch.cache.entry(for: clip))
    #expect(try before.entry(for: clip) != entry)
    #expect(try scratch.cache.poses(at: entry) == nil)
}

/// The folder keeps within its limit, giving up the poses used longest ago.
@Test func theCacheKeepsWithinItsLimit() throws {
    let scratch = try Scratch()
    defer { #expect(throws: Never.self) { try scratch.remove() } }
    let poses = try halfReps()
    let one = scratch.cache
    let first = try #require(try one.entry(for: try scratch.clip("first.mov")))
    try one.keep(poses, at: first)
    let size = try #require(try first.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    // Room for two.
    let cache = PoseCache(folder: one.folder, limit: size * 5 / 2)
    let second = try #require(try cache.entry(for: try scratch.clip("second.mov")))
    try cache.keep(poses, at: second)
    // The first is used again, so the second is the one used longest ago.
    #expect(try cache.poses(at: first) != nil)
    let third = try #require(try cache.entry(for: try scratch.clip("third.mov")))
    try cache.keep(poses, at: third)

    let kept = Set(try FileManager.default.contentsOfDirectory(atPath: cache.folder.path(percentEncoded: false)))
    #expect(kept == [first.lastPathComponent, third.lastPathComponent])
}
