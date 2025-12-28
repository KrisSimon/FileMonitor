import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

@Suite struct FileMonitorExplicitDeleteTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String
    let testFileName: String

    init() throws {
        dir = String.random(length: 10)
        testFileName = "\(String.random(length: 8)).\(String.random(length: 3))"

        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let testFile = tmp.appendingPathComponent(dir).appendingPathComponent(testFileName)
        try "to remove".write(to: testFile, atomically: false, encoding: .utf8)
    }

    struct DeleteWatcher: FileDidChangeDelegate {
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
            case .deleted(let fileInEvent):
                if file.lastPathComponent == fileInEvent.lastPathComponent {
                    DeleteWatcher.fileChanges = DeleteWatcher.fileChanges + 1
                    callback()
                }
            default:
                print("Missed", event)
                DeleteWatcher.missedChanges = DeleteWatcher.missedChanges + 1
            }
        }
    }

    @Test func lifecycleDelete() async throws {
        defer { cleanup() }

        await confirmation("Wait for file deletion") { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent(testFileName)
            let watcher = DeleteWatcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            DeleteWatcher.fileChanges = 0

            try! FileManager.default.removeItem(at: testFile)
            #expect(!FileManager.default.fileExists(atPath: testFile.path))

            try? await Task.sleep(for: .seconds(5))
        }

        #expect(DeleteWatcher.fileChanges == 1)
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}
