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

public class WindowsWatcher: WatcherProtocol {
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
        // Open directory handle for monitoring
        let path = directory.path
        let handle = path.withCString(encodedAs: UTF16.self) { pathPtr in
            CreateFileW(
                pathPtr,
                DWORD(FILE_LIST_DIRECTORY),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                nil
            )
        }

        guard handle != INVALID_HANDLE_VALUE else {
            throw FileMonitorErrors.can_not_open(url: directory)
        }

        directoryHandle = handle
        isRunning = true

        // Start monitoring in background task
        let watchHandle = handle
        let watchDirectory = directory
        let watchDelegate = delegate

        monitorTask = Task.detached { [watchHandle, watchDirectory, watchDelegate] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            var bytesReturned: DWORD = 0

            while !Task.isCancelled {
                let success = buffer.withUnsafeMutableBytes { bufferPtr in
                    ReadDirectoryChangesW(
                        watchHandle,
                        bufferPtr.baseAddress,
                        DWORD(bufferPtr.count),
                        0,  // Don't watch subtree (FALSE = 0)
                        DWORD(FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE),
                        &bytesReturned,
                        nil,
                        nil
                    )
                }

                guard success != 0, bytesReturned > 0 else {
                    continue
                }

                // Parse FILE_NOTIFY_INFORMATION structures
                buffer.withUnsafeBytes { ptr in
                    var offset = 0
                    while offset < Int(bytesReturned) {
                        guard let baseAddress = ptr.baseAddress else { break }

                        let infoPtr = baseAddress.advanced(by: offset)
                        let nextEntryOffset = infoPtr.load(as: DWORD.self)
                        let action = infoPtr.advanced(by: 4).load(as: DWORD.self)
                        let fileNameLength = infoPtr.advanced(by: 8).load(as: DWORD.self)

                        // File name starts at offset 12 (after NextEntryOffset, Action, FileNameLength)
                        let fileNamePtr = infoPtr.advanced(by: 12).assumingMemoryBound(to: WCHAR.self)
                        let charCount = Int(fileNameLength) / MemoryLayout<WCHAR>.size

                        // Convert UTF-16 to String
                        let fileName = String(utf16CodeUnits: fileNamePtr, count: charCount)
                        let fileURL = watchDirectory.appendingPathComponent(fileName)

                        // Map Windows action to FileChangeEvent
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

                        // Move to next entry or break if this is the last one
                        if nextEntryOffset == 0 {
                            break
                        }
                        offset += Int(nextEntryOffset)
                    }
                }
            }
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
