import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

@Suite struct FileMonitorExplicitAddTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String

    init() throws {
        dir = String.random(length: 10)
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    struct AddWatcher: FileDidChangeDelegate {
        nonisolated(unsafe) static var fileChanges = 0
        nonisolated(unsafe) static var missedChanges = 0
        let callback: @Sendable () -> Void
        let file: URL

        init(on file: URL, completion: @escaping @Sendable () -> Void) {
            self.file = file
            callback = completion
        }

        func fileDidChanged(event: FileChangeEvent) {
            switch event {
            case .added(let fileInEvent):
                if file.lastPathComponent == fileInEvent.lastPathComponent {
                    AddWatcher.fileChanges = AddWatcher.fileChanges + 1
                    callback()
                }
            default:
                print("Missed", event)
                AddWatcher.missedChanges = AddWatcher.missedChanges + 1
            }
        }
    }

    @Test func lifecycleAdd() async throws {
        defer { cleanup() }

        await confirmation("Wait for file creation") { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent("\(String.random(length: 8)).\(String.random(length: 3))")
            let watcher = AddWatcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            AddWatcher.fileChanges = 0

            try! "hello".write(to: testFile, atomically: false, encoding: .utf8)
            #expect(FileManager.default.fileExists(atPath: testFile.path))

            try? await Task.sleep(for: .seconds(5))
        }

        #expect(AddWatcher.fileChanges == 1)
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}
