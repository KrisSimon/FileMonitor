//
// aus der Technik, on 15.05.23.
// https://www.ausdertechnik.de
//

import Foundation
import FileMonitorShared

#if os(macOS)
public final class MacosWatcher: WatcherProtocol, @unchecked Sendable {
    public var delegate: WatcherDelegate?
    let fileWatcher: FileWatcher

    /// Paths we've already reported `.added` for on this stream. FSEvents
    /// reports flags *cumulatively* — once the `ItemCreated` bit fires for a
    /// path, it stays set on subsequent edits to the same path — so without
    /// per-path memory every later modification would re-emit `.added`.
    ///
    /// Keyed by raw path string (not `URL`) because the callback receives a
    /// plain POSIX path via `event.path` while `getCurrentFiles` returns
    /// `URL(fileURLWithPath:)` values; mixing the two as `Set<URL>` keys
    /// produces non-equal elements for the same file. Path-keyed avoids
    /// any URL-normalisation surprises.
    ///
    /// Guarded because FSEvents can re-enter the callback concurrently on
    /// the dispatch queue for batched events.
    private var seenPaths: Set<String> = []
    private let seenLock = NSLock()

    required public init(directory: URL) throws {

        fileWatcher = FileWatcher([directory.path])
        fileWatcher.queue = DispatchQueue.global()

        // Seed seenPaths with the directory's contents at startup so files
        // that existed before we started watching don't get reported as
        // newly created on their first edit.
        for url in (try? getCurrentFiles(in: directory)) ?? [] {
            seenPaths.insert(url.path)
        }

        fileWatcher.callback = { [self] event throws in
            guard let url = URL(string: event.path), url.isDirectory == false else { return }
            let path = event.path

            // Trust the kernel's FSEvent flag bits — they are authoritative
            // for what happened. The previous classifier combined flags with
            // a `getCurrentFiles(in: directory)` snapshot diff (changeSetCount)
            // to disambiguate, but the snapshot is only accurate at the
            // instant the callback runs. On slower runloops (notably
            // compiled binaries that don't run a fully-initialised Foundation
            // runloop) the FS state has already settled past the change by
            // the time we sample, so changeSetCount == 0 and every event
            // collapsed to `.changed`.
            let outcome: FileChangeEvent
            if event.fileRemoved {
                // Removed wins even when other bits are also set: FSEvents
                // can report Created|Modified|Removed together for short-
                // lived files, but the file is gone either way.
                seenLock.lock()
                seenPaths.remove(path)
                seenLock.unlock()
                outcome = .deleted(file: url)
            } else if event.fileCreated && isFirstSighting(of: path) {
                // First time we've seen this path on this stream with
                // Created set → real new file.
                outcome = .added(file: url)
            } else if event.fileModified || event.fileCreated {
                // Modified flag (real edit), or a stale Created flag on a
                // path we've already reported (FSEvents flag cumulativity).
                // Remember the path so a future Removed+recreate still
                // surfaces as a fresh .added.
                seenLock.lock()
                seenPaths.insert(path)
                seenLock.unlock()
                outcome = .changed(file: url)
            } else {
                // Metadata-only / unknown flag combination — don't spam
                // .changed for events the consumer can't act on.
                return
            }
            self.delegate?.fileDidChanged(event: outcome)
        }
    }

    deinit {
        stop()
    }

    public func observe() throws {
        fileWatcher.start()
    }

    public func stop() {
        fileWatcher.stop();
    }

    /// First sighting of `path` on this stream? Inserts on success.
    private func isFirstSighting(of path: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        return seenPaths.insert(path).inserted
    }
}
#endif
