import Foundation
import XCTest

@testable import AgentWatchApp

extension XCTestCase {
    /// A settings file of this test's own, in a folder removed when the test ends.
    ///
    /// This replaced a `UserDefaults` suite, and the reason is worth keeping: `cfprefsd`
    /// writes a file per suite into `~/Library/Preferences` and nothing a test can call takes
    /// it away again — `removePersistentDomain`, `removeSuite` and deleting the file by hand
    /// all leave one behind, the last because the daemon writes it back at exit. Over 2500 of
    /// them had collected in the running person's home folder. A file in the temporary folder
    /// is deleted by asking, needs no cross-process lock, and cannot outlive the test.
    func isolatedPreferences() throws -> PreferenceFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchPreferences.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PreferenceFile(directoryURL: directory)
    }
}
