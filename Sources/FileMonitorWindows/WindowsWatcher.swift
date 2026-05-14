//
// aus der Technik, on 27.12.24.
// https://www.ausdertechnik.de
//
// Windows file system watcher using ReadDirectoryChangesW API
//

import Foundation
import FileMonitorShared

#if os(Windows)
import WinSDK

public final class WindowsWatcher: WatcherProtocol, @unchecked Sendable {
    public var delegate: WatcherDelegate?

    private let directory: URL
    private var directoryHandle: HANDLE?
    private let stateLock = NSLock()
    private var _shouldStopWatching: Bool = false

    private var shouldStopWatching: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _shouldStopWatching }
        set { stateLock.lock(); _shouldStopWatching = newValue; stateLock.unlock() }
    }

    public required init(directory: URL) throws {
        guard directory.isDirectory else {
            throw FileMonitorErrors.not_a_directory(url: directory)
        }
        self.directory = directory
    }

    public func observe() throws {
        // Open directory handle for overlapped monitoring.
        let path = directory.path
        let handle = path.withCString(encodedAs: UTF16.self) { pathPtr in
            CreateFileW(
                pathPtr,
                DWORD(FILE_LIST_DIRECTORY),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED),
                nil
            )
        }

        guard handle != INVALID_HANDLE_VALUE else {
            throw FileMonitorErrors.can_not_open(url: directory)
        }

        directoryHandle = handle
        shouldStopWatching = false

        let watchHandle = handle
        let watchDirectory = directory
        let watchDelegate = delegate

        // Block observe() until the worker has actually queued
        // ReadDirectoryChangesW with the kernel. Without this, observe()
        // returns the moment the dispatch is scheduled — the kernel may
        // not yet be watching when the caller performs the operations
        // they want to be notified about. Linux's inotify_add_watch and
        // macOS's FSEventStreamStart both block until the watch is live;
        // this gives Windows the same contract.
        //
        // The priming state is wrapped in a single Sendable class so the
        // closure captures a reference (uniformly safe across the
        // Swift-6 strict-concurrency sending constraint) instead of two
        // separate value-typed captures whose post-send use by observe()
        // would violate the sending rule.
        final class Priming: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            var error: Error?
        }
        let priming = Priming()

        // Use DispatchQueue.global rather than Task.detached: dispatch
        // closures are @Sendable @convention(block), not `sending`, so
        // observe() can keep using `priming` after the call without
        // tripping Swift 6's transfer-of-ownership checker. (And there's
        // no need for structured concurrency here — the worker is a
        // single read loop with explicit stop signalling.)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, watchHandle, watchDirectory, watchDelegate, priming] in
            // Manual-reset event so the wait is edge-safe across iterations
            // even if the kernel signals between Wait calls.
            guard let event = CreateEventW(nil, true, false, nil) else {
                priming.error = FileMonitorErrors.can_not_open(url: watchDirectory)
                priming.semaphore.signal()
                return
            }
            defer { CloseHandle(event) }

            var overlapped = OVERLAPPED()
            overlapped.hEvent = event
            var buffer = [UInt8](repeating: 0, count: 65536)

            // Issue the first read synchronously. Once this returns
            // (either with the operation pending or completed), the
            // kernel is watching for changes — at that point it's safe
            // to wake up observe(). The loop below picks up from the wait.
            ResetEvent(event)
            var bytesReturned: DWORD = 0
            let initialRead = buffer.withUnsafeMutableBytes { bufferPtr in
                ReadDirectoryChangesW(
                    watchHandle,
                    bufferPtr.baseAddress,
                    DWORD(bufferPtr.count),
                    false,  // don't watch subtree
                    DWORD(FILE_NOTIFY_CHANGE_FILE_NAME |
                          FILE_NOTIFY_CHANGE_LAST_WRITE |
                          FILE_NOTIFY_CHANGE_SIZE),
                    &bytesReturned,
                    &overlapped,
                    nil
                )
            }
            if !initialRead {
                let lastError = GetLastError()
                if lastError != DWORD(ERROR_IO_PENDING) {
                    priming.error = FileMonitorErrors.can_not_open(url: watchDirectory)
                    priming.semaphore.signal()
                    return
                }
                // ERROR_IO_PENDING: read queued, event will be signalled.
            }
            // Kernel is now watching. Release observe().
            priming.semaphore.signal()

            // Now consume events. The first iteration waits on the read
            // we just queued; subsequent iterations re-arm and wait.
            var needsRearm = false
            while !(self?.shouldStopWatching ?? true) {
                if needsRearm {
                    ResetEvent(event)
                    let rearmed = buffer.withUnsafeMutableBytes { bufferPtr in
                        ReadDirectoryChangesW(
                            watchHandle,
                            bufferPtr.baseAddress,
                            DWORD(bufferPtr.count),
                            false,
                            DWORD(FILE_NOTIFY_CHANGE_FILE_NAME |
                                  FILE_NOTIFY_CHANGE_LAST_WRITE |
                                  FILE_NOTIFY_CHANGE_SIZE),
                            &bytesReturned,
                            &overlapped,
                            nil
                        )
                    }
                    if !rearmed && GetLastError() != DWORD(ERROR_IO_PENDING) {
                        break
                    }
                }

                // Poll the event with a short timeout so the loop also
                // notices the stop flag in a bounded time.
                var completed = false
                while !(self?.shouldStopWatching ?? true) {
                    let waitResult = WaitForSingleObject(event, 250)
                    if waitResult == WAIT_OBJECT_0 {
                        completed = true
                        break
                    } else if waitResult == DWORD(WAIT_TIMEOUT) {
                        continue
                    } else {
                        break
                    }
                }

                if self?.shouldStopWatching ?? true {
                    CancelIo(watchHandle)
                    var transferred: DWORD = 0
                    _ = GetOverlappedResult(watchHandle, &overlapped, &transferred, true)
                    break
                }

                guard completed else { break }

                var transferred: DWORD = 0
                guard GetOverlappedResult(watchHandle, &overlapped, &transferred, false),
                      transferred > 0 else {
                    needsRearm = true
                    continue
                }

                buffer.withUnsafeBytes { ptr in
                    var offset = 0
                    while offset < Int(transferred) {
                        guard let baseAddress = ptr.baseAddress else { break }

                        let infoPtr = baseAddress.advanced(by: offset)
                        let nextEntryOffset = infoPtr.load(as: DWORD.self)
                        let action = infoPtr.advanced(by: 4).load(as: DWORD.self)
                        let fileNameLength = infoPtr.advanced(by: 8).load(as: DWORD.self)

                        let fileNamePtr = infoPtr.advanced(by: 12).assumingMemoryBound(to: WCHAR.self)
                        let charCount = Int(fileNameLength) / MemoryLayout<WCHAR>.size
                        let fileName = String(utf16CodeUnits: fileNamePtr, count: charCount)
                        let fileURL = watchDirectory.appendingPathComponent(fileName)

                        let event: FileChangeEvent?
                        switch action {
                        case DWORD(FILE_ACTION_ADDED), DWORD(FILE_ACTION_RENAMED_NEW_NAME):
                            event = .added(file: fileURL)
                        case DWORD(FILE_ACTION_REMOVED), DWORD(FILE_ACTION_RENAMED_OLD_NAME):
                            event = .deleted(file: fileURL)
                        case DWORD(FILE_ACTION_MODIFIED):
                            event = .changed(file: fileURL)
                        default:
                            event = nil
                        }

                        if let event = event {
                            watchDelegate?.fileDidChanged(event: event)
                        }

                        if nextEntryOffset == 0 {
                            break
                        }
                        offset += Int(nextEntryOffset)
                    }
                }
                needsRearm = true
            }

            CancelIo(watchHandle)
        }

        priming.semaphore.wait()
        if let error = priming.error {
            // Tear down the handle we successfully opened, since the
            // worker that owns the rest of the lifecycle exited early.
            CloseHandle(handle)
            directoryHandle = nil
            shouldStopWatching = true
            throw error
        }
    }

    public func stop() {
        shouldStopWatching = true

        if let handle = directoryHandle {
            CloseHandle(handle)
            directoryHandle = nil
        }
    }
}

#endif
