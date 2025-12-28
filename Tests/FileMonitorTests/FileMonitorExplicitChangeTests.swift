import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

@Suite struct FileMonitorExplicitChangeTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String
    let testFileName: String

    init() throws {
        dir = String.random(length: 10)
        testFileName = "\(String.random(length: 8)).\(String.random(length: 3))"

        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let testFile = tmp.appendingPathComponent(dir).appendingPathComponent(testFileName)
        try "hello".write(to: testFile, atomically: false, encoding: .utf8)
    }

    struct ChangeWatcher: FileDidChangeDelegate {
        nonisolated(unsafe) static var fileChanges = 0
        nonisolated(unsafe) static var missedChanges = 0
        let callback: () -> Void
        let file: URL

        init(on file: URL, completion: @escaping () -> Void) {
            self.file = file
            callback = completion
        }

        func fileDidChanged(event: FileChangeEvent) {
            switch event {
            case .changed(let fileInEvent):
                if file.lastPathComponent == fileInEvent.lastPathComponent {
                    ChangeWatcher.fileChanges = ChangeWatcher.fileChanges + 1
                    callback()
                }
            default:
                print("Missed", event)
                ChangeWatcher.missedChanges = ChangeWatcher.missedChanges + 1
            }
        }
    }

    @Test func lifecycleChange() async throws {
        defer { cleanup() }

        await confirmation("Wait for file change") { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent(testFileName)
            let watcher = ChangeWatcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            ChangeWatcher.fileChanges = 0

            let fileHandle = try! FileHandle(forWritingTo: testFile)
            try! fileHandle.seekToEnd()
            fileHandle.write("append some text".data(using: .utf8)!)
            try! fileHandle.close()

            try? await Task.sleep(for: .seconds(5))
        }

        #expect(ChangeWatcher.fileChanges == 1)
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}
