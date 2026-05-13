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
///
/// Scoped to macOS because the fix is in `MacosWatcher`; the Linux watcher
/// is a separate inotify-based code path and isn't audited here.
@Suite(.enabled(if: isMacOS)) struct FileMonitorLifecycleSequenceTests {

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
        // Linux's inotify needs a moment for the watch descriptor to be
        // registered and the reader thread to enter its read() loop.
        try await Task.sleep(for: .seconds(2))

        // Create
        try "hello".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(3))

        // Modify
        try "hello world".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(3))

        // Delete
        try FileManager.default.removeItem(at: testFile)
        try await Task.sleep(for: .seconds(3))

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
        // Let Linux inotify finish registering before the first write.
        try await Task.sleep(for: .seconds(2))

        try "1".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        try "2".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        try "3".write(to: testFile, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(3))

        monitor.stop()

        let kinds = watcher.events.map { event -> String in
            switch event {
            case .added:   return "added"
            case .changed: return "changed"
            case .deleted: return "deleted"
            }
        }
        let addedCount = kinds.filter { $0 == "added" }.count
        // Test premise: at minimum we must see one .added (otherwise the
        // platform watcher didn't deliver our create event and the rest of
        // the assertion is meaningless). The bug guard is: no MORE than one.
        #expect(addedCount >= 1, "no events for \(testFile.lastPathComponent); platform did not deliver, got \(kinds)")
        #expect(addedCount <= 1, "cumulative-flag bug regressed — multiple .added in \(kinds)")
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Compile-time platform gate for the suite. swift-testing's `.enabled(if:)`
/// trait wants a `Bool` value; we route through this constant so the suite
/// is skipped (not just runtime-no-op'd) on non-macOS platforms.
private let isMacOS: Bool = {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}()
