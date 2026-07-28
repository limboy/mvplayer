import Foundation
import XCTest
@testable import MVPlayer

@MainActor
final class FolderLibraryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        storageURL = temporaryDirectory.appendingPathComponent("library.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testFolderNavigationFiltersAndSortsEntries() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        let nested = root.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("B.mkv"))
        try Data().write(to: root.appendingPathComponent("a.mp4"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertTrue(library.addFolders([root]))
        library.openRoot(library.roots[0])

        XCTAssertEqual(library.entries.map(\.name), ["Season 1", "a.mp4", "B.mkv"])
        XCTAssertEqual(library.visibleVideos.map(\.lastPathComponent), ["a.mp4", "B.mkv"])

        library.openFolder(nested)
        XCTAssertEqual(library.navigationPath.count, 2)
        library.goBack()
        XCTAssertEqual(library.currentDirectory, root.standardizedFileURL)
    }

    func testDuplicateRootsAreIgnoredAndPersisted() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertTrue(library.addFolders([root]))
        XCTAssertFalse(library.addFolders([root]))
        XCTAssertEqual(library.roots.count, 1)

        let restored = FolderLibrary(storageURL: storageURL, startWatching: false)
        XCTAssertEqual(restored.roots.count, 1)
        XCTAssertEqual(restored.roots[0].url, root.standardizedFileURL)
        XCTAssertTrue(restored.roots[0].isAvailable)
    }

    func testRefreshReflectsAddedAndRemovedVideos() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.mp4")
        let second = root.appendingPathComponent("second.webm")
        try Data().write(to: first)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        _ = library.addFolders([root])
        library.openRoot(library.roots[0])
        XCTAssertEqual(library.visibleVideos, [first.standardizedFileURL])

        try Data().write(to: second)
        try FileManager.default.removeItem(at: first)
        library.refreshAll()
        XCTAssertEqual(library.visibleVideos, [second.standardizedFileURL])
    }

    func testUnavailableRootCanBeRemoved() throws {
        let root = temporaryDirectory.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = FolderLibrary(storageURL: storageURL, startWatching: false)
        _ = library.addFolders([root])
        let id = library.roots[0].id
        try FileManager.default.removeItem(at: root)
        library.refreshAll()

        XCTAssertFalse(library.roots[0].isAvailable)
        library.removeRoot(id: id)
        XCTAssertTrue(library.roots.isEmpty)
    }
}
