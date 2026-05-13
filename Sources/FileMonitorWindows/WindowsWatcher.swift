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
        // Open directory handle for monitoring with overlapped flag.
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

        monitorTask = Task.detached { [watchHandle, watchDirectory, watchDelegate] in
            var buffer = [UInt8](repeating: 0, count: 65536)

            // Event for overlapped I/O. We keep it manual-reset so that we
            // never miss a signal if we observe the loop top while the kernel
            // is signalling completion.
            let event = CreateEventW(nil, true, false, nil)
            guard event != nil else { return }
            defer { CloseHandle(event) }

            var overlapped = OVERLAPPED()
            overlapped.hEvent = event

            while !Task.isCancelled {
                ResetEvent(event)

                // Kick off one read. With FILE_FLAG_OVERLAPPED + a manual-reset
                // event, ReadDirectoryChangesW typically returns FALSE with
                // GetLastError() == ERROR_IO_PENDING and signals `event` when
                // data is available. It may *also* succeed synchronously when
                // changes are already buffered — in that case `event` is set
                // immediately and bytesReturned reflects the data.
                var bytesReturned: DWORD = 0
                let readStarted = buffer.withUnsafeMutableBytes { bufferPtr in
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
                if !readStarted {
                    let lastError = GetLastError()
                    if lastError != DWORD(ERROR_IO_PENDING) {
                        // Real failure — abort.
                        break
                    }
                    // ERROR_IO_PENDING: the read is queued, the event will be
                    // signalled when data arrives. Fall through to the wait
                    // loop below. The previous implementation `continue`d
                    // here, immediately re-issuing ReadDirectoryChangesW on
                    // the same overlapped struct while the previous request
                    // was still pending — undefined behaviour that could
                    // leave events stranded in the kernel and the loop
                    // spinning without ever processing them.
                }

                // Poll the event with a short timeout so the loop can also
                // notice Task cancellation. Manual-reset means the wait is
                // edge-safe across iterations even if WaitForSingleObject is
                // called after the kernel has already signalled.
                var completed = false
                while !Task.isCancelled {
                    let waitResult = WaitForSingleObject(event, 250)
                    if waitResult == WAIT_OBJECT_0 {
                        completed = true
                        break
                    } else if waitResult == DWORD(WAIT_TIMEOUT) {
                        continue
                    } else {
                        // WAIT_ABANDONED / WAIT_FAILED — abort the outer loop.
                        break
                    }
                }

                if Task.isCancelled {
                    // Cancel the queued operation and drain it so we don't
                    // leave the kernel waiting to write into our buffer.
                    CancelIo(watchHandle)
                    var transferred: DWORD = 0
                    _ = GetOverlappedResult(watchHandle, &overlapped, &transferred, true)
                    break
                }

                guard completed else { break }

                // The operation either completed synchronously (readStarted
                // was true) or asynchronously (ERROR_IO_PENDING). Either way,
                // GetOverlappedResult gives us the byte count.
                var transferred: DWORD = 0
                guard GetOverlappedResult(watchHandle, &overlapped, &transferred, false),
                      transferred > 0 else {
                    continue  // empty notification, re-arm
                }

                buffer.withUnsafeBytes { ptr in
                    var offset = 0
                    while offset < Int(transferred) {
                        guard let baseAddress = ptr.baseAddress else { break }

                        let infoPtr = baseAddress.advanced(by: offset)
                        let nextEntryOffset = infoPtr.load(as: DWORD.self)
                        let action = infoPtr.advanced(by: 4).load(as: DWORD.self)
                        let fileNameLength = infoPtr.advanced(by: 8).load(as: DWORD.self)

                        // File name starts at offset 12 (after NextEntryOffset,
                        // Action, FileNameLength).
                        let fileNamePtr = infoPtr.advanced(by: 12).assumingMemoryBound(to: WCHAR.self)
                        let charCount = Int(fileNameLength) / MemoryLayout<WCHAR>.size
                        let fileName = String(utf16CodeUnits: fileNamePtr, count: charCount)
                        let fileURL = watchDirectory.appendingPathComponent(fileName)

                        // Renames generate a paired _OLD_NAME / _NEW_NAME
                        // sequence; the previous code mapped _OLD_NAME to
                        // .deleted and _NEW_NAME to .added, which matches the
                        // POSIX shape consumers expect, so keep that.
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
            }

            // Cancel any pending I/O on the way out.
            CancelIo(watchHandle)
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
