import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

#if os(Windows)
@testable import FileMonitorWindows

@Suite struct WindowsWatcherTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String

    init() throws {
        dir = String.random(length: 10)
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func windowsWatcherInitialization() throws {
        defer { cleanup() }
        let directory = tmp.appendingPathComponent(dir)
        let watcher = try WindowsWatcher(directory: directory)
        #expect(watcher != nil)
    }

    @Test func windowsWatcherStartStop() throws {
        defer { cleanup() }
        let directory = tmp.appendingPathComponent(dir)
        var watcher = try WindowsWatcher(directory: directory)
        try watcher.observe()

        // Give it a moment to start
        Thread.sleep(forTimeInterval: 0.1)

        watcher.stop()
    }

    @Test func windowsWatcherDetectsFileCreation() async throws {
        defer { cleanup() }

        let directory = tmp.appendingPathComponent(dir)
        let testFile = directory.appendingPathComponent("\(String.random(length: 8)).txt")

        class TestDelegate: WatcherDelegate {
            let expectedFile: URL
            let onAdd: () -> Void

            init(expectedFile: URL, onAdd: @escaping () -> Void) {
                self.expectedFile = expectedFile
                self.onAdd = onAdd
            }

            func fileDidChanged(event: FileChangeEvent) {
                switch event {
                case .added(let file):
                    if file.lastPathComponent == expectedFile.lastPathComponent {
                        onAdd()
                    }
                default:
                    break
                }
            }
        }

        await confirmation("Wait for file creation") { confirmed in
            var watcher = try! WindowsWatcher(directory: directory)
            watcher.delegate = TestDelegate(expectedFile: testFile) {
                confirmed()
            }

            try! watcher.observe()

            // Create file after starting watcher
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                try? "test content".write(to: testFile, atomically: false, encoding: .utf8)
            }

            try? await Task.sleep(for: .seconds(5))
            watcher.stop()
        }
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}

#endif
