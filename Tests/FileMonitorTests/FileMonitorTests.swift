import Testing
import Foundation

@testable import FileMonitor
import FileMonitorShared

@Suite struct FileMonitorTests {

    let tmp = FileManager.default.temporaryDirectory
    let dir: String

    init() throws {
        dir = String.random(length: 10)
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func initModule() throws {
        defer { cleanup() }
        _ = try FileMonitor(directory: FileManager.default.temporaryDirectory)
    }

    struct Watcher: FileDidChangeDelegate {
        nonisolated(unsafe) static var fileChanges = 0
        let callback: @Sendable () -> Void
        let file: URL

        init(on file: URL, completion: @escaping @Sendable () -> Void) {
            self.file = file
            callback = completion
        }

        func fileDidChanged(event: FileChangeEvent) {
            switch event {
            case .changed(let fileInEvent), .deleted(let fileInEvent), .added(let fileInEvent):
                if file.lastPathComponent == fileInEvent.lastPathComponent {
                    Watcher.fileChanges = Watcher.fileChanges + 1
                    callback()
                }
            }
        }
    }

    @Test func lifecycleCreate() async throws {
        defer { cleanup() }

        await confirmation("Wait for file creation") { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent("\(String.random(length: 8)).\(String.random(length: 3))")
            let watcher = Watcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            Watcher.fileChanges = 0

            FileManager.default.createFile(atPath: testFile.path, contents: "hello".data(using: .utf8))

            try? await Task.sleep(for: .seconds(5))
        }

        #expect(Watcher.fileChanges > 0)
    }

    @Test func lifecycleChange() async throws {
        defer { cleanup() }

        await confirmation("Wait for file change", expectedCount: 1...) { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent("\(String.random(length: 8)).\(String.random(length: 3))")
            FileManager.default.createFile(atPath: testFile.path, contents: "hello".data(using: .utf8))

            let watcher = Watcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            Watcher.fileChanges = 0

            try! "Next New Content".write(toFile: testFile.path, atomically: true, encoding: .utf8)

            try? await Task.sleep(for: .seconds(5))
            monitor.stop()
        }

        #expect(Watcher.fileChanges > 0)
    }

    @Test func lifecycleChangeAsync() async throws {
        defer { cleanup() }

        let testFile = tmp.appendingPathComponent(dir).appendingPathComponent("\(String.random(length: 8)).\(String.random(length: 3))")
        FileManager.default.createFile(atPath: testFile.path, contents: "hello".data(using: .utf8))

        let monitor = try FileMonitor(directory: tmp.appendingPathComponent(dir))
        try monitor.start()

        var events = [FileChange]()

        Task {
            try? await Task.sleep(for: .seconds(2))
            try? "New Content".write(toFile: testFile.path, atomically: true, encoding: .utf8)
        }

        for await event in monitor.stream {
            events.append(event)
            monitor.stop()
            break
        }

        #expect(events.count > 0)
    }

    @Test func lifecycleDelete() async throws {
        defer { cleanup() }

        await confirmation("Wait for file deletion") { confirmed in
            let testFile = tmp.appendingPathComponent(dir).appendingPathComponent("\(String.random(length: 8)).\(String.random(length: 3))")
            FileManager.default.createFile(atPath: testFile.path, contents: "hello".data(using: .utf8))

            let watcher = Watcher(on: testFile) { confirmed() }

            let monitor = try! FileMonitor(directory: tmp.appendingPathComponent(dir), delegate: watcher)
            try! monitor.start()
            Watcher.fileChanges = 0

            try! FileManager.default.removeItem(at: testFile)

            try? await Task.sleep(for: .seconds(5))
        }

        #expect(Watcher.fileChanges > 0)
    }

    private func cleanup() {
        let directory = tmp.appendingPathComponent(dir)
        try? FileManager.default.removeItem(at: directory)
    }
}
