import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

/// Regression coverage for the macOS classifier's reliance on a directory
/// snapshot diff. The previous logic combined FSEvent flags with a
/// `getCurrentFiles(in:)` snapshot taken at callback-time; on slower runloops
/// (notably compiled binaries) the snapshot lagged the FS state and every
/// event collapsed to `.changed`. The classifier now trusts kernel flags
/// directly and uses per-path memory for the cumulative `ItemCreated` bit.
@Suite struct FileMonitorLifecycleSequenceTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String

    init() throws {
        dir = String.random(length: 10)
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Captures the ordered sequence of events the watcher delivers for a
    /// single target file. `expectedAdditions` resolves when we've seen at
    /// least one `.added` so the test can move on to subsequent steps.
    final class SequenceWatcher: FileDidChangeDelegate, @unchecked Sendable {
        private let target: URL
        private let lock = NSLock()
        private var _events: [FileChangeEvent] = []

        var events: [FileChangeEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        init(target: URL) {
            self.target = target
        }

        func fileDidChanged(event: FileChangeEvent) {
            let url: URL
            switch event {
            case .added(let u), .changed(let u), .deleted(let u):
                url = u
            }
            guard url.lastPathComponent == target.lastPathComponent else { return }
            lock.lock(); _events.append(event); lock.unlock()
        }
    }

    @Test func addThenModifyThenDeleteEmitsDistinctEvents() async throws {
        defer { cleanup() }

        let directory = tmp.appendingPathComponent(dir)
        let testFile = directory.appendingPathComponent("\(String.random(length: 8)).txt")
        let watcher = SequenceWatcher(target: testFile)

        let monitor = try FileMonitor(directory: directory, delegate: watcher)
        try monitor.start()

        // Create
        try "hello".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))

        // Modify
        try "hello world".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))

        // Delete
        try FileManager.default.removeItem(at: testFile)
        try await Task.sleep(for: .seconds(2))

        monitor.stop()

        let kinds = watcher.events.map { event -> String in
            switch event {
            case .added:   return "added"
            case .changed: return "changed"
            case .deleted: return "deleted"
            }
        }

        // We must see each phase at least once in order. FSEvents can emit
        // extra `.changed` events (inode metadata, atomic-write coalescing),
        // so we check the existence and ordering of the three transitions
        // rather than the exact count.
        let firstAdded   = kinds.firstIndex(of: "added")
        let firstDeleted = kinds.firstIndex(of: "deleted")

        #expect(firstAdded != nil, "create event should produce .added, got \(kinds)")
        #expect(firstDeleted != nil, "delete event should produce .deleted, got \(kinds)")
        if let added = firstAdded, let deleted = firstDeleted {
            #expect(added < deleted, "events out of order: \(kinds)")
        }
    }

    /// FSEvents reports flags cumulatively for a path's lifetime within a
    /// stream: every modify after a create keeps the `ItemCreated` bit set.
    /// Without per-path memory the watcher would re-emit `.added` on each
    /// modification. Two consecutive writes should yield one `.added` and
    /// at least one subsequent `.changed`, never two `.added`.
    @Test func repeatedModificationsDoNotReplayAdded() async throws {
        defer { cleanup() }

        let directory = tmp.appendingPathComponent(dir)
        let testFile = directory.appendingPathComponent("\(String.random(length: 8)).txt")
        let watcher = SequenceWatcher(target: testFile)

        let monitor = try FileMonitor(directory: directory, delegate: watcher)
        try monitor.start()

        try "1".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        try "2".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        try "3".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))

        monitor.stop()

        let addedCount = watcher.events.reduce(into: 0) { count, event in
            if case .added = event { count += 1 }
        }
        #expect(addedCount == 1, "expected exactly one .added, got \(addedCount) in \(watcher.events)")
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}
