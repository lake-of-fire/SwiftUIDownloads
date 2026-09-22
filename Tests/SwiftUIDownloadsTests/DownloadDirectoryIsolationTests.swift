import Foundation
import XCTest
@testable import SwiftUIDownloads

#if DEBUG
final class DownloadDirectoryIsolationTests: XCTestCase {
    private let runID = "13f732b9-8782-4a74-9c8a-10bd5ec59e01"
    private let arguments = ["Reader", "--ui-test-isolated-data-root"]
    private let appTemp = URL(fileURLWithPath: "/fixture/app-container/tmp", isDirectory: true)

    private func resolve(_ directory: DownloadDirectory,
                         runID: String? = nil) throws -> URL? {
        try directory.isolatedUITestDirectoryURL(
            arguments: arguments,
            environment: ["MANABI_UI_TEST_DATA_ROOT_RUN_ID": runID ?? self.runID],
            temporaryDirectory: appTemp)
    }

    func testDictionaryDocumentsUseAppProcessRootAndPreserveSubdirectory() throws {
        let directory = DownloadDirectory.documents(
            parentDirectoryName: "manabi-dictionaries", subdirectoryName: "jmdict",
            groupIdentifier: "group.io.manabi.shared")
        XCTAssertEqual(try resolve(directory)?.path,
                       "/fixture/app-container/tmp/ManabiReaderUITests/\(runID)/app-group/manabi-dictionaries/jmdict")
    }

    func testAppSupportAndDefaultDocumentsKeepExistingDestinationLayout() throws {
        let support = DownloadDirectory.appSupport(
            parentDirectoryName: nil, groupIdentifier: "group.io.manabi.shared")
        let documents = DownloadDirectory.documents(
            parentDirectoryName: nil, subdirectoryName: "archive",
            groupIdentifier: "group.io.manabi.shared")
        let base = "/fixture/app-container/tmp/ManabiReaderUITests/\(runID)/app-group"
        XCTAssertEqual(try resolve(support)?.path, base)
        XCTAssertEqual(try resolve(documents)?.path, base + "/swiftui-downloads/archive")
    }

    func testFreshRunGetsSeparateRootWithoutCreatingDirectories() throws {
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: "fonts", groupIdentifier: "group.io.manabi.shared")
        let isolated = try XCTUnwrap(resolve(directory))
        let fresh = try XCTUnwrap(resolve(directory, runID: UUID().uuidString.lowercased()))
        XCTAssertNotEqual(isolated, fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testExplicitIsolationWinsOverRunnerAndSignedHarnessOverrides() throws {
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: "fonts", groupIdentifier: "group.io.manabi.shared")
        let actual = try directory.isolatedUITestDirectoryURL(
            arguments: arguments,
            environment: ["MANABI_UI_TEST_DATA_ROOT_RUN_ID": runID,
                          "MANABI_TEST_APP_GROUP_DIR": "/fixture/runner-container/tmp",
                          "JVIDS_MANABI_DATA_ROOT": "/fixture/stale-signed-run"],
            temporaryDirectory: appTemp)
        XCTAssertEqual(actual, try resolve(directory))
    }

    func testMalformedIsolatedIdentityCannotFallThroughToSharedStorage() {
        let directory = DownloadDirectory.documents(
            parentDirectoryName: nil, groupIdentifier: "group.io.manabi.shared")
        for value in [nil, "", runID.uppercased(), "../escape", "not-a-uuid"] {
            var environment = ["MANABI_TEST_APP_GROUP_DIR": "/fixture/shared"]
            environment["MANABI_UI_TEST_DATA_ROOT_RUN_ID"] = value
            XCTAssertThrowsError(try directory.isolatedUITestDirectoryURL(
                arguments: arguments, environment: environment,
                temporaryDirectory: appTemp)) { error in
                XCTAssertTrue(error is DownloadDirectory.IsolatedUITestDirectoryError)
            }
        }
    }

    func testOrdinaryLaunchAndNongroupDestinationsRemainUnchanged() throws {
        let groupDirectory = DownloadDirectory.appSupport(
            parentDirectoryName: nil, groupIdentifier: "group.io.manabi.shared")
        XCTAssertNil(try groupDirectory.isolatedUITestDirectoryURL(
            arguments: ["Reader"], environment: ["MANABI_UI_TEST_DATA_ROOT_RUN_ID": runID],
            temporaryDirectory: appTemp))
        let personal = DownloadDirectory.documents(parentDirectoryName: nil, groupIdentifier: nil)
        XCTAssertNil(try resolve(personal))
    }
}
#endif
