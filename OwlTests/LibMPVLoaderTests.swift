import CMPVShim
import XCTest
@testable import Owl

final class LibMPVLoaderTests: XCTestCase {
    func testInstalledLibraryLoadsWithCompatibleAPIVersion() throws {
        unsetenv("OWL_LIBMPV_PATH")
        let result = LibMPVLoader.createPlayer()
        switch result {
        case .success(let player, let info):
            XCTAssertEqual(info.apiMajor, 2)
            XCTAssertTrue(info.path.hasSuffix(".dylib"))
            mvp_mpv_destroy(player)
        case .failure(let error):
            throw XCTSkip("libmpv is not installed in this environment: \(error.localizedDescription)")
        }
    }

    func testMissingLibraryReportsActionableError() {
        setenv("OWL_LIBMPV_PATH", "/tmp/does-not-exist/libmpv.2.dylib", 1)
        defer { unsetenv("OWL_LIBMPV_PATH") }

        guard case .failure(let error) = LibMPVLoader.createPlayer() else {
            return XCTFail("An invalid override path should fail.")
        }
        XCTAssertTrue(error.localizedDescription.contains("OWL_LIBMPV_PATH"))
    }

    func testLibraryWithMissingSymbolsIsRejected() {
        setenv("OWL_LIBMPV_PATH", "/usr/lib/libSystem.B.dylib", 1)
        defer { unsetenv("OWL_LIBMPV_PATH") }

        guard case .failure(let error) = LibMPVLoader.createPlayer() else {
            return XCTFail("A non-mpv dynamic library should fail symbol validation.")
        }
        XCTAssertTrue(error.localizedDescription.contains("mpv_client_api_version"))
    }

    func testIncompatibleAPIVersionIsRejected() {
        let incompatible = UInt64(3 << 16)
        XCTAssertNotNil(LibMPVLoader.validate(apiVersion: incompatible))
        XCTAssertNil(LibMPVLoader.validate(apiVersion: UInt64((2 << 16) | 5)))
    }
}
