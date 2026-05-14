//
// aus der Technik, on 19.05.23.
//

import Foundation
#if canImport(CInotify)
import CInotify
#endif

#if os(Linux)
public final class FileSystemWatcher: @unchecked Sendable {
    // inotify_init() initialises a new inotify instance and returns a
    // file descriptor associated with a new inotify event queue.
    private let fileDescriptor: Int32

    // Private serial queue keyed to the watcher instance. The previous
    // implementation used `DispatchQueue.global(qos: .background)` and tried
    // to `activate()` / `suspend()` it; both are undefined behaviour on a
    // system-shared global queue, and `.background` QoS gives the reader
    // thread the lowest priority — under CI load the inotify read loop was
    // starved, events sat in the kernel queue past the test confirmation
    // budget, and tests timed out.
    private let readerQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var watchDescriptor: Int32 = 0
    private let stateLock = NSLock()
    private var _shouldStopWatching: Bool = false

    private var shouldStopWatching: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _shouldStopWatching }
        set { stateLock.lock(); _shouldStopWatching = newValue; stateLock.unlock() }
    }

    public init() {
        // userInitiated so a CPU-loaded CI runner still services the read.
        // Reader and callback queues are separate so a slow callback can't
        // block the reader from draining the kernel queue.
        readerQueue   = DispatchQueue(label: "aus.dertechnik.FileMonitor.reader",
                                      qos: .userInitiated)
        callbackQueue = DispatchQueue(label: "aus.dertechnik.FileMonitor.callback",
                                      qos: .userInitiated)
        fileDescriptor = inotify_init()
        if fileDescriptor < 0 {
            fatalError("Failed to initialize inotify")
        }
    }

    deinit {
        stop()
    }

    public func start() {
        shouldStopWatching = false
    }

    public func stop() {
        shouldStopWatching = true

        // Remove the watch so the kernel stops queueing events. Then close
        // the fd, which wakes any thread blocked in `read()` with EOF/EBADF
        // — the previous version `suspend()`ed the global queue, which only
        // froze new work and left the blocked reader thread alive forever.
        if watchDescriptor > 0 {
            inotify_rm_watch(fileDescriptor, watchDescriptor)
            watchDescriptor = 0
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    @discardableResult
    public func watch(path: String, for mask: InotifyEventMask, thenInvoke callback: @escaping @Sendable (InotifyEvent) -> Void) -> Int32 {
        watchDescriptor = inotify_add_watch(fileDescriptor, path, mask.rawValue)

        // 4 KiB buffer — Linux's inotify(7) man page recommends "sizeof(struct
        // inotify_event) + NAME_MAX + 1" *as a minimum* and notes that bursts
        // are easier to drain with a larger buffer. The old 272-byte buffer
        // fit exactly one event of max name length and forced an extra read
        // per event, lengthening the window during which a full kernel queue
        // could drop events.
        let bufferLength = 4096
        let fd = fileDescriptor

        readerQueue.async { [weak self] in
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferLength)
            defer { buffer.deallocate() }

            while let self, !self.shouldStopWatching {
                let readLength = read(fd, buffer, bufferLength)
                if readLength <= 0 {
                    // EOF or error — either we're stopping (fd closed) or
                    // the kernel gave us a transient error. Either way,
                    // exit cleanly; the loop's outer guard handles stop.
                    break
                }

                var currentIndex = 0
                while currentIndex < readLength {
                    let event = withUnsafePointer(to: &buffer[currentIndex]) {
                        $0.withMemoryRebound(to: inotify_event.self, capacity: 1) {
                            $0.pointee
                        }
                    }

                    if event.len > 0 {
                        let inotifyEvent = InotifyEvent(
                            watchDescriptor: Int(event.wd),
                            mask: event.mask,
                            cookie: event.cookie,
                            length: event.len,
                            name: String(cString: buffer + currentIndex + MemoryLayout<inotify_event>.size)
                        )

                        self.callbackQueue.async {
                            callback(inotifyEvent)
                        }
                    }

                    currentIndex += MemoryLayout<inotify_event>.stride + Int(event.len)
                }
            }
        }

        return watchDescriptor
    }
}
#endif
