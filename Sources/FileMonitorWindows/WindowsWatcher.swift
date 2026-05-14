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
    private var isRunning = false
    private var monitorTask: Task<Void, Never>?

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
        isRunning = true

        let watchHandle = handle
        let watchDirectory = directory
        let watchDelegate = delegate

        // Block observe() until the worker has actually queued
        // ReadDirectoryChangesW with the kernel. Without this, observe()
        // returns the moment Task.detached is scheduled — the kernel may
        // not yet be watching when the caller performs the operations
        // they want to be notified about. Linux's inotify_add_watch and
        // macOS's FSEventStreamStart both block until the watch is live;
        // this gives Windows the same contract.
        let primed = DispatchSemaphore(value: 0)
        // Box for the error so the task can hand one back through the
        // semaphore handoff. @unchecked Sendable because we only touch
        // it from the task (before signal) and from observe() (after
        // wait) — the semaphore is the synchronisation point.
        final class PrimingError: @unchecked Sendable {
            var error: Error?
        }
        let primingError = PrimingError()

        monitorTask = Task.detached { [watchHandle, watchDirectory, watchDelegate] in
            // Manual-reset event so the wait is edge-safe across iterations
            // even if the kernel signals between Wait calls.
            guard let event = CreateEventW(nil, true, false, nil) else {
                primingError.error = FileMonitorErrors.can_not_open(url: watchDirectory)
                primed.signal()
                return
            }
            defer { CloseHandle(event) }

            var overlapped = OVERLAPPED()
            overlapped.hEvent = event
            var buffer = [UInt8](repeating: 0, count: 65536)

            // Issue the first read synchronously. Once this returns (either
            // with the operation pending or completed), the kernel is
            // watching for changes — at that point it's safe to wake up
            // observe(). The loop below picks up from the wait.
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
                    primingError.error = FileMonitorErrors.can_not_open(url: watchDirectory)
                    primed.signal()
                    return
                }
                // ERROR_IO_PENDING: read queued, event will be signalled.
            }
            // Kernel is now watching. Release observe().
            primed.signal()

            // Now consume events. The first iteration waits on the read
            // we just queued; subsequent iterations re-arm and wait.
            var needsRearm = false
            while !Task.isCancelled {
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
                // notices Task cancellation in a bounded time.
                var completed = false
                while !Task.isCancelled {
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

                if Task.isCancelled {
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

        primed.wait()
        if let error = primingError.error {
            // Tear down the handle we successfully opened, since the
            // task that owns the rest of the lifecycle exited early.
            monitorTask?.cancel()
            monitorTask = nil
            CloseHandle(handle)
            directoryHandle = nil
            isRunning = false
            throw error
        }
    }

    public func stop() {
        isRunning = false
        monitorTask?.cancel()
        monitorTask = nil

        if let handle = directoryHandle {
            CloseHandle(handle)
            directoryHandle = nil
        }
    }
}

#endif
