import XCTest

@testable import FileMonitor
import FileMonitorShared

#if os(Windows)
@testable import FileMonitorWindows

final class WindowsWatcherTests: XCTestCase {

    let tmp = FileManager.default.temporaryDirectory
    let dir = String.random(length: 10)

    override func setUpWithError() throws {
        super.setUp()
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        let directory = tmp.appendingPathComponent(dir)
        try FileManager.default.removeItem(at: directory)
    }

    func testWindowsWatcherInitialization() throws {
        let directory = tmp.appendingPathComponent(dir)
        let watcher = try WindowsWatcher(directory: directory)
        XCTAssertNotNil(watcher)
    }

    func testWindowsWatcherStartStop() throws {
        let directory = tmp.appendingPathComponent(dir)
        var watcher = try WindowsWatcher(directory: directory)
        try watcher.observe()

        // Give it a moment to start
        Thread.sleep(forTimeInterval: 0.1)

        watcher.stop()
    }

    func testWindowsWatcherDetectsFileCreation() throws {
        let expectation = expectation(description: "Wait for file creation")
        expectation.assertForOverFulfill = false

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

        var watcher = try WindowsWatcher(directory: directory)
        watcher.delegate = TestDelegate(expectedFile: testFile) {
            expectation.fulfill()
        }

        try watcher.observe()

        // Create file after starting watcher
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? "test content".write(to: testFile, atomically: false, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 10)
        watcher.stop()
    }
}

#endif
